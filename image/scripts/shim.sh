#!/bin/bash
# ==============================================================================
#  🐍 shim —— 面板 pyenv 解释器包装 + 执行入口守卫（运行期，镜像自有）
#
#  装配（构建期 services.sh）：pyenv/bin/python{,3} → 本文件，真解释器挪到
#  python-real。面板代码每次执行都经过这里，是守卫的唯一咽喉点；两个职责合并
#  省掉原本 fork+exec 独立 shim.sh 的开销。
#
#  为什么：面板内「更新」把新代码写进可写层，更新最后重启面板、用磁盘上的代码
#  跑 init_db 迁移 SQLite，出现「库被新版迁移、代码又回退」的降级组合。
#  做法：不拦截写入，只拦截执行 —— 每次执行前比对代码版本与镜像版本，不一致
#  就用 /baota/origin 覆盖回去，新代码从未被执行。升级面板 = 换镜像标签。
#
#  红线：① 必须放 /baota（面板更新不会覆盖它）；② 守卫一律 fail-open ——
#  任何异常都放行并照常执行真解释器，绝不把面板卡死在启动路径上。
#  原理：docs/persistence.md#执行入口守卫不可变面板的兜底
# ==============================================================================
set -u
set -o pipefail

PANEL_DIR=${PANEL_DIR:-/www/server/panel}
REAL=${REAL:-${PANEL_DIR}/pyenv/bin/python-real}

# ------------------------------------------------------------------------------
#  执行入口守卫
#  ★ 一律 fail-open：任何一步异常都 return 0 放行，绝不阻断后面的 exec
# ------------------------------------------------------------------------------
run_guard() {
    LOG_PREFIX='🛡️ [guard]'
    # shellcheck source=image/scripts/common.sh
    . /baota/common.sh || return 0
    # ★ 覆盖 common.sh 的 log：本文件其后还要 exec 真 python，
    #   守卫日志写 stdout 会混进面板自身的标准输出，必须走 stderr
    log() { echo "${LOG_PREFIX} $*" >&2; }

    load_defaults \
        || { log '缺少配置真源 /baota/defaults.env，无法确定排除项，跳过守卫'; return 0; }

    PANEL_ORIGIN_DIR=${PANEL_ORIGIN_DIR:-/baota/origin}
    IMAGE_VERSION_FILE=${IMAGE_VERSION_FILE:-/baota/VERSION}
    LOCK_FILE=${LOCK_FILE:-/run/baota/guard.lock}

    if [ -z "${PANEL_STATE_SUBDIRS:-}" ]; then
        log 'PANEL_STATE_SUBDIRS 为空，无法确定排除项，跳过守卫'
        return 0
    fi
    # 排除项直接来自 PANEL_STATE_SUBDIRS —— 谁在持久化什么，只有一处定义
    EXCLUDES=${EXCLUDES:-"${PANEL_STATE_SUBDIRS} pyenv"}

    # 镜像版本的判定基准优先取**副本里的代码版本**：副本就是镜像那份面板代码，
    # 两边天然一致；本地手工构建时 /baota/VERSION 可能是 dev/unknown，拿它比较会失真
    img_ver=''
    if [ -d "${PANEL_ORIGIN_DIR}" ]; then
        img_ver=$(panel_version "${PANEL_ORIGIN_DIR}/class/common.py")
    fi
    [ -n "${img_ver}" ] \
        || img_ver=$(cat "${IMAGE_VERSION_FILE}" 2> /dev/null | tr -d '[:space:]' || true)

    # 只认 x.y.z 形态：dev / unknown 这类值无法比较，直接放行（fail-open）
    case "${img_ver}" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) log "镜像代码副本不可用或版本无法比较（'${img_ver}'），跳过守卫"; return 0 ;;
    esac
    [ -d "${PANEL_ORIGIN_DIR}" ] \
        || { log "镜像代码副本不存在（${PANEL_ORIGIN_DIR}），跳过守卫"; return 0; }

    cur_ver=$(panel_version "${PANEL_DIR}/class/common.py")
    [ "${cur_ver}" = "${img_ver}" ] && return 0

    # 面板启动时会同时拉起多个 python 进程（init_db / check_db / 面板 / 任务），
    # 互斥避免并发重复恢复；拿不到锁也继续（fail-open，恢复本身是幂等的）
    if command -v flock > /dev/null 2>&1; then
        mkdir -p "$(dirname "${LOCK_FILE}")" 2> /dev/null || true
        # ★ 必须用 `{ ...; } 2>/dev/null` 而不是 `exec 9> "$LOCK" 2>/dev/null`：
        #   后者会把**本脚本后续的 stderr 永久重定向到 /dev/null**，守卫的恢复日志
        #   全部消失（实测踩过：恢复成功了但日志里什么都没有，排障时完全看不见）
        if { exec 9> "${LOCK_FILE}"; } 2> /dev/null; then
            flock -w 60 9 2> /dev/null || true
        fi
        # 等锁期间别人可能已经恢复好了，重新判断一次
        cur_ver=$(panel_version "${PANEL_DIR}/class/common.py")
        [ "${cur_ver}" = "${img_ver}" ] && return 0
    fi

    log "检测到面板代码 ${cur_ver:-未知} ≠ 镜像版本 ${img_ver}：丢弃容器内的面板更新（升级请换镜像标签）"

    # 排除项的写法两套：rsync 按「传输根相对路径」匹配（`/data`），
    # tar 的成员名带 `./` 前缀（`./data`）。写错的表现极隐蔽 —— 排除不生效时
    # rsync/tar 会把镜像副本里的初始数据盖到持久化目录上（用户数据被回退）
    rsync_ex=()
    tar_ex=()
    for _e in ${EXCLUDES}; do
        rsync_ex+=( "--exclude=/${_e}" )
        tar_ex+=( "--exclude=./${_e}" )
    done

    # 优先 rsync：按 大小+mtime 跳过没变过的文件，只把被动过的文件写回去。
    # 副本是构建期用 tar 复制的（mtime 与镜像层文件一致），所以"没变过的文件"
    # 会被跳过 → 常态几乎不产生可写层写入，只有被更新动过的那几个文件回到镜像版本
    if command -v rsync > /dev/null 2>&1; then
        rsync -a --no-motd "${rsync_ex[@]}" "${PANEL_ORIGIN_DIR}/" "${PANEL_DIR}/" > /dev/null 2>&1
        rc=$?
    else
        ( cd "${PANEL_ORIGIN_DIR}" && tar -cf - "${tar_ex[@]}" . ) \
            | ( cd "${PANEL_DIR}" && tar -xf - ) > /dev/null 2>&1
        rc=$?
    fi

    after=$(panel_version "${PANEL_DIR}/class/common.py")
    if [ "${rc}" -eq 0 ] && [ "${after}" = "${img_ver}" ]; then
        log "已恢复：${cur_ver:-未知} -> ${after}（排除：${EXCLUDES}）"
    else
        log "恢复失败（rc=${rc}，当前版本=${after:-未知}），按容器内版本继续"
    fi
    return 0
}

# 守卫 fail-open：返回值不参与判定，失败也照常往下执行真解释器
run_guard || true

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

# 最终回退：PATH 里的 python3。必须先解析目标，否则 PATH 含 pyenv/bin 时
# 会命中本包装器自身并无限递归
_last=$(command -v python3 2> /dev/null || true)
case "$(readlink -f "${_last}" 2> /dev/null || true)" in
    ''|*shim*)
        echo "🛡️ [shim] 回退解释器无效：${_last:-未找到}，拒绝执行以免递归" >&2
        exit 1 ;;
esac
exec "${_last}" "$@"
