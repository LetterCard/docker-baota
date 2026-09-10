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
#  两阶段共 20 项，针对「本容器化方案 + 真机宝塔体验」定制，不是通用探活：
#    A 全新数据卷：systemd / overlay 可写 / 关键路径（含 pyenv 模块）/
#                  面板与任务进程 / 安全入口 / 版本号 / 首启凭据 / 写入落盘 /
#                  自启 / 防火墙关闭 / SSH 与 bt 命令 / 日志体积防线 /
#                  健康检查判据 / 备份工具 / PHP 扩展编译工具链
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
# ICON 供 lib.sh 的 step() 作日志前缀（本文件内无引用，shellcheck 会误报未使用）
# shellcheck disable=SC2034
ICON='🩺'

# 公共样板（配置解析 / 输出 / 容器操作 / 等待 / 启动 / 清理）见 lib.sh
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 目录与「根」全部取自 shared/conf/defaults.env —— 落盘路径由根派生，
# 避免硬编码漂移
PERSIST_SYSTEM_DIRS=$(read_default PERSIST_SYSTEM_DIRS)
[ -n "${PERSIST_SYSTEM_DIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_DIRS"; exit 1; }
WWW_DATA_SUBDIRS=$(read_default WWW_DATA_SUBDIRS)
[ -n "${WWW_DATA_SUBDIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 WWW_DATA_SUBDIRS"; exit 1; }
PANEL_STATE_SUBDIRS=$(read_default PANEL_STATE_SUBDIRS)
[ -n "${PANEL_STATE_SUBDIRS}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PANEL_STATE_SUBDIRS"; exit 1; }
# 三个「根」也读真源：落盘路径由根派生，避免硬编码漂移
PERSIST_DATA_ROOT=$(read_default PERSIST_DATA_ROOT)
PERSIST_SYSTEM_ROOT=$(read_default PERSIST_SYSTEM_ROOT)
PANEL_STATE_ROOT=$(read_default PANEL_STATE_ROOT)
[ -n "${PERSIST_DATA_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_DATA_ROOT"; exit 1; }
[ -n "${PERSIST_SYSTEM_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PERSIST_SYSTEM_ROOT"; exit 1; }
[ -n "${PANEL_STATE_ROOT}" ] || { echo "::error::无法从 shared/conf/defaults.env 解析 PANEL_STATE_ROOT"; exit 1; }

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

# start_container / wait_systemd / wait_panel_http 见 lib.sh

# 只读降级是本方案最危险的失效模式：挂载会「成功」，但所有写入静默丢失。
# 判据从「grep 启动日志里的中文文案」改为读容器内的降级标记文件：
# init.sh 在任何持久化失败/只读降级时都会写 /run/baota/degraded*，
# 这样告警文案怎么改都不影响门禁，也不会漏掉「挂载直接失败」这一类情况
assert_no_readonly_warning() {
    if inside test -e /run/baota/degraded-critical; then
        fail "关键目录未持久化（/run/baota/degraded-critical 存在），数据写入会静默丢失"
    fi
    if inside test -e /run/baota/degraded; then
        fail "存在未持久化目录（/run/baota/degraded）：$(inside cat /run/baota/degraded 2>/dev/null | tr '\n' ' ' || true)"
    fi
}

# 面板状态漂移报告（不对抗上游版）：
# 面板代码来自镜像层、不持久化，运行期对面板目录的写入只会落在容器可写层，
# docker pull 新镜像时这些写入会被整体丢弃。我们要暴露的是「持久化声明的盲区」——
# 上游把状态写到了镜像里原本没有、我们也没声明进 PANEL_STATE_SUBDIRS 的全新位置。
#
# 怎么判断「镜像里原本有没有」：不靠手写白名单去猜上游的瞬态目录（那是在对抗上游，
# 且上游一改写入结构就失准），而是直接问镜像本身——起一个临时容器 ls 镜像里
# /www/server/panel 的顶层目录，作为客观基线。镜像里已有的目录（class/config/logs/…）
# 上的任何运行期写入都是可再生的、升级会重新铺上，不算盲区；只有镜像里不存在的
# 全新顶层目录上的写入，才可能是我们漏声明的状态。
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
        echo "  需保留的话，请加进 shared/conf/defaults.env 的 PANEL_STATE_SUBDIRS"
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
assert_no_readonly_warning
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

