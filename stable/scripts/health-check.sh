#!/usr/bin/env bash
# ==============================================================================
#  宝塔面板镜像发布前健康检查（CI 门禁）
#
#  用法：health-check.sh <镜像名:标签> <期望的宝塔版本号>
#
#  流程定位：
#    镜像先在本地构建并 --load，绝不推送；本脚本全部通过之后，
#    workflow 才会执行登录与推送。任一检查失败即非零退出，阻断发布。
#
#  检查项是针对「本容器化方案 + 真机宝塔运行体验」定制的，不是通用 HTTP 探活：
#    A 阶段（全新数据卷）
#      systemd 就绪 / overlay 持久化可写 / 宝塔真实路径 / 面板与任务进程 /
#      带安全入口的登录页 / 面板版本号 / 首启随机凭据 / 写入落盘 /
#      开机自启 / 定制补丁 / 防火墙默认关闭 / SSH 与 bt 命令
#    B 阶段（销毁容器后用同一个卷重建）
#      业务与系统数据仍在 / 不会二次初始化 / 面板自动恢复运行
# ==============================================================================
set -euo pipefail

IMAGE=${1:?用法: health-check.sh <镜像> <期望版本>}
EXPECT_VERSION=${2:?用法: health-check.sh <镜像> <期望版本>}

CONTAINER="baota-healthcheck-$$"
VOLUME="baota-healthcheck-data-$$"
PERSIST_DIRS="etc usr var www root opt home srv"

pass() { echo "  [ OK ] $*"; }
step() { echo; echo "[health-check] ==== $* ===="; }
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

# 容器内取值的简写
inside()       { docker exec "$CONTAINER" "$@"; }
inside_sh()    { docker exec "$CONTAINER" sh -c "$1"; }
read_file_in() { docker exec "$CONTAINER" cat "$1" 2>/dev/null | tr -d '[:space:]' || true; }

# 去掉 ANSI 颜色码，再判断 bt status 输出
panel_is_running() {
    local status
    status=$(inside bt status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true)
    echo "$status" | grep -q 'Bt-Panel .*already running'
}

task_is_running() {
    local status
    status=$(inside bt status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || true)
    echo "$status" | grep -q 'Bt-Task .*already running'
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

wait_systemd() {
    local state="" i
    for i in $(seq 1 90); do
        state=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
        case "$state" in running|degraded) break ;; esac
        sleep 2
    done
    case "$state" in
        running)  pass "systemd: running" ;;
        degraded) pass "systemd: degraded（容器内属常见，放行）" ;;
        *)        fail "systemd 未就绪：${state:-无响应}" ;;
    esac
}

# 面板进程由 systemd 拉起，需要等一会儿才会监听端口
wait_panel_http() {
    local port code="" i
    port=$(read_file_in /www/server/panel/data/port.pl)
    [ -n "$port" ] || fail "无法确定面板端口"
    for i in $(seq 1 60); do
        code=$(inside curl -skf -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)
        [ "$code" != "000" ] && break
        sleep 2
    done
    [ "$code" != "000" ] || fail "面板端口 ${port} 在 120 秒内没有响应"
}

assert_no_readonly_warning() {
    if docker logs "$CONTAINER" 2>&1 | grep -q "持久化层挂载成功但不可写"; then
        fail "持久化层降级为只读，数据写入会静默丢失"
    fi
}

# ==============================================================================
#  A 阶段：全新数据卷
# ==============================================================================
step "A0) 启动容器（与生产一致的运行条件）"
docker volume create "$VOLUME" >/dev/null
start_container
pass "容器已启动"

step "A1) 等待 systemd 就绪"
wait_systemd

step "A2) 校验 overlay 持久化"
# 只读降级是本方案最危险的失效模式：挂载会「成功」，但所有写入静默丢失
assert_no_readonly_warning
MOUNTED=$(inside_sh "mount | grep -c 'type overlay'" || true)
MOUNTED=${MOUNTED:-0}
EXPECT_MOUNTS=$(echo "$PERSIST_DIRS" | wc -w | tr -d ' ')
[ "$MOUNTED" -ge "$EXPECT_MOUNTS" ] \
    || fail "overlay 挂载数 ${MOUNTED}，期望至少 ${EXPECT_MOUNTS} 个"
pass "overlay 挂载 ${MOUNTED} 个，无只读告警"

for d in $PERSIST_DIRS; do
    inside test -d "/data/${d}/upper" || fail "持久化目录缺失：/data/${d}/upper"
done
pass "${EXPECT_MOUNTS} 个持久化目录齐备"

# /tmp 必须留在容器可写层：变成 tmpfs 会让上传、解压备份直接吃内存
if inside_sh 'grep -q " /tmp " /proc/mounts'; then
    fail "/tmp 被单独挂载（应留在容器可写层）"
fi
pass "/tmp 未被 tmpfs 化"

step "A3) 校验宝塔关键文件（真机上的实际路径）"
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

step "A4) 校验面板双进程"
# 真机上宝塔就是「面板 + 任务」两个常驻进程，缺一不可（任务进程负责计划任务与后台作业）。
# 用宝塔自带的 bt status 判断，避免自己写 ps|grep 反而干扰 bt 脚本的进程判定。
wait_panel_http
panel_is_running || fail "面板进程未运行"
task_is_running  || fail "任务进程未运行"
pass "面板与任务进程均在运行"

