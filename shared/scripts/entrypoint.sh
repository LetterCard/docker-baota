#!/bin/bash
# ==============================================================================
#  [阶段 1] 收尾初始化，然后交给 systemd
#
#  进入本脚本时挂载已就绪：
#    系统层（/etc /usr /var …）      overlay upper 在 data/system/<dir>
#    业务数据（wwwroot/backup/server/data）  bind 到 data/www/<子目录>
#    面板状态（panel/data、panel/plugin）    bind 到 data/panel/<子目录>
#    面板代码（/www/server/panel）   来自镜像层，只读、不持久化
#  于是面板版本随镜像升级，而用户的配置、站点与数据库在容器销毁、重建后都不丢。
#
#  可用环境变量（详见 docs/quickstart.md「首次登录凭据」）：
#    PANEL_PORT / PANEL_USER / PANEL_PASSWORD / PANEL_SAFE_PATH / ROOT_PASSWORD
#    除 TZ 每次生效外，其余都只在首次启动（data/ 为空）时生效，
#    避免每次启动都覆盖用户在面板里改过的设置。
#
#  日志约定：[entrypoint] 普通信息，[entrypoint][WARN] 告警，
#            [entrypoint][ERROR] 致命错误（die 会中断启动）
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 配置真源：/baota/defaults.env（与 init.sh 共用同一份）。
# 必须最先加载 —— 下面所有路径常量都依赖它，加载晚了会取到 Dockerfile 的
# 默认值，用户在 compose 里改的 PERSIST_DATA_ROOT / PERSIST_SYSTEM_ROOT 就失效了。
# ------------------------------------------------------------------------------
if [ -f /baota/defaults.env ]; then
    . /baota/defaults.env
fi

PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
PERSIST_SYSTEM_DIRS="${PERSIST_SYSTEM_DIRS:-etc usr var root opt home srv}"
# 与 init.sh 一致：面板状态根由数据根派生。defaults.env 缺失时兜底，
# 也让 shellcheck 能追踪到赋值（本文件只是读它，真源仍是 defaults.env）
PANEL_STATE_ROOT="${PANEL_STATE_ROOT:-${PERSIST_DATA_ROOT}/panel}"
AUTO_BACKUP_KEEP="${AUTO_BACKUP_KEEP:-3}"

PANEL_DIR=/www/server/panel
PANEL_PY=${PANEL_DIR}/pyenv/bin/python

# 首次启动标记。它在 /www 持久化层里，所以「首次」= 这份 /data 第一次被使用
FIRST_BOOT_MARKER="${PANEL_DIR}/data/.docker-initialized"

# 运行期状态目录（在系统层持久化目录内，跨容器保留）。
# 存放：镜像版本记录、启动历史等
BAOTA_STATE="${PERSIST_SYSTEM_ROOT}/.baota"
BOOT_HISTORY="${BAOTA_STATE}/boot-history.log"
BOOT_HISTORY_MAX_LINES=200

# 镜像自有的版本信息（/baota 不在任何持久化目录内，永远跟随当前镜像）
IMAGE_VERSION_FILE=/baota/VERSION

# 启动期降级标记（由 init.sh 写入 /run，tmpfs，重启即失效）
RUNTIME_DIR=/run/baota
DEGRADED="${RUNTIME_DIR}/degraded"
DEGRADED_CRITICAL="${RUNTIME_DIR}/degraded-critical"

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
    [ -x "${PANEL_PY}" ] \
        || die "找不到面板 Python 运行环境 ${PANEL_PY}；若已把 pyenv 加入 PANEL_STATE_SUBDIRS，请检查 ${PANEL_STATE_ROOT}/pyenv"
}

# ==============================================================================
#  关于「持久化覆盖自检」（已移除）
#
#  旧模型里 /www 是整体 overlay 持久化，所以需要每次启动巡检「上游是否把数据
#  放到了持久化边界之外」。新模型（不可变面板）的边界是显式声明的：
#  WWW_DATA_SUBDIRS（业务）与 PANEL_STATE_SUBDIRS（面板状态）逐个 bind，
#  没列出的部分就是「随镜像更新、不保留」—— 这是设计，不是疏漏。
#  上游若把数据放到新目录，把它加进对应列表即可，无需运行期巡检告警。
# ==============================================================================

