#!/usr/bin/env bash
# ==============================================================================
#  🩺 CI 检查统一入口：发布前门禁 + 每日巡检（published）+ 上游漂移检测（drift）
#
#  用法：check.sh <子命令> [参数]；不带子命令等价于 all（仍需 <镜像> <期望版本>）
#    core 功能完整性｜degrade 只读降级｜upgrade 版本护栏｜restore 备份恢复
#    published 已发布镜像回归｜drift 上游目录漂移｜all 四套门禁全跑｜help 显示用法
#    lint <子命令> 静态检查｜report [报告] [标记] 注入 README 报告区
#
#  为什么合成一份：公共样板与入口分发原本散在 8 个文件里，每套都抄一遍头部
#    胶水；现在每套是一个子 shell 函数，变量与 trap 互不污染，断言逐字保留。
#  判据见 docs/development.md「发布前检查覆盖什么」。
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
CHECK_SELF="$ROOT/.github/scripts/check.sh"
DEFAULTS_ENV="${DEFAULTS_ENV:-$ROOT/image/conf/defaults.env}"


# ---------------------------------------------------------------------------
#  公共样板：配置解析 / 输出 / 容器操作 / 等待 / 启动 / 清理
#  各子命令共用；调用前需设置 CONTAINER（可选 VOLUME / VOL_RO / WORK_ROOT / ICON）
# ---------------------------------------------------------------------------

# 配置真源：与镜像共用 image/conf/defaults.env，不在脚本里再写一份硬编码。
# 两边一旦漂移，表现是「CI 测过的和线上跑的不是同一套目录」，必须在这里对齐。
# 默认值里可能含嵌套引用（如 PANEL_STATE_ROOT="${PERSIST_DATA_ROOT}/panel"），
# sed 取值不会展开，expand_vars 用间接展开补一层；否则拿到的是字面量
# ${PERSIST_DATA_ROOT}/panel，路径全错。被引用的变量（PERSIST_DATA_ROOT 等）
# 已先用 read_default 取过，间接展开时已存在于环境。
#
# 注：upgrade 原先是「不展开」的简化版，只因它当时只取不含嵌套引用的
# PERSIST_SYSTEM_ROOT；统一成展开版后行为不变，且以后取到嵌套引用也不会踩坑
expand_vars() {
    local s="$1" name
    while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        name="${BASH_REMATCH[1]}"
        s="${s//\${$name\}/${!name}}"
    done
    echo "$s"
}

# 唯一解析式：sed 原样取值（不展开嵌套引用），head 只取第一条
read_raw_default() { sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" "$DEFAULTS_ENV" | head -n 1; }
# 需要展开嵌套引用时用这个（被引用变量须先取过，见上方注释）
read_default() { expand_vars "$(read_raw_default "$1")"; }

pass() { echo "  ✅ $*"; }
step() { echo; echo "${ICON:-🩺} ==== $* ===="; }
fail() {
    echo "::error::$*"
    echo "----- 容器日志尾部 -----"
    docker logs "${CONTAINER}" --tail 150 2>/dev/null || true
    echo "----- 日志结束 -----"
    exit 1
}

# 收尾：按各子命令实际用到的资源名清理，没设置的直接跳过。
# 用 ${VAR:-} 而不是 $VAR —— 各 run_* 子 shell 都开着 set -u，
# 且清理会在某个子命令还没赋值到对应资源时触发
cleanup() {
    [ -n "${CONTAINER:-}" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    [ -n "${VOLUME:-}" ]    && docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
    [ -n "${VOL_RO:-}" ]    && docker volume rm -f "$VOL_RO" >/dev/null 2>&1 || true
    [ -n "${WORK_ROOT:-}" ] && rm -rf "$WORK_ROOT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 容器内操作的简写
#   inside      直接执行一条命令
#   inside_sh   在容器里起 sh 执行（需要管道、重定向、通配时用）
#   inside_cat  读取文件内容并去掉全部空白
# ---------------------------------------------------------------------------
inside()     { docker exec "$CONTAINER" "$@"; }
inside_sh()  { docker exec "$CONTAINER" sh -c "$1"; }
inside_cat() { docker exec "$CONTAINER" cat "$1" 2>/dev/null | tr -d '[:space:]' || true; }

# ---------------------------------------------------------------------------
# 无持久化降级 —— core / upgrade / restore 三套共用的断言
#
# 判据是**运行态标记文件**而不是日志文案：init.sh 在任何持久化失败 / 只读降级
# 时都写 /run/baota/degraded，CRITICAL_DIRS 里的目录额外写 critical。
# 这样告警文案怎么改都不影响门禁，也不会漏掉「挂载直接失败」这一类情况。
# ---------------------------------------------------------------------------
assert_no_degraded() {
    if inside test -e /run/baota/critical; then
        fail "关键目录未持久化（/run/baota/critical 存在），数据写入会静默丢失"
    fi
    if inside test -e /run/baota/degraded; then
        fail "存在未持久化目录（/run/baota/degraded）：$(inside cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
    fi
    pass "无持久化降级"
}

is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = 'true' ]
}

# docker logs | grep -q 在 pipefail 下会误判失败：grep -q 一命中就退出并关闭
# 管道，docker logs 写不完剩余输出被 SIGPIPE 终止（141），pipefail 把命中当成
# 失败。用 `{ grep -q && cat >/dev/null; }` 读干净管道，生产者正常收尾。
# grep 未命中时会读完整个输入才退出，同样不会触发 SIGPIPE
logs_match() {
    docker logs "$CONTAINER" 2>&1 | { grep -q -- "$1" && cat > /dev/null; }
}

# ---------------------------------------------------------------------------
# IMAGE 等由各 run_* 子 shell 在调用公共函数前赋值；shellcheck 静态分析
# 看不到跨子 shell 的赋值，属误报
# shellcheck disable=SC2154
# 启动参数必须与 docker-compose.yml 保持一致，否则测的不是生产配置：
#   privileged   overlay 挂载 + systemd
#   tmpfs        仅 /run 与 /run/lock，/tmp 留在容器可写层
#   不带 --cgroupns=host：让 Docker 按宿主机 cgroup 版本自动选择
# ---------------------------------------------------------------------------
start_container() {
    docker run -d --name "$CONTAINER" \
        --privileged \
        --tmpfs /run --tmpfs /run/lock \
        --shm-size=512m \
        --stop-signal=SIGRTMIN+3 \
        --ulimit nofile=65535:65535 --ulimit nproc=65535 \
        -v "${VOLUME}:/data" \
        "$IMAGE" >/dev/null || fail "容器无法启动"
}

# degraded 在容器里属常见（个别 unit 被 mask），放行
wait_systemd() {
    local state="" tries=0
    while [ "$tries" -lt 90 ]; do
        state=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$state" in
        running)  pass "systemd: running" ;;
        degraded) pass "systemd: degraded（容器内属常见，放行）" ;;
        *)        fail "systemd 未就绪：${state:-无响应}" ;;
    esac
}

# 面板进程由 systemd 拉起，需要等一会儿才会监听端口
#
# ⚠️ curl 失败时 -w 仍会输出 000，写成 `|| echo 000` 会得到两行 000 ——
#    永远不等于 "000"，等待循环第一次就 break：面板没起来时既不等待也不报错。
#    正确写法是 `|| true` + case 匹配。
#
# 就绪判据与 healthcheck.sh 同一套语义：'' / 000 之外，5xx 也算「还没起来」
# （502 = nginx 已起、面板后端未起，是启动瞬态，要继续等而不是当成就绪）。
# 失败时一次把证据打全（磁盘满与面板本身故障表象一样、修法完全不同），
# 别让人对着一行「端口没响应」猜
panel_diag() {
    echo "----- 面板启动失败取证 -----"
    echo "[磁盘水位] 判据②：可用 <1GB 或已用 ≥95% 即 unhealthy"
    # ${PERSIST_SYSTEM_ROOT:-} 是空值保护（本文件可能在它赋值前被 source），
    # 不是默认值副本 —— 真正的默认值只在 defaults.env
    inside_sh "df -Ph /data ${PERSIST_SYSTEM_ROOT:-} 2>/dev/null" || true
    echo "[监听端口]"
    inside_sh 'ss -lntp 2>/dev/null | head -10' || true
    echo "[systemd 失败单元]"
    inside_sh 'systemctl --failed --no-legend 2>/dev/null | head -10' || true
    echo "[面板日志尾部]"
    inside_sh 'tail -n 25 /www/server/panel/logs/error.log 2>/dev/null \
               || tail -n 25 /www/server/panel/logs/*.log 2>/dev/null' || true
    echo "----- 取证结束 -----"
}

wait_panel_http() {
    local port code="" tries=0
    port=$(inside_cat /www/server/panel/data/port.pl)
    [ -n "$port" ] || fail "无法确定面板端口"
    while [ "$tries" -lt 60 ]; do
        code=$(inside curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || true)
        case "$code" in ''|000|5*) ;; *) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$code" in
        ''|000|5*) panel_diag; fail "面板端口 ${port} 在 120 秒内没有响应（或返回 ${code}）" ;;
    esac
}


# ---------------------------------------------------------------------------
#  core：功能完整性：启动、持久化落盘、面板代码隔离、守卫、备份、销毁重建
#  断言逐字保留；公共样板在本文件顶部，资源回收由本函数内的 trap 负责
# ---------------------------------------------------------------------------
run_core() (
    trap cleanup EXIT
set -euo pipefail

IMAGE=${1:?用法: check.sh core <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: check.sh core <镜像> <期望版本>}

CONTAINER="baota-healthcheck-$$"
VOLUME="baota-healthcheck-data-$$"
# ICON 供 公共样板段 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🩺'

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 启动 / 清理）见 公共样板段

# 目录与「根」全部取自 image/conf/defaults.env —— 落盘路径由根派生，
# 避免硬编码漂移
PERSIST_SYSTEM_DIRS=$(read_default PERSIST_SYSTEM_DIRS)
[ -n "${PERSIST_SYSTEM_DIRS}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_SYSTEM_DIRS"; exit 1; }
WWW_DATA_SUBDIRS=$(read_default WWW_DATA_SUBDIRS)
[ -n "${WWW_DATA_SUBDIRS}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 WWW_DATA_SUBDIRS"; exit 1; }
PANEL_STATE_SUBDIRS=$(read_default PANEL_STATE_SUBDIRS)
[ -n "${PANEL_STATE_SUBDIRS}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PANEL_STATE_SUBDIRS"; exit 1; }
# 三个「根」也读真源：落盘路径由根派生，避免硬编码漂移
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
PANEL_STATE_ROOT=$(read_default PANEL_STATE_ROOT)
META_BOOT_FILE=$(read_default META_BOOT_FILE)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }
[ -n "${PANEL_STATE_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PANEL_STATE_ROOT"; exit 1; }
[ -n "${META_BOOT_FILE}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 META_BOOT_FILE"; exit 1; }

# 面板运行状态（输出带颜色码，去掉后再判断）。
# 面板与任务两个进程共用这一次调用的结果，不重复执行 bt status
panel_status() {
    inside bt status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true
}

assert_processes_up() {
    local status="$1"
    echo "$status" | grep -q 'Bt-Panel .*already running' || fail "面板进程未运行"
    echo "$status" | grep -q 'Bt-Task .*already running'  || fail "任务进程未运行"
}

# start_container / wait_systemd / wait_panel_http 见 公共样板段

# 只读降级是本方案最危险的失效模式：挂载会「成功」，但所有写入静默丢失。
# 判据读容器内的降级标记文件（assert_no_degraded 见 公共样板段），不 grep 日志文案

