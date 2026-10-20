#!/bin/bash
# ==============================================================================
#  [阶段 1] 收尾初始化，然后交给 systemd
#
#  进入本脚本时挂载已就绪：系统层走 overlay（upper 在 data/.system/<dir>），
#  业务与面板状态走 bind（源在 data/www/<同名>），面板代码来自镜像、不持久化。
#
#  可用环境变量（详见 docs/quickstart.md「首次登录凭据」）：
#    PANEL_PORT / PANEL_USER / PANEL_PASSWORD / PANEL_SAFE_PATH / ROOT_PASSWORD
#    除 TZ 外都只在首次启动（data/ 为空）时生效 —— 避免每次启动覆盖用户的设置。
#
#  日志：[entrypoint] / [entrypoint][WARN] / [entrypoint][ERROR]（die 中断启动）
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（与 init.sh 共用同一份）。
# ★ 只在这里取配置：脚本里不再写默认值副本（副本会漂移，改真源的人不会想到
#   还要改另外几个文件）。真源缺失说明镜像不完整，直接拒绝启动
# ------------------------------------------------------------------------------
if [ ! -f /baota/defaults.env ]; then
    echo '❌ [entrypoint][ERROR] 缺少运行期配置真源 /baota/defaults.env，镜像不完整，拒绝启动' >&2
    exit 1
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. /baota/defaults.env

PANEL_DIR=/www/server/panel
PANEL_PY_BIN=${PANEL_DIR}/pyenv/bin/python
# 镜像里的面板代码副本（构建期生成，排除 pyenv）：代码指纹与守卫都从它取，
# 保证「指纹」与「守卫换回去的那份」是同一份代码
PANEL_ORIGIN_DIR=/baota/origin

# 首次启动标记。它在 /www 持久化层里，所以「首次」= 这份 /data 第一次被使用
FIRST_BOOT_MARKER="${PANEL_DIR}/data/.initialized"

# 运行期状态目录（在系统层持久化目录内，跨容器保留）。
# 存放：镜像版本记录、启动历史等
STATE_DIR="${PERSIST_SYSTEM_ROOT}/.baota"
BOOT_LOG_FILE="${STATE_DIR}/${META_BOOT_FILE}"
BOOT_LOG_MAX_LINES=200

# 镜像自有的版本信息（/baota 不在任何持久化目录内，永远跟随当前镜像）
IMAGE_VERSION_FILE=/baota/VERSION

# 启动期降级标记（由 init.sh 写入 /run，tmpfs，重启即失效）
RUNTIME_DIR=/run/baota
DEGRADED="${RUNTIME_DIR}/degraded"
CRITICAL="${RUNTIME_DIR}/critical"

# 首次启动生成的凭据，仅用于最后打印一次
NEW_PANEL_USER=''
NEW_PANEL_PASSWORD=''
NEW_ROOT_PASSWORD=''

log()  { echo "🚀 [entrypoint] $(date '+%H:%M:%S') - $*"; }
warn() { echo "⚠️ [entrypoint][WARN] $(date '+%H:%M:%S') - $*" >&2; }
die()  { echo "❌ [entrypoint][ERROR] $(date '+%H:%M:%S') - $*" >&2; exit 1; }

# 生成 2N 位十六进制随机串。
# 不用 `tr -dc ... | head -c N`：head 提前关闭管道会触发 SIGPIPE，
# 在 pipefail 下会把整个脚本带崩
random_hex() { od -An -tx1 -N "$1" /dev/urandom | tr -d ' \n'; }

