#!/busybox sh
# shellcheck shell=sh  # 本文件必须保持 POSIX（busybox 解释），shebang 不被 shellcheck 识别，需显式声明方言
# ==============================================================================
#  [阶段 0] 早期初始化 —— 系统层镜像兜底 → 系统层 overlay → 面板代码隔离
#    → pyenv 覆盖层 → 业务/面板子目录 bind → 移交阶段 1
#
#  红线一：解释器用 busybox 而非 bash —— 本脚本要给 /usr 挂 overlay，万一持久化
#    层里的 /usr 被写坏，usrmerge（/bin -> usr/bin）会让 /bin/bash 一起消失。
# 红线二：只能用 POSIX 语法 —— 不能用 local / [[ ]] / 数组 / 进程替换 / pipefail；
#    函数内临时变量统一 `_` 前缀，避免覆盖调用方的循环变量。
#
#  可用环境变量（真源见 /baota/defaults.env）：PERSIST_* / WWW_* / PANEL_*
#    / CRITICAL_DIRS / STAGE1
#
#  日志：[init] 普通信息，[init][WARN] 告警
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（镜像自有，不在任何持久化目录内）。
# 存在性闸门 + log/warn/die 收敛在 /baota/common.sh，全脚本共用一份 ——
# 抄 6 遍的必然结局是漂移，而漂移的表现是「运行期按旧值算路径」，离原因很远
# ------------------------------------------------------------------------------
LOG_PREFIX='⚙️ [init]'
# shellcheck source=image/scripts/common.sh
. /baota/common.sh
load_defaults || exit 1

# init.sh 自己的运行参数（不属于配置真源）
STAGE1="${STAGE1:-/baota/entrypoint.sh}"

# 兜底镜像已挂载标志：系统层与 pyenv 两层共用同一个 ext4 镜像，先触发的那层建好后
# 置位，另一层直接复用，不再重复建。空 = 未启用（持久化根原生支持 overlay，无需镜像）。
OVL_IMAGE=''

# 兜底镜像的 loop 设备与挂载点（供退出清理用，避免崩溃泄漏 loop 导致下次启动耗尽）
OVL_LOOP=''
# 已挂载标记：不能拿 PERSIST_SYSTEM_MOUNT_DIR 当哨兵 —— 它是 defaults.env 的
# 配置变量，清空会把用户在 compose 里的覆盖静默丢掉
OVL_MOUNTED=''
cleanup_overlay_store() {
    [ -n "${OVL_MOUNTED}" ] && umount "${OVL_MOUNTED}" 2> /dev/null || true
    [ -n "${OVL_LOOP}" ] && losetup -d "${OVL_LOOP}" 2> /dev/null || true
}
# init.sh 异常退出（崩溃 / 拒绝启动）时释放 loop，防止泄漏 → 重启耗尽 → 启动死循环
trap cleanup_overlay_store EXIT

# 面板目录（不在 defaults.env，因为它由官方安装脚本固定，全项目同此约定）
# 与它的临时钉桩：挂 /www/server 的 overlay 之前先 bind 到这里，
# 挂完再 bind 回面板目录，面板代码因此始终来自镜像层、不落持久化层
PANEL_DIR="${PANEL_DIR:-/www/server/panel}"
PANEL_PIN_DIR="${PANEL_PIN_DIR:-/run/baota/panel}"

# 业务数据与面板状态：逐个 bind 到 data 下（清单见 defaults.env）
# 面板代码（/www/server/panel）刻意不持久化 —— 它直接来自镜像层

# 可写性探测文件名（同时用于 lower 与 upper 两侧）
PROBE=.probe

# 状态目录（系统层 overlay 的 .baota）：overlay workdir 在这里面。
# overlay 要求 workdir 与 upperdir 同盘（内核硬性要求）：work 放在状态目录内的
# <目录>.work。内核会在它里面再建一层 work（省不掉），详情见
# docs/persistence.md「挂载原理」
# ★ 镜像模式下 init.sh 会把 PERSIST_SYSTEM_ROOT / STATE_DIR 重新指向镜像挂载点
#   （/run/baota/overlay），系统层与 pyenv 两层的 upper/work 一并落入镜像；
#   data/ 因此只留 www/ 与 overlay.img 两个条目。
STATE_DIR="${PERSIST_SYSTEM_ROOT}/.baota"

