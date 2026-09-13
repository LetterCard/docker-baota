#!/bin/bash
# ==============================================================================
#  📦 baota-backup —— 持久化数据的备份 / 校验工具（在容器内执行）
#
#  为什么：手工 tar 有三个坑 —— 升级快照被打进包导致体积逐次翻倍、漏
#    --xattrs 丢掉 overlay 的 opaque 标记、备份包把自己装进去。取舍见 docs/backup.md
#
#  用法（本块由 --help 原样打印）：
#     baota-backup                 全量备份到 /www/backup/manual
#     baota-backup --list          体积分布与磁盘水位
#     baota-backup --verify <包>    校验完整性
#     baota-backup --stdout        tar 流写标准输出（宿主机重定向落盘）
#     baota-backup --rsync <目录>   增量同步（镜像语义，只留最新一份）
#     baota-backup --keep 5        只保留最近 5 份（默认不清理）
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 配置真源：与 init.sh / entrypoint.sh 共用同一份
# ------------------------------------------------------------------------------
if [ ! -f /baota/defaults.env ]; then
    echo '❌ [backup][ERROR] 缺少运行期配置真源 /baota/defaults.env，镜像不完整' >&2
    exit 1
fi
# shellcheck source=image/conf/defaults.env   # 相对仓库根（make lint 的工作目录）
. /baota/defaults.env

# 备份产物目录。写成「数据层根/www/backup/manual」而不是容器内的
# /www/backup/manual —— 开启直通时两者经 bind 指向同一份数据，但只有前者能
#   1) 跟随用户覆盖的 PERSIST_DATA_ROOT；
#   2) 在下面打印宿主机路径时正确剥出「data/www/backup/manual」；
#   3) 用户改了 WWW_DATA_SUBDIRS 时依然成立 —— 路径始终从数据层根派生，
#      而下面的 --exclude 写的是 www/backup/manual，匹配恒定生效，
#      不会出现「备份把自己装进自己」的问题。
# 业务直通目录，宿主机从 data/www/backup/manual 直接取走即可
OUTPUT_DIR="${PERSIST_DATA_ROOT}/www/backup/manual"
NAME_PREFIX='baota-backup'

# 打包时排除的路径（归档成员是 www/，排除项也带 www/ 前缀）。后三项必须排除，
# 否则**自包含**：本次产物被下一次备份装进去，体积逐次翻倍。
#   .baota                项目元数据，启动时自动重建
#   www/backup/{auto,manual,database,rsync}   升级快照/本脚本产物/面板备份/--rsync 落点
#   <系统层>/var/log/journal  journald 运行时日志（systemd 自管、恢复后自动重建，
#                         且是打包期间写入最活跃之处，零恢复价值却白拖慢备份）
# 系统层那一项成员名从真源派生（basename PERSIST_SYSTEM_ROOT）：写死「system」
# 会让排除静默失效 —— 表现为备份体积逐次翻倍
SYSTEM_MEMBER=$(basename "${PERSIST_SYSTEM_ROOT}")
EXCLUDES=(
    '.baota'
    'www/backup/auto'
    'www/backup/manual'
    'www/backup/database'
    'www/backup/rsync'
    "${SYSTEM_MEMBER}/var/log/journal"
)

# 由 EXCLUDES 派生 tar 参数。排除项只在这里写一次，全量打包与 --rsync 共用，
# 避免两条备份路径各自维护一份而漂移（漂移的表现是「某个路径一边排除了、
# 一边没排除」，靠人工对比很难发现）
EXCLUDE_ARGS=()
for _e in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=( "--exclude=${_e}" )
done

# --quiet 下日志改走 stderr：stdout 只保留最后那行备份路径，
# 这样 `baota-backup --quiet` 的输出可以直接被脚本取用（CI 就是这么用的），
# 不会被进度信息干扰。非 quiet 时保持原样，日志仍进容器 stdout 便于人看
log()  {
    if [ "${QUIET:-0}" = '1' ]; then
        echo "📦 [backup] $*" >&2
    else
        echo "📦 [backup] $*"
    fi
}
warn() { echo "⚠️ [backup][WARN] $*" >&2; }
die()  { echo "❌ [backup][ERROR] $*" >&2; exit 1; }

