#!/busybox sh
# shellcheck shell=sh  # 本文件必须保持 POSIX（busybox 解释），shebang 不被 shellcheck 识别，需显式声明方言
# ==============================================================================
#  [阶段 0] 早期初始化 —— 并发锁 → overlay 持久化 → 移交阶段 1
#
#  解释器用 busybox 而非 bash：本脚本要给 /usr 挂 overlay，万一持久化层里的
#  /usr 被写坏，Debian 的 usrmerge（/bin -> usr/bin）会让 /bin/bash 一起消失，
#  脚本自身就跑不起来了。/busybox 静态链接、位于 rootfs 根部，永远可用。
#
#  因此本文件只能用 POSIX shell 语法：
#    不能用 local / [[ ]] / 数组 / pipefail；函数名内的「局部变量」统一用
#    下划线前缀（_dir / _upper / _work）标示，避免与调用方的循环变量重名。
#
#  可用环境变量（真源见 /baota/defaults.env）：
#    PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PERSIST_DATA_DIRS /
#    PERSIST_SYSTEM_DIRS / CRITICAL_DIRS / STAGE2
#
#  日志约定：[init] 普通信息，[init][WARN] 告警
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（镜像自有，不在任何持久化目录内）。
# 文件内部一律写成 ${VAR:-默认值}，保证「已存在的环境变量优先」：
# Dockerfile 的 ENV 与用户在 compose 里传的值都不会被它覆盖。
# ------------------------------------------------------------------------------
if [ -f /baota/defaults.env ]; then
    . /baota/defaults.env
fi

PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
PERSIST_DATA_DIRS="${PERSIST_DATA_DIRS:-www}"
PERSIST_SYSTEM_DIRS="${PERSIST_SYSTEM_DIRS:-etc usr var root opt home srv}"
STAGE2="${STAGE2:-/baota/entrypoint.sh}"

# 这几个目录一旦持久化失败，数据会静默丢失 —— 必须让 healthcheck 可见
CRITICAL_DIRS="${CRITICAL_DIRS:-etc var www}"

# Docker 在 entrypoint 之前把它们 bind mount 到 /etc 下，
# 稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回
DOCKER_META=/run/docker-meta
DOCKER_FILES="hosts resolv.conf hostname"

# 可写性探测文件名（同时用于 lower 与 upper 两侧）
PROBE=.persist-writable-probe

# overlay 要求 workdir 与 upperdir 位于同一文件系统（内核硬性要求），
# 所以 work 只能放在对应持久化层内、且必须与 upper 同盘：
#   数据层 work -> /data/.baota/work
#   系统层 work -> /data/system/.baota/work
DATA_WORK_ROOT="${PERSIST_DATA_ROOT}/.baota/work"
SYS_WORK_ROOT="${PERSIST_SYSTEM_ROOT}/.baota/work"
# 数据层状态（锁 + workdir）落在数据层根的 .baota；项目元数据（版本记录 /
# 启动历史）收进系统层的 .baota，两者都随对应层持久化
DATA_STATE_DIR="${PERSIST_DATA_ROOT}/.baota"
DATA_LOCK_FILE="${DATA_STATE_DIR}/lock"
STATE_DIR="${PERSIST_SYSTEM_ROOT}/.baota"
LOCK_FILE="${STATE_DIR}/lock"

# 运行态标记目录。/run 是 tmpfs：每次启动重新评估，不会残留上次的状态。
# 供 compose healthcheck 与 CI 健康检查判定「本次启动的持久化是否完整」。
# 文案怎么改都不影响门禁 —— 读的是标记文件，不是日志文本。
RUNTIME_DIR=/run/baota
DEGRADED="${RUNTIME_DIR}/degraded"
DEGRADED_CRITICAL="${RUNTIME_DIR}/degraded-critical"

