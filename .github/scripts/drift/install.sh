#!/usr/bin/env bash
# ==============================================================================
#  在一次性容器中原样跑官方安装脚本，只检测一项会破坏持久化的上游变更：
#  **目录漂移** —— 安装产生的文件是否仍落在已知持久化目录集合内（落到集合
#  外 = 那部分数据不会被持久化）。
#
#  ★ 为什么只检测这一项（不对抗上游）：「面板升级入口」「代码级更新旁路」要
#    逐项跟踪上游脚本名与执行路径，永远跟不完且不影响数据安全 —— 面板内更新
#    不生效已由 image/scripts/guard.sh 在执行入口兜住。
#
#  做法：装前快照 → 装 → 装后快照 → 比对。
#  红线：前置包必须在「装前快照」之前装完，否则 apt 的写入会被误算成宝塔的。
#
#  入参：INSTALL_URL（必填）/ BASE_IMAGE / OUT_MD / CRITICAL_FILE
#  退出码：安装失败等为 1；检测到漂移不改退出码，由 CRITICAL_FILE 表达
# ==============================================================================
set -euo pipefail

INSTALL_URL="${INSTALL_URL:?未指定 INSTALL_URL}"
BASE_IMAGE="${BASE_IMAGE:-debian:12}"
OUT_MD="${OUT_MD:-drift.md}"
CRITICAL_FILE="${CRITICAL_FILE:-drift-critical}"

INSTALL_LOG=/tmp/install.log

CONTAINER="baota-drift-$$"
CRITICAL=0

log()  { echo "🔭 [drift] $*"; }
warn() { echo "⚠️ [drift][WARN] $*" >&2; }
die()  { echo "❌ [drift][ERROR] $*" >&2; exit 1; }

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

in_known_dirs() {
    local d="$1" k
    # shellcheck disable=SC2086
    for k in $KNOWN_DIRS; do [ "$k" = "$d" ] && return 0; done
    return 1
}