# 面板状态漂移报告（不对抗上游版）：面板代码来自镜像层、不持久化，运行期写入
# 只落容器可写层，docker pull 新镜像时被整体丢弃。我们要暴露「持久化声明的盲区」——
# 上游把状态写到了镜像里原本没有、我们也没声明进 PANEL_STATE_SUBDIRS 的全新位置。
# 怎么判断「镜像里原本有没有」：不靠手写白名单猜上游瞬态目录（那是在对抗上游），
# 而是直接问镜像本身——起临时容器 ls 镜像里 /www/server/panel 顶层目录作客观基线。
# 镜像里已有的目录（class/config/logs/…）上的写入可再升、升级会重铺，不算盲区；
# 只有镜像里不存在的全新顶层目录上的写入，才可能是漏声明的状态。
# 只报告不阻断：确认需持久化就加进 PANEL_STATE_SUBDIRS。
report_panel_state_drift() {
    local line path rel top
    local -a found=()
    # 镜像里 /www/server/panel 的顶层目录，作为「哪些是面板自带代码目录」的客观基线
    local image_tops
    image_tops=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
        'cd /www/server/panel 2>/dev/null && for x in */; do echo "${x%/}"; done' 2>/dev/null || true)
    image_tops=" $(printf '%s' "$image_tops" | tr '\n' ' ' | sed 's/ *$//') "

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # 删除（D）是镜像自带内容被删，升级会重新铺上，不是持久化盲区
        case "$line" in 'D '*) continue ;; esac
        path=${line#* }                                  # 去掉 A/C/D 前缀
        case "$path" in /www/server/panel/*) ;; *) continue ;; esac
        rel=${path#/www/server/panel/}
        # 只关心落在子目录里的写入；顶层文件（如 default.pl）是面板代码 / 已知瞬态，
        # 不在越界盲区之列
        case "$rel" in */*) ;; *) continue ;; esac
        top=${rel%%/*}
        # 已声明持久化的子目录：有意为之，不算盲区
        case " ${PANEL_STATE_SUBDIRS} " in *" ${top} "*) continue ;; esac
        # 镜像里本来就有的目录（class/config/logs/…）：写入可再生、升级会丢弃，不算盲区
        case "$image_tops" in *" ${top} "*) continue ;; esac
        # 其余：镜像里不存在的全新顶层目录上的写入，才是我们漏声明的状态位置
        found+=("$line")
    done < <(docker diff "$CONTAINER" 2>/dev/null || true)

    if [ "${#found[@]}" -gt 0 ]; then
        echo "::warning::面板在镜像层之外新建了顶层目录并写入（升级会被丢弃），请确认是否需持久化："
        printf '  %s\n' "${found[@]}"
        echo "  需保留的话，请加进 image/conf/defaults.env 的 PANEL_STATE_SUBDIRS"
    else
        pass "面板未在镜像层之外新建越界状态（新建写入均落在镜像已有目录或 PANEL_STATE_SUBDIRS 内）"
    fi
}

# ==============================================================================
#  🅰️ A 阶段：全新数据卷
# ==============================================================================
step "A0) 启动容器（与生产一致的运行条件）"
docker volume create "$VOLUME" >/dev/null
start_container
pass "容器已启动"

step "A1) 等待 systemd 就绪"
wait_systemd

step "A2) 校验 overlay 持久化"
assert_no_degraded
MOUNTED=$(inside_sh "mount | grep -c 'type overlay'" || true)
MOUNTED=${MOUNTED:-0}
# overlay 只用于系统层各目录；面板代码不再 overlay，业务与面板状态走 bind
EXPECT_MOUNTS=$(echo "$PERSIST_SYSTEM_DIRS" | wc -w)
[ "$MOUNTED" -ge "$EXPECT_MOUNTS" ] \
    || fail "overlay 挂载数 ${MOUNTED}，期望至少 ${EXPECT_MOUNTS} 个"
pass "overlay 挂载 ${MOUNTED} 个，无只读告警"

# 系统层 upper 落在「系统层根/<dir>」
for d in $PERSIST_SYSTEM_DIRS; do
    inside test -d "${PERSIST_SYSTEM_ROOT}/${d}" || fail "持久化目录缺失：${PERSIST_SYSTEM_ROOT}/${d}"
done
# 业务子目录的绑定源在「数据层根/www/<子目录>」
for t in $WWW_DATA_SUBDIRS; do
    inside test -d "${PERSIST_DATA_ROOT}/www/${t}" \
        || fail "业务绑定源缺失：${PERSIST_DATA_ROOT}/www/${t}"
done
# 面板状态的绑定源在「面板状态根/<子目录>」
for t in $PANEL_STATE_SUBDIRS; do
    inside test -d "${PANEL_STATE_ROOT}/${t}" \
        || fail "面板状态绑定源缺失：${PANEL_STATE_ROOT}/${t}"
done
pass "系统层 upper 与业务/面板状态绑定源齐备"

# 不可变面板的核心性质：面板代码必须来自镜像、且写入不落持久化层。
# /www/server 现在走 overlay（组件、cron 脚本、插件数据持久化），面板目录则被
# init.sh 用镜像绑定盖回，所以这里查的不是「有没有挂载」，而是「写入去哪了」
inside_sh "mount | grep -q ' on /www/server/panel '" \
    || fail "/www/server/panel 未被镜像绑定覆盖：面板代码会落进持久化层"
inside_sh 'echo probe > /www/server/panel/_code_probe'
if inside test -e "${PERSIST_SYSTEM_ROOT}/www/server/panel/_code_probe"; then
    fail "面板代码写进了持久化层（${PERSIST_SYSTEM_ROOT}/www/server/panel）：换镜像将无法更新面板"
fi
inside_sh 'rm -f /www/server/panel/_code_probe'
pass "面板代码来自镜像、不落持久化层（组件与插件数据则落在 ${PERSIST_SYSTEM_ROOT}/www/server）"

# 隔离标记（init.sh 在 bind 回成功后写下 /run/baota/panel-isolated）：把「隔离是否
# 生效」变成可断言的状态，而不只是启动日志里的一句文案 —— 两者此前出现过不一致
# （日志误报「未隔离」而实际是隔离的），只有标记能让这类不一致在门禁里直接变红
inside test -e /run/baota/panel-isolated \
    || fail "缺少面板隔离标记 /run/baota/panel-isolated：面板代码可能落进持久化层"
pass "面板隔离标记存在（隔离结论与真实挂载结果一致）"

# pyenv 覆盖层：pip 包持久化 + 解释器随镜像更新（init.sh 在面板 bind 回之后挂）。
# 少它一层的表现是「插件代码在、pip 依赖丢」，而面板不会提示重装 ——
# 这种静默坏功能必须拦在发布前
inside_sh "mount | grep -q ' on /www/server/panel/pyenv type overlay '" \
    || fail "pyenv 未挂覆盖层：插件 pip 包重建后会丢（期望 upper 在 ${PANEL_STATE_ROOT}/pyenv）"
inside test -d "${PANEL_STATE_ROOT}/pyenv" \
    || fail "pyenv 覆盖层 upper 缺失：${PANEL_STATE_ROOT}/pyenv"
pass "pyenv 覆盖层已挂载（pip 包持久化，解释器随镜像更新）"

# 同一份 data 只能给一个容器用。本项目已移除持久化独占锁，不再拦截第二个
# 实例；第二实例会因内核禁止两个 overlay 共用 upper 而进入降级态，故这里
# 不对「必须被拦下并退出」做断言（见 docs/faq.md）。

# /tmp 必须留在容器可写层：变成 tmpfs 会让上传、解压备份直接吃内存
if inside_sh 'grep -q " /tmp " /proc/mounts'; then
    fail "/tmp 被单独挂载（应留在容器可写层）"
fi
pass "/tmp 未被 tmpfs 化"

# compose 的 healthcheck 判据已收口到镜像内 /baota/healthcheck.sh，
# 这里直接执行它，等于在真实容器里跑一遍生产健康检查（降级标记 / 磁盘水位 / 端口）
step "A3) 执行生产健康检查脚本"
inside test -x /baota/healthcheck.sh \
    || fail "healthcheck 脚本缺失或不可执行（compose 将永远 unhealthy）"
# 三段判据（降级标记 / 磁盘水位 / 面板端口）共用一个非零退出码，光看它无法
# 区分是「持久化降级」「磁盘快满」还是「面板没起来」，而这三种的修法完全
# 不同。失败时逐段复跑，把原因钉死在日志里
if ! inside /baota/healthcheck.sh; then
    echo "----- healthcheck 三段判据取证 -----"
    inside test -f /run/baota/critical \
        && echo "[① 降级标记] 存在：/run/baota/critical" \
        || echo "[① 降级标记] 无"
    echo "[② 磁盘水位] 判据：可用 <1GB 或已用 ≥95% 即 unhealthy"
    inside_sh "df -Ph ${PERSIST_DATA_ROOT} ${PERSIST_SYSTEM_ROOT} 2>/dev/null" || true
    echo "[③ 面板端口]"
    inside_sh 'p=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo 8888); \
               curl -sk --max-time 5 -o /dev/null -w "http_code=%{http_code}\n" \
               "http://127.0.0.1:${p}/login" 2>/dev/null' || true
    panel_diag
    fail "healthcheck 在正常状态下未通过（见上面三段判据取证）"
fi
pass "healthcheck 三段判据在正常状态下通过"

step "A4) 校验宝塔关键文件（真机上的实际路径）"
# 面板主程序单独用 glob 检查：bt7.init 用 ps|grep 匹配命令行里的面板名判断
# 「是否已在运行」，探活命令里出现该字面量会被误判，所以统一写 BT-P*
# （与 image/build/panel.sh 一致）。glob 必须在容器内展开 —— 宿主上没有 /www
inside_sh 'ls /www/server/panel/BT-P* >/dev/null 2>&1' \
    || fail "缺少面板主程序：/www/server/panel/BT-P*"
for f in /www/server/panel/BT-Task \
         /www/server/panel/pyenv/bin/python \
         /etc/init.d/bt \
         /usr/bin/bt \
         /var/bt_setupPath.conf \
         /www/server/panel/data/port.pl \
         /www/server/panel/data/admin_path.pl; do
    inside test -e "$f" || fail "缺少关键文件：${f}"
done
pass "关键文件齐备"

# pyenv 完整性：arm64 构建下 pip 安装 psutil / pyinotify 可能静默失败
# （实测：默认 pypi 源超时后安装脚本继续跑完，最后才报「宝塔启动失败」，
#  排查方向极易被带偏到 systemd）。这里显式断言，坏镜像在发布前就被拦住
inside /www/server/panel/pyenv/bin/python -c "import psutil, pyinotify" 2>/dev/null \
    || fail "pyenv 缺少关键模块（psutil/pyinotify），面板将无法启动（常见于 arm64 构建）"
pass "pyenv 关键模块齐备（psutil / pyinotify）"

step "A5) 校验面板双进程"
# 真机上宝塔就是「面板 + 任务」两个常驻进程，缺一不可（任务进程负责计划任务与后台作业）。
# 用宝塔自带的 bt status 判断，避免自己写 ps|grep 反而干扰 bt 脚本的进程判定
wait_panel_http
assert_processes_up "$(panel_status)"
pass "面板与任务进程均在运行"

step "A6) 校验面板 HTTP（端口可达 + 安全入口生效）"
PORT=$(inside_cat /www/server/panel/data/port.pl)
SAFE=$(inside_cat /www/server/panel/data/admin_path.pl)
URL="http://127.0.0.1:${PORT}${SAFE}/login"
# 宝塔对 127.0.0.1 无 cookie 的探测会判为「陌生 IP」返回 404（防爆破特性，
# 进程实际在监听），故面板可访问性以「非 000、非 5xx」判定，与 /baota/
# healthcheck.sh 语义一致；端口/进程真挂时才返回 000 或 5xx
CODE=$(inside curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || true)
case "$CODE" in
    ''|000|5*) fail "登录页 ${URL} 返回 ${CODE:-000}（面板未响应或 5xx）" ;;
    *)      pass "登录页 ${URL} 返回 ${CODE}（面板在响应）" ;;
esac

# 裸 /login 不应返回 200，否则说明安全入口没生效
BARE=$(inside curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${PORT}/login" 2>/dev/null || true)
[ "$BARE" != "200" ] || fail "安全入口未生效（裸 /login 返回 200）"
pass "安全入口已生效（裸 /login 返回 ${BARE:-000}）"

step "A7) 校验面板版本号"
# 不可变面板下面板代码来自镜像，所以「面板实际版本」必须等于镜像版本 ——
# 这是对「换镜像即升级面板」最直接的验证：换镜像后若这里对不上，
# 说明面板代码又被持久化层屏蔽了，本方案的核心性质已经失效。
# 首选面板自身的 public.version()，失败则回退读 menu.json 的 version 字段
ACTUAL=$(docker exec -w /www/server/panel "$CONTAINER" ./pyenv/bin/python -c "
import sys
sys.path.insert(0, '/www/server/panel')
sys.path.insert(0, '/www/server/panel/class')
import public
print(public.version())
" 2>/dev/null | tail -1 || true)

if [ -z "$ACTUAL" ]; then
    echo "  [WARN] public.version() 取不到，改用 menu.json"
    ACTUAL=$(docker exec "$CONTAINER" \
        grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
        /www/server/panel/config/menu.json 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi
ACTUAL=$(echo "$ACTUAL" | tr -d '[:space:]')

echo "  实际: ${ACTUAL:-未知}   期望: ${EXPECT_VERSION}"
[ -n "$ACTUAL" ] || fail "无法获取面板版本"
[ "$ACTUAL" = "$EXPECT_VERSION" ] || fail "面板版本与 VERSION 文件不一致"
pass "面板版本一致"

step "A8) 校验首次启动生成的随机凭据"
# 镜像里的构建期占位值形如 bt-build-xxxx，必须已被替换成随机十六进制，
# 否则等于把一个公开可见的口令 / 入口发到线上
inside test -e /www/server/panel/data/.initialized \
    || fail "缺少首次初始化标记，entrypoint 的初始化没有执行"
echo "$SAFE" | grep -Eq '^/[0-9a-f]{8}$' \
    || fail "安全入口不是首启随机生成的（当前：${SAFE}）"
DEFAULT_PW=$(inside_cat /www/server/panel/default.pl)
echo "$DEFAULT_PW" | grep -Eq '^[0-9a-f]{12}$' \
    || fail "面板初始口令不是首启随机生成的（当前长度 ${#DEFAULT_PW}）"
PORT=$(inside_cat /www/server/panel/data/port.pl)
echo "$PORT" | grep -Eq '^[0-9]+$' \
    || fail "面板端口未初始化（当前：${PORT}）"
# 镜像里 root 是锁定的（shadow 字段以 ! 开头），首启后必须已设置真实口令
if inside_sh 'grep "^root:" /etc/shadow | cut -d: -f2 | grep -q "^[!*]"'; then
    fail "root 口令仍处于锁定状态，SSH 无法登录"
fi
pass "安全入口、面板口令、root 口令均为首启随机生成"

step "A9) 校验写入确实落到持久化层"
inside_sh 'echo persist > /www/server/panel/data/_marker'
inside_sh 'echo persist > /www/wwwroot/_marker'
# 面板里装的东西：组件（PHP/nginx/MySQL…）、计划任务脚本、插件数据 ——
# 都落在 /www/server 的 overlay upper 里，重建后必须还在（不用重装）
inside_sh 'mkdir -p /www/server/php /www/server/cron /www/server/total/logs'
inside_sh 'echo persist > /www/server/php/_marker'
inside_sh 'echo persist > /www/server/cron/_marker'
inside_sh 'echo persist > /www/server/total/logs/_marker'
# 落盘路径语义（容易搞混，写清楚再检查）：
#   /etc /usr /var          不持久化（随镜像，defaults.env 已移出覆盖集）
#   /www/server             系统层 overlay（组件 / cron 脚本 / 插件数据）
#   /www/wwwroot            业务 bind，源 = /data/www/wwwroot
#   /www/server/panel/data  面板状态 bind，源 = ${PANEL_STATE_ROOT}/data
#                           （= /data/www/server/panel/data，与容器内位置同名）
#   面板代码（/www/server/panel 本体）刻意不落盘：它属于镜像
inside test -f "${PANEL_STATE_ROOT}/data/_marker"  || fail "面板状态写入未落盘（应为 ${PANEL_STATE_ROOT}/data）"
inside test -f /data/www/wwwroot/_marker           || fail "/www/wwwroot 写入未落到绑定源 /data/www/wwwroot"
inside test -f "${PERSIST_SYSTEM_ROOT}/www/server/php/_marker" \
    || fail "面板里装的组件未落盘（应为 ${PERSIST_SYSTEM_ROOT}/www/server/php）"
inside test -f "${PERSIST_SYSTEM_ROOT}/www/server/cron/_marker" \
    || fail "计划任务脚本未落盘（应为 ${PERSIST_SYSTEM_ROOT}/www/server/cron）"
inside test -f "${PERSIST_SYSTEM_ROOT}/www/server/total/logs/_marker" \
    || fail "插件数据未落盘（应为 ${PERSIST_SYSTEM_ROOT}/www/server/total/logs）"
# 插件 pip 进来的包：经 pyenv 覆盖层落到 upper（data/www/server/panel/pyenv）。
# 这是「面板里装插件 → 重建 → 插件还能跑」的关键一环，B 阶段断言它重建后仍在
inside_sh 'for d in /www/server/panel/pyenv/lib/python3.*/site-packages; do mkdir -p "$d/_gate_pkg"; echo gate > "$d/_gate_pkg/__init__.py"; done'
inside_sh 'ls /www/server/panel/pyenv/lib/python3.*/site-packages/_gate_pkg/__init__.py' \
    || fail "无法在 pyenv site-packages 写入测试包（pyenv 布局与预期不符）"
pass "写入分别落到系统层、面板状态、业务目录与 /www/server（组件 / cron / 插件数据 / pip 包）"

step "A10) 校验面板服务开机自启与运行态"
inside systemctl is-enabled btpanel >/dev/null 2>&1 \
    || fail "btpanel 未设置开机自启（重建容器后面板不会自启）"
inside systemctl is-active btpanel >/dev/null 2>&1 \
    || fail "btpanel 服务未处于 active"
pass "btpanel 已启用且运行中"

step "A11) 校验防火墙默认关闭"
# 官方脚本会 ufw enable + ufw default deny。容器有特权，若开机套用 deny，
# 面板端口会被直接封死，必须确认镜像里已复位为关闭
if inside test -f /etc/ufw/ufw.conf; then
    inside_sh 'grep -q "^ENABLED=no" /etc/ufw/ufw.conf' \
        || fail "ufw 仍处于开启状态，容器启动后会封掉面板端口"
    pass "ufw 已复位为关闭（规则保留，用户可在面板里自行开启）"
else
    pass "未安装 ufw，跳过"
fi

step "A12) 校验 SSH 与 bt 命令"
inside pgrep -x sshd >/dev/null || fail "sshd 未运行"
inside bt status >/dev/null 2>&1 || fail "bt 命令执行失败"
pass "sshd 运行中、bt 命令可用"

step "A13) 校验备份工具"
# 备份是「持久化承诺」的兑现手段，工具本身必须随镜像可用：
#   --list  能读出体积分布（依赖 du / PERSIST_SYSTEM_DIRS 解析正确）
#   生成一份备份并通过自校验（依赖排除项、xattrs、路径解析都正确）
inside test -x /baota/backup.sh \
    || fail "backup.sh 缺失或不可执行（baota-backup 命令不可用）"
inside test -L /usr/local/bin/baota-backup \
    || fail "未创建 /usr/local/bin/baota-backup 软链"
inside baota-backup --list >/dev/null 2>&1 \
    || fail "baota-backup --list 执行失败"

# 跑一次完整备份，把完整输出（stdout + stderr）保留到本地文件
# —— verify_archive 缺关键文件时 die 走 stderr，之前的 `2>/dev/null` 写法
# 把这条关键诊断吞掉，错误只剩"备份包为空"的黑盒。
# 现在失败时把整个输出 dump 给 GH 日志，下次 verify 失败能立刻看到缺什么
if ! inside baota-backup >/tmp/baota-backup.log 2>&1; then
    echo "----- baota-backup 完整输出 -----"
    cat /tmp/baota-backup.log
    echo "----- 输出结束 -----"
    fail "baota-backup 执行失败（见上方输出）"
fi

# 从持久化层取最新备份文件 —— 不再解析 baota-backup 的 stdout。
# 之前用 tail -1 提取路径的写法，在 verify 失败时会把 verify 的
# echo 行（"✅ 含 xxx"）误当路径，让错误链条完全错乱。
# 备份落在容器 /www/backup/manual 下 —— /www/backup 是 WWW_DATA_SUBDIRS 的
# bind 目录，源在 data/www/backup/manual。所以这里在容器内 ls 与在宿主 data
# 卷里 ls 看到的是同一份文件。
# 末尾的 || true 不能省：set -e 下 ls 无匹配会让整条命令替换以非 0 退出、
# 脚本当场中断，下一行那句可读的报错就成了永远走不到的死代码
BACKUP_PATH=$(inside_sh "ls -1t /www/backup/manual/baota-backup-*.tgz 2>/dev/null | head -1" || true)
[ -n "${BACKUP_PATH}" ] || fail "未找到备份文件（baota-backup 报告成功但持久化层没产物）"
inside test -s "${BACKUP_PATH}" || fail "备份包为空：${BACKUP_PATH}"

# 自包含检查：包里绝不能出现 www/backup 下的产物，否则下次备份体积翻倍
if inside_sh "tar tzf ${BACKUP_PATH} | grep -q 'www/backup/\(auto\|manual\|database\)/'"; then
    fail "备份包自包含：含有 www/backup 下的产物"
fi
# journald 日志体积大且零恢复价值，必须在排除清单里（否则备份包白胖一圈）
# 成员名从配置真源派生（与 backup.sh 的 SYSTEM_MEMBER 同源），写死 system 会
# 永远匹配不上 —— 真实成员是 <PERSIST_SYSTEM_ROOT 的 basename>/var/log/journal
_sys_member=$(basename "${PERSIST_SYSTEM_ROOT}")
_journal="${_sys_member}/var/log/journal"
# 整条命令作为单个引号变量传给 inside_sh：变量已在构建期展开，容器内 grep 收到的
# 是字面成员名（如 .system/var/log/journal），不受 shellcheck SC2086 干扰
_journal_check="tar tzf ${BACKUP_PATH} | grep -qF ${_journal}"
if inside_sh "${_journal_check}"; then
    fail "备份包含 journald 日志（应排除：${_journal}）"
fi
_bk=$(basename "${BACKUP_PATH}")
pass "备份工具可用，生成的备份包通过自校验（${_bk}）"

step "A14) PHP 扩展编译工具链护栏（零网络，不装 PHP）"
# 瘦身（dpkg path-exclude / locale 排除）最该守住的底线：镜像必须自带扩展编译工具链
# （autoconf / gcc / make / libtool），否则用户在面板里给 PHP 装扩展时会
# 复现「Cannot find autoconf」类回归。这里只做零网络的存在性断言，不临时
# 安装任何 PHP 环境——真正的「装 PHP + 编译扩展」端到端测试留在日巡检
# （check.sh published），在已发布的纯净镜像上跑，避免污染推送前的候选镜像。
for _b in autoconf gcc make libtool; do
    inside_sh "command -v $_b >/dev/null 2>&1" \
        || fail "镜像缺少扩展编译工具链：$_b（PHP 扩展将装不上，疑似瘦身误删）"
done
pass "扩展编译工具链齐备（autoconf/gcc/make/libtool），足以支撑 PHP 扩展安装"

step "A15) 不可变面板守卫（解释器包装 + 镜像代码副本）"
# 原理见 image/scripts/shim.sh 头部注释：守卫与解释器包装已合并为一个文件，
# 面板代码的每一次执行都先过守卫，于是面板内「更新」写进来的新代码永远不会被执行，
# init_db 只由镜像版本代码执行，持久层的库不可能「比代码新」。
# 这里验装配在位、副本完整且体积可控、守卫行为正确。
inside test -x /baota/shim.sh || fail "缺少 /baota/shim.sh（解释器包装 + 执行入口守卫）"
for _p in python python3; do
    _target=$(inside readlink "/www/server/panel/pyenv/bin/${_p}" 2> /dev/null || true)
    [ "${_target}" = '/baota/shim.sh' ] \
        || fail "pyenv/bin/${_p} 未指向 /baota/shim.sh（当前：${_target:-无}），守卫不会生效"
done
inside test -x /www/server/panel/pyenv/bin/python-real \
    || fail "缺少 /www/server/panel/pyenv/bin/python-real（真解释器）"
inside test -s /baota/origin/class/common.py \
    || fail "缺少镜像代码副本 /baota/origin/class/common.py"

# 副本是实体拷贝（跨构建层给不出硬链接，见 services.sh 注释），所以这里守的是
# 「别把体积大头也抄进来」：pyenv 必须排除，否则镜像体积白白涨几百 MB
if inside test -d /baota/origin/pyenv; then
    fail "镜像代码副本里包含 pyenv（应排除）：镜像会白白多出几百 MB"
fi
pass "镜像代码副本不含 pyenv（体积 $(inside_sh 'du -sh /baota/origin 2>/dev/null | cut -f1' || echo 未知)）"

# 行为断言：模拟「面板内更新」改写代码版本 + 往持久化的状态目录里写用户数据，
# 然后随便跑一次 pyenv python —— 守卫应把代码换回镜像版本，但不能碰状态目录
inside_sh "echo \"g.version = '99.99.99'\" > /www/server/panel/class/common.py"
inside_sh 'echo user-data > /www/server/panel/data/_guard_probe'
inside /www/server/panel/pyenv/bin/python3 -c 'pass' > /dev/null 2>&1 \
    || fail "经包装器执行 python 失败（包装破坏了面板运行环境）"
inside_sh "grep -q '${EXPECT_VERSION}' /www/server/panel/class/common.py" \
    || fail "守卫未把被改写的面板代码换回镜像版本"
# 排除项写错时（rsync 用 ./x、tar 用 /x 之类）恢复会把镜像里的初始数据盖回
# 持久化目录，用户数据被静默回退 —— 这条断言专门盯它
inside_sh 'grep -q user-data /www/server/panel/data/_guard_probe' \
    || fail "守卫恢复了状态目录（排除项失效，用户数据会被镜像初始数据覆盖）"
pass "守卫在位：包装生效、副本完整、代码被换回 ${EXPECT_VERSION}、状态目录未被碰"

step "A16) 任务看门狗兼容 shim 改名（面板里装软件失败的修复）"
# 看门狗只认 /proc/<pid>/comm 含 BT-Task 才认可是面板任务；但 A15 的 shim 把解释器
# 改名 python-real，comm 永远不含 BT-Task，看门狗会误杀安装任务、script_logs 恒空。
# 修复（image/build/panel.sh patch_task_watchdog）把判定补成「comm 或 cmdline 含
# BT-Task 即可」。补丁必须同时落在运行态面板与守卫基准副本 /baota/origin：否则守卫
# 的版本比对会把运行态还原成未修版，装软件继续失败（根因见 docs/faq.md）。
_wd_marker='not in cmdline'
_patched=0
for _f in $(inside_sh 'ls /www/server/panel/BT-P* 2>/dev/null' || true); do
    inside_sh "grep -qF '${_wd_marker}' '${_f}'" && _patched=1
done
[ "$_patched" = 1 ] || fail "运行态面板主程序缺少看门狗 cmdline 补丁（装软件会被误杀）"
_origin_patched=0
for _f in $(inside_sh 'ls /baota/origin/BT-P* 2>/dev/null' || true); do
    inside_sh "grep -qF '${_wd_marker}' '${_f}'" && _origin_patched=1
done
[ "$_origin_patched" = 1 ] || fail "守卫基准副本 /baota/origin/BT-P* 缺少看门狗补丁（守卫会还原成未修版）"
pass "看门狗 cmdline 补丁同时落在运行态面板与守卫基准副本"

# A 阶段末（容器已完整跑过一轮）做一次面板状态漂移报告
report_panel_state_drift

# ==============================================================================
#  🅱️ B 阶段：销毁容器 → 用同一个卷重建
#
#  这是本项目最核心的承诺：容器销毁、重建后，业务与系统环境数据都不丢。
#  只做「重启」是测不出来的（重启不会丢容器可写层），必须真的 rm 掉重建
# ==============================================================================
step "B0) 销毁容器并用同一个数据卷重建"
docker rm -f "$CONTAINER" >/dev/null
start_container
pass "容器已用原数据卷重建"

step "B1) 等待重建后的 systemd 与面板就绪"
wait_systemd
assert_no_degraded
wait_panel_http
pass "重建后面板端口已响应"

step "B2) 校验数据未丢失"
inside test -f /www/server/panel/data/_marker      || fail "面板状态数据在重建后丢失"
inside test -f /www/wwwroot/_marker                || fail "站点数据在重建后丢失"
inside test -f /www/server/php/_marker             || fail "面板里装的组件在重建后丢失"
inside test -f /www/server/cron/_marker            || fail "计划任务脚本在重建后丢失"
inside test -f /www/server/total/logs/_marker      || fail "插件数据在重建后丢失"
# pip 包必须来自持久化 upper：重建后还在，且镜像里本来没有（否则这条断言
# 测到的只是镜像自带内容，失去意义）
inside_sh 'ls /www/server/panel/pyenv/lib/python3.*/site-packages/_gate_pkg/__init__.py >/dev/null 2>&1' \
    || fail "pip 包（测试）在重建后丢失：pyenv 覆盖层没生效"
if docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
    'ls /www/server/panel/pyenv/lib/python3.*/site-packages/_gate_pkg >/dev/null 2>&1'; then
    fail "测试包来自镜像而非持久化 upper（pyenv 覆盖层断言失去意义）"
fi
pass "系统配置、面板状态、业务数据、计划任务、组件、插件数据与 pip 包均已保留"

SAFE_AFTER=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT_AFTER=$(inside_cat /www/server/panel/data/port.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "重建后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PORT_AFTER" = "$PORT" ] || fail "重建后面板端口被改写，说明发生了二次初始化（${PORT} -> ${PORT_AFTER}）"
pass "未发生二次初始化，登录地址与端口保持不变"

step "B3) 校验重建后无持久化降级记录"
# boot.log 只在启动降级时才追加，存在即说明持久化不完整
inside test ! -f "${PERSIST_SYSTEM_ROOT}/.baota/${META_BOOT_FILE}" \
    || fail "存在持久化降级记录：$(inside cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_BOOT_FILE}" 2>/dev/null | tail -3)"
