#!/usr/bin/env bash
# ==============================================================================
#  🩺 宝塔面板镜像发布前健康检查（CI 门禁）
#
#  用法：bash run.sh core <镜像名:标签> <期望的宝塔版本号>
#        （也可直接执行本脚本，参数相同）
#
#  镜像先在本地构建并 --load，绝不推送；本脚本全部通过之后，workflow 才登录
#  并推送。任一检查失败即非零退出，阻断发布。
#
#  两阶段共 19 项，针对「本容器化方案 + 真机宝塔体验」定制，不是通用探活：
#    A 全新数据卷：systemd / overlay 可写 / 关键路径（含 pyenv 模块）/
#                  面板与任务进程 / 安全入口 / 版本号 / 首启凭据 / 写入落盘 /
#                  自启 / 补丁 / 防火墙关闭 / SSH 与 bt 命令 / 日志体积防线 /
#                  健康检查判据 / 备份工具
#    B 销毁容器后用同一个卷重建：数据不丢、不会二次初始化、面板自动恢复
#
#  本脚本只在 CI runner 上执行，放在 .github/ 下即可被 .dockerignore 整体排除，
#  不会进入生产镜像。
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: run.sh core <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: run.sh core <镜像> <期望版本>}

CONTAINER="baota-healthcheck-$$"
VOLUME="baota-healthcheck-data-$$"

# 配置真源：与镜像共用 shared/conf/defaults.env，不在本脚本里再写一份硬编码。
# 两边一旦漂移，表现是「CI 测过的和线上跑的不是同一套目录」，必须在这里对齐
read_default() {
    sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" shared/conf/defaults.env
}

PERSIST_DATA_DIRS=$(read_default PERSIST_DATA_DIRS)
PERSIST_SYSTEM_DIRS=$(read_default PERSIST_SYSTEM_DIRS)
[ -n "${PERSIST_DATA_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_DATA_DIRS"; exit 1; }
[ -n "${PERSIST_SYSTEM_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_DIRS"; exit 1; }
ALL_PERSIST_DIRS="${PERSIST_DATA_DIRS} ${PERSIST_SYSTEM_DIRS}"
# 两层「根」也一起读真源：落盘路径全部由根 + 成员名拼出来。
# 之前脚本里硬写 /data/www/…，改成从真源派生，以后挪根不会再漏改
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }

pass() { echo "  ✅ $*"; }
step() { echo; echo "🩺 ==== $* ===="; }
fail() {
    echo "::error::$*"
    echo "----- 容器日志尾部 -----"
    docker logs "$CONTAINER" --tail 150 2>/dev/null || true
    echo "----- 日志结束 -----"
    exit 1
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 容器内操作的简写
#   inside      直接执行一条命令
#   inside_sh   在容器里起 sh 执行（需要管道、重定向、通配时用）
#   inside_cat  读取文件内容并去掉全部空白
# ---------------------------------------------------------------------------
inside()     { docker exec "$CONTAINER" "$@"; }
inside_sh()  { docker exec "$CONTAINER" sh -c "$1"; }
inside_cat() { docker exec "$CONTAINER" cat "$1" 2>/dev/null | tr -d '[:space:]' || true; }

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

# ---------------------------------------------------------------------------
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
# ⚠️ curl 失败时 -w '%{http_code}' 依然会输出 000，若写成 `|| echo 000`，
#    得到的是两行 000（$'000\n000'）—— 永远不等于 "000"，等待循环第一次
#    迭代就 break、末尾判定也恒过：面板没起来时这里既不等待也不报错。
#    正确写法是 `|| true` + case 匹配（000 由 -w 自行输出，空值兜底）
wait_panel_http() {
    local port code="" tries=0
    port=$(inside_cat /www/server/panel/data/port.pl)
    [ -n "$port" ] || fail "无法确定面板端口"
    while [ "$tries" -lt 60 ]; do
        code=$(inside curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || true)
        case "$code" in ''|000) ;; *) break ;; esac
        tries=$((tries + 1))
        sleep 2
    done
    case "$code" in
        ''|000) fail "面板端口 ${port} 在 120 秒内没有响应" ;;
    esac
}