# ------------------------------------------------------------------------------
# 日志与降级标记
#
# 告警除了打日志，还会写入 /run/baota/degraded（-critical）标记文件。
# 持久化失败有两类，分开记录：
#   degraded          非关键目录未持久化，功能受损但不丢核心数据
#   degraded-critical 关键目录（etc/var/www）出问题，写入会静默丢失
# ------------------------------------------------------------------------------
log()  { echo "⚙️ [init] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [init][WARN] $(date '+%H:%M:%S') - $*" >&2; }

mark_degraded() {
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || return 0
    printf '%s\n' "$1" >> "${DEGRADED}" 2> /dev/null || true
}

mark_critical() {
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || return 0
    printf '%s\n' "$1" >> "${DEGRADED_CRITICAL}" 2> /dev/null || true
}

# ==============================================================================
#  0. 并发互斥锁
#
#  同一份持久化层（同一个 upperdir / workdir）被两个容器同时挂载是内核明确
#  禁止的：可能 EBUSY，也可能挂载成功但行为未定义。这里在挂载之前先抢锁，
#  把「用户误起第二个实例」从静默数据损坏变成一次明确的启动失败。
#
#  用 util-linux 的 /usr/bin/flock 而不是自己实现锁文件：
#    - busybox 不带 flock applet（实测 applet not found）
#    - flock 由内核持有，进程 / 容器死亡时自动释放 ——
#      非正常退出不会留下死锁，下次启动无需人工干预
#    - fd 8 / fd 9 会被后续 exec 继承，锁在容器整个生命周期内保持
#
#  数据层与系统层各一把锁（fd 8 / fd 9）：
#    单挂模式下两者落在同一个 data 目录里，第二把锁是冗余的但无害；
#    用户若把系统层单独 bind 到别的目录，两把锁才能各自覆盖一层
# ==============================================================================

# 单层加锁。参数：$1=状态目录 $2=锁文件 $3=fd 号 $4=层名（仅用于日志）
#
# fd 号用 case 写死 8 / 9 而不是 eval 动态拼接：
# exec 的重定向目标无法用变量展开，eval 又要防注入，
# 两个取值用 case 分支最直接，也不会有拼错命令的风险
_lock_layer() {
    _state="$1"
    _lock="$2"
    _fd="$3"
    _name="$4"

    mkdir -p "${_state}" 2> /dev/null || true

    if [ ! -d "${_state}" ]; then
        warn "无法创建 ${_state}：${_name}持久化根不可写，跳过该层并发保护"
        return 0
    fi

    # 先确认锁文件可写。用 >> 追加探测，避免截断已有内容（busybox sh 里
    # 重定向失败会让当前 shell 直接退出，所以必须先探测、再 exec，不能靠 || 兜底）
    if ! ( exec 2> /dev/null; : >> "${_lock}" ); then
        warn "无法写入 ${_lock}，跳过${_name}并发保护"
        return 0
    fi

    if [ ! -x /usr/bin/flock ]; then
        # 没有 flock 时只放行不阻断：相较于「两个实例共享数据」，
        # 「崩溃后无法启动」的死锁更糟糕
        warn "未找到 /usr/bin/flock，跳过${_name}并发保护"
        return 0
    fi

    # 读写打开不截断：抢不到锁时还能读到持有者信息用于排障
    case "${_fd}" in
        8) exec 8<>"${_lock}" ;;
        9) exec 9<>"${_lock}" ;;
        *) warn "内部错误：不支持的锁 fd ${_fd}，跳过${_name}并发保护"; return 0 ;;
    esac

    if ! /usr/bin/flock -n "${_fd}"; then
        _owner=$(cat "${_lock}" 2> /dev/null || echo '未知')
        warn '=============================================================='
        warn "另一个容器实例正在使用同一份持久化数据（${_name}）"
        warn "  持有者：${_owner}"
        warn '  同一份持久化层不可被两个容器同时挂载（内核 EBUSY / 行为未定义），'
        warn '  为避免数据损坏，本次启动已中止。'
        warn '  常见原因：stable 与 release 两个 compose 用了同一个 data 目录。'
        warn "  确认没有其它实例在跑之后，删除 ${_lock} 再启动。"
        warn '=============================================================='
        return 1
    fi

    # 锁内容仅供排障：谁、什么时候持有的
    case "${_fd}" in
        8) printf 'pid=%s host=%s at=%s\n' \
               "$$" "$(hostname 2> /dev/null || echo unknown)" "$(date '+%F %T')" >&8 ;;
        9) printf 'pid=%s host=%s at=%s\n' \
               "$$" "$(hostname 2> /dev/null || echo unknown)" "$(date '+%F %T')" >&9 ;;
    esac

    log "已获得${_name}持久化层独占锁"
    return 0
}