# 运行态标记目录。/run 是 tmpfs：每次启动重新评估，不会残留上次的状态。
# 供 compose healthcheck 与 CI 健康检查判定「本次启动的持久化是否完整」。
RUNTIME_DIR=/run/baota
DEGRADED="${RUNTIME_DIR}/degraded"
CRITICAL="${RUNTIME_DIR}/critical"
# 面板代码隔离成功的标记。与 degraded / critical 同属「运行态标记」：/run 是 tmpfs，
# 每次启动重新评估、不会残留上次的结果。core 门禁断言它存在 —— 让「隔离是否生效」
# 能被门禁直接判定，而不是只体现在启动日志的文案里（两者此前出现过不一致）
# 变量名照 §5 的对应规则：标记文件 /run/baota/critical 对应变量 CRITICAL，
# 故这里不加 _FILE（_FILE 是给 META_VERSION_FILE 那种「文件名」用的）
PANEL_ISOLATED="${RUNTIME_DIR}/panel-isolated"

# ------------------------------------------------------------------------------
# 降级标记（log/warn 由 common.sh 提供，前缀见 LOG_PREFIX）
# ------------------------------------------------------------------------------
mark_degraded() {
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || return 0
    printf '%s\n' "$1" >> "${DEGRADED}" 2> /dev/null || true
}

mark_critical() {
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || return 0
    printf '%s\n' "$1" >> "${CRITICAL}" 2> /dev/null || true
}