pass "两次启动均未发生持久化降级"

step "B4) 校验重建后面板自动恢复运行"
assert_processes_up "$(panel_status)"
inside systemctl is-active btpanel >/dev/null 2>&1 || fail "重建后 btpanel 未 active"
pass "面板与任务进程随容器自动恢复"

step "B5) 校验优雅停机（SIGRTMIN+3 → systemd 依次停服）"
# 生产里的停机路径是 docker stop / compose down：把 SIGRTMIN+3 发给 PID 1，
# systemd 依次停掉服务，在 compose 的 90s 宽限期内退出。这条路径此前没有任何
# 门禁覆盖 —— 所有重建测试用的都是 docker rm -f（硬杀）。它真出问题时的表现是
# 「宽限期内停不下来 → 被 SIGKILL（退出码 137）→ MySQL/InnoDB 被硬杀」，
# 属于丢数据风险，值得在这一层拦住（判据只看退出码与耗时，不看日志文案）
_stop_start=$(date +%s)
docker stop -t 90 "$CONTAINER" >/dev/null 2>&1 || true
_stop_elapsed=$(( $(date +%s) - _stop_start ))
_stop_exit=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo '?')
[ "${_stop_exit}" != '137' ] \
    || fail "优雅停机被 SIGKILL（退出码 137）：systemd 未在 90s 宽限期内停服（耗时 ${_stop_elapsed}s）"
[ "${_stop_elapsed}" -le 90 ] \
    || fail "优雅停机耗时 ${_stop_elapsed}s，超过 compose 的 stop_grace_period=90s"
