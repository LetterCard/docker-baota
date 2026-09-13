#!/bin/sh
# ==============================================================================
#  🩺 容器健康检查 —— compose healthcheck 的统一入口
#
#     （compose 的 test 只留 [CMD, /baota/healthcheck.sh]，判据收口在这里）
#
#  判据（任一失败即非零退出 → unhealthy）：
#    ① 降级标记 /run/baota/critical（init.sh 写入）—— 写入静默丢失，最危险
#    ② 磁盘水位  任一持久化根可用 < DISK_MIN_AVAIL_MB 或已用 ≥ DISK_MAX_USED_PCT
#    ③ 守卫在位  pyenv/bin/python3 -> /baota/shim.sh
#    ④ 版本一致  面板代码版本 == /baota/VERSION（dev 构建跳过）
#    ⑤ 端口可达  从 port.pl 现读，http 失败再试 https
#
#  红线：判据里绝不能出现面板进程名 —— bt 脚本会 ps|grep 到自己而跳过启动。
#  解释器用 /bin/sh：每 30 秒跑一次，越轻越好
# ==============================================================================

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（与 init.sh / entrypoint / backup 共用同一份）
#
# 磁盘水位查的是「持久化根」。用户一旦覆盖 PERSIST_DATA_ROOT /
# PERSIST_SYSTEM_ROOT，这里的路径必须跟着变 ——
# 写死路径（比如直接写 /data/www）会导致目录不存在 → 被判成 disk_ok=0
# → 容器永远 unhealthy，而且现象与「磁盘真的满了」完全无法区分，
# 是最难排查的一类故障
# ------------------------------------------------------------------------------
if [ ! -f /baota/defaults.env ]; then
    echo '❌ [health] 缺少运行期配置真源 /baota/defaults.env，镜像不完整' >&2
    exit 1
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. /baota/defaults.env

# 阈值必须是正整数：用户填错（空值 / 带单位）时退回默认，
# 否则下面的 -lt / -ge 会报「integer expression expected」并让探活整体失败
case "${DISK_MIN_AVAIL_MB}" in ''|*[!0-9]*) DISK_MIN_AVAIL_MB=1024 ;; esac
case "${DISK_MAX_USED_PCT}" in ''|*[!0-9]*) DISK_MAX_USED_PCT=95 ;; esac

# ------------------------------------------------------------------------------
# ① 持久化降级
# ------------------------------------------------------------------------------
[ ! -f /run/baota/critical ] || exit 1

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
    # 任一探测拿不到输出（df 失败 / 挂载点异常）直接按不健康处理 ——
    # 空值兜底成 0 只对「探测到了且值确实小」成立，区分不出「根本没探测到」，
    # 而后者按本文件头注释的承诺同样要判 unhealthy
    if [ -z "${_avail}" ] || [ -z "${_pct}" ] \
       || [ "${_avail}" -lt "${DISK_MIN_AVAIL_MB}" ] \
       || [ "${_pct}" -ge "${DISK_MAX_USED_PCT}" ]; then
        disk_ok=0
    fi
done
[ "${disk_ok}" = 1 ] || exit 1

# ------------------------------------------------------------------------------
# ③④ 不可变面板的两段判据（比端口更重要：面板跑着却不是镜像版本，
#     意味着有人点过「更新」而守卫没兜住 —— 那会让持久层的库比代码新）：
#   ③ 守卫装配在位    pyenv/bin/python3 仍指向 /baota/shim.sh（上游改 pyenv 布局会失效）
#   ④ 面板版本一致    面板代码版本 == /baota/VERSION（本地 dev 构建无版本号时跳过）
# ------------------------------------------------------------------------------
_shim=$(readlink /www/server/panel/pyenv/bin/python3 2> /dev/null || true)
if [ "${_shim}" != '/baota/shim.sh' ]; then
    echo "❌ [health] pyenv/bin/python3 未指向 /baota/shim.sh（当前：${_shim:-无}），执行入口守卫未生效" >&2
    exit 1
fi

_img=$(tr -d '[:space:]' < /baota/VERSION 2> /dev/null || true)
case "${_img}" in
    [0-9]*.[0-9]*.[0-9]*)
        _cur=$(sed -n "s/.*g\.version *= *'\([0-9][0-9.]*\)'.*/\1/p" \
               /www/server/panel/class/common.py 2> /dev/null | head -n1)
        if [ "${_cur}" != "${_img}" ]; then
            echo "❌ [health] 面板代码版本 ${_cur:-未知} ≠ 镜像版本 ${_img}（重建容器即回到镜像版本）" >&2
            exit 1
        fi
        ;;
    *) : ;;   # dev / unknown：本地构建，无法比较，跳过
esac

# ------------------------------------------------------------------------------
# ⑤ 面板端口可达（--max-time 5 防止面板挂起拖满 compose 的 10s 超时）
#    判定语义：探活只回答「面板 HTTP 服务是否活着」—— 任何非 5xx 响应
#    （200/302/401/403/404…）都证明 BT-Panel 在处理请求，判活通过；
#    000（连接失败/超时）与 5xx（nginx 在但后端已死）才是不健康。
#    不能用 curl -f：宝塔安全入口会对部分请求返回 404（面板伪装成 nginx 响应，
#    重启后 /<入口>/login 也可能 404），-f 会把活面板判死、长期静默 unhealthy。
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