# 不可变面板的核心性质：面板代码目录不能被任何 bind / overlay 覆盖，
# 否则换镜像就更新不了面板。纯挂载语义检查，不依赖宝塔任何内部结构
if inside_sh "mount | grep -q ' on /www/server/panel '"; then
    fail "面板代码目录被挂载覆盖了：/www/server/panel 应直接来自镜像层"
fi
pass "面板代码未被持久化（直接来自镜像层）"

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
# 三段判据（降级标记 / 磁盘水位 / 面板端口）共用一个非零退出码，光看它无法
# 区分是「持久化降级」「磁盘快满」还是「面板没起来」，而这三种的修法完全
# 不同。失败时逐段复跑，把原因钉死在日志里
if ! inside /baota/healthcheck.sh; then
    echo "----- healthcheck 三段判据取证 -----"
    inside test -f /run/baota/degraded-critical \
        && echo "[① 降级标记] 存在：/run/baota/degraded-critical" \
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
# （与 shared/build/panel.sh 一致）。glob 必须在容器内展开 —— 宿主上没有 /www
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
inside test -e /www/server/panel/data/.docker-initialized \
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
inside_sh 'echo persist > /etc/_persist_marker'
inside_sh 'echo persist > /www/server/panel/data/_persist_marker'
inside_sh 'mkdir -p /var/spool/cron && echo persist > /var/spool/cron/_persist_marker'
inside_sh 'echo persist > /www/wwwroot/_persist_marker'
# 落盘路径语义（容易搞混，写清楚再检查）：
#   /etc /var               系统层 overlay，upper 在 /data/system/<dir>
#   /www/wwwroot            业务 bind，源 = /data/www/wwwroot
#   /www/server/panel/data  面板状态 bind，源 = ${PANEL_STATE_ROOT}/data
#   面板代码（/www/server/panel 本体）刻意不落盘：它属于镜像
inside test -f /data/system/etc/_persist_marker            || fail "/etc 写入未落盘"
inside test -f "${PANEL_STATE_ROOT}/data/_persist_marker"  || fail "面板状态写入未落盘（应为 ${PANEL_STATE_ROOT}/data）"
inside test -f /data/www/wwwroot/_persist_marker           || fail "/www/wwwroot 写入未落到绑定源 /data/www/wwwroot"
inside test -f /data/system/var/spool/cron/_persist_marker || fail "/var 计划任务目录未落盘"
pass "写入落到 data/www/wwwroot、${PANEL_STATE_ROOT}/data 与 data/system/<dir>"

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
_bk=$(basename "${BACKUP_PATH}")
pass "备份工具可用，生成的备份包通过自校验（${_bk}）"

step "A14) PHP 扩展编译工具链护栏（零网络，不装 PHP）"
# 瘦身（dpkg path-exclude / locale 排除）最该守住的底线：镜像必须自带扩展编译工具链
# （autoconf / gcc / make / libtool），否则用户在面板里给 PHP 装扩展时会
# 复现「Cannot find autoconf」类回归。这里只做零网络的存在性断言，不临时
# 安装任何 PHP 环境——真正的「装 PHP + 编译扩展」端到端测试留在日巡检
# （published.sh），在已发布的纯净镜像上跑，避免污染推送前的候选镜像。
for _b in autoconf gcc make libtool; do
    inside_sh "command -v $_b >/dev/null 2>&1" \
        || fail "镜像缺少扩展编译工具链：$_b（PHP 扩展将装不上，疑似瘦身误删）"
done
pass "扩展编译工具链齐备（autoconf/gcc/make/libtool），足以支撑 PHP 扩展安装"

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
assert_no_readonly_warning
wait_panel_http
pass "重建后面板端口已响应"

step "B2) 校验数据未丢失"
inside test -f /data/system/etc/_persist_marker            || fail "/etc 数据在重建后丢失"
inside test -f /www/server/panel/data/_persist_marker      || fail "面板状态数据在重建后丢失"
inside test -f /www/wwwroot/_persist_marker                || fail "站点数据在重建后丢失"
inside test -f /data/system/var/spool/cron/_persist_marker || fail "/var 计划任务在重建后丢失"
pass "系统配置、面板状态、业务数据、计划任务均已保留"

SAFE_AFTER=$(inside_cat /www/server/panel/data/admin_path.pl)
PORT_AFTER=$(inside_cat /www/server/panel/data/port.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "重建后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PORT_AFTER" = "$PORT" ] || fail "重建后面板端口被改写，说明发生了二次初始化（${PORT} -> ${PORT_AFTER}）"
pass "未发生二次初始化，登录地址与端口保持不变"

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
