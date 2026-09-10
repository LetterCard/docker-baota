#!/bin/bash
# ==============================================================================
#  📦 baota-backup —— 持久化数据的备份 / 校验工具（在容器内执行）
#
#  构建期装到 /baota/backup.sh，并软链到 /usr/local/bin/baota-backup。
#  宿主机用法：docker exec baota baota-backup [选项]
#
#  为什么要有它：
#    手工 tar 有三个很容易踩的坑，本脚本替你绕开 ——
#      1. 漏掉 --exclude='www/backup/auto'，上一次的升级快照被打包进本次备份，
#         体积逐次翻倍（实测 10M 数据 + 60M 快照：不排除 70M，排除后 10M）
#      2. 漏掉 --xattrs，overlay 的「目录被整体替换」标记
#         （trusted.overlay.opaque）丢失，恢复后该目录会与镜像内容合并，
#         而不是保持你替换后的样子
#      3. 备份落在 www/backup 下却没排除自身，下一次备份把它又装进去
#
#  用法：
#    baota-backup                 在 /www/backup/manual（宿主 data/www/backup/manual）生成一份全量备份
#    baota-backup --list          只打印各持久化目录的体积分布，不打包
#    baota-backup --verify <包>    校验备份包是否完整
#    baota-backup --stdout        把 tar 流写到标准输出（供宿主机重定向落盘）
#    baota-backup --rsync <目录>   增量同步到另一个目录（首次全量，之后只传变化）
#    baota-backup --keep 5        生成后只保留最近 5 份（默认 0 = 不清理）
#    baota-backup --help
#
#  与面板自带备份的分工：
#    面板备份   = 站点文件 + 数据库，不含面板配置与系统环境，适合日常救急
#    本工具     = 整份 data/，含面板配置与系统环境，适合升级 / 迁移前的全量快照
#
#  全量打包 与 --rsync 怎么选：
#    全量打包  每次产出一份自包含的 tgz，可离线归档；data 大了会慢
#    --rsync   同步到另一个位置，之后每次只传变化部分，快得多；
#              代价是目标里始终只有「最新一份」—— 它是镜像同步，不是版本化备份。
#              要留历史请用 NAS / 云盘快照，或定期把同步目标整体归档
#    两者都保留扩展属性（-aAX / --xattrs），恢复效果等价
#
#  日志约定：[backup] 普通信息，[backup][WARN] 告警，[backup][ERROR] 错误
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 配置真源：与 init.sh / entrypoint.sh 共用同一份
# ------------------------------------------------------------------------------
if [ -f /baota/defaults.env ]; then
    . /baota/defaults.env
fi

PERSIST_DATA_ROOT="${PERSIST_DATA_ROOT:-/data}"
PERSIST_SYSTEM_ROOT="${PERSIST_SYSTEM_ROOT:-/data/system}"
PERSIST_SYSTEM_DIRS="${PERSIST_SYSTEM_DIRS:-etc usr var root opt home srv}"

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

