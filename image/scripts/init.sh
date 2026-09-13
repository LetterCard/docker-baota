#!/busybox sh
# shellcheck shell=sh  # 本文件必须保持 POSIX（busybox 解释），shebang 不被 shellcheck 识别，需显式声明方言
# ==============================================================================
#  [阶段 0] 早期初始化 —— 并发锁 → 系统层 overlay → 业务/面板子目录 bind → 移交阶段 1
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
#    PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT / PERSIST_SYSTEM_DIRS /
#    WWW_DATA_SUBDIRS / PANEL_STATE_ROOT / PANEL_STATE_SUBDIRS /
#    CRITICAL_DIRS / STAGE2
#
#  日志约定：[init] 普通信息，[init][WARN] 告警
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（镜像自有，不在任何持久化目录内）。
# ★ 只在这里取配置，脚本里不再写默认值副本 —— 副本必然漂移，而漂移的表现
#   是「构建期按旧值建目录 / 运行期按旧值算路径」，离原因很远
# ------------------------------------------------------------------------------
if [ ! -f /baota/defaults.env ]; then
    echo '❌ [init][ERROR] 缺少运行期配置真源 /baota/defaults.env，镜像不完整，拒绝启动' >&2
    exit 1
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. /baota/defaults.env

# init.sh 自己的运行参数（不属于配置真源）
STAGE2="${STAGE2:-/baota/entrypoint.sh}"

# 面板目录（不在 defaults.env，因为它由官方安装脚本固定，全项目同此约定）
# 与它的临时钉桩：挂 /www/server 的 overlay 之前先 bind 到这里，
# 挂完再 bind 回面板目录，面板代码因此始终来自镜像层、不落持久化层
PANEL_DIR="${PANEL_DIR:-/www/server/panel}"
PANEL_ORIGIN="${PANEL_ORIGIN:-/run/baota/panel}"

# 业务数据与面板状态：逐个 bind 到 data 下（清单见 defaults.env）
# 面板代码（/www/server/panel）刻意不持久化 —— 它直接来自镜像层

# Docker 在 entrypoint 之前把它们 bind mount 到 /etc 下，
# 稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回
DOCKER_META=/run/docker-meta
DOCKER_FILES="hosts resolv.conf hostname"

# 可写性探测文件名（同时用于 lower 与 upper 两侧）
PROBE=.persist-writable-probe

# overlay 要求 workdir 与 upperdir 同盘（内核硬性要求）：work 放在持久化层内的
# .baota/<目录>.work。内核会在它里面再建一层 work（省不掉），详情见
# docs/persistence.md「挂载原理」
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