# ==============================================================================
#  清理 systemd 运行时目录
#  /run 不在持久化范围内，但镜像层可能残留构建期写入的状态
# ==============================================================================
prepare_runtime_dirs() {
    # 清理镜像层残留的构建期运行时文件。但 /run/baota 必须保留：
    # 里面的降级标记（degraded / degraded-critical）由 init.sh 在本脚本
    # 运行之前刚写入（/run 是 tmpfs，每次启动全新，不存在跨启动的残留），
    # 是 healthcheck / boot-history / CI 判断「本次持久化是否完整」的唯一依据。
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
#
#  比较镜像内 /baota/VERSION 与持久化层里记录的版本：
#    - 首次使用  → 仅记录，不快照（没有可回滚的旧数据）
#    - 版本一致  → 零写入、零开销
#    - 版本升高  → 先快照再启动
#    - 版本降低  → 明确告警 + 同样先快照再启动
#                  （生产环境「拒绝启动」往往比降级更糟：
#                   出故障时运维最需要的是能起来，所以只告警不阻断）
#
#  快照在 entrypoint 里做是有意的：此刻 systemd 尚未拉起面板与数据库，
#  数据处于静止态，天然一致，无需额外停机。
#
#  为什么只快照 /www/server/panel/data（已实测确证）：
#    站点（/www/wwwroot）、MySQL 数据（/www/server/data）、备份（/www/backup）
#    都是 bind 到 data/ 的持久化目录，换镜像动不到它们；
#    会随镜像变的是面板代码（/www/server/panel 整体来自镜像层）。
#    于是升级后唯一「对不上」的地方是：
#    新版面板代码 + 旧版面板数据库（SQLite，升级时可能做 schema 迁移）。
#    快照它，升级失败就能回到
#    「旧代码 + 旧库」的原始组合。站点与数据库另有更好的备份手段
#    （面板内备份、baota-backup），不在这里重复造轮子
# ==============================================================================
prune_snapshots() {
    local dir="$1" keep="$2" n
    # 两处 ls 都要 || true：包被手工删空时 ls 会返回非零，
    # 配合 pipefail 会把整个 entrypoint 带崩，不该为「清理过期快照」冒这个险。
    # -d 让目录快照只列自己、不展开内容；匹配 baota-* 而非 baota-*.tgz，
    # 这样旧版留下的 .tgz 快照会被一并按同一份保留策略清理掉
    n=$(ls -1td "${dir}"/baota-* 2> /dev/null | wc -l || true)
    [ "${n}" -le "${keep}" ] && return 0

    ls -1td "${dir}"/baota-* 2> /dev/null | tail -n "$((n - keep))" | while read -r f; do
        rm -rf "${f}"
        log "已清理过期快照：$(basename "${f}")"
    done || true
}

take_snapshot() {
    local prev="$1" keep="${AUTO_BACKUP_KEEP}"
    local dir=/www/backup/auto stamp out

    if ! [ "${keep}" -gt 0 ] 2> /dev/null; then
        log "AUTO_BACKUP_KEEP=${keep}，跳过快照"
        return 0
    fi

    # 只快照 /www/server/panel/data —— 升级时唯一会「对不上」的地方
    if [ ! -d /www/server/panel/data ]; then
        log '面板数据目录不存在（面板尚未初始化），跳过快照'
        return 0
    fi

    mkdir -p "${dir}" 2> /dev/null || { warn "快照目录不可写：${dir}"; return 1; }

    stamp=$(date '+%Y%m%d-%H%M%S')
    out="${dir}/baota-${prev:-fresh}-${stamp}"
    # 同一秒内重复执行时目标可能已存在，cp -a 会把它复制成 out/data 子目录。
    # 先清掉，保证 out 始终是「panel/data 的一份完整副本」
    rm -rf "${out}" 2> /dev/null || true

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

version_guard() {
    local img_ver prev='' state_file="${BAOTA_STATE}/image-version"

    img_ver=$(cat "${IMAGE_VERSION_FILE}" 2> /dev/null || true)
    if [ -z "${img_ver}" ]; then
        log "镜像未提供版本信息（${IMAGE_VERSION_FILE}），跳过版本护栏"
        return 0
    fi
    [ -f "${state_file}" ] && prev=$(cat "${state_file}" 2> /dev/null || true)

    if [ -z "${prev}" ]; then
        # 首次使用：没有可回滚的旧数据，只记录版本，不做快照
        log "首次使用这份持久化数据，记录镜像版本 ${img_ver}"
        mkdir -p "${BAOTA_STATE}" 2> /dev/null || true
        printf '%s\n' "${img_ver}" > "${state_file}" 2> /dev/null \
            || warn "无法写入镜像版本记录：${state_file}"
        return 0
    fi

    if [ "${prev}" = "${img_ver}" ]; then
        # 版本未变：什么都不写，避免每次启动都产生无意义的持久化层写入
        return 0
    fi

    if version_lt "${img_ver}" "${prev}"; then
        warn '=============================================================='
        warn "⚠️ 检测到镜像降级：${prev} -> ${img_ver}"
        warn '   宝塔不提供降级迁移：旧版代码读取新版数据库可能出现功能异常'
        warn '   将先创建快照再继续启动；如需彻底回退，请用备份按「恢复」流程操作'
        warn '=============================================================='
    else
        log "检测到镜像升级：${prev} -> ${img_ver}，正在创建升级前快照"
    fi

    take_snapshot "${prev}"

    mkdir -p "${BAOTA_STATE}" 2> /dev/null || true
    printf '%s\n' "${img_ver}" > "${state_file}" 2> /dev/null \
        || warn "无法写入镜像版本记录：${state_file}"
}

# ==============================================================================
#  关于「面板启动器刷新」（已移除）
#
#  旧模型下面板代码走 overlay，而 /etc/init.d/bt 每次启动都对
#  BT-Panel / BT-Task 做 sed + chmod —— 触发 copy-up，把启动器永久锁进
#  持久化层，之后换什么镜像都不再更新。于是不得不在镜像里另存一份原版，
#  版本变化时刷回去。
#  现在面板代码直接来自镜像层、不持久化，启动器永远是当前镜像的那一份，
#  这个补丁连同 /baota/launcher 一起不再需要。
# ==============================================================================

# ==============================================================================
#  日志体积防线：journald 上限 + 面板 / 站点日志轮转
#
#  为什么必须有这道防线：持久化层把 /var/log、/www 都留了下来，日志不再随
#  容器销毁而消失 —— 这是好事，但意味着日志会一直长下去，而且是静默地长。
#  journald 的编译默认值是「所在文件系统的 10%」，data/ 挂在几 TB 存储池上
#  时，这个默认值等于没有上限。
#
#  两个配置的源都放在 /baota/conf/log/（镜像内，不在任何持久化目录里），
#  和启动器、面板补丁同一个套路：镜像里直接写 /etc 会被用户的旧数据屏蔽。
#
#  更新策略刻意不同：
#    journald  每次比对后重放 —— 它是纯基础设施配置。镜像落盘名为
#              /etc/systemd/journald.conf.d/baota-size.conf（不带数字前缀）。
#              systemd 按文件名排序加载、排后面的覆盖同名键；用户想覆盖请另建
#              一个排在 baota-size.conf 之后的 drop-in（如 zz-my.conf）——
#              注意别用数字或大写字母开头，它们排在字母 b 之前，会被本文件盖掉
#    logrotate 仅在缺失时生成 —— 直接改这个文件是用户的正当权利，不该被冲掉
#
#  两者都用 cmp 先比对，内容一致就不写，避免无谓的持久化层写入
# ==============================================================================
setup_log_limits() {
    local src=/baota/conf
    [ -d "${src}" ] || { warn "未找到 ${src}，跳过日志体积防线配置"; return 0; }

    # ① journald 体积上限
    local jtgt=/etc/systemd/journald.conf.d/baota-size.conf
    if [ -f "${src}/log/journald.conf" ]; then
        if ! cmp -s "${src}/log/journald.conf" "${jtgt}" 2> /dev/null; then
            mkdir -p /etc/systemd/journald.conf.d 2> /dev/null
            if cp -f "${src}/log/journald.conf" "${jtgt}" 2> /dev/null; then
                log "已写入 journald 体积上限：${jtgt}（总占用 ≤200M / 保留 7 天）"
            else
                warn '写入 journald 配置失败：日志将退回 systemd 默认值（所在文件系统的 10%）'
                warn '   大盘上这等于没有上限，请检查 /etc/systemd/journald.conf.d 是否可写'
            fi
        fi
    fi

    # ② 面板 / 站点日志轮转
    local ltgt=/etc/logrotate.d/baota-panel
    if [ -f "${src}/log/logrotate.conf" ] && [ ! -f "${ltgt}" ]; then
        if cp "${src}/log/logrotate.conf" "${ltgt}" 2> /dev/null; then
            chmod 0644 "${ltgt}" 2> /dev/null || true
            log "已生成日志轮转配置：${ltgt}（面板 7 份 / 站点 14 份）"
        else
            warn '生成 logrotate 配置失败：面板与站点日志不会自动轮转，会一直增长'
        fi
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
    if ! ( cd "${PANEL_DIR}" && "${PANEL_PY}" tools.py panel "${password}" ) > /dev/null 2>&1; then
        warn "面板口令初始化失败（tools.py 接口可能已变动），请启动后用 \`bt\` 命令重置"
    fi
    if ! ( cd "${PANEL_DIR}" && "${PANEL_PY}" -c "import tools;tools.set_panel_username('${user}')" ) > /dev/null 2>&1; then
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
#  关于「面板版本一致性提示」（已移除）
#
#  旧模型下面板代码可被面板内更新写进持久化层，于是「面板实际版本」可能
#  与「镜像自带版本」不一致，需要每次启动读一次面板内部版本做对比提示。
#  现在面板代码不可变、恒等于镜像版本，不存在两者不一致的情况，
#  也就不必再去读宝塔内部的 public.version() / menu.json。
#  升级面板 = 换镜像标签。
# ==============================================================================

# ==============================================================================
#  启动报告归档
#
#  降级标记写在 /run（tmpfs），容器一重启就没了。这里把「本次启动是否降级」
#  追加到持久化层的 boot-history.log，事后排查时能回答「从哪次启动开始不对的」。
#  只在状态确实有变化时才写，常态零写入
# ==============================================================================
archive_boot_report() {
    local stamp detail

    if [ ! -f "${DEGRADED_CRITICAL}" ] && [ ! -f "${DEGRADED}" ]; then
        return 0
    fi

    # 两个标记文件可能只存在一个，cat 对缺失文件会报错但不影响另一个。
    # 必须 || true：cat 对缺失文件返回非零，配合 pipefail 会让这行赋值
    # 以失败收场，set -e 直接把整个 entrypoint 带崩 —— 本该「记录降级」的
    # 逻辑反而变成容器起不来
    detail=$(cat "${DEGRADED_CRITICAL}" "${DEGRADED}" 2> /dev/null | tr -s '\n' ' ' || true)
    [ -n "${detail}" ] || return 0

    stamp=$(date '+%F %T')
    detail="[${stamp}] 镜像 $(cat "${IMAGE_VERSION_FILE}" 2> /dev/null || echo unknown) 启动降级：${detail}"

    mkdir -p "${BAOTA_STATE}" 2> /dev/null \
        || { warn "无法写入启动历史：${BAOTA_STATE}"; return 0; }
    printf '%s\n' "${detail}" >> "${BOOT_HISTORY}" 2> /dev/null \
        || { warn "无法写入启动历史：${BOOT_HISTORY}"; return 0; }

    # 只留最近若干行，避免它自己也变成一颗静默增长的种子
    if [ -f "${BOOT_HISTORY}" ]; then
        tail -n "${BOOT_HISTORY_MAX_LINES}" "${BOOT_HISTORY}" > "${BOOT_HISTORY}.tmp" 2> /dev/null \
            && mv -f "${BOOT_HISTORY}.tmp" "${BOOT_HISTORY}" 2> /dev/null || true
    fi

    warn "本次启动存在持久化降级，已记录到 ${BOOT_HISTORY}"
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
        log '查看面板账号：docker exec <容器名> bt default'
        log '重置面板口令：docker exec -it <容器名> bt 5'
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
    setup_log_limits
    init_first_boot
    archive_boot_report
    print_summary

    log "移交 systemd：$*"
    exec "$@"
}

main "$@"