# 挂载点是否属于「失败即静默丢数据」的关键目录。
# 传入容器内路径（/etc、/www/wwwroot…），与 CRITICAL_DIRS 列表中的写法一致
is_critical() {
    case " ${CRITICAL_DIRS} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# 挂载成功 ≠ 可写（virtiofs / NFS / 9p 会降级只读）：实测一次写入，
# 成功则在 upper 看到探测文件。返回 0 = 可写，1 = 只读。
# $1 = 挂载点（写探测文件处），$2 = upperdir（应出现探测文件处）
probe_writable() {
    if ( exec 2>/dev/null; : > "$1/${PROBE}" ) && [ -e "$2/${PROBE}" ]; then
        rm -f "$1/${PROBE}"
        return 0
    fi
    rm -f "$1/${PROBE}" 2> /dev/null || true
    return 1
}

# 尝试挂一次 overlay：建 upper/work → mount → 实测可写。
# 返回 0 = 成功且可写；1 = 任一环节失败（含挂载成功但只读）。
# 失败告警在此打印，但**不打 degraded 标记**——是否关键由调用方决定。
# 挂载成功却只读时顺手 umount，给兜底重试留一个干净的挂载点。
try_overlay() {
    _l="$1"; _u="$2"; _w="$3"
    if ! mkdir -p "${_l}" "${_u}" 2> /dev/null; then
        warn "无法创建 ${_u}：持久化根不可写，${_l} 本次不会持久化"
        return 1
    fi
    rm -rf "${_w}" 2> /dev/null || true
    if ! mkdir -p "${_w}" 2> /dev/null; then
        warn "无法创建 ${_w}：持久化根不可写，${_l} 本次不会持久化"
        return 1
    fi
    if ! mount -t overlay overlay \
        -o "lowerdir=${_l},upperdir=${_u},workdir=${_w},index=off" "${_l}" 2> /dev/null; then
        warn "overlay 挂载失败：${_l} 本次不会持久化"
        warn '  常见原因：容器未以 --privileged 运行 / 持久化根位于 overlay 之上 / 内核未启用 overlayfs'
        return 1
    fi
    if probe_writable "${_l}" "${_u}"; then
        return 0
    fi
    warn "${_l} 的 overlay 挂载成功但不可写，本次不会持久化"
    rm -f "${_l}/${PROBE}" 2> /dev/null || true
    umount "${_l}" 2> /dev/null || true
    return 1
}

# ------------------------------------------------------------------------------
# 挂载汇总成目录树（替代逐条打印的冗长日志）
#   · 只读 /proc/mounts 为真值来源，不改任何挂载行为（仅用于渲染系统层 / 数据层
#     / 面板状态的目录树）
#   · 失败路径的告警仍由各 mount 函数 inline 打印，这里只渲染成功态
#   · 面板代码隔离状态不走 /proc/mounts 反查：盖在 /www/server overlay 之下的
#     bind 在 /proc/mounts 里的 device 字段不可靠，会误报「未隔离」；这里直接
#     用 main() 按 bind 回的成败写下的 PANEL_ISOLATED 标记判断
# ------------------------------------------------------------------------------
_emit_group() {
    _hdr="$1"; _items="$2"; _cont="$3"; _seeded="${4:-}"
    echo "${_hdr}"
    _i=0
    _total=$(set -- ${_items}; echo $#)
    [ "${_total}" -eq 0 ] && return 0
    for _it in ${_items}; do
        _i=$((_i + 1))
        _mark=''
        case " ${_seeded} " in *" ${_it} "*) _mark=' (首次初始化)';; esac
        if [ "${_i}" -eq "${_total}" ]; then
            echo "${_cont}└── ${_it}${_mark}"
        else
            echo "${_cont}├── ${_it}${_mark}"
        fi
    done
}

print_mount_tree() {
    _sys='' _www='' _panel='' _pyenv=0
    _seeded_list=''
    if [ -f "${RUNTIME_DIR}/.seeded" ]; then
        _seeded_list=$(cat "${RUNTIME_DIR}/.seeded" 2> /dev/null | tr '\n' ' ')
    fi
    # _dev _mp _fstype _opts：overlay 看 upperdir，bind 看源路径。
    # 末尾 _f _p 是**故意留的占位** —— 吸掉 /proc/mounts 的第 5、6 列
    # （dump / fsck 顺序），去掉会让 _opts 连带吸进这两个字段
    while read -r _dev _mp _fstype _opts _f _p; do
        case "${_fstype}" in
            overlay)
                _up=''
                _ifs="${IFS}"
                IFS=,
                for _o in ${_opts}; do
                    case "${_o}" in upperdir=*) _up="${_o#upperdir=}";; esac
                done
                IFS="${_ifs}"
                case "${_up}" in
                    "${PERSIST_SYSTEM_ROOT}/"*) _sys="${_sys} ${_up#${PERSIST_SYSTEM_ROOT}/}";;
                    "${PANEL_STATE_ROOT}/pyenv") _pyenv=1 ;;
                esac
                ;;
            *)
                case "${_dev}" in
                    "${PERSIST_DATA_ROOT}/www/"*)
                        case "${_mp}" in
                            /www/server/panel/*) _panel="${_panel} ${_mp#/www/server/panel/}";;
                            *) _www="${_www} ${_mp#/www/}";;
                        esac
                        ;;
                esac
                ;;
        esac
    done < /proc/mounts

    echo "💾 持久化层挂载"
    _emit_group "├─ 系统层  ${PERSIST_SYSTEM_ROOT}" "${_sys}" "│   "
    _emit_group "├─ 数据层  ${PERSIST_DATA_ROOT}/www" "${_www}" "│   "
    if [ "${_pyenv}" = 1 ]; then
        echo "├─ 覆盖层  ${PANEL_STATE_ROOT}/pyenv（pip 包持久化，解释器随镜像）"
    fi
    _emit_group "└─ 面板状态  ${PERSIST_DATA_ROOT}/www/server/panel" "${_panel}" "    " "${_seeded_list}"
    if [ -e "${PANEL_ISOLATED}" ]; then
        echo "📦 面板代码：来自镜像层 ${PANEL_DIR}（不落持久化层）"
    else
        warn "面板代码未能隔离出持久化层，面板内「更新」可能污染持久化"
    fi
}

# ==============================================================================
#  -0.5 系统层 ext4 镜像模式（自动 + 可强制）
#   data/ 落在 SMB / NFS / exFAT / NTFS / virtiofs 时，overlay upper 会「挂载成功
#   但只读」、写入静默失败（详见 docs/persistence.md 硬约束）。把系统层 + pyenv
#   两层装进同一个 ext4 镜像文件 data/overlay.img，loop 挂载到 /run/baota/overlay
#   （在 /data 之外），之后的 overlay 流程原样跑，对上层逻辑零改动。
#   ★ 触发：auto/未设=自动兜底；true/on/1/yes 或显式路径=强制镜像模式。
#   ★ 删镜像文件 = 两层同时重置；强制开启却配不起来直接拒绝启动，不静默回落只读根。
# ==============================================================================
die_image() {
    echo "❌ [init][ERROR] $*" >&2
    exit 1
}

attach_overlay_store() {
    # 幂等：系统层与 pyenv 两层共用，先触发的那层建好即置位，另一层直接复用
    [ -n "${OVL_IMAGE:-}" ] && return 0
    [ "${_IMG_DISABLED:-0}" = 1 ] && return 1   # 用户显式禁用镜像模式（false/0/no/off）

    # 镜像路径由 main 解析到 _IMG_PATH（true/on/1/yes → data/overlay.img；显式路径 → 该路径）
    _img="${_IMG_PATH}"
    case "${_img}" in
        "${PERSIST_DATA_ROOT}"/*) ;;
        *) die_image "PERSIST_SYSTEM_IMAGE=${_img} 不在数据层 ${PERSIST_DATA_ROOT} 内（容器只挂了 data），拒绝启动" ;;
    esac

    # 镜像文件父目录（默认 data/）必须在 truncate 前就位，否则 truncate 直接失败 → 启动 die
    mkdir -p "$(dirname "${_img}")" 2> /dev/null \
        || die_image "无法创建镜像目录 $(dirname "${_img}")（数据层不可写？）"

    _fresh=0
    if [ ! -f "${_img}" ]; then
        _fresh=1
        truncate -s "${PERSIST_SYSTEM_IMAGE_SIZE_MB}M" "${_img}" 2> /dev/null \
            || die_image "无法创建镜像文件 ${_img}（数据层不可写？）"
    fi

    # 上一个容器异常退出时 loop 设备可能没释放：先解掉**本镜像名下**的旧绑定再挂，
    # 否则每重启一次就漏一个 loop 设备（只动本文件的绑定，不碰宿主机其它 loop）
    # BusyBox losetup 无 -j；改用 -a 解析（util-linux 同样兼容）
    for _old in $(losetup -a 2> /dev/null | grep -F "${_img}" | cut -d: -f1); do
        losetup -d "${_old}" 2> /dev/null || true
    done
    # BusyBox 内建 losetup 不支持 util-linux 的 --show，改用两步法（util-linux 同样兼容）
    _loop=$(losetup -f 2> /dev/null || true)
    [ -n "${_loop}" ] && losetup "${_loop}" "${_img}" >/dev/null 2>&1 || _loop=""
    [ -n "${_loop}" ] || die_image "无法把 ${_img} 绑定到 loop 设备（losetup 缺失或无空闲 loop 设备，或 Docker Desktop 虚拟机无 loop 支持）"
    # 绑定成功就登记给 EXIT trap：后面 mkfs / e2fsck / mount 任一步失败都要释放 loop
    OVL_LOOP="${_loop}"

    if [ "${_fresh}" = 1 ]; then
        mkfs.ext4 -F -q "${_loop}" > /dev/null 2>&1 \
            || die_image "mkfs.ext4 失败：${_loop}（镜像缺 e2fsprogs？）"
        log "overlay 兜底镜像已创建：${_img}（${PERSIST_SYSTEM_IMAGE_SIZE_MB}MB，ext4）"
    else
        # set -eu 下必须显式兜住非零退出：1/2（日志回放 / 已修复）与 >=4（无法修复）
        # 都要走到下面分支，否则 e2fsck 一返回非零就当场退出，重建逻辑全是死代码
        _rc=0
        e2fsck -p "${_loop}" > /dev/null 2>&1 || _rc=$?
        if [ "${_rc}" -le 2 ]; then
            : # 干净或已自动修复，直接用
        elif [ "${_IMG_EXPLICIT:-0}" = 1 ]; then
            # 用户显式指定了 PERSIST_SYSTEM_IMAGE 路径（即自己的备份）→ 不擅自重建，拒绝启动
            die_image "e2fsck 无法修复 ${_img}（退出码 ${_rc}），请从备份恢复该镜像"
        else
            # 自动/默认兜底的镜像是我们自己管理的可重建上层（内容可由镜像 lower 再派生），
            # 损坏只可能来自上次非正常卸载 → 直接重建，避免 e2fsck 失败陷入启动死循环
            log "兜底镜像 e2fsck 退出码 ${_rc}，自动重建（上层内容可由镜像再派生）"
            mkfs.ext4 -F -q "${_loop}" > /dev/null 2>&1 \
                || die_image "mkfs.ext4 失败：${_loop}（镜像缺 e2fsprogs？）"
        fi
    fi

    # 镜像挂载点移到 /data 之外（/run/baota/overlay）：data/ 因此只剩 www/ 与 overlay.img
    # 两个条目，重置 = 删一个文件，迁移 = 打包 data/ 走人。
    PERSIST_SYSTEM_MOUNT_DIR="${PERSIST_SYSTEM_MOUNT_DIR:-/run/baota/overlay}"
    if [ -d "${PERSIST_SYSTEM_ROOT}" ] && [ -n "$(ls -A "${PERSIST_SYSTEM_ROOT}" 2> /dev/null)" ] && [ "${_FORCE_IMG:-0}" = 1 ]; then
        warn "PERSIST_SYSTEM_ROOT=${PERSIST_SYSTEM_ROOT} 非空：强制镜像模式后不再读取这里（旧内容仍留在 data/，可手工删除）"
    fi
    mkdir -p "${PERSIST_SYSTEM_MOUNT_DIR}" 2> /dev/null \
        || die_image "无法创建挂载点 ${PERSIST_SYSTEM_MOUNT_DIR}"
    mount -t ext4 -o defaults "${_loop}" "${PERSIST_SYSTEM_MOUNT_DIR}" 2> /dev/null \
        || die_image "ext4 镜像挂载失败：${_loop} → ${PERSIST_SYSTEM_MOUNT_DIR}"
    OVL_MOUNTED="${PERSIST_SYSTEM_MOUNT_DIR}"

    # 镜像挂好后，把系统层 upper 基路径与状态目录都指向挂载点（两层 upper/work 落入镜像）
    PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_MOUNT_DIR}"
    STATE_DIR="${PERSIST_SYSTEM_MOUNT_DIR}/.baota"

    # 备份工具改为「检测 data/overlay.img 是否存在」来识别镜像模式（见 backup.sh），
    # 不再写宿主侧标记文件 —— data/ 保持只有 www/ 与 overlay.img。
    # 该镜像同时兜系统层 + pyenv 两层，删它即两层一起重置。
    log "系统层 + pyenv 已装入同一 ext4 镜像：${_img}（挂载于 ${PERSIST_SYSTEM_MOUNT_DIR}）"

    OVL_IMAGE=1
}

# ==============================================================================
#  1. overlay 分层持久化（仅系统层）
#   系统层只持久化 /www/server（upper：镜像模式 /run/baota/overlay/www/server，原生模式 data/.system/www/server）
#  ★ 面板（/www）不再走 overlay：代码由镜像层直接提供、不持久化，
#    只有业务与状态子目录走 bind（见 mount_www_layer）。
#  ★ index=off 是必须的，不是优化（同 upper 换 lower 的升级语义需要它）
#  ★ 刻意不开 metacopy=on：「只改元数据」的 copy-up 会在 upper 落零数据的元数据
#    副本，备份打包 upper 原始内容时会把它打成零长文件，恢复后盖住镜像真文件
#    （CI 实测）。要开先让备份能跳过这类条目，推导见 docs/persistence.md
# ==============================================================================
mount_persist() {
    _dir="$1"
    _lower="/${_dir}"

    # 自动模式：先试原生 overlay（仅当未强制镜像模式）
    if [ -z "${_FORCE_IMG:-}" ]; then
        if try_overlay "${_lower}" "${PERSIST_SYSTEM_ROOT}/${_dir}" "${STATE_DIR}/${_dir}.work"; then
            return 0
        fi
    fi

    # 镜像模式（自动兜底 or 显式强制）：系统层 + pyenv 兜进同一个 ext4 镜像。
    # 镜像挂好后 PERSIST_SYSTEM_ROOT / STATE_DIR 已指向挂载点，这里实时取值。
    if attach_overlay_store; then
        if try_overlay "${_lower}" "${PERSIST_SYSTEM_ROOT}/${_dir}" "${STATE_DIR}/${_dir}.work"; then
            [ -z "${_FORCE_IMG:-}" ] && log "/${_dir} 持久化根不支持 overlay，已自动切 ext4 镜像兜底"
            return 0
        fi
    fi

    mark_degraded "${_dir}: overlay 不可用"
    return 1
}

# ==============================================================================
#  2. 业务数据与面板状态（逐子目录 bind）
#  ★ 绝不能 bind 整个 /www —— 那会把镜像里的面板代码一起遮住，换镜像就再也
#    更新不了面板。只 bind 需要的子目录（清单见 defaults.env 的 WWW_DATA_SUBDIRS
#    与 PANEL_STATE_SUBDIRS，源一律是 data/www/<同名>）。
#  ★ 规则只有一条：data/www 下的路径 = 容器内的路径，面板状态也归位在
#    www/server/panel 下（与容器内同名），不单列一层。
#  可选模块（vmail / dk_project）装了才 bind、不预建，见 bind_optional_subdir。
#  面板状态首次使用时从镜像 seed 一次，之后由 data 接管，镜像不再覆盖。
# ==============================================================================
bind_subdir() {
    _source="$1"
    _target="$2"

    [ -d "${_target}" ] || mkdir -p "${_target}" 2> /dev/null || true
    if [ ! -d "${_target}" ]; then
        warn "绑定目标不存在且无法创建：${_target}"
        return 1
    fi
    if ! mkdir -p "${_source}" 2> /dev/null; then
        warn "无法创建持久化源 ${_source}：数据层根不可写"
        return 1
    fi
    if mount -o bind "${_source}" "${_target}" 2> /dev/null; then
        return 0
    fi
    warn "绑定失败：${_target}（本次启动不会保存该目录）"
    return 1
}

# 可选模块目录（邮局 / 面板 Docker 项目…）：装了才出现，所以**不预建** ——
# 没装模块的容器不该在 data/www 下看到空目录。三种情况：
#   ① 持久化源已存在          → 照常 bind（已装过，正常路径）
#   ② 源与容器里都没有        → 模块没装，什么都不做
#   ③ 容器里有、源没有        → 用户在面板里装了模块（写在容器可写层）：
#                              先把现有内容 seed 进持久化源再 bind，
#                              从本次启动起纳入持久化
# 目录存在但为空按 ③ 处理会得到一个空目录，与「不预建」矛盾，所以空目录也走 ②
# （不打印：那是常态，每次启动都提示就成了噪音）。等模块真装出内容后，
# 下次启动走 ③ 自动纳入持久化。
bind_optional_subdir() {
    _source="${PERSIST_DATA_ROOT}/www/$1"
    _target="/www/$1"

    [ -e "${_source}" ] && { bind_subdir "${_source}" "${_target}"; return $?; }

    if [ ! -d "${_target}" ] || [ -z "$(ls -A "${_target}" 2> /dev/null)" ]; then
        return 0
    fi

    if mkdir -p "${_source}" 2> /dev/null && cp -a "${_target}/." "${_source}/" 2> /dev/null; then
        log "可选模块 $1 已纳入持久化（首次装载现有数据）"
        bind_subdir "${_source}" "${_target}"
        return $?
    fi

    warn "可选模块 $1 的持久化源创建失败，本次启动它不会被保存"
    return 1
}

# 面板状态子目录：首次把镜像里的初始内容复制到 data，再 bind 上去。
# 之后 data 里的内容就是唯一真身（面板配置属于用户，镜像不覆盖它）
seed_panel_state() {
    _sub="$1"
    _source="${PANEL_STATE_ROOT}/${_sub}"
    _target="/www/server/panel/${_sub}"

    if [ ! -e "${_source}" ] && [ -d "${_target}" ]; then
        if mkdir -p "${_source}" 2> /dev/null \
           && cp -a "${_target}/." "${_source}/" 2> /dev/null; then
            echo "${_sub}" >> "${RUNTIME_DIR}/.seeded" 2> /dev/null || true
        else
            warn "面板状态 ${_sub} 初始化失败，将以空目录启动"
        fi
    fi

    # 宝塔把面板 data/ 等目录设为 600（无 x 位），cp -a 会把目录自身的模式
    # 一起带到持久化源目录上。目录没有 x 位时连所有者都无法在其下创建文件：
    # Linux 上容器 root 靠 CAP_DAC_OVERRIDE 侥幸能写，但 Docker Desktop 的
    # virtiofs 不豁免 —— 首次启动写 port.pl 直接 Permission denied，容器起不来；
    # CI 的宿主机侧断言（非 root）也穿不透，会误报「写入未落盘」。
    # 源目录是本方案的挂载基础设施，归我们管，归位 700；目录内容仍保持镜像原样
    if [ -d "${_source}" ]; then
        chmod 700 "${_source}" 2> /dev/null \
            || warn "无法修正 ${_source} 目录权限（缺少 x 位），面板可能无法写入"
    fi

    bind_subdir "${_source}" "${_target}"
}

# 业务与面板状态的统一入口。失败记 degraded，关键目录额外记 critical
mount_www_layer() {
    # 注意：WWW_DATA_SUBDIRS 直接 bind，不像 PANEL_STATE_SUBDIRS 那样先从镜像 seed。
    # 因此这些目录在镜像内必须为空（MySQL 等由容器首启初始化），否则首启会被空持久化源遮住镜像内容。
    for _sub in ${WWW_DATA_SUBDIRS}; do
        [ -n "${_sub}" ] || continue
        if ! bind_subdir "${PERSIST_DATA_ROOT}/www/${_sub}" "/www/${_sub}"; then
            mark_degraded "/www/${_sub}: 业务目录绑定失败"
            if is_critical "/www/${_sub}"; then
                mark_critical "/www/${_sub}: 业务目录未持久化"
                _failed=1
            fi
        fi
    done

    for _sub in ${PANEL_STATE_SUBDIRS}; do
        [ -n "${_sub}" ] || continue
        if ! seed_panel_state "${_sub}"; then
            mark_degraded "/www/server/panel/${_sub}: 面板状态绑定失败"
            if is_critical "/www/server/panel/${_sub}"; then
                mark_critical "/www/server/panel/${_sub}: 面板状态未持久化"
                _failed=1
            fi
        fi
    done

    # 可选模块失败不算关键（模块没装时本来就没有数据），只记 degraded
    for _sub in ${WWW_OPTIONAL_SUBDIRS:-}; do
        [ -n "${_sub}" ] || continue
        bind_optional_subdir "${_sub}" \
            || mark_degraded "/www/${_sub}: 可选模块目录绑定失败"
    done
}

# ==============================================================================
#  2.5 pyenv 覆盖层：pip 包持久化 + 解释器随镜像更新（PANEL_PYENV_OVERLAY=on）
#   lower = 钉桩里的镜像 pyenv（随镜像走）；upper = 数据层 pyenv（pip 的包在这里）。
#  于是两者同时成立：pip 包重建后还在，镜像升级的新解释器 / 新依赖照样生效 ——
#  不再有「把 pyenv 加进 PANEL_STATE_SUBDIRS 就不再随镜像更新」的取舍。
#  ★ 原生模式 upper/work 都在数据层 PANEL_STATE_ROOT（同盘，满足内核要求）；
#    镜像模式时两者改指镜像挂载点（由 attach_overlay_store 重定向 PERSIST_SYSTEM_ROOT）。
#  ★ 必须挂在「面板代码 bind 回镜像」之后：早于它会被那次 bind 遮住
# ==============================================================================
mount_pyenv_overlay() {
    _target="${PANEL_DIR}/pyenv"

    if [ -z "${PANEL_PIN_DIR}" ]; then
        warn "面板代码未钉桩，pyenv 覆盖层跳过：插件 pip 包不会持久化"
        mark_degraded "${_target}: 面板未钉桩，pyenv 覆盖层未挂载"
        mark_critical "${_target}: pyenv 覆盖层未挂载，pip 包将丢失"
        return 1
    fi
    if [ ! -d "${PANEL_PIN_DIR}/pyenv" ]; then
        warn "镜像里没有 ${PANEL_PIN_DIR}/pyenv，pyenv 覆盖层跳过"
        mark_degraded "${_target}: 镜像无 pyenv，覆盖层未挂载"
        return 1
    fi

    # 自动模式：原生 overlay（upper/work 都在数据层，同盘）
    if [ -z "${_FORCE_IMG:-}" ]; then
        if try_overlay "${_target}" "${PANEL_STATE_ROOT}/pyenv" "${PANEL_STATE_ROOT}/pyenv.work"; then
            log "pyenv 覆盖层已挂载：pip 包持久化，解释器随镜像更新"
            return 0
        fi
    fi

    # 兜底/强制：与系统层共用同一个 ext4 镜像（挂载后 PERSIST_SYSTEM_ROOT 指向挂载点）
    if attach_overlay_store; then
        if try_overlay "${_target}" "${PERSIST_SYSTEM_ROOT}/pyenv" "${PERSIST_SYSTEM_ROOT}/pyenv.work"; then
            log "pyenv 覆盖层走 ext4 镜像兜底：pip 包持久化"
            return 0
        fi
    fi

    warn "pyenv 覆盖层挂载失败或不可写：插件 pip 包不会持久化"
    rm -f "${_target}/${PROBE}" 2> /dev/null || true
    mark_degraded "${_target}: pyenv 覆盖层不可用"
    mark_critical "${_target}: pyenv 覆盖层不可用，pip 包将丢失"
    return 1
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    # ---- 0. 解析 PERSIST_SYSTEM_IMAGE 并（可选）提前挂载镜像 ----
    #   true/on/1/yes  → 强制镜像模式，默认路径 <data>/overlay.img
    #   显式路径        → 强制镜像模式，使用该路径（必须落在 data 内）
    #   auto/空        → 自动：原生 overlay 优先，失败才用镜像兜底
    #   false/0/no/off → 关闭镜像模式：走原生 overlay，不自动兜底
    #   _FORCE_IMG=1 时跳过原生 overlay 试探；_IMG_EXPLICIT=1 时镜像损坏不擅自重建
    case "${PERSIST_SYSTEM_IMAGE:-}" in
        true|on|1|yes)  _FORCE_IMG=1; _IMG_EXPLICIT=0; _IMG_DISABLED=0 ;;
        false|0|no|off) _FORCE_IMG=''; _IMG_EXPLICIT=0; _IMG_DISABLED=1 ;;
        auto|"")        _FORCE_IMG=''; _IMG_EXPLICIT=0; _IMG_DISABLED=0 ;;
        *)              _FORCE_IMG=1; _IMG_EXPLICIT=1; _IMG_DISABLED=0 ;;
    esac
    _IMG_PATH="${PERSIST_SYSTEM_IMAGE_PATH}"
    export _FORCE_IMG _IMG_PATH _IMG_EXPLICIT _IMG_DISABLED

    # 强制镜像模式：提前挂载（跳过原生 overlay 试探）
    if [ "${_FORCE_IMG}" = 1 ]; then
        attach_overlay_store
    fi

    # 运行态标记目录（tmpfs）：准备 seeded 记录文件，供挂载汇总树标注「首次初始化」
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || true
    : > "${RUNTIME_DIR}/.seeded" 2> /dev/null || true

    # ---- 1. 系统层 overlay 持久化 ----
    #     /www/server 也在这一层（组件、计划任务脚本、插件数据都在它下面），
    #     但面板代码必须先钉在 /run 上、挂完 overlay 再 bind 回去 —— 见下面
    _failed=0
    # 标记先清掉：/run 正常是 tmpfs（重启即空），但万一不是，也不能让上次的
    # 「已隔离」残留成假阳性 —— 隔离结论只认本次 bind 回的成败
    rm -f "${PANEL_ISOLATED}" 2> /dev/null || true

    # 面板代码来自镜像层、不落持久化层：先把镜像里的面板目录 bind 到 /run，
    # 等 /www/server 的 overlay 挂上后再 bind 回去（顺序反了装的就是镜像里那份
    # 被 overlay 合并后的视图，面板内更新会写进持久化层，换镜像就升不了面板）
    if [ -d "${PANEL_DIR}" ] && mkdir -p "${PANEL_PIN_DIR}" 2> /dev/null; then
        if mount -o bind "${PANEL_DIR}" "${PANEL_PIN_DIR}" 2> /dev/null; then
            :
        else
            warn "无法把 ${PANEL_DIR} bind 到 ${PANEL_PIN_DIR}，本次面板代码会落进持久化层"
            PANEL_PIN_DIR=''
        fi
    else
        PANEL_PIN_DIR=''
    fi

    for _dir in ${PERSIST_SYSTEM_DIRS}; do
        if ! mount_persist "${_dir}"; then
            _failed=1
            if is_critical "/${_dir}"; then
                mark_critical "/${_dir}: 关键目录未持久化"
            fi
        fi
    done

    # 把面板代码 bind 回镜像那份：/www/server 其余内容（组件、cron 脚本、
    # 插件数据）留在 overlay 的 upper 里持久化，面板目录本身则始终来自镜像
    if [ -n "${PANEL_PIN_DIR}" ]; then
        if mount -o bind "${PANEL_PIN_DIR}" "${PANEL_DIR}" 2> /dev/null; then
            : > "${PANEL_ISOLATED}" 2> /dev/null || true
        else
            warn "面板代码 bind 回 ${PANEL_DIR} 失败：面板代码可能落进持久化层"
            mark_critical "${PANEL_DIR}: 面板代码未隔离出持久化层"
        fi
    fi

    # ---- 2.5 pyenv 覆盖层（必须晚于上面的 bind 回，否则会被那次 bind 遮住）----
    case "${PANEL_PYENV_OVERLAY}" in
        on)
            mount_pyenv_overlay || _failed=1
            ;;
        *)
            warn "PANEL_PYENV_OVERLAY=${PANEL_PYENV_OVERLAY}：pyenv 不持久化，插件 pip 包重建即丢"
            ;;
    esac

    # ---- 3. 业务数据与面板状态（逐子目录 bind）----
    mount_www_layer

    # ---- 3.5 挂载汇总成目录树（替代逐条日志）----
    print_mount_tree

    if [ "${_failed}" -ne 0 ]; then
        warn '存在未持久化的目录，容器仍会启动，但销毁后这些目录的数据会丢失'
    fi

    # ---- 4. 交给阶段 1 ----
    if [ -f "${STAGE1}" ] && [ -x /bin/bash ]; then
        exec /bin/bash "${STAGE1}" "$@"
    fi
    warn "未找到 /bin/bash 或 ${STAGE1}，跳过阶段 1，直接执行：$*"
    exec "$@"
}

main "$@"
