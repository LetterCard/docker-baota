#!/busybox sh
# shellcheck shell=sh  # 本文件必须保持 POSIX（busybox 解释），shebang 不被 shellcheck 识别，需显式声明方言
# ==============================================================================
#  [阶段 0] 早期初始化 —— 并发锁 → overlay 持久化 → 业务直通 → 移交阶段 1
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
#    PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PANEL_UPPER_DIR /
#    PERSIST_SYSTEM_DIRS / PASSTHROUGH_DIRS / CRITICAL_DIRS / STAGE2
#
#  日志约定：[init] 普通信息，[init][WARN] 告警
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（镜像自有，不在任何持久化目录内）。
# 文件内部一律写成 ${VAR:-默认值}，保证「已存在的环境变量优先」。
# ------------------------------------------------------------------------------
if [ -f /baota/defaults.env ]; then
    . /baota/defaults.env
fi

PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
PANEL_UPPER_DIR="${PANEL_UPPER_DIR:-${PERSIST_SYSTEM_ROOT}/panel}"
PERSIST_SYSTEM_DIRS="${PERSIST_SYSTEM_DIRS:-etc usr var root opt home srv}"
PASSTHROUGH_DIRS="${PASSTHROUGH_DIRS:-/www/wwwroot /www/backup /www/server/data}"
STAGE2="${STAGE2:-/baota/entrypoint.sh}"

# 这几个目录一旦持久化失败，数据会静默丢失 —— 必须让 healthcheck 可见。
# 名字必须是循环里传进 mount_persist 的顶层目录名（www / PERSIST_SYSTEM_DIRS 之一），
# 不是 upper 目录名：面板这层循环里叫 www，upper 才叫 data/system/panel
CRITICAL_DIRS="${CRITICAL_DIRS:-etc var www}"

# Docker 在 entrypoint 之前把它们 bind mount 到 /etc 下，
# 稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回
DOCKER_META=/run/docker-meta
DOCKER_FILES="hosts resolv.conf hostname"

# 可写性探测文件名（同时用于 lower 与 upper 两侧）
PROBE=.persist-writable-probe

# overlay 要求 workdir 与 upperdir 位于同一文件系统（内核硬性要求），
# 所以 work 放在对应持久化层内、且必须与 upper 同盘。
# 面板（/www overlay）upper 在系统层下（data/system/panel），work 用系统层的工作目录
#
# 各 overlay 的 workdir 形如 <STATE_DIR>/<目录>.work。内核挂载后会**在它里面再建一层
# work**（即 <目录>.work/work）—— 那层是内核行为，省不掉；能省的只有外面那层容器目录，
# 所以这里不再多套一层 work/，直接挂在 .baota 下（少一层、少一次重复命名）
SYS_WORK_ROOT="${PERSIST_SYSTEM_ROOT}/.baota"
DATA_STATE_DIR="${PERSIST_DATA_ROOT}/.baota"
DATA_LOCK_FILE="${DATA_STATE_DIR}/lock"
STATE_DIR="${PERSIST_SYSTEM_ROOT}/.baota"
LOCK_FILE="${STATE_DIR}/lock"

# 运行态标记目录。/run 是 tmpfs：每次启动重新评估，不会残留上次的状态。
# 供 compose healthcheck 与 CI 健康检查判定「本次启动的持久化是否完整」。
RUNTIME_DIR=/run/baota
DEGRADED="${RUNTIME_DIR}/degraded"
DEGRADED_CRITICAL="${RUNTIME_DIR}/degraded-critical"

