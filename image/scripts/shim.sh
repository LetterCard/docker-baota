#!/bin/bash
# ==============================================================================
#  🐍 shim —— 面板 pyenv 解释器的包装（运行期，镜像自有）
#
#  装配（构建期由 services.sh 完成）：pyenv/bin/python{,3} → 本文件，
#  真解释器挪到 python-real。面板代码的每一次执行都要经过 pyenv 解释器，
#  所以这里是「执行入口守卫」的唯一咽喉点：先让面板代码回到镜像版本，再执行。
#
#  红线：① 必须放 /baota —— 面板更新不会覆盖它，不会出现「脚本自己改自己」的
#  竞态；② 必须 fail-open —— 守卫或真解释器缺失都不能让面板起不来。
#
#  日志：[guard] 由 guard.sh 输出；本文件自身不出声
# ==============================================================================
set -u

PANEL_DIR=${PANEL_DIR:-/www/server/panel}
GUARD=${GUARD:-/baota/guard.sh}
REAL=${REAL:-${PANEL_DIR}/pyenv/bin/python-real}

if [ -x "${GUARD}" ]; then
    bash "${GUARD}" || true
fi

# 真解释器：★ 用「venv 内的路径」执行，不能用解析后的目标路径 ——
#   CPython 靠可执行文件旁边是否有 pyvenv.cfg 来判断 venv，换成解析后的
#   /usr/bin/python3.x 会丢掉 venv（sys.prefix 变成 /usr，面板依赖全找不到）。
#   解析后的目标只用来做一个判断：它是不是又指回本包装器（重复装配会无限递归）
_real_target=$(readlink -f "${REAL}" 2> /dev/null || true)
case "${_real_target}" in
    ''|*shim*) ;;
    *) [ -x "${REAL}" ] && exec "${REAL}" "$@" ;;
esac

# 回退：python-real 不在（上游重装了 pyenv、或镜像被手工改动）时从 venv 里
# 另找一个解释器。★ 必须先 readlink -f 解析，跳过指回本包装器的候选 ——
# venv 里常见 python3.x -> python3 -> 本包装器 的链条，直接 exec 会无限递归
# 把面板挂死（实测踩过）
for _c in "${PANEL_DIR}"/pyenv/bin/python3.[0-9]*; do
    [ -e "${_c}" ] || continue
    _real=$(readlink -f "${_c}" 2> /dev/null || true)
    case "${_real}" in
        ''|*shim*) continue ;;
    esac
    [ -x "${_c}" ] && exec "${_c}" "$@"
done

exec python3 "$@"
