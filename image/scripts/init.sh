#!/busybox sh
# shellcheck shell=sh  # 本文件必须保持 POSIX（busybox 解释），shebang 不被 shellcheck 识别，需显式声明方言
# ==============================================================================
#  [阶段 0] 早期初始化 —— 并发锁 → 系统层 overlay → 业务/面板子目录 bind → 移交阶段 1
#
#  红线一：解释器用 busybox 而非 bash —— 本脚本要给 /usr 挂 overlay，万一持久化
#    层里的 /usr 被写坏，usrmerge（/bin -> usr/bin）会让 /bin/bash 一起消失。
# 红线二：只能用 POSIX 语法 —— 不能用 local / [[ ]] / 数组 / pipefail；
#    函数内临时变量统一 `_` 前缀，避免覆盖调用方的循环变量。
#
#  可用环境变量（真源见 /baota/defaults.env）：PERSIST_* / WWW_* / PANEL_STATE_*
#    / CRITICAL_DIRS / STAGE1
#
#  日志：[init] 普通信息，[init][WARN] 告警
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
STAGE1="${STAGE1:-/baota/entrypoint.sh}"

# 面板目录（不在 defaults.env，因为它由官方安装脚本固定，全项目同此约定）
# 与它的临时钉桩：挂 /www/server 的 overlay 之前先 bind 到这里，
# 挂完再 bind 回面板目录，面板代码因此始终来自镜像层、不落持久化层
PANEL_DIR="${PANEL_DIR:-/www/server/panel}"
PANEL_PIN_DIR="${PANEL_PIN_DIR:-/run/baota/panel}"

# 业务数据与面板状态：逐个 bind 到 data 下（清单见 defaults.env）
# 面板代码（/www/server/panel）刻意不持久化 —— 它直接来自镜像层

# Docker 在 entrypoint 之前把它们 bind mount 到 /etc 下，
# 稍后 overlay 盖到 /etc 上会遮住这些子挂载，所以先取出内容、稍后写回
STAGING_DIR=/run/staging
DOCKER_FILES="hosts resolv.conf hostname"

# 可写性探测文件名（同时用于 lower 与 upper 两侧）
PROBE=.probe

# 状态目录（各层自己的 .baota）：项目元数据 + overlay workdir 都在里面。
# overlay 要求 workdir 与 upperdir 同盘（内核硬性要求）：work 放在状态目录内的
# <目录>.work。内核会在它里面再建一层 work（省不掉），详情见
# docs/persistence.md「挂载原理」
STATE_DIR="${PERSIST_SYSTEM_ROOT}/.baota"
LOCK_FILE="${STATE_DIR}/lock"
DATA_STATE_DIR="${PERSIST_DATA_ROOT}/.baota"
DATA_LOCK_FILE="${DATA_STATE_DIR}/lock"

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
    _sys='' _www='' _panel=''
    _seeded_list=''
    if [ -f "${RUNTIME_DIR}/.seeded" ]; then
        _seeded_list=$(cat "${RUNTIME_DIR}/.seeded" 2> /dev/null | tr '\n' ' ')
    fi
    # _dev _mp _fstype _opts …：overlay 看 upperdir，bind 看源路径
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
    _emit_group "└─ 面板状态  ${PERSIST_DATA_ROOT}/www/server/panel" "${_panel}" "    " "${_seeded_list}"
    if [ -e "${PANEL_ISOLATED}" ]; then
        echo "📦 面板代码：来自镜像层 ${PANEL_DIR}（不落持久化层）"
    else
        warn "面板代码未能隔离出持久化层，面板内「更新」可能污染持久化"
    fi
}

# ==============================================================================
#  0. 并发互斥锁（flock）
#  ★ 持锁必须是「独立后台进程」，不能用 exec 8<>lock + flock -n 8 的 fd 方式：
#    fd 随 exec 链（busybox → bash entrypoint → systemd）移交给 PID 1，systemd
#    启动时关闭非标准 fd → 锁随之释放。实测（flock 2.38）主容器就绪后第二实例
#    能再次取锁、并发保护在启动数秒后即失效。独立进程持锁与 exec 链无关：
#    进程活 → 锁在；容器停 → 进程亡 → 锁自动释放（docker top 里是个 sleep 进程）。
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
#    /etc /usr /var … ←overlay→  upper = data/.system/<同名>
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
    _work="${STATE_DIR}/${_dir}.work"

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

    # 可选模块失败不算关键（模块没装时本来就没有数据），只记 degraded
    for _sub in ${WWW_OPTIONAL_SUBDIRS:-}; do
        [ -n "${_sub}" ] || continue
        bind_optional_subdir "${_sub}" \
            || mark_degraded "/www/${_sub}: 可选模块目录绑定失败"
    done
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    acquire_lock || exit 1

    # 运行态标记目录（tmpfs）：准备 seeded 记录文件，供挂载汇总树标注「首次初始化」
    mkdir -p "${RUNTIME_DIR}" 2> /dev/null || true
    : > "${RUNTIME_DIR}/.seeded" 2> /dev/null || true

    # ---- 1. 暂存 Docker 动态注入的文件（/etc 即将被 overlay 盖住）----
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"
    for _f in ${DOCKER_FILES}; do
        if [ -e "/etc/${_f}" ]; then
            cp -f "/etc/${_f}" "${STAGING_DIR}/${_f}"
        fi
    done

    # ---- 2. 系统层 overlay 持久化 ----
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

    # ---- 3. 业务数据与面板状态（逐子目录 bind）----
    mount_www_layer

    # ---- 3.5 挂载汇总成目录树（替代逐条日志）----
    print_mount_tree

    if [ "${_failed}" -ne 0 ]; then
        warn '存在未持久化的目录，容器仍会启动，但销毁后这些目录的数据会丢失'
    fi

    # ---- 4. 还原 Docker 动态文件 ----
    for _f in ${DOCKER_FILES}; do
        if [ -f "${STAGING_DIR}/${_f}" ]; then
            cp -f "${STAGING_DIR}/${_f}" "/etc/${_f}" \
                || warn "无法写回 /etc/${_f}，容器 DNS / 主机名解析可能异常"
            chmod 0644 "/etc/${_f}" 2> /dev/null || true
        fi
    done
    rm -rf "${STAGING_DIR}"

    # ---- 5. 交给阶段 1 ----
    if [ -f "${STAGE1}" ] && [ -x /bin/bash ]; then
        exec /bin/bash "${STAGE1}" "$@"
    fi
    warn "未找到 /bin/bash 或 ${STAGE1}，跳过阶段 1，直接执行：$*"
    exec "$@"
}

main "$@"