pass "优雅停机正常：${_stop_elapsed}s 内退出（未触发宽限期 SIGKILL；退出码 ${_stop_exit}）"

echo
echo "发布前健康检查全部通过（宝塔 ${EXPECT_VERSION}，含容器重建后的持久化验证）"
)


# ---------------------------------------------------------------------------
#  degrade：只读持久化根必须被识别为 critical 且判 unhealthy
#  断言逐字保留；公共样板在本文件顶部，资源回收由本函数内的 trap 负责
# ---------------------------------------------------------------------------
run_degrade() (
    trap cleanup EXIT
set -euo pipefail

IMAGE=${1:?用法: check.sh degrade <镜像>}

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 清理）见 公共样板段

# ICON 供 公共样板段 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🧪'
CONTAINER="baota-degrade-$$"
VOL_RO="baota-degrade-ro-$$"

# ==============================================================================
#  只读持久化根必须被识别为降级
#
#  最危险的失效模式是「overlay 挂载成功，但所有写入静默丢失」。
#  只读根是它的等价场景：如果这条用例过了，说明 init.sh 的实测写入探测
#  与 critical 标记确实在工作。
# ==============================================================================
step "B1) 只读持久化根必须被识别为降级"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker volume create "$VOL_RO" >/dev/null
docker run -d --name "$CONTAINER" \
    --privileged \
    --tmpfs /run --tmpfs /run/lock \
    -v "${VOL_RO}:/data:ro" \
    "$IMAGE" >/dev/null || fail "只读场景容器无法启动"

# 只读根下 /etc 等目录挂不上 overlay，entrypoint 随后会因写不进凭据而退出，
# 容器活不了多久 —— 所以要趁它还活着轮询标记文件
critical_found=0
for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" test -e /run/baota/critical 2>/dev/null; then
        critical_found=1
        break
    fi
    is_running || break
    sleep 1
done

if [ "$critical_found" = 1 ]; then
    pass "只读持久化根已写入 critical"
elif logs_match '本次不会持久化'; then
    # 兜底：容器退得比轮询更快时，退而求其次看启动日志里的降级告警
    pass "只读持久化根已被识别（启动日志有降级告警）"
elif is_running && docker exec "$CONTAINER" sh -c ': > /data/.probe 2>/dev/null'; then
    # 区分两种失败：挂载没真正只读 vs 镜像的降级识别失效。
    # volume 的 :ro 在个别 runner（容器化 runner / 无 ro 传播的嵌套 Docker）下
    # 可能不生效，此时容器按可写正常启动 —— 门禁测的是镜像对只读的响应，
    # 该结果不反映镜像本身，不能误导成「最危险的失效模式失去了防护」
    fail "只读挂载未生效：容器内 /data 仍可写（runner 未执行 volume :ro），本次门禁结果无效"
else
    fail "只读持久化根既没写 critical、日志里也没有降级告警 —— 最危险的失效模式失去了防护"
fi

step "B2) 降级状态下健康检查必须判 unhealthy"
if is_running; then
    if docker exec "$CONTAINER" /baota/healthcheck.sh >/dev/null 2>&1; then
        fail "降级状态下 healthcheck 仍判为健康 —— 容器一直显示 healthy，写入却全丢"
    fi
    pass "降级状态下 healthcheck 判定为 unhealthy"
else
    # 只读根下 entrypoint 写不进凭据会主动退出。
    # 「拒绝启动」本身就是没有静默失败，属于可接受的结果
    pass "容器已因只读根主动退出（未静默继续运行），跳过 healthcheck 判定"
fi

echo
echo "持久化降级场景检查全部通过（只读持久化根被识别为 critical 且判 unhealthy）"
)


# ---------------------------------------------------------------------------
#  upgrade：版本护栏：升级 / 降级识别、快照完整性、降级不阻断启动
#  断言逐字保留；公共样板在本文件顶部，资源回收由本函数内的 trap 负责
# ---------------------------------------------------------------------------
run_upgrade() (
    trap cleanup EXIT
set -euo pipefail

IMAGE=${1:?用法: check.sh upgrade <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: check.sh upgrade <镜像> <期望版本>}

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 启动 / 清理）见 公共样板段。
# 注：本脚本要取的 PERSIST_SYSTEM_ROOT 默认值是 ${PERSIST_DATA_ROOT}/.system，
# **含嵌套引用**，必须用 公共样板段 的展开版；PERSIST_DATA_ROOT 因此要先读 ——
# 展开时它必须已存在于环境，否则 set -u 下会直接中断

# ICON 供 公共样板段 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🔼'
CONTAINER="baota-upgrade-$$"
VOLUME="baota-upgrade-data-$$"

# 伪造的版本记录：低于 / 高于当前镜像版本，用于触发升级与降级分支
OLD_VERSION='0.0.1'
FUTURE_VERSION='999.0.0'

# 版本记录落在持久化层的 .baota 下，路径取自 image/conf/defaults.env。
# PERSIST_DATA_ROOT 必须先读：PERSIST_SYSTEM_ROOT 的默认值引用了它，
# expand_vars 的间接展开在 set -u 下遇到未定义变量会直接中断
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
META_VERSION_FILE=$(read_default META_VERSION_FILE)
META_DIGEST_FILE=$(read_default META_DIGEST_FILE)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }
[ -n "${META_VERSION_FILE}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 META_VERSION_FILE"; exit 1; }
[ -n "${META_DIGEST_FILE}" ] || { echo "::error::无法从 image/conf/defaults.env 解析 META_DIGEST_FILE"; exit 1; }

# start_container 见 公共样板段

# 改写持久化层里记录的镜像版本。
# 用 --entrypoint 覆盖默认的 init.sh，避免跑一整套 overlay 挂载 ——
# 这里只是往卷里写一个文件而已
set_recorded_version() {
    local ver="$1" actual

    docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "printf '%s\n' '${ver}' > '${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}'" \
        || fail "无法写入版本记录：${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}"

    # 回读校验：写不进去的话后面所有断言都会失去意义
    actual=$(docker run --rm --entrypoint /bin/sh -v "${VOLUME}:/data" "$IMAGE" \
        -c "cat '${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}'" 2>/dev/null || true)
    [ "$(printf '%s' "${actual}" | tr -d '[:space:]')" = "${ver}" ] \
        || fail "版本记录写入校验失败：期望 ${ver}，实际 ${actual}"
    pass "持久化层里的镜像版本记录已改写为 ${ver}"
}

# ==============================================================================
#  A) 全新卷初始化：写入真实的版本记录，作为后续两个阶段的基础
# ==============================================================================
step "A) 全新数据卷初始化"
docker volume create "$VOLUME" >/dev/null
start_container
wait_systemd
wait_panel_http
assert_no_degraded

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}")
[ "${RECORDED}" = "${EXPECT_VERSION}" ] \
    || fail "首次启动未正确记录镜像版本：期望 ${EXPECT_VERSION}，实际 ${RECORDED}"
# 代码指纹与版本一起记录：同版本号镜像被重新构建时，只靠版本号判不出变化
RECORDED_DIGEST=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_DIGEST_FILE}")
[ -n "${RECORDED_DIGEST}" ] \
    || fail "首次启动未记录面板代码指纹：${PERSIST_SYSTEM_ROOT}/.baota/${META_DIGEST_FILE}"
pass "首次启动已记录镜像版本 ${RECORDED} 与代码指纹（首次不生成快照，因为没有可回滚的旧数据）"

# ==============================================================================
#  B) 升级分支：把记录改低，重新启动
# ==============================================================================
step "B) 模拟「从旧版本升级到当前镜像」"
set_recorded_version "${OLD_VERSION}"
docker rm -f "$CONTAINER" >/dev/null
start_container
wait_systemd

logs_match '检测到镜像升级' \
    || fail "未识别为镜像升级 —— 版本护栏失效（快照与启动器刷新都不会发生）"
pass "已识别为镜像升级"

# 快照必须存在，且**内容完整**。只检查目录存在是不够的：
# cp -a 失败时也可能留下一个空目录，而空的回滚点比没有更危险
SNAPSHOT=$(inside_sh "ls -1d /www/backup/auto/baota-${OLD_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAPSHOT}" ] || fail "未生成升级前快照（期望 /www/backup/auto/baota-${OLD_VERSION}-*）"
inside test -f "${SNAPSHOT}/port.pl" \
    || fail "快照内容不完整：${SNAPSHOT} 里没有 port.pl（cp -a 可能只建了空目录）"
pass "升级前快照已生成且内容完整：${SNAPSHOT}"

# 不可变面板下，启动器随镜像层只读提供，不再被 copy-up 锁进持久化层，
# 因此不再存在「版本变化时刷回启动器」这一步骤。
assert_no_degraded

RECORDED=$(inside_cat "${PERSIST_SYSTEM_ROOT}/.baota/${META_VERSION_FILE}")
[ "${RECORDED}" = "${EXPECT_VERSION}" ] \
    || fail "升级后版本记录未回写：期望 ${EXPECT_VERSION}，实际 ${RECORDED}"
pass "版本记录已回写为 ${RECORDED}"

wait_panel_http
pass "升级后面板正常响应"

# ==============================================================================
#  C) 降级分支：把记录改高，重新启动
#     语义要求：必须告警 + 必须快照，但**不阻断启动**
#     （出故障时运维最需要的是能起来）
# ==============================================================================
step "C) 模拟「从更高版本降级到当前镜像」"
set_recorded_version "${FUTURE_VERSION}"
docker rm -f "$CONTAINER" >/dev/null
start_container
wait_systemd

logs_match '检测到镜像降级' \
    || fail "未识别为镜像降级 —— 降级告警丢失"
pass "已识别为镜像降级并输出告警"

SNAPSHOT=$(inside_sh "ls -1d /www/backup/auto/baota-${FUTURE_VERSION}-* 2>/dev/null | head -1" || true)
[ -n "${SNAPSHOT}" ] || fail "降级前未生成快照（降级同样需要回滚点）"
inside test -f "${SNAPSHOT}/port.pl" || fail "降级快照内容不完整：${SNAPSHOT}"
pass "降级前快照已生成且内容完整：${SNAPSHOT}"

assert_no_degraded

# 降级刻意不阻断启动：这里必须能起来，否则违反设计
wait_panel_http
pass "降级后容器仍能正常启动（符合「只告警、不阻断」的设计）"

echo
echo "升级 / 降级路径检查全部通过（版本护栏 + 快照 + 降级不阻断）"
)