# 统计每个顶层目录的文件数（排除虚拟文件系统与临时目录）
count_top_dirs() {
    docker exec -i "$CONTAINER" bash -s <<'EOS'
for d in /*; do
    [ -d "$d" ] || continue
    case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
    n=$(find "$d" -xdev -type f 2>/dev/null | wc -l | tr -d ' ')
    printf '%s %s\n' "${d#/}" "$n"
done
EOS
}

# /www 是按子路径分别处理的（server 走 overlay、wwwroot/backup/server/data 等走
# bind、wwwlogs 按设计不持久化），顶层文件数没法表达这件事 —— 单独看它的子目录
www_subdirs() {
    docker exec "$CONTAINER" bash -c \
        'find /www -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort' || true
}

# ------------------------------------------------------------------------------
#  声明清单**从 defaults.env 派生**，不另抄一份：抄一份必然漂移（那边加了数据
#  目录、这边还在用旧清单 → 新目录每次被报成关键漂移，或反过来漏报）。
#    KNOWN_DIRS           顶层目录 = PERSIST_SYSTEM_DIRS 里不含 / 的项。
#                         ★ 刻意不含 www：算进来会把「新出现的 /www 子路径」一并放过
#    WWW_PERSIST_SUBDIRS  /www 一级子目录 = PERSIST_SYSTEM_DIRS 的 www/*
#                         + WWW_DATA_SUBDIRS + WWW_OPTIONAL_SUBDIRS
#    WWW_VOLATILE_SUBDIRS 按设计不持久化的 /www 子路径（本文件定义，运行期不读：
#                         列的是上游落点，不该固化成项目配置 —— 见「不对抗上游」）
# ------------------------------------------------------------------------------
DEFAULTS_ENV="${DEFAULTS_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/image/conf/defaults.env}"
# 与 check/lib.sh 的 read_default **同名不同义**：那一份会展开嵌套引用（那边要取
# PERSIST_SYSTEM_ROOT 这类引用别人的变量），这一份不展开 —— 本脚本只取
# PERSIST_SYSTEM_DIRS / WWW_*_SUBDIRS 这些不含引用的清单。
# 显式区分开：同名不同实现是最难发现的一类坑，哪天这里要取嵌套引用的变量，
# 直接换成 lib.sh 的展开版，不要在本文件里再写第二份。
read_raw_default() { sed -n "s/^$1=\"\${$1:-\(.*\)}\"$/\1/p" "$DEFAULTS_ENV" | head -n 1; }

PERSIST_SYSTEM_DIRS=$(read_raw_default PERSIST_SYSTEM_DIRS)
WWW_DATA_SUBDIRS=$(read_raw_default WWW_DATA_SUBDIRS)
WWW_OPTIONAL_SUBDIRS=$(read_raw_default WWW_OPTIONAL_SUBDIRS)
[ -n "$PERSIST_SYSTEM_DIRS" ] && [ -n "$WWW_DATA_SUBDIRS" ] \
    || die "无法从 ${DEFAULTS_ENV} 解析 PERSIST_SYSTEM_DIRS / WWW_DATA_SUBDIRS"

# shellcheck disable=SC2086
KNOWN_DIRS=$(printf '%s\n' $PERSIST_SYSTEM_DIRS | grep -v / | tr '\n' ' ')
# 可选模块目录也要算进「已被持久化覆盖」：它虽然按需出现，但一旦装了就是用户数据
# shellcheck disable=SC2086
WWW_PERSIST_SUBDIRS=$(
    {
        printf '%s\n' $PERSIST_SYSTEM_DIRS | grep '^www/'
        printf '%s\n' $WWW_DATA_SUBDIRS
        printf '%s\n' $WWW_OPTIONAL_SUBDIRS
    } | sed -e 's#^www/##' -e 's#/.*##' | sort -u | tr '\n' ' '
)


# 上游落点清单：上游新增可再生目录时，把目录名加进来即可（否则会被报成关键漂移）
WWW_VOLATILE_SUBDIRS='wwwlogs .Recycle_bin Recycle_bin php_session panel-static monitor_data'

: > "$OUT_MD"
echo 0 > "$CRITICAL_FILE"

# ------------------------------------------------------------------------------
#  0. 起容器并装前置包
#  清单取 base.sh install_packages 的「基础系统」部分，刻意不含编译工具链与
#  LNMP dev 库：漂移检测只关心「装完往哪些顶层目录写」，而工具链不新增顶层
#  目录、只让 /usr 多几万个文件，装上它纯属多花几分钟构建时间。
#  同理不含 logrotate —— 它随「日志体积防线」一起从 base.sh 移除了，这里若
#  留着，被测环境就与真实镜像不一致（漂移检测的前提是「装的东西一致」）
# ------------------------------------------------------------------------------
docker run -d --name "$CONTAINER" --privileged "$BASE_IMAGE" sleep infinity >/dev/null
log "已启动一次性容器（${BASE_IMAGE}）"

docker exec -i "$CONTAINER" bash -s <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates \
    systemd systemd-sysv dbus dbus-user-session \
    cron rsyslog \
    openssh-server \
    procps psmisc lsof htop \
    net-tools iproute2 iputils-ping dnsutils \
    curl wget \
    tar xz-utils zip unzip gzip bzip2 rsync \
    lsb-release sudo \
    busybox-static \
    vim-tiny less file
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOS
log '前置软件包已就绪'

# ------------------------------------------------------------------------------
#  1. 目录漂移检测
# ------------------------------------------------------------------------------
WWW_BEFORE=$(www_subdirs)
BEFORE=$(count_top_dirs)

log '执行官方安装脚本（参数与 image/build/panel.sh 保持一致）'
docker exec "$CONTAINER" bash -c "cd /root && wget -q -O install.sh '${INSTALL_URL}'" \
    || die "下载安装脚本失败：${INSTALL_URL}"

# 参数故意不加引号：官方脚本要求逐个参数传入（与 panel.sh 一致）
docker exec "$CONTAINER" bash -c \
    "cd /root && bash install.sh -y --ssl-disable" \
    || { docker exec "$CONTAINER" bash -c "tail -n 80 '${INSTALL_LOG}'" >&2 || true
         die '官方安装脚本执行失败'; }
log '安装完成，开始比对'

AFTER=$(count_top_dirs)

declare -A BEFORE_MAP=() AFTER_MAP=()
while read -r d n; do [ -n "${d:-}" ] && BEFORE_MAP["$d"]="$n"; done <<< "$BEFORE"
while read -r d n; do [ -n "${d:-}" ] && AFTER_MAP["$d"]="$n"; done <<< "$AFTER"

{
    echo '### 目录漂移检测'
    echo
    echo "> 安装脚本：\`${INSTALL_URL}\`"
    echo
    echo '| 顶层目录 | 安装前 | 安装后 | 新增 | 状态 |'
    echo '|---|---:|---:|---:|---|'
} >> "$OUT_MD"

DIRS=$(printf '%s\n%s\n' "$BEFORE" "$AFTER" | awk '{print $1}' | sort -u)
# shellcheck disable=SC2086
for d in $DIRS; do
    b="${BEFORE_MAP[$d]:-0}"
    a="${AFTER_MAP[$d]:-0}"
    delta=$(( a - b ))
    [ "$delta" -gt 0 ] || continue
    if in_known_dirs "$d"; then
        printf '| `/%s` | %s | %s | %s | ✅ 已被持久化覆盖 |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    elif [ "$d" = 'www' ]; then
        # /www 的子路径各有归属，顶层计数没有意义，交给下面的子目录比对
        printf '| `/%s` | %s | %s | %s | ℹ️ 按子路径处理（见下表） |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    else
        printf '| `/%s` | %s | %s | %s | ❌ **未覆盖，会静默丢数据** |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
        warn "未覆盖的写入目录：/${d}（新增 ${delta} 个文件）"
        CRITICAL=1
    fi
done

# /www 的子目录漂移：新出现的子路径如果不在声明清单里，按关键漂移报出来
WWW_AFTER=$(www_subdirs)
{
    echo
    echo '| `/www` 子目录 | 状态 |'
    echo '|---|---|'
} >> "$OUT_MD"
for sub in $WWW_AFTER; do
    case " $(printf '%s' "$WWW_BEFORE" | tr '\n' ' ') " in
        *" ${sub} "*) continue ;;   # 装之前就有：上游行为没变
    esac
    state=''
    # shellcheck disable=SC2086
    for p in $WWW_PERSIST_SUBDIRS; do
        [ "$p" = "$sub" ] && state='✅ 已在声明清单内（持久化）'
    done
    # shellcheck disable=SC2086
    for p in $WWW_VOLATILE_SUBDIRS; do
        [ "$p" = "$sub" ] && state='⚪ 按设计不持久化（重建即清空）'
    done
    if [ -n "$state" ]; then
        printf '| `www/%s` | %s |\n' "$sub" "$state" >> "$OUT_MD"
    else
        printf '| `www/%s` | ❌ **新出现且未声明，需人工确认怎么持久化** |\n' "$sub" >> "$OUT_MD"
        warn "未声明的 /www 子目录：/www/${sub}"
        CRITICAL=1
    fi
done

# ------------------------------------------------------------------------------
#  结论
# ------------------------------------------------------------------------------
{
    echo
    echo '### 结论'
    echo
    if [ "$CRITICAL" -eq 0 ]; then
        echo '✅ 未检测到会破坏持久化的上游变更（数据仍全部落在持久化目录内）。'
    else
        echo '❌ 检测到关键漂移，需人工介入（详见上文）。'
    fi
} >> "$OUT_MD"

echo "$CRITICAL" > "$CRITICAL_FILE"
log "检测完成（关键漂移：${CRITICAL}），报告：${OUT_MD}"