# ==============================================================================
#  tar 退出码判定（热备份必须区分，否则会把「正常竞态」误当成失败）
#  GNU tar 三档：0 干净；1 读取期间被改写（包仍完整可用，是热备份固有特性，
#    非错误，CI 曾在 journald 写入瞬间随机失败就是没区分这档）；≥2 真失败必须拦。
#  返回 0 = 可接受（含第 1 档），非 0 = 真失败，由调用方 die。
# ==============================================================================
check_tar_rc() {
    case "$1" in
        0) return 0 ;;
        1)
            warn '部分文件在打包期间被改写（热备份的固有竞态）：备份已生成，内容可用，'
            warn '  但不是字节级一致。需要严格一致请停机后再打一次：'
            warn '    docker compose down → 打包 → docker compose up -d'
            return 0
            ;;
        *) return "$1" ;;
    esac
}

# 可选的 MySQL 转储临时目录。
# --stdout 模式同样会用到（清单与转储要先落盘，再喂给 tar），
# 只有 --list / --verify 这两个只读模式不涉及
TMP_DIR=''

cleanup() { [ -n "${TMP_DIR}" ] && rm -rf "${TMP_DIR}" 2> /dev/null || true; }
trap cleanup EXIT

# ==============================================================================
#  参数解析
# ==============================================================================
MODE='create'      # create | list | verify | stdout | rsync
VERIFY_FILE=''
RSYNC_DEST=''
KEEP=0
QUIET=0

usage() {
    # 直接打印本文件头部的说明块，避免用法与实现脱节
    awk 'NR==1 {next} /^# ===/ {c++} c>=2 {exit} {sub(/^# ?/, ""); print}' "$0"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output) OUTPUT_DIR="${2:?--output 需要参数}"; shift 2 ;;
            -n|--name)   NAME_PREFIX="${2:?--name 需要参数}";  shift 2 ;;
            --stdout)    MODE='stdout';  shift ;;
            --list)      MODE='list';    shift ;;
            --verify)    MODE='verify'; VERIFY_FILE="${2:?--verify 需要参数}"; shift 2 ;;
            --rsync)     MODE='rsync';  RSYNC_DEST="${2:?--rsync 需要目标目录参数}"; shift 2 ;;
            --keep)      KEEP="${2:?--keep 需要参数}"; shift 2 ;;
            -q|--quiet)  QUIET=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "未知参数：$1（用 --help 查看用法）" ;;
        esac
    done

    case "${KEEP}" in
        ''|*[!0-9]*) die "--keep 需要一个非负整数，当前为：${KEEP}" ;;
    esac
}

# ==============================================================================
#  体积分布：回答「我的 data 到底被什么占满了」
# ==============================================================================
show_sizes() {
    log "数据层：${PERSIST_DATA_ROOT}    系统层：${PERSIST_SYSTEM_ROOT}"
    echo
    echo '各持久化目录体积（降序）：'
    # shellcheck disable=SC2086,SC2046
    du -sh \
        "${PERSIST_DATA_ROOT}/www" \
        $(for d in ${PERSIST_SYSTEM_DIRS}; do echo "${PERSIST_SYSTEM_ROOT}/${d}"; done) \
        2> /dev/null | sort -rh || true
    echo
    echo '可排除项体积：'
    for d in "${PERSIST_DATA_ROOT}/.baota" "${PERSIST_SYSTEM_ROOT}/.baota" \
             "${PERSIST_DATA_ROOT}/www/backup/auto" "${PERSIST_DATA_ROOT}/www/backup/manual" \
             "${PERSIST_DATA_ROOT}/www/backup/database"; do
        [ -e "${d}" ] || continue
        printf '  %-40s %s\n' "${d#/*/}" "$(du -sh "${d}" 2> /dev/null | cut -f1)"
    done
    echo
    echo '磁盘水位：'
    for _m in "${PERSIST_DATA_ROOT}" "${PERSIST_SYSTEM_ROOT}"; do
        # || true：目录缺失 / df 失败时保持 --list 可用（这本来就是排障工具），
        # 而不是让 pipefail + set -e 把整条命令带崩
        df -Ph "${_m}" | awk -v r="${_m}" 'NR==1 || NR==2 {print "  "r": "$0}' || true
    done
}