# ---------------------------------------------------------------------------
#  restore：备份恢复闭环：解回全新数据卷后站点 / 数据库 / 面板状态可恢复
#  断言逐字保留；公共样板在本文件顶部，资源回收由本函数内的 trap 负责
# ---------------------------------------------------------------------------
run_restore() (
    trap cleanup EXIT
set -euo pipefail

IMAGE=${1:?用法: check.sh restore <镜像>}

# 公共样板（输出 / 容器操作 / 等待 / 启动 / 清理）见 公共样板段

# ICON 供 公共样板段 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='♻️'

# 两段式：源容器（造数据 + 备份）→ 目标容器（全新卷恢复 + 校验）。
# 公共样板段 的 cleanup 只认当前的 CONTAINER / VOLUME，所以切换前先手动回收源端。
# 名字照 §4 的 baota-<用途>-<PID> / baota-<用途>-data-<PID>，用途写全称：
# source / target 不写成 src / dst —— 缩写只在业界通用时才用（rc / pid / sha / tmp）
SOURCE_CONTAINER="baota-restore-source-$$"
SOURCE_VOLUME="baota-restore-source-data-$$"
TARGET_CONTAINER="baota-restore-target-$$"
TARGET_VOLUME="baota-restore-target-data-$$"
WORK_ROOT=$(mktemp -d)

# ==============================================================================
#  A) 源容器：写入三类数据并生成备份
# ==============================================================================
step "A1) 启动源容器并写入待恢复的数据"
CONTAINER="$SOURCE_CONTAINER"
VOLUME="$SOURCE_VOLUME"
docker volume create "$VOLUME" >/dev/null
start_container
wait_systemd
wait_panel_http

# 恢复前的凭据锚点：安全入口与端口（与 core B 阶段同款判据）
SAFE=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT=$(inside_cat /www/server/panel/data/port.pl)
[ -n "$SAFE" ] || fail "无法读取安全入口（面板未初始化）"
[ -n "$PORT" ] || fail "无法读取面板端口（面板未初始化）"

# 三类必须能回来的数据：站点 / 数据库目录 / 面板状态
# 站点文件直接写到持久化源 /data/www/wwwroot（即 bind 挂载源），并立即 sync 落盘，
# 随后断言它确实落在 /data 侧——bind 未生效会在 A1 暴露，而不是到 A3 才报「包里缺路径」
inside_sh 'echo marker > /data/www/wwwroot/_restore_marker && sync /data/www/wwwroot/_restore_marker'
inside test -f /data/www/wwwroot/_restore_marker \
    || fail "站点写入未落到绑定源 /data/www/wwwroot（bind 挂载未生效，备份自然读不到）"
inside test -d /www/server/data || fail "MySQL 数据目录缺失：/www/server/data"
inside_sh 'echo state > /www/server/panel/data/_restore_probe'
pass "已写入站点 / 数据库目录 / 面板状态三类数据"

step "A2) 生成备份（--stdout 直落宿主机，不占容器内空间）"
BACKUP_FILE="${WORK_ROOT}/backup.tgz"
# 热备份下 tar 可能因「边读边写」返回 1，退出码不作判据 —— 判据是包的大小与内容
docker exec "$SOURCE_CONTAINER" baota-backup --stdout > "$BACKUP_FILE" 2> "${WORK_ROOT}/backup.err" || true
if [ ! -s "$BACKUP_FILE" ]; then
    echo "----- baota-backup 输出 -----"
    cat "${WORK_ROOT}/backup.err" 2>/dev/null || true
    fail "备份包为空（baota-backup --stdout 没有产出）"
fi
pass "备份包已生成（$(du -h "$BACKUP_FILE" | cut -f1)）"

step "A3) 校验包内含三类关键路径（文档「验证备份（别跳过）」）"
# 只认包内成员名（相对 data 根），与 baota-backup 的产出结构一致
# 注意：`tar | grep -q` 里 grep -q 命中即关闭管道，会让上游 tar 收到 SIGPIPE，
# 在 set -o pipefail 下整条管道返回 141（非 0），把「已命中」误判成「命令失败」，
# 从而错误报「缺路径」。所以先把清单读进变量，再用 here-string 做固定串匹配。
_listing="$(tar tzf "$BACKUP_FILE" 2>/dev/null)"
missing=''
for _m in 'www/wwwroot/_restore_marker' 'www/server/data' 'www/server/panel/data/system.db'; do
    if ! grep -qF "$_m" <<<"$_listing"; then
        missing="${missing}${missing:+, }${_m}"
    fi
done
if [ -n "$missing" ]; then
    echo "----- 备份包条目统计 -----"
    printf '总条目: %s\n' "$(tar tzf "$BACKUP_FILE" 2>/dev/null | wc -l)"
    printf 'www/wwwroot: %s\n' "$(tar tzf "$BACKUP_FILE" 2>/dev/null | grep -c '^www/wwwroot/' || true)"
    printf 'www/server/data: %s\n' "$(tar tzf "$BACKUP_FILE" 2>/dev/null | grep -c '^www/server/data/' || true)"
    printf 'www/server/panel/data: %s\n' "$(tar tzf "$BACKUP_FILE" 2>/dev/null | grep -c '^www/server/panel/data/' || true)"
    echo "----- 标记文件查找 -----"
    tar tzf "$BACKUP_FILE" 2>/dev/null | grep -F 'www/wwwroot/_restore_marker' || echo '未找到 www/wwwroot/_restore_marker'
    echo "----- /data/www/wwwroot 现场 -----"
    inside_sh 'ls -la /data/www/wwwroot/ 2>/dev/null || echo "目录不存在"' || true
    fail "备份包缺少关键路径：${missing}（站点 / 数据库 / 面板状态缺一不可）"
fi
pass "三类关键路径均在包内"

# ==============================================================================
#  B) 目标容器：全新数据卷恢复并校验
# ==============================================================================
step "B1) 把备份解开到全新数据卷（照文档「恢复」步骤）"
docker volume create "$TARGET_VOLUME" >/dev/null
docker run --rm -i --entrypoint /bin/sh -v "${TARGET_VOLUME}:/data" "$IMAGE" \
    -c 'tar xzf - -C /data' < "$BACKUP_FILE" || fail "解包到新数据卷失败"
pass "备份已恢复到全新数据卷"

# 回收源端：公共样板段 的 cleanup 只认切换后的 CONTAINER / VOLUME
docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
docker volume rm "$SOURCE_VOLUME" >/dev/null 2>&1 || true

step "B2) 用恢复后的数据卷启动容器"
CONTAINER="$TARGET_CONTAINER"
VOLUME="$TARGET_VOLUME"
start_container
wait_systemd
assert_no_degraded
# 解释器必须是真二进制，不能是零长文件：「upper 里的零长副本盖住 lower 真文件」
# 这类损坏 [ -x] 能过、exec 才报 Exec format error（metacopy 事故的形态），
# 在这里先用文件大小拦下，报错比「面板起不来」直指原因
_py_real=$(inside_sh 'readlink -f /www/server/panel/pyenv/bin/python-real' || true)
[ -n "${_py_real}" ] || fail "无法解析面板真解释器（/www/server/panel/pyenv/bin/python-real）"
inside test -s "${_py_real}" \
    || fail "面板真解释器是空文件（${_py_real}）：恢复出的持久化层里有零长副本盖住了镜像文件"
wait_panel_http
# 显式带上 CONTAINER / VOLUME：它们后续由 公共样板段 的样板使用，这里出现一次
# 既让日志可读，也免掉 shellcheck 的「赋值后未读取」误报
pass "恢复后的容器 ${CONTAINER} 已启动且面板响应（数据卷 ${VOLUME}）"

step "B3) 校验恢复后的数据完整"
inside test -f /www/wwwroot/_restore_marker      || fail "站点数据在恢复后丢失"
inside test -d /www/server/data                        || fail "MySQL 数据目录在恢复后丢失"
inside test -f /www/server/panel/data/_restore_probe   || fail "面板状态在恢复后丢失"
pass "站点、数据库目录、面板状态均随备份恢复"

step "B4) 恢复不得被误判为首次启动（安全入口与端口不变）"
# .baota 被备份排除，恢复后没有版本记录；若因此触发「首次初始化」，安全入口与
# 面板口令会被重新随机 —— 用户按旧地址就再也进不去面板
SAFE_AFTER=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT_AFTER=$(inside_cat /www/server/panel/data/port.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "恢复后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PORT_AFTER" = "$PORT" ] || fail "恢复后面板端口被改写（${PORT} -> ${PORT_AFTER}）"
pass "恢复后未发生二次初始化，安全入口与端口保持不变"

echo
echo "备份恢复闭环检查全部通过（站点 / 数据库 / 面板状态可恢复，且未触发二次初始化）"
)


