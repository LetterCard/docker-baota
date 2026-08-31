#!/bin/bash
# ==============================================================================
#  🚀 阶段 1 —— 收尾初始化，然后交给 systemd
#
#  进入本脚本时 overlay 已挂载完成，此后对 /etc、/usr、/var、/www 等目录的
#  写入都会落入 /data/<同名目录>，容器销毁、重建、升级都不丢。
#
#  可用环境变量（详见 README「首次登录凭据」）：
#    PANEL_PORT / PANEL_USER / PANEL_PASSWORD / PANEL_SAFE_PATH / ROOT_PASSWORD
#    除 TZ 每次生效外，其余都只在首次启动（data/ 为空）时生效，
#    避免每次启动都覆盖用户在面板里改过的设置。
# ==============================================================================
set -euo pipefail

PANEL_DIR=/www/server/panel
PANEL_PY=${PANEL_DIR}/pyenv/bin/python

# 首次启动标记。它在 /www 持久化层里，所以「首次」= 这份 /data 第一次被使用。
FIRST_BOOT_MARKER="${PANEL_DIR}/data/.docker-initialized"

# 首次启动生成的凭据，仅用于最后打印一次
NEW_PANEL_USER=""
NEW_PANEL_PASSWORD=""
NEW_ROOT_PASSWORD=""

# ---------------------------------------------------------------------------
# 日志约定：[entrypoint] 带时间戳；die() 用于致命错误
# ---------------------------------------------------------------------------
log()  { echo "🚀 [entrypoint] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [entrypoint][WARN] $(date '+%H:%M:%S') - $*" >&2; }
die()  { echo "❌ [entrypoint][ERROR] $(date '+%H:%M:%S') - $*" >&2; exit 1; }

# 生成 2N 位十六进制随机串。
# 不用 `tr -dc ... | head -c N`：head 提前关闭管道会触发 SIGPIPE，
# 在 pipefail 下会把整个脚本带崩。
random_hex() { od -An -tx1 -N "$1" /dev/urandom | tr -d ' \n'; }

# ---------------------------------------------------------------------------
# 🔍 面板文件自检
#    持久化层被写坏时（例如误删 /www/server/panel），这里给出明确指引，
#    而不是让 systemd 反复拉不起面板、用户在日志里毫无头绪。
# ---------------------------------------------------------------------------
check_panel_files() {
    [ -f "${PANEL_DIR}/BT-Panel" ] \
        || die "找不到 ${PANEL_DIR}/BT-Panel，持久化层可能已损坏；清空 ${PERSIST_ROOT:-/data}/www 后重启可回退到镜像自带的面板"
    [ -x "$PANEL_PY" ] \
        || die "找不到面板 Python 运行环境 ${PANEL_PY}"
}

# ---------------------------------------------------------------------------
# 🛡️ 持久化覆盖自检（针对上游变更）
#
#  数据安全的前提是「宝塔只往 PERSIST_DIRS 里写」（已实测确认）。
#  上游一旦把数据挪走，数据会静默丢失，所以每次启动做两项只读检查：
#  只告警、不阻断 —— 把面板停掉反而让用户无从下手。
# ---------------------------------------------------------------------------
# 兜底列表必须与 Dockerfile 的 ENV、init-mounts.sh 的默认值一致
is_persisted() {
    local top="$1"
    case " ${PERSIST_DIRS:-etc usr var www root opt home srv} " in
        *" ${top} "*) return 0 ;;
        *)            return 1 ;;
    esac
}

# 1) 宝塔自己记录的安装路径，必须落在持久化目录内
check_setup_path_covered() {
    local conf=/var/bt_setupPath.conf
    [ -s "$conf" ] || return 0

    local setup_path top
    setup_path=$(tr -d '[:space:]' < "$conf")
    [ -n "$setup_path" ] || return 0
    top="${setup_path#/}"
    top="${top%%/*}"

    is_persisted "$top" && return 0

    warn "宝塔安装路径为 ${setup_path}，其顶层目录 /${top} 不在持久化范围内"
    warn "  该目录下的数据会在容器销毁时丢失"
    warn "  修复：把 ${top} 加进 PERSIST_DIRS，例如在 compose 的 environment 里写"
    warn "    PERSIST_DIRS: \"etc usr var www root opt home srv ${top}\""
    warn "  然后重建容器（已有数据需要手动从容器里拷出来再放回新位置）"
}