# 打包时排除的路径。数据层 /www 是 www 这一层 overlay，归档成员是 www/，
# rsync 又以 /data 为根同步（www/… 同理），所以快照/备份都带 www/ 前缀：
#   .baota              项目元数据（数据层 /data/.baota、系统层 /data/system/.baota），
#                       启动时自动重建，跟着备份走只会带来陈旧状态
#   www/backup/auto     升级前自动快照（entrypoint take_snapshot 写到 /www/backup/auto，
#                       业务直通 → data/www/backup/auto）。不排除会把它打进本次备份、
#                       下次再打进来，体积逐次翻倍；它只是升级时的临时回滚点
#   www/backup/manual   本脚本自己的产物。不排除会自包含
#   www/backup/database 面板「数据库」页产生的备份，同样会自包含
#   www/backup/rsync    --rsync 的落点之一（也可以挂独立卷同步到容器外）。
#                       不排除的话，同步目标会被下一次全量备份装进去，同样自包含
#   system/var/log/journal  journald 的运行时日志（system.journal / user-*.journal）。
#                       三重理由都必须排除：
#                         1) 它由 systemd 自己管理，镜像里已限到「总占用 ≤200M、
#                            保留 7 天」（journald.conf.d/baota-size.conf），
#                            恢复后 journald 自动重建，不是需要保留的用户数据；
#                         2) 它是打包期间写入最活跃的文件 —— 「file changed as
#                            we read it」几乎都出自这里；
#                         3) 体积不小却零恢复价值，白拖慢备份
EXCLUDES=(
    '.baota'
    'www/backup/auto'
    'www/backup/manual'
    'www/backup/database'
    'www/backup/rsync'
    'system/var/log/journal'
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
#
#  GNU tar 的三档语义：
#    0   干净完成
#    1   有文件在读取期间被改写（"file changed as we read it"）——
#        ★ 包本身是完整可用的，只是那些文件是「某一时刻的快照」。
#        容器在跑，journald / MySQL / 面板日志随时可能写入，这是热备份的
#        固有特性，不是错误。CI 曾在 journald 写入的瞬间随机失败，
#        就是因为没区分这一档。
#    ≥2  真正的失败（源读不到 / 目标写不下 / 参数错），必须拦住。
#
#  返回 0 表示可以接受（含第 1 档），非 0 表示真失败，由调用方 die。
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
show_usage() {
    log "数据层：${PERSIST_DATA_ROOT}    系统层：${PERSIST_SYSTEM_ROOT}"
    echo
    echo '各持久化目录体积（降序）：'
    # shellcheck disable=SC2086,SC2046
    du -sh \
        "${PERSIST_DATA_ROOT}/www" \
        "${PERSIST_DATA_ROOT}/panel" \
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
#  MySQL 数据在 /www/server/data —— 它是 WWW_DATA_SUBDIRS 里的 bind 目录，
#  源在 data/www/server/data，不在任何 overlay upper 里。
#  容器运行时它被直接复制，InnoDB 文件可能处于半写状态，
#  恢复后表损坏。这里在打包前先做一次单事务转储，作为包内的「一致副本」：
#  恢复时若发现 InnoDB 起不来，导入这份 SQL 即可。
#
#  拿不到连接就直接跳过并告警 —— 宁可少一份转储，也不让备份整体失败
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
本包是整份 data 卷的镜像（业务 data/www、面板状态 data/panel、
系统层 data/system/... 都在里面），直接整包解回 data 即可。
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
#  打包
#
#  --xattrs 是关键：overlay 的「删除 / 替换」信息就存在持久化层里，有两种形式 ——
#    · 被删除的镜像文件：表现为字符设备节点（0:0），tar 默认就会原样保留
#    · 被整体替换过的目录：表现为 trusted.overlay.opaque 扩展属性。
#      tar 默认不带 xattrs，丢了它恢复后该目录会与镜像内容合并，
#      而不是保持你替换后的样子
#
#  分两段 -C（数据层 /data 与系统层 /data/system）让包内路径保持相对，
#  恢复到任何机器、任何目录都不受绝对路径影响
# ==============================================================================
# 收集确实存在的持久化目录。全量打包、--stdout、--rsync 三处共用：
# tar / rsync 遇到不存在的源目录会直接报错退出，所以必须先筛一遍。
# 结果写进全局数组（build_archive 与 --rsync 分支都要读）
# shellcheck disable=SC2086   # PERSIST_*_DIRS 是空格分隔的目录列表，需要按词切开
collect_members() {
    # 归档 data 卷内的三层顶层目录：
    #   业务（www/）+ 面板状态（panel/）+ 系统（system/）。
    # 面板代码不在 data 卷里 —— 它属于镜像，换镜像即升级，无需备份。
    # 用显式成员而不是 '.'：'.' 会让成员名带 ./ 前缀，EXCLUDES 里
    # 'www/backup/manual' 匹配不上 → 边写边读自己的输出包 → tar 报错。
    # 顶层 .baota 不进成员、内部 .baota 由 basename 排除，天然不打包。
    data_members=('www' 'panel' 'system')
    return 0
}

build_archive() {
    local out="$1"

    log '正在收集文件清单…'
    collect_members
    [ ${#data_members[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

    # 附加项：清单 + 数据库转储（都放在临时目录，作为 tar 的第二个来源）
    TMP_DIR=$(mktemp -d)
    write_manifest "${TMP_DIR}/MANIFEST.txt" "${out}"

    if dump_databases "${TMP_DIR}/databases.sql"; then
        log '已附加 MySQL 一致性转储（databases.sql）'
    else
        log '未附加 MySQL 转储（MySQL 未运行或未安装）—— InnoDB 文件可能处于半写状态，恢复后如起不来请改用停机备份（docker compose down 后再打）'
    fi

    local -a extra=()
    [ -f "${TMP_DIR}/databases.sql" ] && extra+=(databases.sql)

    # 数据层（/data）与系统层（/data/system）分两段打包，
    # 包内路径仍为 www/... 与 etc/...，恢复时不受挂载方式影响
    #
    # 退出码不能直接 || die：热备份下 tar 常以 1（文件在读取期间被改写）结束，
    # 那是可接受的，包照样完整；只有 ≥2 才是真失败。详见 check_tar_rc。
    local rc=0
    tar --xattrs --xattrs-include='trusted.overlay.*' \
        "${EXCLUDE_ARGS[@]}" \
        -C "${PERSIST_DATA_ROOT}" -czf "${out}" "${data_members[@]}" \
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
    local file="$1" listing missing=0 pattern

    [ -f "${file}" ] || die "备份包不存在：${file}"

    log "正在校验：${file}"
    listing=$(tar tzf "${file}" 2> /dev/null) || die "无法读取备份包（文件损坏或不是 tar.gz）"

    # 关键成员检查（整份 data 卷归档，结构与宿主机一致）：
    #   www/wwwroot/      站点（业务 bind）
    #   panel/data  面板配置 + 数据库（面板状态 bind）
    #   MANIFEST.txt                   备份清单（由 backup.sh 自动生成）
    # 用 case 而非 `printf | grep -q`：pipefail 下 grep -q 一命中就关闭管道，
    # 大清单的 printf 写不完被 SIGPIPE 终止（141），会把「含」误判成「缺少」。
    # listing 已在变量里，case 子串匹配既无管道也无该隐患
    for pattern in 'www/wwwroot/' 'panel/data' 'MANIFEST.txt'; do
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
#
#  为什么值得有它：全量打包每次都要重读并重压整份 data/，几十 GB 时非常慢。
#  rsync 只传变化部分，后续备份从「几十分钟」降到「几分钟」。
#
#  为什么必须用 -aAX：
#    -a  归档模式（递归 + 保留权限 / 属主 / 时间 / 链接 / 设备节点）
#    -A  保留 ACL
#    -X  保留扩展属性 ← 关键：overlay 的 trusted.overlay.opaque 标记全靠它保住，
#        与全量打包的 --xattrs 等价。少了它，恢复后「被整体替换过的目录」会与
#        镜像内容合并，而不是保持你替换后的样子
#
#  整份持久化层同步到目标的 data/：源 ${PERSIST_DATA_ROOT}/ 下已经有 www/ 与
#  system/ 两个顶层，一条 rsync 就都带过去了，不再分两次同步。
#  包内结构与全量备份一致，恢复方式也一致。
#
#  安全护栏（--delete 的危险性）：
#    --delete 会让目标严格对齐源，目标里「源没有的」会被删掉。
#    指错位置等于当场删库，所以这里拦三种情况：
#      1) 目标是 / 或持久化层自身
#      2) 目标是持久化层的上层目录（同步会把源自己也删掉）
#      3) 目标非空且不像本工具的同步产物（可能是用户的其它目录）
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
    done

    # 目标非空时，必须是本工具之前的同步产物，否则拒绝用 --delete。
    # 判据只看 data/：整份持久化层（含系统层 system/）都同步进 dest/data 里，
    # 早先版本额外建过一个 dest/system 却从不往里写，拿它当判据等于
    # 「手工 mkdir -p dest/data dest/system 就能骗过护栏」，没有意义。
    # 老目标里的那个空 system/ 不影响判定，可以直接删掉。
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
    [ ${#data_members[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

    local -a rargs=( -aAX --delete --human-readable --stats )
    local _e
    for _e in "${EXCLUDES[@]}"; do
        rargs+=( "--exclude=${_e}" )
    done

    # --rsync 整层同步 data 卷（业务 data/www + 面板状态 data/panel
    # + 系统层 data/system/<dir> 都在里面），一条命令覆盖全部
    log "增量同步 ${PERSIST_DATA_ROOT} -> ${dest}/data"
    rsync "${rargs[@]}" "${PERSIST_DATA_ROOT}/" "${dest}/data/" \
        || die "同步失败：${dest}/data"

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
            show_usage
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
            # ★ 本分支里所有输出必须走 stderr：stdout 是 tar 流，
            #   任何混进去的文字都会让备份包损坏（且是解压时才发现）。
            #   所以这里用 echo ... >&2，不能用 log()（log 走 stdout）。
            #
            # 产物必须与 create 模式一致，否则过不了自己的 --verify：
            #   · 归档整份 data 卷（collect_members 用显式成员 www / system），与 create 一致
            #   · 同样附加 MANIFEST.txt 与 MySQL 转储
            #   · 排除项共用 EXCLUDE_ARGS
            # 唯一的区别是无法生成后自校验 —— 流已经吐出去了，读不回来
            collect_members
            [ ${#data_members[@]} -gt 0 ] || die "数据层 ${PERSIST_DATA_ROOT} 下没有任何持久化目录，无需备份"

            TMP_DIR=$(mktemp -d)
            write_manifest "${TMP_DIR}/MANIFEST.txt" '<stdout>'

            local -a extra=()
            if dump_databases "${TMP_DIR}/databases.sql"; then
                extra+=( databases.sql )
                echo '📦 [backup] 已附加 MySQL 一致性转储（databases.sql）' >&2
            else
                echo '📦 [backup] 未附加 MySQL 转储（MySQL 未运行或未安装）' >&2
            fi

            # 退出码处理与 create 模式一致（热备份下 tar 返回 1 可接受）。
            # 这里无法清理半成品 —— 流已经吐出去了，读不回来。
            # check_tar_rc 的告警走 stderr，不会污染 stdout 的 tar 流
            local rc=0
            tar --xattrs --xattrs-include='trusted.overlay.*' \
                "${EXCLUDE_ARGS[@]}" \
                -C "${PERSIST_DATA_ROOT}" -cz "${data_members[@]}" \
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