# 只读降级是本方案最危险的失效模式：挂载会「成功」，但所有写入静默丢失。
# 判据从「grep 启动日志里的中文文案」改为读容器内的降级标记文件：
# init-mounts.sh 在任何持久化失败/只读降级时都会写 /run/baota/degraded*，
# 这样告警文案怎么改都不影响门禁，也不会漏掉「挂载直接失败」这一类情况
assert_no_readonly_warning() {
    if inside test -e /run/baota/degraded-critical; then
        fail "关键目录未持久化（/run/baota/degraded-critical 存在），数据写入会静默丢失"
    fi
    if inside test -e /run/baota/degraded; then
        fail "存在未持久化目录（/run/baota/degraded）：$(inside cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
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
assert_no_readonly_warning
MOUNTED=$(inside_sh "mount | grep -c 'type overlay'" || true)
MOUNTED=${MOUNTED:-0}
EXPECT_MOUNTS=$(echo "$ALL_PERSIST_DIRS" | wc -w | tr -d ' ')
[ "$MOUNTED" -ge "$EXPECT_MOUNTS" ] \
    || fail "overlay 挂载数 ${MOUNTED}，期望至少 ${EXPECT_MOUNTS} 个"
pass "overlay 挂载 ${MOUNTED} 个，无只读告警"

# 数据层目录落在「数据层根/<dir>」，系统层落在「系统层根/<dir>」
for d in $ALL_PERSIST_DIRS; do
    case " $PERSIST_DATA_DIRS " in
        *" $d "*) m="${PERSIST_DATA_ROOT}/${d}" ;;
        *)            m="${PERSIST_SYSTEM_ROOT}/${d}" ;;
    esac
    inside test -d "$m" || fail "持久化目录缺失：${m}"
done
pass "${EXPECT_MOUNTS} 个持久化目录齐备"

# /tmp 必须留在容器可写层：变成 tmpfs 会让上传、解压备份直接吃内存
if inside_sh 'grep -q " /tmp " /proc/mounts'; then
    fail "/tmp 被单独挂载（应留在容器可写层）"
fi
pass "/tmp 未被 tmpfs 化"

# 日志体积防线：持久化让日志不再随容器销毁而消失，上限与轮转必须就位，
# 否则日志会静默吃掉整个磁盘 —— 这类问题往往几个月后才暴露，只能靠门禁拦住
inside test -f /etc/systemd/journald.conf.d/baota-size.conf \
    || fail "journald 体积上限未就位：日志将退回 systemd 默认值（所在文件系统的 10%）"
inside_sh 'grep -q "^SystemMaxUse=" /etc/systemd/journald.conf.d/baota-size.conf' \
    || fail "journald drop-in 未设置 SystemMaxUse，等于没有上限"
pass "journald 体积上限已就位"

inside test -f /etc/logrotate.d/baota-panel \
    || fail "日志轮转配置缺失：面板与站点日志会一直增长"
inside_sh 'grep -q "copytruncate" /etc/logrotate.d/baota-panel' \
    || fail "轮转未启用 copytruncate：进程持有句柄时日志会写进已删除的文件，空间不释放"
pass "日志轮转已就位（copytruncate）"

# compose 的 healthcheck 判据已收口到镜像内 /baota/healthcheck.sh，
# 这里直接执行它，等于在真实容器里跑一遍生产健康检查（降级标记 / 磁盘水位 / 端口）
step "A3) 执行生产健康检查脚本"
inside test -x /baota/healthcheck.sh \
    || fail "healthcheck 脚本缺失或不可执行（compose 将永远 unhealthy）"
inside /baota/healthcheck.sh \
    || fail "healthcheck 在正常状态下未通过（三段判据之一异常）"
pass "healthcheck 三段判据在正常状态下通过"

step "A4) 校验宝塔关键文件（真机上的实际路径）"
for f in /www/server/panel/BT-Panel \
         /www/server/panel/BT-Task \
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
inside test -e /www/server/panel/data/.docker-initialized \
    || fail "缺少首次初始化标记，entrypoint 的初始化没有执行"
echo "$SAFE" | grep -Eq '^/[0-9a-f]{8}$' \
    || fail "安全入口不是首启随机生成的（当前：${SAFE}）"
DEFAULT_PW=$(inside_cat /www/server/panel/default.pl)
echo "$DEFAULT_PW" | grep -Eq '^[0-9a-f]{12}$' \
    || fail "面板初始口令不是首启随机生成的（当前长度 ${#DEFAULT_PW}）"
# 镜像里 root 是锁定的（shadow 字段以 ! 开头），首启后必须已设置真实口令
if inside_sh 'grep "^root:" /etc/shadow | cut -d: -f2 | grep -q "^[!*]"'; then
    fail "root 口令仍处于锁定状态，SSH 无法登录"
fi
pass "安全入口、面板口令、root 口令均为首启随机生成"

step "A9) 校验写入确实落到持久化层"
inside_sh 'echo persist > /etc/_persist_marker'
inside_sh 'echo persist > /www/_persist_marker'
inside_sh 'mkdir -p /var/spool/cron && echo persist > /var/spool/cron/_persist_marker'
inside_sh 'echo persist > /www/wwwroot/_persist_marker'
# 落盘路径语义（容易搞混，写清楚再检查）：
#   /etc /var      系统层 overlay，upper 在 /data/system/<dir>
#   /www           数据层 overlay，upper = /data/www，与容器内的 /www 一一对应
#   /www/wwwroot   也是 /www 这一层 overlay 的内容，落在 data/www/wwwroot
#                  （没有独立的直通目录 —— /www 整体就是一层 overlay）
inside test -f /data/system/etc/_persist_marker            || fail "/etc 写入未落盘"
inside test -f /data/www/_persist_marker                   || fail "/www 写入未落盘（overlay upper 应为 /data/www）"
inside test -f /data/www/wwwroot/_persist_marker           || fail "/www/wwwroot 写入未落到 /data/www/wwwroot"
inside test -f /data/system/var/spool/cron/_persist_marker || fail "/var 计划任务目录未落盘"
pass "写入已落到 /data/www（含 wwwroot）与 /data/system/<目录>"

