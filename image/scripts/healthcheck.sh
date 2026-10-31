#!/bin/sh
# ==============================================================================
#  🩺 容器健康检查 —— compose healthcheck 的统一入口
#     （compose 的 test 只留 [CMD, /baota/healthcheck.sh]，判据收口在这里）
#
#  判据（任一失败即非零退出 → unhealthy）：
#    ① 降级标记    /run/baota/critical（init.sh 写入）—— 持久化静默丢失，最危险
#    ② 守卫在位    pyenv/bin/python3 -> /baota/shim.sh
#    ③ 版本一致    面板代码版本 == /baota/VERSION（dev 构建跳过）
#
#  说明：磁盘水位与面板端口存活由宝塔内置监控负责，本检查只守封装自身不变量。
#  红线：判据里绝不能出现面板进程名 —— bt 脚本会 ps|grep 到自己而跳过启动。
#  解释器用 /bin/sh：每 30 秒跑一次，越轻越好。
# ==============================================================================

# 配置真源：/baota/defaults.env（与 init / entrypoint / backup / guard 共用闸门）
LOG_PREFIX='🩺 [health]'
. /baota/common.sh
load_defaults || exit 1

# ------------------------------------------------------------------------------
# ① 持久化降级
# ------------------------------------------------------------------------------
[ ! -f /run/baota/critical ] || exit 1

# ------------------------------------------------------------------------------
# ②③ 不可变面板的两段判据（面板跑着却不是镜像版本，意味着有人点过
#     「更新」而守卫没兜住 —— 那会让持久层的库比代码新）：
#    ② 守卫装配在位    pyenv/bin/python3 仍指向 /baota/shim.sh（上游改 pyenv 布局会失效）
#    ③ 面板版本一致    面板代码版本 == /baota/VERSION（无版本号时跳过）
# ------------------------------------------------------------------------------
_shim=$(readlink /www/server/panel/pyenv/bin/python3 2> /dev/null || true)
if [ "${_shim}" != '/baota/shim.sh' ]; then
    warn "pyenv/bin/python3 未指向 /baota/shim.sh（当前：${_shim:-无}），执行入口守卫未生效"
    exit 1
fi

_img=$(tr -d '[:space:]' < /baota/VERSION 2> /dev/null || true)
case "${_img}" in
    [0-9]*.[0-9]*.[0-9]*)
        _cur=$(panel_version /www/server/panel/class/common.py)
        if [ "${_cur}" != "${_img}" ]; then
            warn "面板代码版本 ${_cur:-未知} ≠ 镜像版本 ${_img}（重建容器即回到镜像版本）"
            exit 1
        fi
        ;;
    *) : ;;   # dev / unknown：本地构建，无法比较，跳过
esac

exit 0