# ---------------------------------------------------------------------------
#  published：已发布镜像每日回归：拉取 + 脱敏首启日志 + PHP 扩展编译 + 复用四套门禁
#  断言逐字保留；公共样板在本文件顶部，资源回收由本函数内的 trap 负责
# ---------------------------------------------------------------------------
run_published() (
set -uo pipefail

IMAGE=${1:?用法: check.sh published <镜像:标签> <期望版本> [输出 md]}
EXPECT_VERSION=${2:?用法: check.sh published <镜像:标签> <期望版本> [输出 md]}
OUT_MD=${3:-}


CONTAINER="baota-verify-$$"
VOLUME="baota-verify-data-$$"

START_TS=$(date +%s)
RESULTS=()
PASS=0
FAIL=0

log()  { echo "🔬 [verify] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [verify][WARN] $(date '+%H:%M:%S') - $*" >&2; }
ok()   { PASS=$((PASS + 1)); RESULTS+=("- [x] $*"); echo "  ✅ $*"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS+=("- [ ] ❌ $*"); echo "  ❌ $*"; }

trap cleanup EXIT


# 首启日志里的凭据与安全入口不能进仓库（report.md 会被提交）
sanitize() {
    # 锚定要足够紧，否则会误伤提示文案：
    #   「- 面板口令：<值>」是凭据（独立成行、值在行尾）
    #   「- 重置面板口令：docker exec ...」是提示命令，不是凭据
    sed -E \
        -e 's/(- 面板口令：)[^[:space:]]*$/\1***已脱敏***/' \
        -e 's/(root 口令：)[^（]*(（容器内 SSH 用）)/\1***已脱敏***\2/' \
        -e 's#(http://<宿主机IP>:[0-9]+/)[^/]*(/login)#\1***已脱敏***\2#'
}

# ---------------------------------------------------------------------------
#  PHP 扩展「安装 + 编译」端到端验证（只在已发布镜像上跑）
#
#  复现用户在面板里给 PHP 装扩展的真实链路：先取得 PHP（镜像一律不预装 PHP，
#  优先用面板里已装的宝塔 PHP；都没有才临时 apt 装 php-dev 拿到真 phpize），
#  再 phpize → configure → make → 加载最小扩展。等价于用户装 redis / igbinary
#  时的失败面。
#  ★ 工具链护栏（autoconf/gcc/make/libtool）必须先于任何 apt 安装判定，
#    否则 apt 会把缺失依赖补上，得到「假绿」——那正是瘦身误删 autoconf 时要抓的回归。
# ---------------------------------------------------------------------------
check_php_ext_compile() {
    log "验证 PHP 扩展安装 + 编译链路（真编译最小扩展）"
    local _phpize _ver _phpcfg _php _build _out _rc _msg _b
    _rc=0

    for _b in autoconf gcc make libtool; do
        if ! inside_sh "command -v $_b >/dev/null 2>&1"; then
            _rc=1; _msg="镜像缺少扩展编译工具链：$_b（PHP 扩展将装不上，疑似瘦身误删）"; break
        fi
    done
    [ "$_rc" -ne 0 ] && { bad "PHP 扩展安装 + 编译链路失败：$_msg"; return; }

    _phpize=$(inside_sh 'ls -d /www/server/php/*/bin/phpize 2>/dev/null | head -1' || true)
    if [ -n "$_phpize" ]; then
        _ver=$(dirname "$(dirname "$_phpize")")
        _phpcfg="$_ver/bin/php-config"
        _php="$_ver/bin/php"
    else
        if inside_sh 'apt-get update >/dev/null 2>&1 && apt-get install -y php-cli php-dev >/dev/null 2>&1'; then
            _phpize=$(inside_sh 'command -v phpize' || true)
            _phpcfg=$(inside_sh 'command -v php-config' || true)
            _php=$(inside_sh 'command -v php' || true)
        fi
    fi

    if [ -z "$_phpize" ]; then
        # 工具链护栏已过，只是本环境拿不到 phpize（无预装 PHP 且 apt 不可用）
        ok "未预装 PHP 且 apt 不可用，但扩展编译工具链齐备（autoconf/gcc/make/libtool），足以装扩展"
        return
    fi

    _build=$(mktemp -d)
    cat > "$_build/config.m4" <<'M4'
PHP_ARG_ENABLE(myext, whether to enable myext,
[  --enable-myext   Enable myext support], no)
if test "$PHP_MYEXT" != "no"; then
  PHP_NEW_EXTENSION(myext, myext.c, $ext_shared)
fi
M4
    cat > "$_build/myext.c" <<'C'
#include "php.h"

PHP_FUNCTION(myext_hello) { php_printf("hello from myext\n"); }

const zend_function_entry myext_functions[] = {
    PHP_FE(myext_hello, NULL)
    PHP_FE_END
};

PHP_MINIT_FUNCTION(myext) { return SUCCESS; }

zend_module_entry myext_module_entry = {
    STANDARD_MODULE_HEADER,
    "myext",
    myext_functions,
    PHP_MINIT(myext),
    NULL, NULL, NULL, NULL,
    NO_VERSION_YET,
    STANDARD_MODULE_PROPERTIES
};

/* get_module 无条件导出：动态加载只认这个符号。写成 #ifdef COMPILE_DL_MYEXT
   的话，一旦该宏没被定义（phpize 对扩展名宏的处理随 PHP 版本而异），编译照过、
   加载却报 "Invalid library (maybe not a PHP library)" —— 这正是假红的来源 */
ZEND_GET_MODULE(myext)
C

    if ! docker cp "$_build" "$CONTAINER:/tmp/myext_check" >/dev/null 2>&1; then
        _rc=1; _msg="无法拷贝扩展源码进容器"
    else
        # 分步执行、分步报错：失败时报告里直接写出是 phpize / configure / make /
        # 产出 / 加载 哪一环挂了（笼统一句「链路未通过」的排查成本太高）
        _out=$(docker exec "$CONTAINER" sh -c "
            cd /tmp/myext_check || exit 9
            '$_phpize' > /tmp/phpize.log 2>&1 \
                || { echo 'phpize 失败'; tail -n 10 /tmp/phpize.log; exit 1; }
            ./configure --with-php-config='$_phpcfg' > /tmp/configure.log 2>&1 \
                || { echo 'configure 失败'; tail -n 10 /tmp/configure.log; exit 1; }
            make -j\"\$(nproc)\" > /tmp/make.log 2>&1 \
                || { echo 'make 失败'; tail -n 10 /tmp/make.log; exit 1; }
            test -f modules/myext.so || { echo '未产出 modules/myext.so'; exit 1; }
            '$_php' -d extension=\"\$PWD/modules/myext.so\" -m 2> /tmp/load.log | grep -iq myext \
                || { echo '加载 myext 失败'; tail -n 5 /tmp/load.log; exit 1; }
        " 2>&1)
        _rc=$?
        [ "$_rc" -ne 0 ] && _msg="phpize→configure→make→加载 未通过"
    fi
    inside rm -rf /tmp/myext_check >/dev/null 2>&1 || true
    rm -rf "$_build"

    if [ "$_rc" -eq 0 ]; then
        ok "PHP 扩展安装 + 编译链路可用（phpize→configure→make→加载 myext 成功）"
    else
        # 首行进报告（其余多行输出留在 CI 日志里）
        _b=$(printf '%s' "${_out}" | head -n 1)
        bad "PHP 扩展安装 + 编译链路失败：${_msg}${_b:+（${_b}）}"
        [ -n "$_out" ] && warn "编译输出：${_out}"
    fi
}

# ---------------------------------------------------------------------------
#  跑四套发布前门禁（同一份代码，避免两处断言漂移）
# ---------------------------------------------------------------------------
run_suites() {
    local suite rc
    for suite in core degrade upgrade restore; do
        log "运行门禁：${suite}"
        rc=0
        # 统一传三个参数：degrade / restore 只取 $1，多余参数被忽略
        bash "${CHECK_SELF}" "$suite" "$IMAGE" "${EXPECT_VERSION:-}" \
            > "/tmp/suite-${suite}.log" 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            ok "门禁 ${suite} 通过"
        else
            bad "门禁 ${suite} 失败（rc=${rc}，日志见构建产物 / 下方尾部）"
            echo "----- ${suite}.log (tail 30) -----" >&2
            tail -n 30 "/tmp/suite-${suite}.log" >&2 || true
        fi
    done
}

# ==============================================================================
#  流程
# ==============================================================================
log "拉取 ${IMAGE}"
if docker pull "$IMAGE" >/dev/null 2>&1; then
    ok "镜像拉取成功"
else
    bad "镜像拉取失败"
fi

BOOT_LOG=''
if [ "$FAIL" -eq 0 ]; then
    docker volume create "$VOLUME" >/dev/null
    log "首次启动（全新数据卷）"
    docker run -d --name "$CONTAINER" --privileged \
        --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
        --tmpfs /run --tmpfs /run/lock --shm-size=512m \
        --stop-signal=SIGRTMIN+3 --stop-timeout=90 \
        -v "${VOLUME}:/data" "$IMAGE" >/dev/null

    # 等面板端口响应（最多 120s），再抓首启日志与跑扩展编译
    _port=''
    for _ in $(seq 1 60); do
        _port=$(inside_sh 'cat /www/server/panel/data/port.pl 2>/dev/null' || true)
        if [ -n "$_port" ] \
           && inside_sh "curl -sk -o /dev/null --max-time 5 'http://127.0.0.1:${_port}/'" 2>/dev/null; then
            break
        fi
        _port=''
        sleep 2
    done
    if [ -n "$_port" ]; then
        ok "首次启动（持久化挂载 + entrypoint + systemd + 面板就绪）"
    else
        bad "首次启动失败（面板 120 秒内未响应）"
        docker logs "$CONTAINER" --tail 30 >&2 2>/dev/null || true
    fi
    BOOT_LOG=$(docker logs "$CONTAINER" 2>&1 | sanitize | tail -n 40)

    check_php_ext_compile
    run_suites
fi

ELAPSED=$(( $(date +%s) - START_TS ))
RESULT_ICON=$([ "$FAIL" -eq 0 ] && echo '✅' || echo '❌')

# 失败时不落 OUT_MD：check.yml 以「有报告 = 通过」判结果，失败也写文件会把
# 失败线标成 ✅ 并注入 README；失败内容改为打印到 CI 日志便于排查
if [ "$FAIL" -eq 0 ]; then _report_dest="${OUT_MD:-/dev/stdout}"; else _report_dest=/dev/stdout; fi

{
    echo "### ${RESULT_ICON} ${IMAGE}"
    echo
    echo '| 项 | 值 |'
    echo '|---|---|'
    echo "| 镜像 | \`${IMAGE}\` |"
    echo "| 期望宝塔版本 | \`${EXPECT_VERSION}\` |"
    echo "| 结果 | ${RESULT_ICON} 通过 ${PASS} / 失败 ${FAIL} |"
    echo "| 耗时 | ${ELAPSED}s |"
    echo
    echo '#### 检查项'
    echo
    if [ ${#RESULTS[@]} -gt 0 ]; then
        printf '%s\n' "${RESULTS[@]}"
    else
        echo '- （无）'
    fi
    echo
    echo '> 持久化 / 重建 / 版本护栏 / 只读降级 / 备份恢复等细节由 core、degrade、upgrade、restore 四套门禁覆盖'
    echo '> （本节只报它们的通过与否；逐项日志见该次运行的 CI 产物）。'
    echo
    echo '#### 首次启动日志（全新数据卷，已脱敏）'
    echo
    echo '```text'
    printf '%s\n' "${BOOT_LOG:-（未获取到启动日志）}"
    echo '```'
} > "${_report_dest}"

log "完成：${IMAGE} 通过 ${PASS} / 失败 ${FAIL}（${ELAPSED}s）"
[ "$FAIL" -eq 0 ]
)


# ---------------------------------------------------------------------------
#  drift：一次性容器原样跑官方安装脚本，检测目录漂移（数据落点）
#  入参 INSTALL_URL（必填）/ BASE_IMAGE / OUT_MD / CRITICAL_FILE；断言逐字保留
# ---------------------------------------------------------------------------
run_drift() (
set -euo pipefail

INSTALL_URL="${INSTALL_URL:?未指定 INSTALL_URL}"
BASE_IMAGE="${BASE_IMAGE:-debian:12}"
OUT_MD="${OUT_MD:-drift.md}"
CRITICAL_FILE="${CRITICAL_FILE:-drift-critical}"
# 先写 .part，跑完才改名成 OUT_MD：中途 die 不会留下「看似成功的空报告」，
# drift.yml 的 report job 据此判断是否真的完成了安装对比
_OUT_MD_FINAL="${OUT_MD}"
OUT_MD="${OUT_MD}.part"

CONTAINER="baota-drift-$$"
CRITICAL=0

log()  { echo "🔭 [drift] $*"; }
warn() { echo "⚠️ [drift][WARN] $*" >&2; }
die()  { echo "❌ [drift][ERROR] $*" >&2; exit 1; }

trap cleanup EXIT

# 官方安装脚本通过 exec > >(tee -a /tmp/btpanel-install.log) 2>&1 把全部输出写进该日志
INSTALL_LOG=/tmp/btpanel-install.log

in_known_dirs() {
    local d="$1" k
    # shellcheck disable=SC2086
    for k in $KNOWN_DIRS; do [ "$k" = "$d" ] && return 0; done
    return 1
}

# 统计每个顶层目录的文件数（排除虚拟文件系统与临时目录）
count_top_dirs() {
    docker exec -i "$CONTAINER" bash -s <<'EOS'
for d in /*; do
    [ -d "$d" ] || continue
    case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
    n=$(find "$d" -xdev -type f 2>/dev/null | wc -l | tr -d ' ')
    printf '%s %s\n' "${d#/}" "$n"
done
EOS
}

# /www 是按子路径分别处理的（server 走 overlay、wwwroot/backup/server/data 等走
# bind、wwwlogs 按设计不持久化），顶层文件数没法表达这件事 —— 单独看它的子目录
www_subdirs() {
    docker exec "$CONTAINER" bash -c \
        'find /www -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort' || true
}

# ------------------------------------------------------------------------------
#  声明清单**从 defaults.env 派生**，不另抄一份：抄一份必然漂移（那边加了数据
#  目录、这边还在用旧清单 → 新目录每次被报成关键漂移，或反过来漏报）。
#    KNOWN_DIRS           顶层目录 = PERSIST_SYSTEM_DIRS 里不含 / 的项。
#                         ★ 刻意不含 www：算进来会把「新出现的 /www 子路径」一并放过
#    WWW_PERSIST_SUBDIRS  /www 一级子目录 = PERSIST_SYSTEM_DIRS 的 www/*
#                         + WWW_DATA_SUBDIRS + WWW_OPTIONAL_SUBDIRS
#    WWW_VOLATILE_SUBDIRS 按设计不持久化的 /www 子路径（本文件定义，运行期不读：
#                         列的是上游落点，不该固化成项目配置 —— 见「不对抗上游」）
# ------------------------------------------------------------------------------

# 这里只读不含引用的清单，用不展开的 read_raw_default（公共样板段定义）
PERSIST_SYSTEM_DIRS=$(read_raw_default PERSIST_SYSTEM_DIRS)
WWW_DATA_SUBDIRS=$(read_raw_default WWW_DATA_SUBDIRS)
WWW_OPTIONAL_SUBDIRS=$(read_raw_default WWW_OPTIONAL_SUBDIRS)
[ -n "$PERSIST_SYSTEM_DIRS" ] && [ -n "$WWW_DATA_SUBDIRS" ] \
    || die "无法从 ${DEFAULTS_ENV} 解析 PERSIST_SYSTEM_DIRS / WWW_DATA_SUBDIRS"

# shellcheck disable=SC2086
KNOWN_DIRS=$(printf '%s\n' $PERSIST_SYSTEM_DIRS | grep -v / | tr '\n' ' ')
# 可选模块目录也要算进「已被持久化覆盖」：它虽然按需出现，但一旦装了就是用户数据
# shellcheck disable=SC2086
WWW_PERSIST_SUBDIRS=$(
    {
        printf '%s\n' $PERSIST_SYSTEM_DIRS | grep '^www/'
        printf '%s\n' $WWW_DATA_SUBDIRS
        printf '%s\n' $WWW_OPTIONAL_SUBDIRS
    } | sed -e 's#^www/##' -e 's#/.*##' | sort -u | tr '\n' ' '
)


# 上游落点清单：上游新增可再生目录时，把目录名加进来即可（否则会被报成关键漂移）
WWW_VOLATILE_SUBDIRS='wwwlogs .Recycle_bin Recycle_bin php_session panel-static monitor_data'

: > "$OUT_MD"
echo 0 > "$CRITICAL_FILE"

# ------------------------------------------------------------------------------
#  0. 起容器并装前置包
#  清单取 base.sh install_packages 的「基础系统」部分，刻意不含编译工具链与
#  LNMP dev 库：漂移检测只关心「装完往哪些顶层目录写」，工具链只让 /usr 多几万文件。
#  同理不含 logrotate（已随「日志体积防线」从 base.sh 移除），否则被测环境与真实
#  镜像不一致（漂移检测前提是「装的东西一致」）；apt 环境（policy-rc.d、no-recommends、
#  force-confold）须与真实构建一致，已在上方单独设置。
# ------------------------------------------------------------------------------
docker run -d --name "$CONTAINER" --privileged "$BASE_IMAGE" sleep infinity >/dev/null
log "已启动一次性容器（${BASE_IMAGE}）"

# 必须与 image/build/base.sh 的 apt 环境保持一致，否则官方安装脚本里的
# systemctl/invoke-rc.d 行为会与真实构建不同，可能挂起或产生不一样的目录落点。
log '同步真实构建的 apt 环境（移除 policy-rc.d、关闭推荐包、强制保留旧配置）'
docker exec -i "$CONTAINER" bash -s <<'EOS'
set -e
rm -f /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive
echo 'APT::Install-Recommends "false";' >  /etc/apt/apt.conf.d/01norecommends
echo 'APT::Install-Suggests "false";'   >> /etc/apt/apt.conf.d/01norecommends
echo 'DPkg::Options { "--force-confold"; "--force-confdef"; }' \
    > /etc/apt/apt.conf.d/02dpkg-options
EOS

docker exec -i "$CONTAINER" bash -s <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates \
    systemd systemd-sysv dbus dbus-user-session \
    cron rsyslog \
    openssh-server \
    procps psmisc lsof htop \
    net-tools iproute2 iputils-ping dnsutils \
    curl wget \
    tar xz-utils zip unzip gzip bzip2 rsync \
    lsb-release sudo \
    busybox-static \
    vim-tiny less file
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOS
log '前置软件包已就绪'

# ------------------------------------------------------------------------------
#  1. 目录漂移检测
# ------------------------------------------------------------------------------
WWW_BEFORE=$(www_subdirs)
BEFORE=$(count_top_dirs)

log '执行官方安装脚本（参数与 image/build/panel.sh 保持一致）'
# 给 wget 加超时与重试，避免 download.bt.cn 瞬时无响应导致下载挂死
ok=0
for i in 1 2 3; do
    if docker exec "$CONTAINER" bash -c "cd /root && wget -T 30 -t 1 -O install.sh '${INSTALL_URL}'" >/dev/null 2>&1; then
        ok=1; break
    fi
    log "下载安装脚本第 ${i} 次失败，$((i * 5))s 后重试"
    sleep $((i * 5))
done
[ "${ok}" = 1 ] || die "下载安装脚本失败：${INSTALL_URL}"

# 流式执行：后台跑安装、前台 tail 实时进度，避免长静默像卡死。
# 官方安装脚本通过 exec > >(tee -a /tmp/btpanel-install.log) 2>&1 把进度写进该日志。
# 外层包 timeout 5400（90 分钟）防止安装脚本因 systemctl/网络等原因无限挂起。
#
# 注意：官方脚本末尾会启动后台进程（如监控、证书异步检查等），这些后台进程
# 因进程替换仍持有脚本 stdout，导致主 bash 进程无法立即退出。我们不能无限等
# "install.sh" 进程消失，而是等"日志不再增长且面板主程序已就位"就视为完成。
docker exec -d "$CONTAINER" bash -c "cd /root && timeout 5400 bash install.sh -y --ssl-disable" \
    || die '官方安装脚本启动失败'
log '官方安装脚本执行中（实时输出见下方），请稍候…'
docker exec "$CONTAINER" tail -F /tmp/btpanel-install.log 2>/dev/null &
_TAIL_PID=$!

elapsed=0
last_size=-1
idle=0
while docker exec "$CONTAINER" bash -c 'pgrep -f "install.sh" >/dev/null 2>&1'; do
    sleep 5
    elapsed=$((elapsed + 5))

    if [ "$((elapsed % 60))" -eq 0 ]; then
        log "安装仍在运行，已等待 ${elapsed}s…"
        # 每分钟把当前安装日志落盘到 /tmp/uw，即使后续被 CI 超时杀掉也能留下现场
        docker cp "$CONTAINER:$INSTALL_LOG" /tmp/uw/btpanel-install.log.partial >/dev/null 2>&1 || true
    fi

    # 日志静止 2 分钟且面板主程序已就位 => 认为安装已实质完成
    current_size=$(docker exec "$CONTAINER" bash -c "stat -c%s '${INSTALL_LOG}' 2>/dev/null || echo 0")
    if [ "${current_size}" = "${last_size}" ]; then
        idle=$((idle + 5))
        if [ "${idle}" -ge 120 ] && docker exec "$CONTAINER" bash -c 'ls /www/server/panel/BT-P* >/dev/null 2>&1'; then
            log '安装日志已静止 2 分钟且面板主程序在位，视为安装完成'
            break
        fi
    else
        idle=0
        last_size="${current_size}"
    fi
done
kill "$_TAIL_PID" 2>/dev/null || true
wait "$_TAIL_PID" 2>/dev/null || true

# 若因日志静止而提前跳出，后台可能还残留 install 相关进程；杀掉它们以便后续清理
docker exec "$CONTAINER" bash -c 'pkill -9 -f "install.sh" 2>/dev/null || true' >/dev/null 2>&1 || true
sleep 2

# 最终把安装日志拷出来，方便超时/失败后排查
if docker cp "$CONTAINER:$INSTALL_LOG" /tmp/uw/btpanel-install.log >/dev/null 2>&1; then
    log '安装日志已导出到 /tmp/uw/btpanel-install.log'
fi

# 成功判据：面板主程序已就位（与原「依赖退出码」等价，但兼容后台执行；
# core A4 同样以 /www/server/panel/BT-P* 存在作为面板装好的标志）
if docker exec "$CONTAINER" bash -c 'ls /www/server/panel/BT-P* >/dev/null 2>&1'; then
    log '安装完成，开始比对'
else
    docker exec "$CONTAINER" bash -c "tail -n 80 '${INSTALL_LOG}'" >&2 || true
    die '官方安装脚本执行失败'
fi

# ------------------------------------------------------------------------------
#  1.5 附加守卫（裸上游也能验的两件事；与 image/build/panel.sh + core A16 互补）
# ------------------------------------------------------------------------------
guard_anchor=''
guard_smoke=''
guard_extra() {
    local crit=0
    local _anchor="BT-Task' not in comm"

    # (a) 看门狗判定锚点：我们的 patch_task_watchdog 靠它定位。上游一旦改了看门狗
    #     判定，构建期 assert 与 core A16 都会失败——这里先一步在漂移里预警。
    log '检查上游看门狗判定锚点（决定我们的补丁能否打上）'
    if docker exec "$CONTAINER" bash -c "grep -rqF \"${_anchor}\" /www/server/panel/BT-P* 2>/dev/null"; then
        log '上游看门狗仍用 comm 判定，我们的 cmdline 补丁锚点有效'
        guard_anchor='✅ 锚点仍在（补丁可打）'
    else
        warn '上游看门狗判定已改，我们的看门狗补丁可能无法应用（需人工复查 patch_task_watchdog）'
        crit=1
        guard_anchor='❌ 锚点丢失（补丁将失败）'
    fi

    # (b) 面板冒烟：裸装后面板应起来并响应 HTTP（抓上游安装脚本自身坏掉这类
    #     目录比对抓不到的回归）。裸容器无 systemd，拉起方式可能与真机不同，
    #     起不来只告警、不直接判死——真正的「面板能起」由构建门禁 core 验。
    log '面板冒烟：等待面板 HTTP 起来'
    local _port=8888 _up=0 _i
    for _i in $(seq 1 12); do
        if docker exec "$CONTAINER" bash -c "curl -fsS -o /dev/null 'http://127.0.0.1:${_port}/' 2>/dev/null"; then
            _up=1; break
        fi
        sleep 5
    done
    if [ "$_up" = 0 ]; then
        docker exec "$CONTAINER" bash -c '/etc/init.d/bt start >/dev/null 2>&1' || true
        for _i in $(seq 1 12); do
            if docker exec "$CONTAINER" bash -c "curl -fsS -o /dev/null 'http://127.0.0.1:${_port}/' 2>/dev/null"; then
                _up=1; break
            fi
            sleep 5
        done
    fi
    if [ "$_up" = 1 ]; then
        log "面板在 :${_port} 正常响应"
        guard_smoke='✅ 面板 HTTP 可响应'
    else
        warn "面板 HTTP 在裸容器未起来（可能是无 systemd 的启动差异，CI 构建门禁 core 会真验）"
        guard_smoke='⚠️ 裸容器未起（需结合构建门禁判断）'
    fi

    [ "$crit" = 0 ] || return 1
}
if ! guard_extra; then
    CRITICAL=1
fi

AFTER=$(count_top_dirs)

declare -A BEFORE_MAP=() AFTER_MAP=()
while read -r d n; do [ -n "${d:-}" ] && BEFORE_MAP["$d"]="$n"; done <<< "$BEFORE"
while read -r d n; do [ -n "${d:-}" ] && AFTER_MAP["$d"]="$n"; done <<< "$AFTER"

{
    echo '### 目录漂移检测'
    echo
    echo "> 安装脚本：\`${INSTALL_URL}\`"
    echo
    echo '| 顶层目录 | 安装前 | 安装后 | 新增 | 状态 |'
    echo '|---|---:|---:|---:|---|'
} >> "$OUT_MD"

DIRS=$(printf '%s\n%s\n' "$BEFORE" "$AFTER" | awk '{print $1}' | sort -u)
# shellcheck disable=SC2086
for d in $DIRS; do
    b="${BEFORE_MAP[$d]:-0}"
    a="${AFTER_MAP[$d]:-0}"
    delta=$(( a - b ))
    [ "$delta" -gt 0 ] || continue
    if in_known_dirs "$d"; then
        printf '| `/%s` | %s | %s | %s | ✅ 已被持久化覆盖 |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    elif [ "$d" = 'www' ]; then
        # /www 的子路径各有归属，顶层计数没有意义，交给下面的子目录比对
        printf '| `/%s` | %s | %s | %s | ℹ️ 按子路径处理（见下表） |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    else
        printf '| `/%s` | %s | %s | %s | ❌ **未覆盖，会静默丢数据** |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
        warn "未覆盖的写入目录：/${d}（新增 ${delta} 个文件）"
        CRITICAL=1
    fi
done

# /www 的子目录漂移：新出现的子路径如果不在声明清单里，按关键漂移报出来
WWW_AFTER=$(www_subdirs)
{
    echo
    echo '| `/www` 子目录 | 状态 |'
    echo '|---|---|'
} >> "$OUT_MD"
for sub in $WWW_AFTER; do
    case " $(printf '%s' "$WWW_BEFORE" | tr '\n' ' ') " in
        *" ${sub} "*) continue ;;   # 装之前就有：上游行为没变
    esac
    state=''
    # shellcheck disable=SC2086
    for p in $WWW_PERSIST_SUBDIRS; do
        [ "$p" = "$sub" ] && state='✅ 已在声明清单内（持久化）'
    done
    # shellcheck disable=SC2086
    for p in $WWW_VOLATILE_SUBDIRS; do
        [ "$p" = "$sub" ] && state='⚪ 按设计不持久化（重建即清空）'
    done
    if [ -n "$state" ]; then
        printf '| `www/%s` | %s |\n' "$sub" "$state" >> "$OUT_MD"
    else
        printf '| `www/%s` | ❌ **新出现且未声明，需人工确认怎么持久化** |\n' "$sub" >> "$OUT_MD"
        warn "未声明的 /www 子目录：/www/${sub}"
        CRITICAL=1
    fi
done

# ------------------------------------------------------------------------------
#  结论
# ------------------------------------------------------------------------------
{
    echo
    echo '### 附加守卫（裸上游可验，与 core A16 互补）'
    echo
    echo "| 项 | 结果 |"
    echo '|---|---|'
    echo "| 看门狗判定锚点 \`BT-Task' not in comm\` | ${guard_anchor} |"
    echo "| 面板冒烟（裸装后 HTTP 可响应） | ${guard_smoke} |"
    echo
    echo '### 结论'
    echo
    if [ "$CRITICAL" -eq 0 ]; then
        echo '✅ 未检测到会破坏持久化的上游变更（数据仍全部落在持久化目录内）。'
    else
        echo '❌ 检测到关键漂移，需人工介入（详见上文）。'
    fi
} >> "$OUT_MD"

echo "$CRITICAL" > "$CRITICAL_FILE"
mv -f "${OUT_MD}" "${_OUT_MD_FINAL}"
log "检测完成（关键漂移：${CRITICAL}），报告：${_OUT_MD_FINAL}"
)

# ==============================================================================
#  静态检查工具（原 lint.sh 已并入）：check.sh lint <子命令>
# ==============================================================================
# 把 workflow 的 run: 块抽成 .sh；$1=输出目录 $2=单个 yml（空=全部）$3=补 shebang(1/0)
# 静态检查与 bash -n 共用这一份抽取逻辑，避免两边漂移
extract_run_blocks() (
python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys, yaml
out_dir, single_src, shebang = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
srcs = ([pathlib.Path(single_src)] if single_src
        else sorted(pathlib.Path('.github/workflows').glob('*.yml')))
for src in srcs:
    doc = yaml.safe_load(src.read_text(encoding='utf-8'))
    n = 0
    def walk(node):
        global n
        if isinstance(node, dict):
            for k, v in node.items():
                if k == 'run' and isinstance(v, str):
                    n += 1
                    stem = src.stem if not single_src else ''
                    name = f'{stem}-{n:02d}.sh' if stem else f'{n:02d}.sh'
                    text = ('#!/bin/bash\n' if shebang else '') + v
                    (pathlib.Path(out_dir) / name).write_text(text, encoding='utf-8')
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(doc)
PY
)

# 下载 shellcheck、检查 .sh 与 workflow 内嵌 run 块（PATH 里没有时落到 .cache）
run_shellcheck() (
# --- 1. 确保 shellcheck 可用（PATH 没有就下载到 .cache）---
SC_DIR=.cache/shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  SC_BIN=shellcheck
else
  mkdir -p "$SC_DIR"
  if [ ! -x "$SC_DIR/shellcheck" ] || ! "$SC_DIR/shellcheck" --version >/dev/null 2>&1; then
    ver=v0.10.0
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    m=$(uname -m)
    # release 资产按真实架构区分；缓存的异架构二进制（Bad CPU type）也在此重下
    case "$m" in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
    url="https://github.com/koalaman/shellcheck/releases/download/${ver}/shellcheck-${ver}.${os}.${arch}.tar.xz"
    echo "  下载 shellcheck：${url}"
    rm -f "$SC_DIR/shellcheck"
    # --http1.1：部分代理下 HTTP/2 会报 framing layer 错误；--retry 抗瞬时断流
    curl --http1.1 -fsSL --retry 2 "$url" -o "$SC_DIR/shellcheck.tar.xz" \
      && tar -xf "$SC_DIR/shellcheck.tar.xz" -C "$SC_DIR" --strip-components=1 \
      && rm -f "$SC_DIR/shellcheck.tar.xz" \
      && "$SC_DIR/shellcheck" --version >/dev/null 2>&1 \
      || { echo "  FAIL 下载 shellcheck 失败（网络或架构不匹配？）"; exit 1; }
  fi
  SC_BIN="$SC_DIR/shellcheck"
fi
echo "  shellcheck：$("${SC_BIN}" --version | awk 'NR==2')"

# --- 2. .sh 脚本（--source-path=. 让 source 指令解析到仓库根真源）---
echo "--- shellcheck（.sh 脚本）---"
sh_files=()
# data/ 是运行期持久化数据（含用户站点），不属于仓库源码，且常有权限禁区
while IFS= read -r f; do sh_files+=("$f"); done < <(find . -path './.git' -prune -o -path './data' -prune -o -name '*.sh' -print)
if "${SC_BIN}" -x --source-path=. -S warning "${sh_files[@]}"; then
  echo "  ok  全部 .sh 通过"
else
  echo "  FAIL shellcheck 在 .sh 脚本中发现问题"
  exit 1
fi

# --- 3. workflow 内嵌 run 块（这里曾是未定义变量 bug 的藏身处）---
echo "--- shellcheck（workflow 内嵌 run 块）---"
tmp=$(mktemp -d)
extract_run_blocks "$tmp" '' 1 || { echo '  FAIL workflow run 块抽取失败'; exit 1; }
# 排除 GitHub ${{ }} 模板导致的误报；保留 SC2154（未定义变量）
if "${SC_BIN}" -S warning -e SC2296 -e SC2195 -e SC2050 -e SC2193 "$tmp"/*.sh; then
  echo "  ok  workflow 内嵌脚本通过"
else
  echo "  FAIL workflow 内嵌脚本中发现问题（重点查 SC2154 未定义变量）"
  rc=1
fi
rm -rf "$tmp"
[ "${rc:-0}" -eq 0 ]
)

# 配置真源唯一：受管变量只允许在 defaults.env 有默认值
run_config() (
TRUTH=image/conf/defaults.env
FILES=(
    image/scripts/init.sh
    image/scripts/entrypoint.sh
    image/scripts/backup.sh
    image/scripts/healthcheck.sh
    image/scripts/common.sh
    image/build/services.sh
    .github/scripts/check.sh
)
VARS=(
    PERSIST_DATA_ROOT
    PERSIST_SYSTEM_ROOT
    PERSIST_SYSTEM_DIRS
    PERSIST_SYSTEM_IMAGE_SIZE_MB
    WWW_DATA_SUBDIRS
    WWW_OPTIONAL_SUBDIRS
    META_VERSION_FILE
    META_DIGEST_FILE
    META_BOOT_FILE
    PANEL_STATE_ROOT
    PANEL_STATE_SUBDIRS
    PANEL_PYENV_OVERLAY
    CRITICAL_DIRS
    AUTO_SNAPSHOT_KEEP
    AUTO_SNAPSHOT_MODE
)
# PERSIST_SYSTEM_IMAGE 刻意不进本清单：它是 opt-in 开关，默认值为**空**
# （留空 = 用默认布局），而本检查要求受管变量有非空默认值。脚本里对它的引用
# 一律写成 ${PERSIST_SYSTEM_IMAGE:-}（空值保护），不受「不许写默认值副本」约束

[ -f "$TRUTH" ] || { echo "  FAIL 真源不存在：$TRUTH"; exit 1; }

# 真源必须为每个受管变量提供默认值（否则脚本拿到空值，行为不可预期）
rc=0
for v in "${VARS[@]}"; do
    grep -qE "^${v}=\"\\\$\{${v}:-.+\}\"$" "$TRUTH" \
        || { echo "  FAIL 真源缺少默认值：${TRUTH} 里的 ${v}"; rc=1; }
done

# 其它脚本不许再写默认值副本
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    for v in "${VARS[@]}"; do
        # 只认「非空默认值」：`${VAR:-}` 这种空值保护放行
        if grep -nE "\\\$\{${v}:?-[^}]" "$f" > /dev/null 2>&1; then
            # 变量一律写成 ${x}：bash 会把全角冒号当成变量名的一部分
            echo "  FAIL ${f}：${v} 又写了默认值副本（真源只能是 ${TRUTH}）"
            grep -nE "\\\$\{${v}:?-[^}]" "$f" | head -3 | sed 's/^/       /'
            rc=1
        fi
    done
done

if [ "$rc" -eq 0 ]; then
    echo "  ok  配置真源唯一（${#VARS[@]} 个变量只在 $(basename "$TRUTH") 里定义默认值）"
else
    echo '  改配置请只改 image/conf/defaults.env，脚本里不要再写兜底副本'
fi
exit "$rc"
)

# 命名规范：禁用标识符 / 自造缩写 / 容器名 / 卷名 / 前后缀 / 术语 / 声明表
run_naming() (
python3 - <<'PY'
import pathlib, re, sys

bad: list[str] = []

# ---------------------------------------------------------------- ① 禁用标识符
# 出现过就说明又有人在自造缩写 / 用回已废弃的旧名。
# 词边界匹配：避免 `SYSTEM` 被 `SYS` 命中、`CONTAINERS` 被 `C` 命中。
BANNED = [
    'SYS', 'VFILE', 'CNAME', 'KNOWNS', 'in_knowns', 'CRIT_FILE', 'SNAP',
    'HC', 'COMPOSE_DIR', 'CHANNEL', 'channel', 'channels.conf', 'AUTO_BACKUP_KEEP',
    'WWW_PERSIST', 'WWW_VOLATILE', 'data_members', 'pythonreal',
    'STAGE2', 'PERSIST_DIRS', 'show_usage',
    # 已废弃的旧名：写回来说明是在照抄旧文档
    'bt-drift', 'assert_no_readonly_warning', 'reset-panel', 'health-mounts',
    'mounts.sh', 'DEGRADED_CRITICAL', 'BAOTA_STATE', 'PERSIST_ROOT',
]
SCAN_SUFFIX = {'.sh', '.yml', '.yaml', '.env', '.conf', '.service', ''}
SCAN_DIRS = ['image', '.github/scripts', '.github/workflows']
SCAN_FILES = ['Makefile', 'docker-compose.yml']

def lines_of(path: pathlib.Path):
    """产出 (行号, 行)；.sh 里 heredoc 正文是内嵌 Python，不当 bash 标识符扫描"""
    text = path.read_text(encoding='utf-8')
    if path.suffix != '.sh':
        yield from enumerate(text.splitlines(), 1)
        return
    delim = None
    for n, line in enumerate(text.splitlines(), 1):
        if delim:
            if line.strip() == delim:
                delim = None
            continue
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if m:
            delim = m.group(1)
            continue
        yield n, line

targets: list[pathlib.Path] = [pathlib.Path(f) for f in SCAN_FILES if pathlib.Path(f).exists()]
for d in SCAN_DIRS:
    p = pathlib.Path(d)
    if p.exists():
        targets += [f for f in p.rglob('*')
                    if f.is_file() and f.suffix in SCAN_SUFFIX]

for f in targets:
    try:
        text = f.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for lineno, line in lines_of(f):
        if line.lstrip().startswith('#'):
            continue          # 注释里举例说明「不该叫 X」是允许的
        for word in BANNED:
            if re.search(r'\b' + re.escape(word) + r'\b', line):
                bad.append(f'{f}:{lineno}: 禁用标识符 `{word}` → {line.strip()[:70]}')

# ------------------------------------------------------------------ ② 容器名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in lines_of(f):
        for m in re.finditer(r'(?:--name[= ]"?|(?:CONTAINER|CNAME)=")([a-z][a-z0-9_-]*)', line):
            name = m.group(1)
            if not name.startswith('baota-'):
                bad.append(f'{f}:{lineno}: 容器名 `{name}` 未用 baota- 前缀 → {line.strip()[:70]}')

# -------------------------------------------------------------------- ③ 卷名
for f in [p for p in targets if p.suffix in ('.sh', '.yml', '.yaml')]:
    for lineno, line in lines_of(f):
        # 卷名形如 `baota-verify-data-$$`：尾部可能是 PID 占位符，先剥掉再判后缀
        for m in re.finditer(r'(?:VOLUME|VOL_RO|VOLUME_NAME)="([a-z][a-z0-9_$-]*)', line):
            name = m.group(1).replace('$$', '').rstrip('-')
            if not re.search(r'-(data|ro)$', name):
                bad.append(f'{f}:{lineno}: 卷名 `{name}` 应以 -data 或 -ro 结尾 → {line.strip()[:70]}')

# -------------------------------------------------------------- ④ 配置变量名
ALLOWED_SUFFIX = ('_ROOT', '_DIR', '_DIRS', '_FILE', '_BIN', '_SUBDIRS',
                  '_MIN', '_MAX', '_MB', '_PCT', '_KEEP')
ALLOWED_PREFIX = ('META_', 'IMAGE_', 'PERSIST_', 'WWW_', 'PANEL_',
                  'CRITICAL_', 'DISK_', 'AUTO_')
truth = pathlib.Path('image/conf/defaults.env')
for lineno, line in enumerate(truth.read_text(encoding='utf-8').splitlines(), 1):
    m = re.match(r'^([A-Z][A-Z0-9_]+)="\$\{\1:-', line)
    if not m:
        continue
    name = m.group(1)
    if not (name.endswith(ALLOWED_SUFFIX) or name.startswith(ALLOWED_PREFIX)):
        bad.append(f'{truth}:{lineno}: 变量名 `{name}` 的前缀/后缀不在约定内'
                   f'（允许后缀 {" ".join(ALLOWED_SUFFIX)}；允许前缀 {" ".join(ALLOWED_PREFIX)}）'
                   f' → 新变量请同步 docs/development.md §5')

# ------------------------------------------------------------------ ⑤ 中文术语
docs = [p for p in pathlib.Path('.').rglob('*.md')
        if '.git/' not in str(p) and p.name != 'CHANGELOG.md']
for f in docs:
    for lineno, line in lines_of(f):
        if '通道' in line:
            bad.append(f'{f}:{lineno}: 术语「通道」已废弃，统一叫「线」→ {line.strip()[:70]}')

# ---------------------------------------------------- ⑥ 运行期脚本一律 .sh 后缀
# 它们由 Dockerfile 逐条 COPY 到 /baota，同目录混着无后缀文件，会让 COPY、
# chmod 与门禁断言各写一套名字（曾经的 `shim` 就是这样）
for f in sorted(pathlib.Path('image/scripts').iterdir()):
    if f.is_file() and f.suffix != '.sh':
        bad.append(f'{f}: 运行期脚本缺少 .sh 后缀（image/scripts/ 下一律 .sh）')

# ---------------------------------------------------------------- ⑦ 线声明表
lines_conf = pathlib.Path('image/lines.conf')
if not lines_conf.exists():
    bad.append('缺少 image/lines.conf（线声明表）')
else:
    head = [l for l in lines_conf.read_text(encoding='utf-8').splitlines()
            if l.strip().startswith('#  line')]
    if not head or 'line' not in head[0] or 'display' not in head[0]:
        bad.append('image/lines.conf 的列标题行缺少 line / display 两列')

# ---------------------------------------------------------------- ⑧ 自造缩写
# §4：缩写只在**业界通用**时才用，白名单就 rc / pid / sha / tmp 四个。
# 机器分不出「缩写」与「本就完整的短单词」—— SAFE / PORT / MODE / ICON 是完整
# 单词，SRC / DST / PKG 是把一个词截断，没有字典就判不出来。所以只能列清单：
# 新踩到一个就往这里加一个，并把对应的全称同步进 docs/development.md §4 与
# skills/baota-docker/SKILL.md 的红线，让下一个人不用再踩同一个坑。
ABBREV = {
    'SRC':  'source',
    'DST':  'target（dest 同样是缩写，别换过去）',
    'PKG':  'BACKUP_FILE（路径变量的 _FILE 后缀见 §5）',
    'CFG':  'config',
    'TMPL': 'template',
}
for f in targets:
    try:
        text = f.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for lineno, line in lines_of(f):
        if line.lstrip().startswith('#'):
            continue          # 同 ①：注释里举例「不该叫 X」是允许的
        # 必须把标识符按 _ 拆开再比：`\bSRC\b` 抓不到 SRC_CONTAINER —— 下划线是
        # 词字符，SRC 后面没有词边界，整词匹配会静默漏掉「缩写 + 后缀」这种写法，
        # 而那恰恰是缩写最常见的出现形式（SRC_CONTAINER / DST_VOLUME / PKG_PATH）
        for token in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', line):
            for part in re.split(r'[^A-Za-z0-9]+', token):
                if part in ABBREV:
                    bad.append(f'{f}:{lineno}: 自造缩写 `{part}` → 写全称'
                               f' {ABBREV[part]} → {line.strip()[:60]}')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    print('  命名规范见 docs/development.md；改约定时要同时改本检查')
    sys.exit(1)
print('  ok  命名规范（禁用标识符 / 自造缩写 / 容器名 / 卷名 / 变量前后缀 / 术语 / 声明表）')
PY
)

# 注释体积：文件头 ≤16 行、连续注释块 ≤10 行
run_comments() (
python3 - <<'PY'
import pathlib, sys

HEAD_MAX = 16
BLOCK_MAX = 10
# 这些文件的注释块本身就是「给人读的说明」，放宽到 30 行
LENIENT = {'image/lines.conf': 30}

SCAN = []
for d in ('image', '.github/scripts', '.github/workflows'):
    p = pathlib.Path(d)
    if p.exists():
        SCAN += [f for f in p.rglob('*')
                 if f.is_file() and f.suffix in {'.sh', '.yml', '.env', '.conf', '.service', ''}]
for name in ('docker-compose.yml', 'Makefile', '.dockerignore', '.editorconfig', '.shellcheckrc'):
    f = pathlib.Path(name)
    if f.exists():
        SCAN.append(f)

bad: list[str] = []
for f in sorted(set(SCAN)):
    try:
        lines = f.read_text(encoding='utf-8').splitlines()
    except (UnicodeDecodeError, OSError):
        continue
    if not lines:
        continue

    limit_head = LENIENT.get(str(f), HEAD_MAX)

    # 切出连续注释块：(起始行号, 长度)。首行 shebang 不计入。
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith('#') and not lines[i].startswith('#!'):
            j = i
            while j < len(lines) and (lines[j].lstrip().startswith('#')
                                      or (j == i and lines[j].startswith('#!'))):
                j += 1
            blocks.append((i, j - i))
            i = j
        else:
            i += 1
    if not blocks:
        continue

    start, n = blocks[0]
    if n > limit_head:
        bad.append(f'{f}:{start+1}: 文件头注释 {n} 行 > 上限 {limit_head} 行')

    limit_block = LENIENT.get(str(f), BLOCK_MAX)
    for start, n in blocks[1:]:
        if n > limit_block:
            bad.append(f'{f}:{start+1}: 注释块 {n} 行 > 上限 {limit_block} 行'
                       f'（长推导写进 docs/，这里留一行指针）')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    print('  注释规范见 docs/development.md「注释与文档规范」')
    sys.exit(1)
print(f'  ok  注释体积（文件头 ≤{HEAD_MAX} 行、注释块 ≤{BLOCK_MAX} 行）')
PY
)

# 文档链接与锚点：目标存在、标题不缺空格、一篇只有一个 H1
run_links() (
python3 - <<'PY'
import pathlib, re, sys

def slug(text: str) -> str:
    """近似 GitHub 的标题 slug：小写 → 去掉标点 → 空白转 -"""
    s = text.strip().lower()
    s = re.sub(r'[^\w\s\u4e00-\u9fff-]', '', s)   # 标点直接删（不是替换成 -）
    s = re.sub(r'\s+', '-', s)
    return s.strip('-')

def anchors(path: pathlib.Path):
    out = set()
    for line in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        if line.startswith('#'):
            out.add(slug(line.lstrip('#').strip()))
    return out

bad = []

def headings(path: pathlib.Path, content: str):
    """逐行产出 (行号, 行) 形式的真标题 —— 跳过围栏代码块里的 `# 注释`"""
    fenced = False
    for i, line in enumerate(content.splitlines(), 1):
        if re.match(r'^\s*(```|~~~)', line):
            fenced = not fenced
            continue
        if fenced:
            continue
        if re.match(r'^#{1,6}(\s|$)', line):
            yield i, line
        elif re.match(r'^#{1,6}[^\s#]', line):
            bad.append(f'{path}:{i}: 标题缺少空格（GitHub 会当正文）→ {line}')
            yield i, line

docs = [p for p in pathlib.Path('.').glob('**/*.md')
        if not any(x in str(p) for x in ('.git/', 'data/'))]

for f in docs:
    content = f.read_text(encoding='utf-8', errors='ignore')
    h1 = [i for i, line in headings(f, content) if re.match(r'^#\s', line)]
    if len(h1) > 1:
        bad.append(f'{f}: 出现 {len(h1)} 个一级标题（行 {", ".join(map(str, h1))}），'
                   f'只有首个是对的，其余应为更低层级（报告是注入进来的，'
                   f'见 .github/scripts/check.sh report）')
    for m in re.finditer(r'\]\(([^)#\s]+)(?:#([^)]*))?\)', content):
        target, anchor = m.group(1), m.group(2)
        if target.startswith(('http://', 'https://', 'mailto:')):
            continue
        p = (f.parent / target).resolve()
        if not p.exists():
            bad.append(f'{f}: 链接目标不存在 → {target}')
            continue
        if anchor and p.suffix == '.md' and anchor not in anchors(p):
            bad.append(f'{f}: 锚点不存在 → {target}#{anchor}')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    sys.exit(1)
print(f'  ok  文档内部链接、锚点与标题层级有效（{len(docs)} 篇）')
PY
)

# workflow 内嵌 run 块必须是合法 bash（bash -n 看不到它们）
run_workflow() (
rc=0
for f in .github/workflows/*.yml; do
    [ -f "$f" ] || continue
    tmp=$(mktemp -d)
    if ! extract_run_blocks "$tmp" "$f" 0; then
        echo "  FAIL ${f}：解析失败（YAML 或内嵌脚本抽取出错）"
        rc=1
        rm -rf "$tmp"
        continue
    fi

    bad=0
    for s in "$tmp"/*.sh; do
        [ -f "$s" ] || continue
        bash -n "$s" || { echo "  FAIL ${f}：第 $(basename "$s" .sh) 个 run 块不是合法 bash"; bad=1; rc=1; }
    done
    [ "$bad" -eq 0 ] && echo "  ok  ${f}（内嵌 run 块语法正确）"
    rm -rf "$tmp"
done

[ "$rc" -eq 0 ] || echo '  修 workflow 里的 run 块后重跑 make lint'
exit "$rc"
)

# 报告注入 README 标记区（由原 report.py 合并）：整篇标题降 2 级后替换标记区
run_report() (
python3 - "$1" "$2" <<'PY'
import re, sys, pathlib

DEMOTE = 2

def demote_headings(text: str) -> str:
    out, fenced = [], False
    for line in text.splitlines():
        if re.match(r'^\s*(```|~~~)', line):
            fenced = not fenced
            out.append(line)
            continue
        m = None if fenced else re.match(r'^(#{1,6})(\s.*)$', line)
        out.append('#' * min(len(m.group(1)) + DEMOTE, 6) + m.group(2) if m else line)
    return '\n'.join(out)

readme_path = pathlib.Path('README.md')
report_path = pathlib.Path(sys.argv[1] or '.github/reports/report.md')
marker = sys.argv[2] or 'DAILY-VERIFY-REPORT'
if not readme_path.exists():
    sys.exit('README.md 不存在')
if not report_path.exists():
    sys.exit(f'{report_path} 不存在')
start = f'<!-- {marker}:START -->'
end = f'<!-- {marker}:END -->'
readme = readme_path.read_text(encoding='utf-8')
report = demote_headings(report_path.read_text(encoding='utf-8'))
pat = re.compile(re.escape(start) + r'.*?' + re.escape(end), re.S)
if not pat.search(readme):
    sys.exit(f'README.md 缺少报告注入标记 {marker}，请先添加 {marker}:START/END 标记区')
readme = pat.sub(lambda m: f'{start}\n{report.strip()}\n{end}', readme)
readme_path.write_text(readme, encoding='utf-8')
print(f'已注入 README 报告区（{marker}）')
PY
)

usage() {
    sed -n '2,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

MODE=${1:-all}
if [ $# -gt 0 ]; then shift; fi

case "${MODE}" in
    lint)
        sub="${1:-all}"
        case "$sub" in
            all)
                echo '--- shellcheck ---';         run_shellcheck || exit 1
                echo '--- 配置真源一致性 ---';     run_config     || exit 1
                echo '--- 命名规范 ---';           run_naming     || exit 1
                echo '--- 注释体积 ---';           run_comments   || exit 1
                echo '--- 文档链接与锚点 ---';     run_links      || exit 1
                echo '--- workflow 内嵌脚本 ---';  run_workflow   || exit 1
                ;;
            shellcheck|config|naming|comments|links|workflow)
                "run_${sub}" || exit 1
                ;;
            *)
                echo "用法: check.sh lint [all|shellcheck|config|naming|comments|links|workflow]" >&2
                exit 2
                ;;
        esac
        ;;
    report)
        run_report "${1:-}" "${2:-}" || exit 1
        ;;
    all)
        [ $# -ge 2 ] || { echo "用法: check.sh all <镜像> <期望版本>" >&2; exit 1; }
        run_core "$@"           || exit 1
        run_degrade "$1"        || exit 1
        run_upgrade "$@"        || exit 1
        run_restore "$1"        || exit 1
        ;;
    core|degrade|upgrade|restore|published|drift)
        "run_${MODE}" "$@" || exit 1
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "未知子命令：${MODE}" >&2
        usage >&2
        exit 1
        ;;
esac
