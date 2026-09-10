#!/bin/sh
# ==============================================================================
#  🩺 容器健康检查 —— compose healthcheck 的统一入口
#
#  compose 里的 test 只留 [CMD, /baota/healthcheck.sh] 一行，判据全部收口到本
#  脚本：逻辑可以直接执行与测试，改判据不用动 compose。
#
#  三段判据，任一失败即非零退出（unhealthy）：
#    ① 持久化降级标记  /run/baota/degraded-critical 由 init.sh 在
#                      关键目录持久化失败 / 只读降级时写入 —— 写入会静默丢失，
#                      是本方案最危险的失效模式，必须在容器状态里直接可见。
#    ② /data 磁盘水位  可用 < 1GB 或已用 ≥ 95%。
#                      满盘时 InnoDB 写坏会丢库、面板写配置会失败，必须在
#                      崩溃前暴露。水位是动态的，所以不写标记文件、每次现查，
#                      interval 30s 自动刷新，腾出空间后即转回 healthy。
#    ③ 面板端口可达    端口可能被用户改掉，从 port.pl 现读；
#                      面板开 HTTPS 也能探到，http 失败再试 https。
#
#  注意：判据里绝不能出现面板进程名 —— bt 脚本会 ps|grep 到自己，
#  把「面板已在运行」误判出来而跳过启动。
#
#  解释器用 /bin/sh：健康检查每 30 秒跑一次，越轻越好，
#  且本脚本只用 POSIX 语法，不依赖 bash
# ==============================================================================

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（与 init.sh / entrypoint / backup 共用同一份）
#
# 磁盘水位查的是「持久化根」。用户一旦覆盖 PERSIST_DATA_ROOT /
# PERSIST_SYSTEM_ROOT，这里的路径必须跟着变 ——
# 写死路径（比如旧版的 /data/www）会导致目录不存在 → 被判成 disk_ok=0
# → 容器永远 unhealthy，而且现象与「磁盘真的满了」完全无法区分，
# 是最难排查的一类故障
# ------------------------------------------------------------------------------
if [ -f /baota/defaults.env ]; then
    . /baota/defaults.env
fi

PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
DISK_MIN_AVAIL_MB="${DISK_MIN_AVAIL_MB:-1024}"
DISK_MAX_USED_PCT="${DISK_MAX_USED_PCT:-95}"

# 阈值必须是正整数：用户填错（空值 / 带单位）时退回默认，
# 否则下面的 -lt / -ge 会报「integer expression expected」并让探活整体失败
case "${DISK_MIN_AVAIL_MB}" in ''|*[!0-9]*) DISK_MIN_AVAIL_MB=1024 ;; esac
case "${DISK_MAX_USED_PCT}" in ''|*[!0-9]*) DISK_MAX_USED_PCT=95 ;; esac

# ------------------------------------------------------------------------------
# ① 持久化降级
# ------------------------------------------------------------------------------
[ ! -f /run/baota/degraded-critical ] || exit 1

# ------------------------------------------------------------------------------
# ② 磁盘水位
#    df -P 用 POSIX 格式保证列位稳定：-Pm 取可用量（MB），-P 取已用百分比。
#    数据层与系统层都要查：任一可用 < DISK_MIN_AVAIL_MB 或
#    已用 ≥ DISK_MAX_USED_PCT 即 unhealthy。两者至少有一个探测不到
#    （目录不存在 / df 失败）也判 unhealthy。
# ------------------------------------------------------------------------------
disk_ok=1
for _m in "${PERSIST_DATA_ROOT}" "${PERSIST_SYSTEM_ROOT}"; do
    [ -d "${_m}" ] || { disk_ok=0; continue; }
    _avail=$(df -Pm "${_m}" 2> /dev/null | awk 'NR==2{print $4+0}')
    _pct=$(df -P "${_m}" 2> /dev/null | awk 'NR==2{gsub("%", ""); print int($5)}')
    if [ "${_avail:-0}" -lt "${DISK_MIN_AVAIL_MB}" ] \
       || [ "${_pct:-0}" -ge "${DISK_MAX_USED_PCT}" ]; then
        disk_ok=0
    fi
done
[ "${disk_ok}" = 1 ] || exit 1

# ------------------------------------------------------------------------------
# ③ 面板端口可达（--max-time 5 防止面板挂起时拖满 compose 的 10s 超时）
#
#    判定语义：探活只回答「面板 HTTP 服务是否活着」—— 任何非 5xx 的响应
#    （200/302/401/403/404…）都证明 BT-Panel 进程在正常处理请求，判活通过；
#    000（连接失败 / 超时）与 5xx（nginx 在但后端已死）才是不健康。
#    不能用 `curl -f`：宝塔的安全入口机制会对部分请求返回 404（面板伪装成
#    nginx 的响应，实测重启后 /<入口>/login 也可能 404），-f 会把活着的面板
#    判死 —— 旧版 compose 判据正是这么写的，容器长期静默 unhealthy。
#    端口与安全入口都从文件现读
# ------------------------------------------------------------------------------
p=$(cat /www/server/panel/data/port.pl 2> /dev/null)
[ -n "$p" ] || p=8888

ap=$(cat /www/server/panel/data/admin_path.pl 2> /dev/null)
case "$ap" in /*) ;; *) ap="/$ap" ;; esac

probe() {
    curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2> /dev/null
}

# shellcheck disable=SC2140  # 变量在引号内自然拼接，非 A"B"C 误用
code=$(probe "http://127.0.0.1:$p$ap/login")
case "$code" in
    000|'')
        # shellcheck disable=SC2140
        code=$(probe "https://127.0.0.1:$p$ap/login") ;;
esac

case "$code" in
    000|'') exit 1 ;;
    5*)     exit 1 ;;
    *)      exit 0 ;;
esac