acquire_lock() {
    # 系统层：overlay workdir、镜像版本记录、启动历史都在这里
    _lock_layer "${STATE_DIR}" "${LOCK_FILE}" 9 '系统层' || return 1
    # 数据层：面板 / 站点 / 数据库 / 备份
    _lock_layer "${DATA_STATE_DIR}" "${DATA_LOCK_FILE}" 8 '数据层' || return 1
    log '持久化层并发保护已就位'
    return 0
}

# ==============================================================================
#  1. overlay 分层持久化
#
#    /www              ←overlay→  upper = /data/www
#    /etc /usr /var…   ←overlay→  upper = /data/system/<同名>
#    lowerdir = 镜像内的同名目录（随镜像升级而更新）
#    workdir  = /data/.baota/work/<dir>.work 或 /data/system/.baota/work/<dir>.work
#               （内部工作目录，须与 upper 同文件系统）
#
#  ★ index=off 是必须的，不是优化：
#    内核文档 Overlay Filesystem 明确——「用同一个 upper 挂载不同的 lower」
#    仅在未启用 index / metacopy 时才合法。本方案「换镜像升级」的本质
#    就是同一个 upper 换 lower，一旦发行版内核把 index 编译为默认开启，
#    每次升级都会进入未定义行为区。显式写死才能让这份保证不依赖默认值。
#
#  workdir 用固定名字、启动时先清理：清理与挂载都在独占锁的保护下，
#  同一时刻不可能有另一个实例在用这份 workdir。
# ==============================================================================
mount_persist() {
    _dir="$1"
    _lower="/${_dir}"
    # 数据层与系统层落到不同的持久化根，workdir 必须与 upper 同盘
    case " ${PERSIST_DATA_DIRS} " in
        *" ${_dir} "*) _upper="${PERSIST_DATA_ROOT}/${_dir}"; _work="${DATA_WORK_ROOT}/${_dir}.work" ;;
        *)            _upper="${PERSIST_SYSTEM_ROOT}/${_dir}"; _work="${SYS_WORK_ROOT}/${_dir}.work" ;;
    esac

    # 先确认持久化根本身可写。最常见的误配就是把只读目录挂成了持久化根，
    # 这里直接给出结论，避免用户被后面一串 mount / rm 的原始报错带偏
    if ! mkdir -p "${_lower}" "${_upper}" 2> /dev/null; then
        warn "无法创建 ${_upper}：持久化根不可写，/${_dir} 本次不会持久化"
        mark_degraded "${_dir}: 持久化根不可写"
        return 1
    fi

    # 清理历史 workdir（已持锁，不会有别的实例在用），再建本次专用的
    rm -rf "${_work}" 2> /dev/null || true
    if ! mkdir -p "${_work}" 2> /dev/null; then
        warn "无法创建 ${_work}：持久化根不可写，/${_dir} 本次不会持久化"
        mark_degraded "${_dir}: workdir 创建失败"
        return 1
    fi

    if ! mount -t overlay overlay \
        -o "lowerdir=${_lower},upperdir=${_upper},workdir=${_work},index=off" "${_lower}"; then
        warn "overlay 挂载失败：/${_dir} 本次不会持久化"
        warn '  常见原因：'
        warn '    1) 容器未以 --privileged 运行（挂载 overlay 需要 CAP_SYS_ADMIN）'
        warn '    2) 持久化根（/data 或 /data/system）本身位于 overlay 之上（例如落在容器可写层里）'
        warn '    3) 宿主机内核未启用 overlayfs'
        warn '  与「挂载成功但只读」不同，这种情况文件系统层面直接拒绝挂载'
        mark_degraded "${_dir}: overlay 挂载失败"
        return 1
    fi

    # 挂载成功 ≠ 可写、≠ 写得进 upper。
    # 当持久化根位于 virtiofs / NFS / 9p（典型：把 macOS、Windows 宿主机目录
    # bind 进容器）时，overlay 会挂载成功却降级为只读，之后所有写入静默失败。
    # 这里实测一次，把隐患在启动阶段就暴露出来，而不是等用户丢了数据才发现。
    #
    # 探测必须写成子 shell，两个坑都得躲：
    #   1) dash / busybox sh 里重定向失败会让「当前 shell 直接退出」，
    #      套一层子 shell 才能挡住，否则整个启动脚本在这里就没了；
    #   2) 得先 exec 2>/dev/null 再重定向 —— 重定向是从左到右处理的，
    #      把 2>/dev/null 写在后面时报错已经打到 stderr 上了。
    if ( exec 2> /dev/null; : > "${_lower}/${PROBE}" ) && [ -e "${_upper}/${PROBE}" ]; then
        rm -f "${_lower}/${PROBE}"
        log "持久化已挂载 /${_dir} <- ${_upper}"
        return 0
    fi

    warn "/${_dir} 的持久化层挂载成功但不可写，本次不会持久化"
    warn "  原因通常是持久化根（/data 或 /data/system）位于 virtiofs / NFS / 9p 等文件系统"
    warn "  请让持久化根落在 ext4 / xfs / btrfs 上，或改用 Docker 管理的 volume"
    rm -f "${_lower}/${PROBE}" 2> /dev/null || true
    mark_degraded "${_dir}: 挂载成功但不可写"
    return 1
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    # ---- 0. 并发锁（抢不到就中止，不做任何挂载）----
    acquire_lock || exit 1

    # ---- 1. 暂存 Docker 动态注入的文件 ----
    # Docker 会把 hosts / resolv.conf / hostname bind 到 /etc 下，随后的 overlay
    # 会盖住这些子挂载；先把内容取出，挂完 overlay 再写回（见第 3 步）
    rm -rf "${DOCKER_META}"
    mkdir -p "${DOCKER_META}"
    for _f in ${DOCKER_FILES}; do
        if [ -e "/etc/${_f}" ]; then
            cp -f "/etc/${_f}" "${DOCKER_META}/${_f}"
        fi
    done

    # ---- 2. overlay 持久化 ----
    _failed=0
    for _dir in ${PERSIST_DATA_DIRS} ${PERSIST_SYSTEM_DIRS}; do
        if ! mount_persist "${_dir}"; then
            _failed=1
            case " ${CRITICAL_DIRS} " in
                *" ${_dir} "*) mark_critical "${_dir}: 关键目录未持久化" ;;
            esac
        fi
    done
    if [ "${_failed}" -ne 0 ]; then
        warn '存在未持久化的目录，容器仍会启动，但销毁后这些目录的数据会丢失'
    fi

    # ---- 3. 还原 Docker 动态文件 ----
    # 写回内容而非重新 bind，效果等价且更简单。
    # 这里失败也不中断启动：持久化层只读时，至少还能进容器看日志排查
    for _f in ${DOCKER_FILES}; do
        if [ -f "${DOCKER_META}/${_f}" ]; then
            cp -f "${DOCKER_META}/${_f}" "/etc/${_f}" \
                || warn "无法写回 /etc/${_f}，容器 DNS / 主机名解析可能异常"
            chmod 0644 "/etc/${_f}" 2> /dev/null || true
        fi
    done
    rm -rf "${DOCKER_META}"

    # ---- 4. 交给阶段 1 ----
    if [ -f "${STAGE2}" ] && [ -x /bin/bash ]; then
        exec /bin/bash "${STAGE2}" "$@"
    fi

    warn "未找到 /bin/bash 或 ${STAGE2}，跳过阶段 1，直接执行：$*"
    exec "$@"
}

main "$@"