# ==============================================================================
#  数据库热转储
#
#  MySQL 数据在 /www/server/data（WWW_DATA_SUBDIRS 里的 bind 目录，不在 overlay upper 里）。
#  容器运行时它被直接复制，InnoDB 可能半写、恢复后表损坏；所以打包前先做一次
#  单事务转储，作为包内「一致副本」：InnoDB 起不来时导入这份 SQL 即可。
#  拿不到连接就跳过并告警 —— 宁可少一份转储，也不让备份整体失败
# ==============================================================================
find_mysql_bin() {
    local name="$1" candidate
    for candidate in "/www/server/mysql/bin/${name}" "/usr/bin/${name}" "/usr/local/mysql/bin/${name}"; do
        if [ -x "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

dump_databases() {
    local out="$1" mysql_bin dump_bin

    mysql_bin=$(find_mysql_bin mysql)     || return 1
    dump_bin=$(find_mysql_bin mysqldump)  || return 1

    # 宝塔的 MySQL 默认允许本机 root 免密登录（socket 或 127.0.0.1）
    if ! "${mysql_bin}" -e 'SELECT 1' > /dev/null 2>&1; then
        return 1
    fi

    # --single-transaction：InnoDB 的一致性快照，不锁表、不影响业务
    if "${dump_bin}" --single-transaction --routines --triggers --all-databases \
            > "${out}" 2> /dev/null && [ -s "${out}" ]; then
        return 0
    fi

    rm -f "${out}" 2> /dev/null || true
    return 1
}

# 生成包内说明：版本号、时间、目录清单，以及恢复步骤
write_manifest() {
    local file="$1" image_ver db_note

    image_ver=$(cat /baota/VERSION 2> /dev/null || echo unknown)
    if [ -f "${TMP_DIR}/databases.sql" ]; then
        db_note='包含 MySQL 单事务转储 databases.sql'
    else
        db_note='未包含 MySQL 转储（容器停止或未安装 MySQL）'
    fi

    cat > "${file}" <<EOF
baota-backup 备份清单
=====================
生成时间    : $(date '+%F %T %Z')
镜像版本    : ${image_ver}
持久化根目录: ${PERSIST_DATA_ROOT}
数据库      : ${db_note}

恢复步骤
--------
本包是整份 data 卷的镜像（业务与面板状态 data/www、系统层 data/.system/...
都在里面），直接整包解回 data 即可。
面板代码不在包里 —— 它属于镜像，换镜像即升级：

【./data:/data（compose 默认）】
1. 停止容器：docker compose down
2. 移走现有数据：mv data "data.bak-\$(date +%F)" && mkdir data
3. 解开备份：tar xzf $(basename "${2:-本包}") -C data
4. 启动容器：docker compose up -d && docker compose logs -f baota

若 MySQL 起不来（热备份时 InnoDB 文件可能半写）：
  导入包内的 databases.sql 即可，它是一致性快照：
    docker exec -i baota mysql < databases.sql

注意
----
- 本包不含 .baota 元数据目录与升级自动快照，启动时会自动重建
- 持久化层必须落在 ext4 / btrfs / xfs 上，放到 SMB / NFS / exFAT 会导致
  持久化层只读、写入静默失败
EOF
}

# ==============================================================================
#  打包（-C 到数据层，包内路径相对 www/... 与 .system/...，恢复不受绝对路径影响）
#  --xattrs 是关键：overlay 把「整体替换过的目录」记成 trusted.overlay.opaque
#    扩展属性，丢了它恢复后该目录会与镜像内容合并（被删镜像文件是 0:0 设备节点，
#    默认就保留）。
#  收集确实存在的持久化目录（全量 / --stdout / --rsync 共用）：tar / rsync 遇
#    不存在的源目录会报错退出，先筛一遍；成员名从真源派生（defaults.env 允许
#    覆盖 PERSIST_SYSTEM_ROOT / PANEL_STATE_ROOT，写死会找不到）。
# ==============================================================================
collect_members() {
    # 归档 data 卷内的顶层成员：业务与面板状态（www/）+ 系统层（.system/）。
    # 面板状态已归位在 www/server/panel 下（与容器内位置同名），不再独立顶层；
    # 面板代码不在 data 卷里 —— 它属于镜像，换镜像即升级，无需备份。
    # 用显式成员而非 '.'：'.' 让成员名带 ./ 前缀，EXCLUDES 里的 'www/backup/manual'
    # 匹配不上 → 边写边读自己的输出包 → tar 报错。
    # 顶层 .baota 不进成员、内部 .baota 由 basename 排除，天然不打包。
    # 系统层成员名从配置真源派生（defaults.env 允许覆盖 PERSIST_SYSTEM_ROOT），
    # 写死成员名在非默认布局下 tar 找不到成员，报错还指向不存在的路径。
    # 系统层若被指到 data 卷之外（tar 单一来源打不进来），在这里响亮拒绝；
    # --rsync 分支没有这个限制，会对 data 卷外的系统层补第二条同步
    local _system
    _system=$(basename "${PERSIST_SYSTEM_ROOT}")
    DATA_MEMBERS=('www')
    if [ -d "${PERSIST_DATA_ROOT}/${_system}" ]; then
        DATA_MEMBERS+=("${_system}")
    elif [ "${PERSIST_SYSTEM_ROOT}" != "${PERSIST_DATA_ROOT}/${_system}" ]; then
        die "PERSIST_SYSTEM_ROOT=${PERSIST_SYSTEM_ROOT} 不在数据层 ${PERSIST_DATA_ROOT} 内，tar 打包覆盖不到系统层（含面板账号、用户装的环境）；请改用 --rsync，或把系统层指回数据层内"
    fi
    return 0
}

build_archive() {
    local out="$1"

    log '正在收集文件清单…'
    collect_members
    [ ${#DATA_MEMBERS[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

    # 附加项：清单 + 数据库转储（都放在临时目录，作为 tar 的第二个来源）
    TMP_DIR=$(mktemp -d)

    if dump_databases "${TMP_DIR}/databases.sql"; then
        log '已附加 MySQL 一致性转储（databases.sql）'
    else
        log '未附加 MySQL 转储（MySQL 未运行或未安装）—— InnoDB 文件可能处于半写状态，恢复后如起不来请改用停机备份（docker compose down 后再打）'
    fi

    # ★ 清单必须在转储之后生成：write_manifest 靠「databases.sql 在不在」决定
    #   清单里的数据库一行，先写会把「已随包转储」误报成「未包含 MySQL 转储」，
    #   而 MANIFEST.txt 正是恢复时的说明书（已踩过这个顺序坑）
    write_manifest "${TMP_DIR}/MANIFEST.txt" "${out}"

    local -a extra=()
    [ -f "${TMP_DIR}/databases.sql" ] && extra+=(databases.sql)

    # 系统层已在数据层之内（data/.system），一次 -C 就够了；
    # 包内路径仍为 www/... 与 .system/...，恢复时不受挂载方式影响
    #
    # 退出码不能直接 || die：热备份下 tar 常以 1（文件在读取期间被改写）结束，
    # 那是可接受的，包照样完整；只有 ≥2 才是真失败。详见 check_tar_rc。
    local rc=0
    tar --xattrs --xattrs-include='trusted.overlay.*' \
        "${EXCLUDE_ARGS[@]}" \
        -C "${PERSIST_DATA_ROOT}" -czf "${out}" "${DATA_MEMBERS[@]}" \
        -C "${TMP_DIR}" MANIFEST.txt "${extra[@]}" \
        || rc=$?

    if ! check_tar_rc "${rc}"; then
        # 失败的半成品必须清掉：留着会让用户误以为手里有回滚点
        rm -f "${out}" 2> /dev/null || true
        die "打包失败（tar 退出码 ${rc}）：${out}"
    fi

    log "备份完成：${out}（$(du -mh "${out}" 2> /dev/null | cut -f1)）"
}

# ==============================================================================
#  校验
#
#  只有恢复过一次的备份才算备份。这里检查三类关键路径是否都在包里：
#  站点 / 数据库数据 / 面板配置
# ==============================================================================
verify_archive() {
    local file="$1" listing missing=0 pattern panel_state_member

    [ -f "${file}" ] || die "备份包不存在：${file}"

    log "正在校验：${file}"
    listing=$(tar tzf "${file}" 2> /dev/null) || die "无法读取备份包（文件损坏或不是 tar.gz）"

    # 关键成员检查（整份 data 卷归档，结构与宿主机一致）：
    #   www/wwwroot/          站点（业务 bind）
    #   <面板状态根>/data     面板配置 + 数据库（面板状态 bind）
    #   MANIFEST.txt          备份清单（由 backup.sh 自动生成）
    # 面板状态那一项从真源派生（basename PANEL_STATE_ROOT），不能写死 panel：
    # defaults.env 允许覆盖 PANEL_STATE_ROOT，写死会「备份成功、自校验却恒失败」。
    # 用 case 而非 `printf | grep -q`：pipefail 下 grep -q 命中即关管道，大清单的
    # printf 写不完被 SIGPIPE（141）终止，把「含」误判成「缺少」；case 无此隐患
    # 面板状态已归位到 www/server/panel 下，成员名取「相对数据层根的路径」：
    # basename 只有一层（panel），对不上 www/server/panel/data，会恒判缺失
    panel_state_member="${PANEL_STATE_ROOT#${PERSIST_DATA_ROOT}/}"
    case "${panel_state_member}" in
        /*) die "PANEL_STATE_ROOT=${PANEL_STATE_ROOT} 不在数据层 ${PERSIST_DATA_ROOT} 内，备份包里不会有面板状态" ;;
    esac
    panel_state_member="${panel_state_member}/data"
    for pattern in 'www/wwwroot/' "${panel_state_member}" 'MANIFEST.txt'; do
        case "${listing}" in
            *"${pattern}"*) echo "  ✅ 含 ${pattern}" ;;
            *)              echo "  ❌ 缺少 ${pattern}"; missing=$((missing + 1)) ;;
        esac
    done

    # 自包含检查：备份包不应把业务备份目录（data/www/backup/*）里的产物装进来
    case "${listing}" in
        *'www/backup/auto/'*|*'www/backup/manual/'*|*'www/backup/database/'*|*'www/backup/rsync/'*)
            warn '备份包内含有 www/backup/ 下的产物，发生自包含（下一次备份体积会翻倍）'
            missing=$((missing + 1)) ;;
    esac

    [ "${missing}" -eq 0 ] || die "校验未通过（${missing} 项异常）"
    log "校验通过，共 $(printf '%s\n' "${listing}" | wc -l | tr -d ' ') 个条目"
}

# ==============================================================================
#  清理历史备份
# ==============================================================================
prune_archives() {
    local dir="$1" keep="$2" n
    [ "${keep}" -gt 0 ] || return 0

    # 两处 ls 都要 || true：目录被手工清空时 ls 返回非零，
    # 配合 pipefail 会让整个备份「成功之后」以失败收场
    n=$(ls -1t "${dir}/${NAME_PREFIX}"-*.tgz 2> /dev/null | wc -l || true)
    [ "${n}" -le "${keep}" ] && return 0

    ls -1t "${dir}/${NAME_PREFIX}"-*.tgz 2> /dev/null | tail -n "$((n - keep))" | while read -r f; do
        rm -f "${f}"
        log "已清理过期备份：$(basename "${f}")"
    done || true
}

# ==============================================================================
#  增量同步（--rsync）
#  为什么值得有它：全量打包每次重读重压整份 data/，几十 GB 时非常慢；rsync 只传
#    变化部分，后续从「几十分钟」降到「几分钟」。
#  ★ 必须用 -aAX：-X 保留扩展属性（overlay 的 opaque 标记全靠它，与 --xattrs 等价），
#    少了它恢复后被替换过的目录会与镜像内容合并。一条 rsync 带过 www/ 与 .system/。
#  安全护栏：--delete 让目标严格对齐源，指错位置等于当场删库，拦三种情况 ——
#    ① 目标是 / 或持久化层自身 ② 目标是持久化层的上层目录 ③ 目标非空且不像同步产物
# ==============================================================================
rsync_sync() {
    local dest="$1"

    command -v rsync > /dev/null 2>&1 \
        || die '未找到 rsync（镜像内已预装；若缺失请 apt-get install -y rsync）'

    [ -n "${dest}" ] || die '--rsync 需要目标目录参数'
    [ "${dest}" != '/' ] || die '拒绝同步到 /：目标不能是根目录'

    local _src
    for _src in "${PERSIST_DATA_ROOT}" "${PERSIST_SYSTEM_ROOT}"; do
        [ "${dest}" = "${_src}" ] && die "拒绝同步到持久化层自身：${dest}"
        case "${_src}" in
            "${dest}"/*)
                die "拒绝同步到持久化层的上层目录：${dest}（--delete 会把它下面的持久化层一起删掉）"
                ;;
        esac
        # 反向同样要拦：目标在持久化层内部时，rsync 会把「包含目标的源」往
        # 目标里同步，每跑一次体积近似翻倍，最终撑满 data 卷
        case "${dest}" in
            "${_src}"/*)
                die "拒绝同步到持久化层内部：${dest}（源包含目标，越同步越大）"
                ;;
        esac
    done

    # 目标非空时，必须是本工具之前的同步产物，否则拒绝用 --delete。
    # 判据只看 data/：整份持久化层（含系统层 .system/）都同步进 dest/data 里。
    if [ -n "$(ls -A "${dest}" 2> /dev/null)" ]; then
        if [ ! -d "${dest}/data" ]; then
            die "目标目录非空且不像本工具的同步产物（缺少 data/ 子目录）：${dest}
  --delete 会删除目标里源没有的文件。请换一个空目录，或先清空目标"
        fi
    fi

    mkdir -p "${dest}/data" 2> /dev/null \
        || die "无法创建目标目录：${dest}"

    # 先转储再同步：热同步时 InnoDB 文件可能半写，这份 SQL 是「一致副本」。
    # 放在 dest 根目录，不参与两侧同步，不会被 --delete 波及
    if dump_databases "${dest}/databases.sql.tmp" && [ -s "${dest}/databases.sql.tmp" ]; then
        mv -f "${dest}/databases.sql.tmp" "${dest}/databases.sql"
        log '已附加 MySQL 一致性转储（databases.sql）'
    else
        rm -f "${dest}/databases.sql.tmp" 2> /dev/null || true
        log '未附加 MySQL 转储（MySQL 未运行或未安装）'
    fi

    collect_members
    [ ${#DATA_MEMBERS[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

    local -a rargs=( -aAX --delete --human-readable --stats )
    local _e
    for _e in "${EXCLUDES[@]}"; do
        rargs+=( "--exclude=${_e}" )
    done

    # --rsync 整层同步 data 卷（业务与面板状态 data/www + 系统层 data/.system/<dir>
    # 都在里面），一条命令覆盖全部。
    # 但用户把 PERSIST_SYSTEM_ROOT 指到 data 卷之外时（defaults.env 允许），
    # 这条 rsync 摸不到它 —— 会静默漏掉整个系统层，恢复后账号、环境全丢。
    # 对这种布局显式补第二条同步
    log "增量同步 ${PERSIST_DATA_ROOT} -> ${dest}/data"
    rsync "${rargs[@]}" "${PERSIST_DATA_ROOT}/" "${dest}/data/" \
        || die "同步失败：${dest}/data"

    case "${PERSIST_SYSTEM_ROOT}" in
        "${PERSIST_DATA_ROOT}"/*) ;;   # 系统层在 data 卷内，上面那条已覆盖
        *)
            log "增量同步 ${PERSIST_SYSTEM_ROOT} -> ${dest}/system"
            mkdir -p "${dest}/system" 2> /dev/null \
                || die "无法创建目标目录：${dest}/system"
            rsync "${rargs[@]}" "${PERSIST_SYSTEM_ROOT}/" "${dest}/system/" \
                || die "同步失败：${dest}/system"
            ;;
    esac

    log "增量同步完成：${dest}"
    log '提示：--rsync 是镜像同步，目标里始终只有最新一份；要留历史请配合 NAS 快照'
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
    parse_args "$@"

    case "${MODE}" in
        list)
            show_sizes
            return 0
            ;;
        verify)
            verify_archive "${VERIFY_FILE}"
            return 0
            ;;
        rsync)
            rsync_sync "${RSYNC_DEST}"
            return 0
            ;;
        stdout)
            # 标准输出模式下把 tar 流直接吐出去，由宿主机重定向落盘：
            #   docker exec baota baota-backup --stdout > baota-backup.tgz
            #
            # ★ 本分支所有输出必须走 stderr：stdout 是 tar 流，混进文字会让备份包
            #   损坏（且解压时才发现）。所以这里用 echo ... >&2，不能用 log()（走 stdout）。
            #
            # 产物必须与 create 一致，否则过不了自己的 --verify：整份 data 卷、
            # 附 MANIFEST.txt 与 MySQL 转储、排除项共用 EXCLUDE_ARGS；唯一区别是
            # 流已吐出、无法生成后自校验
            collect_members
            [ ${#DATA_MEMBERS[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

            TMP_DIR=$(mktemp -d)

            local -a extra=()
            if dump_databases "${TMP_DIR}/databases.sql"; then
                extra+=( databases.sql )
                echo '📦 [backup] 已附加 MySQL 一致性转储（databases.sql）' >&2
            else
                echo '📦 [backup] 未附加 MySQL 转储（MySQL 未运行或未安装）' >&2
            fi

            # 同 create 模式：清单要在转储之后生成，否则「已转储」会被写成「未包含」
            write_manifest "${TMP_DIR}/MANIFEST.txt" '<stdout>'

            # 退出码处理与 create 模式一致（热备份下 tar 返回 1 可接受）。
            # 这里无法清理半成品 —— 流已经吐出去了，读不回来。
            # check_tar_rc 的告警走 stderr，不会污染 stdout 的 tar 流
            local rc=0
            tar --xattrs --xattrs-include='trusted.overlay.*' \
                "${EXCLUDE_ARGS[@]}" \
                -C "${PERSIST_DATA_ROOT}" -cz "${DATA_MEMBERS[@]}" \
                -C "${TMP_DIR}" MANIFEST.txt "${extra[@]}" \
                || rc=$?

            if ! check_tar_rc "${rc}"; then
                die "打包失败（tar 退出码 ${rc}）"
            fi
            return 0
            ;;
    esac

    [ -d "${PERSIST_DATA_ROOT}" ] || die "数据层根目录不存在：${PERSIST_DATA_ROOT}（容器未挂载 data 卷？）"
    [ -d "${PERSIST_SYSTEM_ROOT}" ] || die "系统层根目录不存在：${PERSIST_SYSTEM_ROOT}（容器未挂载 data 卷？）"

    mkdir -p "${OUTPUT_DIR}" 2> /dev/null || die "无法创建输出目录：${OUTPUT_DIR}"

    local out
    out="${OUTPUT_DIR}/${NAME_PREFIX}-$(date '+%Y%m%d-%H%M%S').tgz"
    build_archive "${out}"
    verify_archive "${out}"
    prune_archives "${OUTPUT_DIR}" "${KEEP}"

    if [ "${QUIET}" = '1' ]; then
        echo "${out}"
    else
        # 宿主机可见路径 = compose 目录（data 卷）下的相对路径，即去掉根斜杠。
        # 只有产物落在持久化层里才谈得上「宿主机位置」：用户用 -o 指到容器内
        # 其它地方时，那个路径在宿主机上并不存在，如实打印容器内路径，
        # 不要拼出一个看起来像、实际打不开的路径。
        case "${out}" in
            "${PERSIST_DATA_ROOT}"/*) log "宿主机上的位置：<compose 目录>/${out#/}" ;;
            *)                        log "备份已生成（容器内路径）：${out}" ;;
        esac
    fi
}

main "$@"