step "A10) 校验面板服务开机自启与运行态"
inside systemctl is-enabled btpanel >/dev/null 2>&1 \
    || fail "btpanel 未设置开机自启（重建容器后面板不会自启）"
inside systemctl is-active btpanel >/dev/null 2>&1 \
    || fail "btpanel 服务未处于 active"
pass "btpanel 已启用且运行中"

step "A11) 校验定制补丁生效"
inside test ! -e /www/server/panel/data/autoUpdate.pl \
    || fail "自动更新未关闭（autoUpdate.pl 仍存在）"

# 更新脚本被换成 stub 后必须返回非零
if inside test -f /www/server/panel/script/upgrade_panel.py; then
    if inside /www/server/panel/script/upgrade_panel.py >/dev/null 2>&1; then
        fail "面板更新脚本未被禁用（仍可执行成功）"
    fi
fi
pass "自动更新已关闭、升级脚本已禁用"

step "A12) 校验防火墙默认关闭"
# 官方脚本会 ufw enable + ufw default deny。容器有特权，若开机套用 deny，
# 面板端口会被直接封死，必须确认镜像里已复位为关闭
if inside test -f /etc/ufw/ufw.conf; then
    inside_sh 'grep -q "^ENABLED=no" /etc/ufw/ufw.conf' \
        || fail "ufw 仍处于开启状态，容器启动后会封掉面板端口"
    pass "ufw 已复位为关闭（规则保留，用户可在面板里自行开启）"
else
    pass "未安装 ufw，跳过"
fi

step "A13) 校验 SSH 与 bt 命令"
inside pgrep -x sshd >/dev/null || fail "sshd 未运行"
inside bt status >/dev/null 2>&1 || fail "bt 命令执行失败"
pass "sshd 运行中、bt 命令可用"

step "A14) 校验备份工具"
# 备份是「持久化承诺」的兑现手段，工具本身必须随镜像可用：
#   --list  能读出体积分布（依赖 du / PERSIST_DIRS 解析正确）
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
# 备份落在容器 /www/backup/manual 下（= www 这层 overlay 的 upper data/www/backup/manual）
BACKUP_PATH=$(inside_sh "ls -1t /www/backup/manual/baota-backup-*.tgz 2>/dev/null | head -1")
[ -n "${BACKUP_PATH}" ] || fail "未找到备份文件（baota-backup 报告成功但持久化层没产物）"
inside test -s "${BACKUP_PATH}" || fail "备份包为空：${BACKUP_PATH}"

# 自包含检查：包里绝不能出现 www/backup 下的产物，否则下次备份体积翻倍
if inside_sh "tar tzf ${BACKUP_PATH} | grep -q 'www/backup/\(auto\|manual\|database\)/'"; then
    fail "备份包自包含：含有 www/backup 下的产物"
fi
_bk=$(basename "${BACKUP_PATH}")
pass "备份工具可用，生成的备份包通过自校验（${_bk}）"

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
assert_no_readonly_warning
wait_panel_http
pass "重建后面板端口已响应"

step "B2) 校验数据未丢失"
inside test -f /data/system/etc/_persist_marker            || fail "/etc 数据在重建后丢失"
inside test -f /www/_persist_marker            || fail "/www 数据在重建后丢失"
inside test -f /data/system/var/spool/cron/_persist_marker || fail "/var 计划任务在重建后丢失"
pass "系统配置、业务数据、计划任务均已保留"

SAFE_AFTER=$(inside_cat /www/server/panel/data/admin_path.pl)
PW_AFTER=$(inside_cat /www/server/panel/default.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "重建后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PW_AFTER" = "$DEFAULT_PW" ] || fail "重建后初始口令被改写，说明发生了二次初始化"
pass "未发生二次初始化，登录地址与账号保持不变"

step "B3) 校验重建后无持久化降级记录"
# boot-history.log 只在启动降级时才追加，存在即说明持久化不完整
inside test ! -f /data/system/.baota/boot-history.log \
    || fail "存在持久化降级记录：$(inside cat /data/system/.baota/boot-history.log 2>/dev/null | tail -3)"
pass "两次启动均未发生持久化降级"

step "B4) 校验重建后面板自动恢复运行"
assert_processes_up "$(panel_status)"
inside systemctl is-active btpanel >/dev/null 2>&1 || fail "重建后 btpanel 未 active"
pass "面板与任务进程随容器自动恢复"

echo
echo "发布前健康检查全部通过（宝塔 ${EXPECT_VERSION}，含容器重建后的持久化验证）"