# ------------------------------------------------------------------------------
# 日志与降级标记
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
#  0. 并发互斥锁（flock）
#
#  ★ 持锁方式必须是「独立后台进程」，不能用 exec 8<>lock + flock -n 8 的
#    fd 方式：fd 会随 exec 链（busybox → bash entrypoint → systemd）一路
#    移交给 PID 1，而 systemd 启动时会关闭继承的非标准 fd —— 锁随 fd 关闭
#    而自动释放。实测（Docker Desktop，flock util-linux 2.38）主容器就绪
#    （systemd 接管后）第二实例能再次取得同一把锁、锁文件被覆盖，并发保护
#    在启动数秒后即失效。独立进程持锁与 exec 链无关：进程活 → 锁在；
#    容器停止 → 进程亡 → 锁自动释放。持锁者在 docker top 里是一个 sleep
#    进程，属预期。
# ==============================================================================
_lock_layer() {
    _lock="$1"
    _name="$2"

    _dir=$(dirname "${_lock}")
    if ! mkdir -p "${_dir}" 2> /dev/null || [ ! -d "${_dir}" ]; then
        warn "无法创建 ${_dir}：${_name}持久化根不可写，跳过该层并发保护"
        return 0
    fi
    if ! ( exec 2> /dev/null; : >> "${_lock}" ); then
        warn "无法写入 ${_lock}，跳过${_name}并发保护"
        return 0
    fi
    if [ ! -x /usr/bin/flock ]; then
        warn "未找到 /usr/bin/flock，跳过${_name}并发保护"
        return 0
    fi

    # 一步完成「非阻塞互斥 + 长期持有」：拿到锁 → flock 驻留后台（持锁直到
    # 进程退出）；拿不到 → flock 立即非零退出。通过 kill -0 观察其生死来判定。
    /usr/bin/flock -n "${_lock}" -c 'exec sleep infinity' &
    _holder=$!
    _tries=0
    while kill -0 "${_holder}" 2> /dev/null && [ "${_tries}" -lt 3 ]; do
        _tries=$((_tries + 1))
        sleep 1
    done
    if ! kill -0 "${_holder}" 2> /dev/null; then
        wait "${_holder}" 2> /dev/null || true
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

    printf 'pid=%s host=%s at=%s\n' \
        "$$" "$(hostname 2> /dev/null || echo unknown)" "$(date '+%F %T')" \
        >> "${_lock}" 2> /dev/null || true
    log "已获得${_name}持久化层独占锁"
    return 0
}

acquire_lock() {
    _lock_layer "${LOCK_FILE}" '系统层' || return 1
    _lock_layer "${DATA_LOCK_FILE}" '数据层' || return 1
    log '持久化层并发保护已就位'
    return 0
}

# ==============================================================================
#  1. overlay 分层持久化
#
#    /www（面板，含 server/panel、wwwlogs…）←overlay→  upper = data/system/panel
#    /etc /usr /var …                            ←overlay→  upper = data/system/<同名>
#    lowerdir = 镜像内的同名目录（随镜像升级而更新）
#
#  ★ index=off 是必须的，不是优化（同 upper 换 lower 的升级语义需要它）
# ==============================================================================
mount_persist() {
    _dir="$1"
    _lower="/${_dir}"
    # 面板那一层：/www → upper = data/system/panel（放系统层下，便于宿主感知）
    if [ "${_dir}" = 'www' ]; then
        _upper="${PANEL_UPPER_DIR}"
        _work="${SYS_WORK_ROOT}/www.work"
    else
        _upper="${PERSIST_SYSTEM_ROOT}/${_dir}"
        _work="${SYS_WORK_ROOT}/${_dir}.work"
    fi

    if ! mkdir -p "${_lower}" "${_upper}" 2> /dev/null; then
        warn "无法创建 ${_upper}：持久化根不可写，/${_dir} 本次不会持久化"
        mark_degraded "${_dir}: 持久化根不可写"
        return 1
    fi

    rm -rf "${_work}" 2> /dev/null || true
    if ! mkdir -p "${_work}" 2> /dev/null; then
        warn "无法创建 ${_work}：持久化根不可写，/${_dir} 本次不会持久化"
        mark_degraded "${_dir}: workdir 创建失败"
        return 1
    fi

    if ! mount -t overlay overlay \
        -o "lowerdir=${_lower},upperdir=${_upper},workdir=${_work},index=off" "${_lower}"; then
        warn "overlay 挂载失败：/${_dir} 本次不会持久化"
        warn '  常见原因：容器未以 --privileged 运行 / 持久化根位于 overlay 之上 / 内核未启用 overlayfs'
        mark_degraded "${_dir}: overlay 挂载失败"
        return 1
    fi

    # 挂载成功 ≠ 可写（virtiofs / NFS / 9p 会降级只读），实测写入
    if ( exec 2> /dev/null; : > "${_lower}/${PROBE}" ) && [ -e "${_upper}/${PROBE}" ]; then
        rm -f "${_lower}/${PROBE}"
        log "持久化已挂载 /${_dir} <- ${_upper}"
        return 0
    fi

    warn "/${_dir} 的持久化层挂载成功但不可写，本次不会持久化"
    warn "  请让持久化根落在 ext4 / xfs / btrfs 上，或改用 Docker 管理的 volume"
    rm -f "${_lower}/${PROBE}" 2> /dev/null || true
    mark_degraded "${_dir}: 挂载成功但不可写"
    return 1
}