# 语义化版本比较：$1 < $2 时返回 0
version_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# ==============================================================================
#  面板文件自检
#
#  面板代码不持久化、直接来自镜像层，所以这里只可能是镜像本身不完整
#  （或用户把 pyenv 持久化后误删）。给出明确指引，避免 systemd 反复拉不起
#  面板、用户在日志里毫无头绪
# ==============================================================================
check_panel_files() {
    # 用 glob 而非面板名字面量：bt7.init 用 ps|grep 匹配进程命令行里的面板名判断
    # 「是否已在运行」，本脚本若让该字面量进入命令行会被误判。这里是 test -f 不产生
    # 进程，但全仓统一用 BT-P*，make lint 的越界检查才能直接生效
    ls ${PANEL_DIR}/BT-P* > /dev/null 2>&1 \
        || die "找不到面板主程序 ${PANEL_DIR}/BT-P*，镜像可能不完整；面板代码来自镜像层（不持久化），请重新拉取镜像"
    [ -x "${PANEL_PY_BIN}" ] \
        || die "找不到面板 Python 运行环境 ${PANEL_PY_BIN}；若已把 pyenv 加入 PANEL_STATE_SUBDIRS，请检查 ${PANEL_STATE_ROOT}/pyenv"
}

# ==============================================================================
#  清理 systemd 运行时目录
#  /run 不在持久化范围内，但镜像层可能残留构建期写入的状态
# ==============================================================================
prepare_runtime_dirs() {
    # 清理镜像层残留的构建期运行时文件。但 /run/baota 必须保留：
    # 里面的降级标记（degraded / critical）由 init.sh 在本脚本
    # 运行之前刚写入（/run 是 tmpfs，每次启动全新，不存在跨启动的残留），
    # 是 healthcheck / boot.log / CI 判断「本次持久化是否完整」的唯一依据。
    # 若连它一起清掉，最危险的「只读降级」就再也无法被观测到 ——
    # healthcheck 恒 healthy、启动历史永不记录、CI 也测不出来。
    for _r in /run/*; do
        [ "${_r}" = "${RUNTIME_DIR}" ] || rm -rf "${_r}" 2> /dev/null || true
    done
    rm -rf /run/lock/* 2> /dev/null || true
    mkdir -p /run/lock /run/sshd /run/dbus "${RUNTIME_DIR}"
    rm -f /var/lib/systemd/random-seed 2> /dev/null || true

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
    rm -rf /var/tmp/* 2> /dev/null || true

    # journald：/var/log/journal 在持久化层里，日志可跨重启保留
    mkdir -p /var/log/journal
}

# ==============================================================================
#  每次启动刷新的一致性修正
#
#  原则：持久化层的每一次写入都不可逆，能不写就不写。
#  只在「结果确实需要变化」时才动手
# ==============================================================================
refresh_consistency() {
    # /etc/mtab 指向正确时跳过，避免每次启动都产生一次无意义的 upper 写入
    if [ ! -L /etc/mtab ] || [ "$(readlink /etc/mtab 2> /dev/null)" != '/proc/self/mounts' ]; then
        ln -sfn /proc/self/mounts /etc/mtab
    fi

    # machine-id：为空才生成；已有则保留，以保证 journald 日志的连续性
    if [ ! -s /etc/machine-id ]; then
        systemd-machine-id-setup > /dev/null 2>&1 \
            || tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
    fi

    if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        if [ "$(readlink /etc/localtime 2> /dev/null)" != "/usr/share/zoneinfo/${TZ}" ]; then
            ln -sfn "/usr/share/zoneinfo/${TZ}" /etc/localtime
            echo "${TZ}" > /etc/timezone
        fi
    fi
}

# ==============================================================================
#  版本护栏 + 升级前自动快照
#  比对镜像内 /baota/VERSION 与持久化层记录（版本 + 面板代码指纹）：首次仅记录；
#  两者都一致则零写入；任一个变化（升高 / 降低 / 同版本号镜像被重新构建）都先
#  快照再启动 —— 降级只告警不阻断（出故障要先能起来）。
#  快照在此刻做是有意的：systemd 尚未拉起面板与数据库，数据静止、天然一致。
#  ★ 只快照 /www/server/panel/data：站点 / MySQL / 备份都是 bind 目录，换镜像
#    动不到；唯一「对不上」的是新版代码 + 旧版 SQLite。推导见 docs/persistence.md
# ==============================================================================
prune_snapshots() {
    local dir="$1" keep="$2" n
    # 两处 ls 都要 || true：包被手工删空时 ls 会返回非零，
    # 配合 pipefail 会把整个 entrypoint 带崩，不该为「清理过期快照」冒这个险。
    # -d 让目录快照只列自己、不展开内容；匹配 baota-* 而非 baota-*.tgz，
    # 这样残留下来的 .tgz 也会被同一份保留策略一起清理掉
    n=$(ls -1td "${dir}"/baota-* 2> /dev/null | wc -l || true)
    [ "${n}" -le "${keep}" ] && return 0

    ls -1td "${dir}"/baota-* 2> /dev/null | tail -n "$((n - keep))" | while read -r f; do
        # btrfs 只读子卷删不掉（rm -rf 报 Read-only file system），必须用
        # subvolume delete；判据是 inode 256（子卷根的固定 inode）
        if [ "$(stat -c %i "${f}" 2> /dev/null || echo 0)" = '256' ] \
           && command -v btrfs > /dev/null 2>&1 \
           && btrfs subvolume delete "${f}" > /dev/null 2>&1; then
            log "已清理过期快照（btrfs 子卷）：$(basename "${f}")"
        else
            rm -rf "${f}"
            log "已清理过期快照：$(basename "${f}")"
        fi
    done || true
}

# 快照后端判定：AUTO_SNAPSHOT_MODE=auto 时，宿主持 btrfs 且面板数据目录是子卷
# （inode 256）才用只读子卷快照 —— O(1)，与目录大小无关；其余情况 cp -a。
# 子卷是一次性宿主机动作（btrfs subvolume create），见 docs/persistence.md
snapshot_backend() {
    case "${AUTO_SNAPSHOT_MODE}" in
        copy) echo copy; return 0 ;;
    esac
    command -v btrfs > /dev/null 2>&1 || { echo copy; return 0; }
    [ "$(stat -f -c %T /www/server/panel/data 2> /dev/null || true)" = 'btrfs' ] \
        || { echo copy; return 0; }
    [ "$(stat -c %i /www/server/panel/data 2> /dev/null || true)" = '256' ] \
        || { echo copy; return 0; }
    echo btrfs
}

take_snapshot() {
    local prev="$1" keep="${AUTO_SNAPSHOT_KEEP}"
    local dir=/www/backup/auto stamp out backend

    case "${keep}" in
        ''|*[!0-9]*)
            # 护栏开关填错（如「3份」）不能静默当成 0 禁用快照 —— 那是这类
            # 开关最危险的失效方式；与 healthcheck 的 DISK_* 阈值一样退回默认
            warn "AUTO_SNAPSHOT_KEEP=${keep} 不是正整数，按默认 3 继续"
            keep=3
            ;;
        0)
            log 'AUTO_SNAPSHOT_KEEP=0，显式禁用快照'
            return 0
            ;;
    esac

    # 只快照 /www/server/panel/data —— 升级时唯一会「对不上」的地方
    if [ ! -d /www/server/panel/data ]; then
        log '面板数据目录不存在（面板尚未初始化），跳过快照'
        return 0
    fi

    mkdir -p "${dir}" 2> /dev/null || { warn "快照目录不可写：${dir}"; return 1; }

    backend=$(snapshot_backend)
    stamp=$(date '+%Y%m%d-%H%M%S')
    out="${dir}/baota-${prev:-fresh}-${stamp}"
    # 同一秒内重复执行时目标可能已存在，cp -a 会把它复制成 out/data 子目录。
    # 先清掉，保证 out 始终是「panel/data 的一份完整副本」
    rm -rf "${out}" 2> /dev/null || true

    if [ "${backend}" = 'btrfs' ]; then
        if btrfs subvolume snapshot -r /www/server/panel/data "${out}" > /dev/null 2>&1; then
            log "升级前快照已保存（btrfs 只读子卷，秒级）：${out}"
            prune_snapshots "${dir}" "${keep}"
            return 0
        fi
        warn "btrfs 子卷快照失败，回退 cp -a：${out}"
        rm -rf "${out}" 2> /dev/null || true
    fi

    # 用 cp -a 而不是 tar czf：
    #   1) 快得多 —— 面板数据里主要是 SQLite 与二进制，gzip 压缩收益很低，
    #      却要为「每次换镜像」都付一次完整压缩的 CPU 时间
    #   2) cp -a 等价于 --preserve=all，天然保留扩展属性
    #      （含 overlay 的 trusted.overlay.opaque 标记），与 tar --xattrs 效果相同，
    #      而且不必维护 --xattrs-include 白名单
    #   3) 恢复就是反向 cp -a，比解 tar 更直观
    if cp -a /www/server/panel/data "${out}" 2> /dev/null; then
        log "升级前快照已保存：${out}（$(du -sh "${out}" 2> /dev/null | cut -f1)）"
        prune_snapshots "${dir}" "${keep}"
        return 0
    fi

    # 失败的半成品必须清掉：既占空间，又会让用户误以为手里有回滚点
    rm -rf "${out}" 2> /dev/null || true
    warn "快照失败：${out}（不影响启动，但本次升级没有自动回滚点）"
    return 1
}

# 面板代码指纹：/baota/origin 内容的 sha256（只含内容，不含 mtime —— 同代码
# 重新构建的镜像指纹必须一致）。与 version 一起回答「代码是不是真的变了」
compute_code_digest() {
    local out=''
    [ -d "${PANEL_ORIGIN_DIR}" ] || return 1
    out=$( cd "${PANEL_ORIGIN_DIR}" 2> /dev/null \
           && find . -type f -exec sha256sum {} + 2> /dev/null | LC_ALL=C sort | sha256sum \
           | cut -d' ' -f1 ) || true
    [ -n "${out}" ] || return 1
    printf '%s' "${out}"
}

# 版本与指纹一起回写。digest 为空（守卫副本缺失）时只写版本，不留空文件
write_version_record() {
    local state_file="$1" ver="$2" digest_file="$3" digest="$4"
    mkdir -p "${STATE_DIR}" 2> /dev/null || true
    printf '%s\n' "${ver}" > "${state_file}" 2> /dev/null \
        || warn "无法写入镜像版本记录：${state_file}"
    if [ -n "${digest}" ]; then
        printf '%s\n' "${digest}" > "${digest_file}" 2> /dev/null \
            || warn "无法写入面板代码指纹：${digest_file}"
    else
        # 算不出指纹时删掉旧记录：留着会让下次启动把它当「代码变了」而反复快照
        rm -f "${digest_file}" 2> /dev/null || true
    fi
}

version_guard() {
    local img_ver prev='' prev_digest='' img_digest=''
    local state_file="${STATE_DIR}/${META_VERSION_FILE}"
    local digest_file="${STATE_DIR}/${META_DIGEST_FILE}"

    img_ver=$(cat "${IMAGE_VERSION_FILE}" 2> /dev/null || true)
    if [ -z "${img_ver}" ]; then
        log "镜像未提供版本信息（${IMAGE_VERSION_FILE}），跳过版本护栏"
        return 0
    fi
    [ -f "${state_file}" ] && prev=$(cat "${state_file}" 2> /dev/null || true)
    [ -f "${digest_file}" ] && prev_digest=$(cat "${digest_file}" 2> /dev/null || true)

    if [ -z "${prev}" ]; then
        # 首次使用：没有可回滚的旧数据，只记录版本，不做快照
        log "首次使用这份持久化数据，记录镜像版本 ${img_ver}"
        write_version_record "${state_file}" "${img_ver}" "${digest_file}" "$(compute_code_digest || true)"
        return 0
    fi

    img_digest=$(compute_code_digest || true)

    # 取不到指纹（守卫副本缺失 / 读不到）时不让它参与比较：没有可比的东西，
    # 否则「记录里有、现在算不出」会被判成代码变化，每次启动都快照一次
    [ -n "${img_digest}" ] || prev_digest=''

    # 旧数据没有指纹：补记一份，不当成「代码变了」—— 没有可比较的基准，
    # 为一个不存在的差异生成快照只会让人困惑
    if [ -z "${prev_digest}" ] && [ -n "${img_digest}" ]; then
        log "补记面板代码指纹（旧版本数据未记录）"
        printf '%s\n' "${img_digest}" > "${digest_file}" 2> /dev/null \
            || warn "无法写入面板代码指纹：${digest_file}"
        prev_digest="${img_digest}"
    fi

    if [ "${prev}" = "${img_ver}" ] && [ "${prev_digest}" = "${img_digest}" ]; then
        # 版本与代码指纹都没变：什么都不写，避免每次启动都产生无意义的持久化层写入
        return 0
    fi

    if [ "${prev}" = "${img_ver}" ]; then
        # 版本号相同但代码变了 = 同标签镜像被重新构建（换基础镜像、改构建脚本）。
        # 只比版本号会漏过这种变化，升级前快照随之缺席
        warn '=============================================================='
        warn "⚠️ 检测到镜像代码变化（版本号相同 ${img_ver}）"
        warn "   指纹：${prev_digest:-未知} → ${img_digest:-未知}"
        warn '   同版本号镜像被重新构建：按升级处理，先创建快照再启动'
        warn '=============================================================='
    elif version_lt "${img_ver}" "${prev}"; then
        warn '=============================================================='
        warn "⚠️ 检测到镜像降级：${prev} -> ${img_ver}"
        warn '   宝塔不提供降级迁移：旧版代码读取新版数据库可能出现功能异常'
        warn '   将先创建快照再继续启动；如需彻底回退，请用备份按「恢复」流程操作'
        warn '=============================================================='
    else
        log "检测到镜像升级：${prev} -> ${img_ver}，正在创建升级前快照"
    fi

    # 快照失败就不推进版本记录：prev 与 img_ver 的差异留到下次启动、
    # 自动重试快照 —— 否则一次瞬时故障（如磁盘满）就让回滚点永久缺席
    if take_snapshot "${prev}"; then
        write_version_record "${state_file}" "${img_ver}" "${digest_file}" "${img_digest}"
    else
        warn '本次不更新版本记录，下次启动将重试升级前快照'
    fi
}


# ==============================================================================
#  首次启动初始化：端口、安全入口、账号
#
#  镜像是公开的，里面的口令和安全入口人人可见，所以必须在部署侧重新生成。
#  只在首次执行，之后用户在面板里改过的设置属于持久化数据，绝不覆盖
# ==============================================================================
init_first_boot() {
    [ -e "${FIRST_BOOT_MARKER}" ] && return 0

    local user="${PANEL_USER:-baota}"
    local password="${PANEL_PASSWORD:-$(random_hex 6)}"
    local safe_path="${PANEL_SAFE_PATH:-$(random_hex 4)}"
    local root_password="${ROOT_PASSWORD:-$(random_hex 6)}"
    local port="${PANEL_PORT:-8888}"

    log '首次启动，正在初始化面板端口、安全入口、面板账号与 root 口令'

    # 端口 / 安全入口是纯文本文件，写完即生效，不依赖面板内部 API，先写稳
    echo "${port}" > "${PANEL_DIR}/data/port.pl"
    # 宝塔约定 admin_path.pl 以 / 开头，登录地址即 http://IP:端口<该值>/login
    echo "/${safe_path#/}" > "${PANEL_DIR}/data/admin_path.pl"

    # 用户名 / 口令走 tools.py —— 这是与宝塔内部实现强耦合的一处（上游改 API 就失败）。
    # 不再 die：即便失败面板仍能起来，用户用容器内 `bt` 命令即可重置，
    # 不至于「升级即整个容器起不来」
    if ! ( cd "${PANEL_DIR}" && "${PANEL_PY_BIN}" tools.py panel "${password}" ) > /dev/null 2>&1; then
        warn "面板口令初始化失败（tools.py 接口可能已变动），请启动后用 \`bt\` 命令重置"
    fi
    if ! ( cd "${PANEL_DIR}" && "${PANEL_PY_BIN}" -c "import tools;tools.set_panel_username('${user}')" ) > /dev/null 2>&1; then
        warn "面板用户名初始化失败（tools.py 接口可能已变动），默认用户名仍为镜像内置值"
    fi

    # 与真机安装一致：初始口令落在 default.pl，供 bt default 命令读取。
    # 即便上面 tools.py 失败，这里也把生成的口令写盘，至少 bt default 能读到。
    printf '%s\n' "${password}" > "${PANEL_DIR}/default.pl"
    chmod 600 "${PANEL_DIR}/default.pl"

    # 镜像里的 root 是锁定状态，这里才给它一个口令（/etc/shadow 在持久化层，会保留）。
    # chpasswd 极稳定，失败也只告警，不阻断启动
    echo "root:${root_password}" | chpasswd \
        || warn 'root 口令初始化失败（chpasswd 异常），请手动设置'

    date '+%Y-%m-%d %H:%M:%S' > "${FIRST_BOOT_MARKER}"

    NEW_PANEL_USER="${user}"
    NEW_PANEL_PASSWORD="${password}"
    NEW_ROOT_PASSWORD="${root_password}"
}

# ==============================================================================
#  启动报告归档
#
#  降级标记写在 /run（tmpfs），容器一重启就没了。这里把「本次启动是否降级」
#  追加到持久化层的 boot.log，事后排查时能回答「从哪次启动开始不对的」。
#  只在状态确实有变化时才写，常态零写入
# ==============================================================================
archive_boot_report() {
    local stamp detail

    if [ ! -f "${CRITICAL}" ] && [ ! -f "${DEGRADED}" ]; then
        return 0
    fi

    # 两个标记文件可能只存在一个，cat 对缺失文件会报错但不影响另一个。
    # 必须 || true：cat 对缺失文件返回非零，配合 pipefail 会让这行赋值
    # 以失败收场，set -e 直接把整个 entrypoint 带崩 —— 本该「记录降级」的
    # 逻辑反而变成容器起不来
    detail=$(cat "${CRITICAL}" "${DEGRADED}" 2> /dev/null | tr -s '\n' ' ' || true)
    [ -n "${detail}" ] || return 0

    stamp=$(date '+%F %T')
    detail="[${stamp}] 镜像 $(cat "${IMAGE_VERSION_FILE}" 2> /dev/null || echo unknown) 启动降级：${detail}"

    mkdir -p "${STATE_DIR}" 2> /dev/null \
        || { warn "无法写入启动历史：${STATE_DIR}"; return 0; }
    printf '%s\n' "${detail}" >> "${BOOT_LOG_FILE}" 2> /dev/null \
        || { warn "无法写入启动历史：${BOOT_LOG_FILE}"; return 0; }

    # 只留最近若干行，避免它自己也变成一颗静默增长的种子
    if [ -f "${BOOT_LOG_FILE}" ]; then
        tail -n "${BOOT_LOG_MAX_LINES}" "${BOOT_LOG_FILE}" > "${BOOT_LOG_FILE}.tmp" 2> /dev/null \
            && mv -f "${BOOT_LOG_FILE}.tmp" "${BOOT_LOG_FILE}" 2> /dev/null || true
    fi

    warn "本次启动存在持久化降级，已记录到 ${BOOT_LOG_FILE}"
}

# ==============================================================================
#  启动信息
# ==============================================================================
print_summary() {
    local port safe

    port=$(cat "${PANEL_DIR}/data/port.pl" 2> /dev/null || echo "${PANEL_PORT:-8888}")
    safe=$(cat "${PANEL_DIR}/data/admin_path.pl" 2> /dev/null || echo '')

    echo '=================================================================='
    log "面板地址：http://<宿主机IP>:${port}${safe}/login"
    if [ -n "${NEW_PANEL_PASSWORD}" ]; then
        log "面板用户：${NEW_PANEL_USER}"
        log "面板口令：${NEW_PANEL_PASSWORD}"
        log "root 口令：${NEW_ROOT_PASSWORD}（容器内 SSH 用）"
        log '以上凭据只在首次启动时打印，请登录后立即修改'
    else
        log '重置面板口令：docker exec -it <容器名> bt 5'
        log '（bt default 只在首次启动后有效：它读的 default.pl 属于面板代码、'
        log '  不持久化，重建容器后会退回镜像内置的占位值）'
    fi
    log "数据层：${PERSIST_DATA_ROOT}（站点目录在 ${PERSIST_DATA_ROOT}/www/wwwroot）"
    echo '=================================================================='
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    check_panel_files
    prepare_runtime_dirs
    refresh_consistency
    version_guard
    init_first_boot
    archive_boot_report
    print_summary

    log "移交 systemd：$*"
    exec "$@"
}

main "$@"