# 2) 顶层目录巡检：镜像里没有的新目录，可能意味着上游换了数据落点
#    构建期在 /opt/baota/baseline-dirs.txt 存了一份快照。这个文件从不在
#    运行期写入，所以按 overlay 语义它始终跟随当前镜像 —— 换镜像即换基线。
check_new_top_dirs() {
    local baseline_file=/opt/baota/baseline-dirs.txt
    [ -f "$baseline_file" ] || return 0

    # 一次读入后做整体匹配，避免每个目录都起一次 grep
    local baseline d
    baseline=" $(tr '\n' ' ' < "$baseline_file") "

    for d in /*; do
        [ -d "$d" ] || continue
        case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
        case "$baseline" in *" ${d#/} "*) continue ;; esac
        # 挂载点是用户自己挂进来的（如 NAS 共享目录），属于预期行为，跳过
        awk -v p="$d" '$2==p{c++} END{exit(c?0:1)}' /proc/mounts && continue

        warn "检测到镜像里没有的顶层目录：${d}"
        warn "  若上游把数据放到了这里，请把它加入 PERSIST_DIRS，否则容器销毁后内容会丢失"
    done
}

audit_persist_coverage() {
    check_setup_path_covered
    check_new_top_dirs
}

# ---------------------------------------------------------------------------
# 🧹 清理 systemd 运行时目录
#    /run 不在持久化范围内，但镜像层可能残留构建期写入的状态
# ---------------------------------------------------------------------------
prepare_runtime_dirs() {
    rm -rf /run/* /run/lock/* 2>/dev/null || true
    mkdir -p /run/lock /run/sshd /run/dbus
    rm -f /var/lib/systemd/random-seed 2>/dev/null || true

    # /var 已被持久化，这两个必须回到 tmpfs 化的 /run，
    # 否则 systemd 会读到上一次运行的 pid / socket 残留而起不来
    if [ ! -L /var/run ]; then
        rm -rf /var/run
        ln -s /run /var/run
    fi
    if [ ! -L /var/lock ]; then
        rm -rf /var/lock
        ln -s /run/lock /var/lock
    fi
    rm -rf /var/tmp/* 2>/dev/null || true

    # journald：/var/log/journal 在持久化层里，日志可跨重启保留
    mkdir -p /var/log/journal
}

# ---------------------------------------------------------------------------
# 🔄 每次启动刷新的一致性修正
# ---------------------------------------------------------------------------
refresh_consistency() {
    ln -sfn /proc/self/mounts /etc/mtab

    # machine-id：为空才生成；已有则保留，以保证 journald 日志的连续性
    if [ ! -s /etc/machine-id ]; then
        systemd-machine-id-setup >/dev/null 2>&1 \
            || tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
    fi

    if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        ln -sfn "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
    fi
}

# ---------------------------------------------------------------------------
# 🩹 复位面板补丁
#    补丁改的是 /www 里的文件，而 /www 在持久化层里 ——
#    用户还原备份、覆盖文件都可能把补丁冲掉，所以每次启动重放一遍（幂等）。
# ---------------------------------------------------------------------------
reset_panel_patches() {
    [ -x /opt/baota/patch-panel.sh ] || return 0

    if [ "${DISABLE_PANEL_UPDATE:-true}" = "true" ]; then
        /opt/baota/patch-panel.sh disable-update \
            || warn "复位「禁用面板更新」失败，请检查 ${PANEL_DIR}/script 权限"
    fi
}

# ---------------------------------------------------------------------------
# 🔑 首次启动初始化：端口、安全入口、账号
#
#  镜像是公开的，里面的口令和安全入口人人可见，所以必须在部署侧重新生成。
#  只在首次执行，之后用户在面板里改过的设置属于持久化数据，绝不覆盖。
# ---------------------------------------------------------------------------
init_first_boot() {
    [ -e "$FIRST_BOOT_MARKER" ] && return 0

    local user="${PANEL_USER:-baota}"
    local password="${PANEL_PASSWORD:-$(random_hex 6)}"
    local safe_path="${PANEL_SAFE_PATH:-$(random_hex 4)}"
    local root_password="${ROOT_PASSWORD:-$(random_hex 6)}"
    local port="${PANEL_PORT:-8888}"

    log "首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令"

    echo "${port}" > "${PANEL_DIR}/data/port.pl"
    # 宝塔约定 admin_path.pl 以 / 开头，登录地址即 http://IP:端口<该值>/login
    echo "/${safe_path#/}" > "${PANEL_DIR}/data/admin_path.pl"

    ( cd "$PANEL_DIR" && "$PANEL_PY" tools.py panel "$password" ) >/dev/null \
        || die "面板口令初始化失败，请检查 ${PANEL_DIR}/data/db/panel.db 是否可写"
    ( cd "$PANEL_DIR" && "$PANEL_PY" -c "import tools;tools.set_panel_username('${user}')" ) >/dev/null \
        || die "面板用户名初始化失败"

    # 与真机安装一致：初始口令落在 default.pl，供 bt default 命令读取
    printf '%s\n' "$password" > "${PANEL_DIR}/default.pl"
    chmod 600 "${PANEL_DIR}/default.pl"

    # 镜像里的 root 是锁定状态，这里才给它一个口令（/etc/shadow 在持久化层，会保留）
    echo "root:${root_password}" | chpasswd || die "root 口令初始化失败"

    date '+%Y-%m-%d %H:%M:%S' > "$FIRST_BOOT_MARKER"

    NEW_PANEL_USER="$user"
    NEW_PANEL_PASSWORD="$password"
    NEW_ROOT_PASSWORD="$root_password"
}

# ---------------------------------------------------------------------------
# 📋 启动信息
# ---------------------------------------------------------------------------
print_summary() {
    local port safe
    port=$(cat "${PANEL_DIR}/data/port.pl" 2>/dev/null || echo "${PANEL_PORT:-8888}")
    safe=$(cat "${PANEL_DIR}/data/admin_path.pl" 2>/dev/null || echo "")

    echo "=================================================================="
    log "面板地址：http://<宿主机IP>:${port}${safe}/login"
    if [ -n "$NEW_PANEL_PASSWORD" ]; then
        log "面板用户：${NEW_PANEL_USER}"
        log "面板口令：${NEW_PANEL_PASSWORD}"
        log "root 口令：${NEW_ROOT_PASSWORD}（容器内 SSH 用）"
        log "以上凭据只在首次启动时打印，请登录后立即修改"
    else
        log "查看面板账号：docker exec <容器名> bt default"
        log "重置面板口令：docker exec -it <容器名> bt 5"
    fi
    log "持久化根目录：${PERSIST_ROOT:-/data}（可写层与容器内路径同名，站点目录在 /data/www/wwwroot）"
    echo "=================================================================="
}

# ---------------------------------------------------------------------------
# ▶️ 入口
# ---------------------------------------------------------------------------
main() {
    check_panel_files
    prepare_runtime_dirs
    refresh_consistency
    reset_panel_patches
    init_first_boot
    audit_persist_coverage
    print_summary

    log "移交 systemd：$*"
    exec "$@"
}

main "$@"