step "A5) 校验面板 HTTP（必须带安全入口）"
PORT=$(read_file_in /www/server/panel/data/port.pl)
SAFE=$(read_file_in /www/server/panel/data/admin_path.pl)
URL="http://127.0.0.1:${PORT}${SAFE}/login"
CODE=$(inside curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || echo 000)
case "$CODE" in
    200|302) pass "登录页 ${URL} 返回 ${CODE}" ;;
    *)       fail "登录页 ${URL} 返回 ${CODE}（期望 200/302）" ;;
esac

# 裸 /login 不应返回 200，否则说明安全入口没生效
BARE=$(inside curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${PORT}/login" || echo 000)
[ "$BARE" != "200" ] || fail "安全入口未生效（裸 /login 返回 200）"
pass "安全入口已生效（裸 /login 返回 ${BARE}）"

step "A6) 校验面板版本号"
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

step "A7) 校验首次启动生成的随机凭据"
# 镜像里的构建期占位值形如 bt-build-xxxx，必须已被替换成随机十六进制，
# 否则等于把一个公开可见的口令 / 入口发到线上
inside test -e /www/server/panel/data/.docker-initialized \
    || fail "缺少首次初始化标记，entrypoint 的初始化没有执行"
echo "$SAFE" | grep -Eq '^/[0-9a-f]{8}$' \
    || fail "安全入口不是首启随机生成的（当前：${SAFE}）"
DEFAULT_PW=$(read_file_in /www/server/panel/default.pl)
echo "$DEFAULT_PW" | grep -Eq '^[0-9a-f]{12}$' \
    || fail "面板初始口令不是首启随机生成的（当前长度 ${#DEFAULT_PW}）"
# 镜像里 root 是锁定的（shadow 字段以 ! 开头），首启后必须已设置真实口令
if inside_sh 'grep "^root:" /etc/shadow | cut -d: -f2 | grep -q "^[!*]"'; then
    fail "root 口令仍处于锁定状态，SSH 无法登录"
fi
pass "安全入口、面板口令、root 口令均为首启随机生成"

step "A8) 校验写入确实落到 upper 层"
inside_sh 'echo persist > /etc/_persist_marker'
inside_sh 'echo persist > /www/_persist_marker'
inside_sh 'mkdir -p /var/spool/cron && echo persist > /var/spool/cron/_persist_marker'
inside test -f /data/etc/upper/_persist_marker            || fail "/etc 写入未落盘"
inside test -f /data/www/upper/_persist_marker            || fail "/www 写入未落盘"
inside test -f /data/var/upper/spool/cron/_persist_marker || fail "/var 计划任务目录未落盘"
pass "写入已落到 /data/*/upper"

step "A9) 校验面板服务开机自启与运行态"
inside systemctl is-enabled btpanel >/dev/null 2>&1 \
    || fail "btpanel 未设置开机自启（重建容器后面板不会自启）"
inside systemctl is-active btpanel >/dev/null 2>&1 \
    || fail "btpanel 服务未处于 active"
pass "btpanel 已启用且运行中"

step "A10) 校验定制补丁生效"
inside test ! -e /www/server/panel/data/autoUpdate.pl \
    || fail "自动更新未关闭（autoUpdate.pl 仍存在）"

# 更新脚本被换成 stub 后必须返回非零
if inside test -f /www/server/panel/script/upgrade_panel.py; then
    if inside /www/server/panel/script/upgrade_panel.py >/dev/null 2>&1; then
        fail "面板更新脚本未被禁用（仍可执行成功）"
    fi
fi

pass "自动更新已关闭、升级脚本已禁用"

step "A11) 校验防火墙默认关闭"
# 官方脚本会 ufw enable + ufw default deny。容器有特权，若开机套用 deny，
# 面板端口会被直接封死，必须确认镜像里已复位为关闭。
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

# ==============================================================================
#  B 阶段：销毁容器 → 用同一个卷重建
#
#  这是本项目最核心的承诺：容器销毁、重建后，业务与系统环境数据都不丢。
#  只做「重启」是测不出来的（重启不会丢容器可写层），必须真的 rm 掉重建。
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
inside test -f /etc/_persist_marker            || fail "/etc 数据在重建后丢失"
inside test -f /www/_persist_marker            || fail "/www 数据在重建后丢失"
inside test -f /var/spool/cron/_persist_marker || fail "/var 计划任务在重建后丢失"
pass "系统配置、业务数据、计划任务均已保留"

SAFE_AFTER=$(read_file_in /www/server/panel/data/admin_path.pl)
PW_AFTER=$(read_file_in /www/server/panel/default.pl)
[ "$SAFE_AFTER" = "$SAFE" ] || fail "重建后安全入口被改写（${SAFE} -> ${SAFE_AFTER}）"
[ "$PW_AFTER" = "$DEFAULT_PW" ] || fail "重建后初始口令被改写，说明发生了二次初始化"
pass "未发生二次初始化，登录地址与账号保持不变"

step "B3) 校验重建后面板自动恢复运行"
panel_is_running || fail "重建后面板进程未自启"
task_is_running  || fail "重建后任务进程未自启"
inside systemctl is-active btpanel >/dev/null 2>&1 || fail "重建后 btpanel 未 active"
pass "面板与任务进程随容器自动恢复"

echo
echo "发布前健康检查全部通过（宝塔 ${EXPECT_VERSION}，含容器重建后的持久化验证）"