# ==============================================================================
#  2. 业务直通（bind 绕过 overlay）
#
#  站点 / 备份 / MySQL 是纯运行期数据，镜像里为空。走 bind 直通：
#    - 宿主机 data/www/<同名> 直接用 SMB / 文件管理读写，有内核保证
#    - 源在 /www overlay upper（data/system/panel）之外，无 overlay 语义冲突
#  顺序要求：先挂完 /www 的 overlay，再 bind 子目录
# ==============================================================================
mount_passthrough() {
    _target="$1"
    # /www/wwwroot -> data/www/wwwroot
    _source="${PERSIST_DATA_ROOT}/www${_target#/www}"

    [ -d "${_target}" ] || mkdir -p "${_target}" 2> /dev/null || true
    if [ ! -d "${_target}" ]; then
        warn "直通目标不存在且无法创建：${_target}"
        return 1
    fi
    if ! mkdir -p "${_source}" 2> /dev/null; then
        warn "无法创建直通源 ${_source}：数据层根不可写，${_target} 回落到 overlay"
        return 1
    fi
    if mount -o bind "${_source}" "${_target}" 2> /dev/null; then
        log "直通挂载 ${_target} <- ${_source}"
        return 0
    fi
    warn "直通挂载失败：${_target}（回落到 overlay，功能不受影响）"
    return 1
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    acquire_lock || exit 1

    # ---- 0. 清理旧版 workdir 容器 ----
    # 早期版本把各 overlay 的 workdir 收在 .baota/work/<目录>.work 下，
    # 现在直接放在 .baota/<目录>.work。旧目录里没有任何持久数据（workdir 每次启动
    # 都重建），直接删掉，避免它在用户的 data/ 里留下孤儿目录
    rm -rf "${STATE_DIR}/work" 2> /dev/null || true

    # ---- 1. 暂存 Docker 动态注入的文件（/etc 即将被 overlay 盖住）----
    rm -rf "${DOCKER_META}"
    mkdir -p "${DOCKER_META}"
    for _f in ${DOCKER_FILES}; do
        if [ -e "/etc/${_f}" ]; then
            cp -f "/etc/${_f}" "${DOCKER_META}/${_f}"
        fi
    done

    # ---- 2. overlay 持久化：/www（面板层）+ 系统层各目录 ----
    _failed=0
    for _dir in www ${PERSIST_SYSTEM_DIRS}; do
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

    # ---- 3. 业务直通（在 /www overlay 之上 bind 三个业务目录）----
    for _t in ${PASSTHROUGH_DIRS}; do
        [ -n "${_t}" ] || continue
        mount_passthrough "${_t}" || true
    done

    # ---- 4. 还原 Docker 动态文件 ----
    for _f in ${DOCKER_FILES}; do
        if [ -f "${DOCKER_META}/${_f}" ]; then
            cp -f "${DOCKER_META}/${_f}" "/etc/${_f}" \
                || warn "无法写回 /etc/${_f}，容器 DNS / 主机名解析可能异常"
            chmod 0644 "/etc/${_f}" 2> /dev/null || true
        fi
    done
    rm -rf "${DOCKER_META}"

    # ---- 5. 交给阶段 1 ----
    if [ -f "${STAGE2}" ] && [ -x /bin/bash ]; then
        exec /bin/bash "${STAGE2}" "$@"
    fi
    warn "未找到 /bin/bash 或 ${STAGE2}，跳过阶段 1，直接执行：$*"
    exec "$@"
}

main "$@"