# 挂载点是否属于「失败即静默丢数据」的关键目录。
# 传入容器内路径（/etc、/www/wwwroot…），与 CRITICAL_DIRS 列表中的写法一致
is_critical() {
    case " ${CRITICAL_DIRS} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
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
        # 并发锁是「同一份 data 不被两个容器同时写」的最后防线，这里 fail-open
        # 等于放行并发损坏。debian:12 自带 util-linux，缺它说明镜像被改动过，
        # 拒绝启动比静默丢数据好
        echo "❌ [init][ERROR] 未找到 /usr/bin/flock，无法保证${_name}持久化层互斥，拒绝启动" >&2
        exit 1
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
        warn '  常见原因：12.0.0 与 13.0.0 两个 compose 用了同一个 data 目录。'
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
#  1. overlay 分层持久化（仅系统层）
#
#    /etc /usr /var … ←overlay→  upper = data/system/<同名>
#    lowerdir = 镜像内的同名目录（随镜像升级而更新）
#
#  ★ 面板（/www）不再走 overlay：代码由镜像层直接提供、不持久化，
#    只有业务与状态子目录走 bind（见 mount_www_layer）。
#  ★ index=off 是必须的，不是优化（同 upper 换 lower 的升级语义需要它）
# ==============================================================================
mount_persist() {
    _dir="$1"
    _lower="/${_dir}"
    _upper="${PERSIST_SYSTEM_ROOT}/${_dir}"
    _work="${SYS_WORK_ROOT}/${_dir}.work"

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
#  2. 业务数据与面板状态（逐子目录 bind）
#
#  面板代码不进持久化层，所以绝不能 bind 整个 /www —— 那会把镜像里的面板
#  代码一起遮住，换镜像就再也更新不了面板。改为只 bind 需要的子目录：
#    /www/wwwroot              <- data/www/wwwroot          （站点）
#    /www/backup               <- data/www/backup           （备份）
#    /www/server/data          <- data/www/server/data      （MySQL）
#    /www/server/panel/data    <- data/panel/data     （面板配置 / SQLite）
#    /www/server/panel/plugin  <- data/panel/plugin   （插件）
#    /www/server/panel/vhost   <- data/panel/vhost    （站点配置 / 证书 / 伪静态）
#    /www/server/panel/ssl     <- data/panel/ssl      （面板自身 HTTPS 证书）
#    /www/server/panel/config  <- data/panel/config   （面板设置）
#  其余部分（/www/server/panel 的代码、pyenv、启动器）保持镜像层原样：
#  不持久化、换镜像即整体更新 —— 这就是「不可变面板」。
#
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
        log "持久化挂载 ${_target} <- ${_source}"
        return 0
    fi
    warn "绑定失败：${_target}（本次启动不会保存该目录）"
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
            log "面板状态首次初始化：${_sub} <- 镜像"
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
    if [ -d "${_source}" ] && ! [ -x "${_source}" ]; then
        chmod 700 "${_source}" 2> /dev/null \
            || warn "无法修正 ${_source} 目录权限（缺少 x 位），面板可能无法写入"
    fi

    bind_subdir "${_source}" "${_target}"
}

# 业务与面板状态的统一入口。失败记 degraded，关键目录额外记 critical
mount_www_layer() {
    _sub=''
    for _sub in ${WWW_DATA_SUBDIRS}; do
        [ -n "${_sub}" ] || continue
        if ! bind_subdir "${PERSIST_DATA_ROOT}/www/${_sub}" "/www/${_sub}"; then
            mark_degraded "/www/${_sub}: 业务目录绑定失败"
            if is_critical "/www/${_sub}"; then
                mark_critical "/www/${_sub}: 业务目录未持久化"
            fi
        fi
    done

    for _sub in ${PANEL_STATE_SUBDIRS}; do
        [ -n "${_sub}" ] || continue
        if ! seed_panel_state "${_sub}"; then
            mark_degraded "/www/server/panel/${_sub}: 面板状态绑定失败"
            if is_critical "/www/server/panel/${_sub}"; then
                mark_critical "/www/server/panel/${_sub}: 面板状态未持久化"
            fi
        fi
    done
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

    # ---- 2. 系统层 overlay 持久化 ----
    #     /www/server 也在这一层（组件、计划任务脚本、插件数据都在它下面），
    #     但面板代码必须先钉在 /run 上、挂完 overlay 再 bind 回去 —— 见下面
    _failed=0

    # 面板代码来自镜像层、不落持久化层：先把镜像里的面板目录 bind 到 /run，
    # 等 /www/server 的 overlay 挂上后再 bind 回去（顺序反了装的就是镜像里那份
    # 被 overlay 合并后的视图，面板内更新会写进持久化层，换镜像就升不了面板）
    if [ -d "${PANEL_DIR}" ] && mkdir -p "${PANEL_ORIGIN}" 2> /dev/null; then
        if mount -o bind "${PANEL_DIR}" "${PANEL_ORIGIN}" 2> /dev/null; then
            log "面板代码已钉在 ${PANEL_ORIGIN}（挂 overlay 后 bind 回 ${PANEL_DIR}）"
        else
            warn "无法把 ${PANEL_DIR} bind 到 ${PANEL_ORIGIN}，本次面板代码会落进持久化层"
            PANEL_ORIGIN=''
        fi
    else
        PANEL_ORIGIN=''
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
    if [ -n "${PANEL_ORIGIN}" ]; then
        if mount -o bind "${PANEL_ORIGIN}" "${PANEL_DIR}" 2> /dev/null; then
            log "面板代码已 bind 回镜像层：${PANEL_DIR}（不落持久化层）"
        else
            warn "面板代码 bind 回 ${PANEL_DIR} 失败：面板代码可能落进持久化层"
            mark_critical "${PANEL_DIR}: 面板代码未隔离出持久化层"
        fi
    fi

    # ---- 3. 业务数据与面板状态（逐子目录 bind）----
    mount_www_layer

    if [ "${_failed}" -ne 0 ]; then
        warn '存在未持久化的目录，容器仍会启动，但销毁后这些目录的数据会丢失'
    fi

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
