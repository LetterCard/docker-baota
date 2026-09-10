#!/usr/bin/env bash
# ==============================================================================
#  [漂移检测] 在一次性容器中原样执行官方安装脚本，检测会破坏持久化的上游变更：
#
#   目录漂移：安装产生的文件是否仍只落在已知的 overlay 持久化目录集合内。
#    落到集合之外 = 那部分数据不会被持久化（静默丢数据）。
#
#  为什么只检测这一项：本项目的核心保证是「销毁容器重建后数据不丢」，而数据
#  落点就是唯一会影响这条保证的上游行为。曾经还检测「面板升级入口」与「代码级
#  更新旁路」——它们要求逐项跟踪上游脚本名、脚本内容乃至代码里的执行路径，与
#  上游内部实现强耦合、永远跟不完，且并不影响数据安全，已移除。
#
#  做法与 docs/persistence.md 的实测一致：装前快照 → 装 → 装后快照 → 比对。
#  注意前置软件包必须在「装前快照」之前装完，否则 apt 自身写入的文件会被
#  误算成宝塔的写入。
#
#  入参（环境变量）：
#    INSTALL_URL    官方安装脚本地址（必填）
#    BASE_IMAGE     基础镜像（默认 debian:12，与 dockerfile/12.0.0/Dockerfile 的默认值一致）
#    OUT_MD         markdown 报告输出路径（默认 drift.md）
#    CRIT_FILE      关键标记输出路径，内容 1 表示存在关键漂移
#
#  退出码：安装失败等非预期错误为 1。检测到漂移不改变退出码，由 CRIT_FILE 表达，
#          由工作流据此决定是否提醒。
# ==============================================================================
set -euo pipefail

INSTALL_URL="${INSTALL_URL:?未指定 INSTALL_URL}"
BASE_IMAGE="${BASE_IMAGE:-debian:12}"
OUT_MD="${OUT_MD:-drift.md}"
CRIT_FILE="${CRIT_FILE:-drift-critical}"

# 已知 overlay 持久化目录集合（真源是 shared/conf/defaults.env 的
# PERSIST_SYSTEM_DIRS）。这里刻意不含 www：面板 /www 已改为按子目录 bind，
# 不再整层 overlay —— 把 www 算进来，会让写到 /www/server/php、/www/server/mysql
# 的内容被误判成「已被持久化覆盖」，把真正的静默丢数据判成绿
KNOWNS='etc usr var root opt home srv'

INSTALL_LOG=/tmp/btpanel-install.log

CNAME="bt-drift-$$"
CRIT=0

log()  { echo "🔭 [drift] $*"; }
warn() { echo "⚠️ [drift][WARN] $*" >&2; }
die()  { echo "❌ [drift][ERROR] $*" >&2; exit 1; }

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

in_knowns() {
    local d="$1" k
    # shellcheck disable=SC2086
    for k in $KNOWNS; do [ "$k" = "$d" ] && return 0; done
    return 1
}

# 统计每个顶层目录的文件数（排除虚拟文件系统与临时目录）
snapshot() {
    docker exec -i "$CNAME" bash -s <<'EOS'
for d in /*; do
    [ -d "$d" ] || continue
    case "$d" in /proc|/sys|/dev|/run|/tmp) continue ;; esac
    n=$(find "$d" -xdev -type f 2>/dev/null | wc -l | tr -d ' ')
    printf '%s %s\n' "${d#/}" "$n"
done
EOS
}

: > "$OUT_MD"
echo 0 > "$CRIT_FILE"

# ------------------------------------------------------------------------------
#  0. 起容器并装前置包
#  清单取 base.sh install_packages 的「基础系统」部分，刻意不含编译工具链与
#  LNMP dev 库：漂移检测只关心「装完往哪些顶层目录写」，而工具链不新增顶层
#  目录、只让 /usr 多几万个文件，装上它纯属多花几分钟构建时间
# ------------------------------------------------------------------------------
docker run -d --name "$CNAME" --privileged "$BASE_IMAGE" sleep infinity >/dev/null
log "已启动一次性容器（${BASE_IMAGE}）"

docker exec -i "$CNAME" bash -s <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    locales tzdata ca-certificates \
    systemd systemd-sysv dbus dbus-user-session \
    cron logrotate rsyslog \
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
BEFORE=$(snapshot)

log '执行官方安装脚本（参数与 shared/build/panel.sh 保持一致）'
docker exec "$CNAME" bash -c "cd /root && wget -q -O install.sh '${INSTALL_URL}'" \
    || die "下载安装脚本失败：${INSTALL_URL}"

# 参数故意不加引号：官方脚本要求逐个参数传入（与 panel.sh 一致）
docker exec "$CNAME" bash -c \
    "cd /root && bash install.sh -y --ssl-disable" \
    || { docker exec "$CNAME" bash -c "tail -n 80 '${INSTALL_LOG}'" >&2 || true
         die '官方安装脚本执行失败'; }
log '安装完成，开始比对'

AFTER=$(snapshot)

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
    if in_knowns "$d"; then
        printf '| `/%s` | %s | %s | %s | ✅ 已被持久化覆盖 |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
    else
        printf '| `/%s` | %s | %s | %s | ❌ **未覆盖，会静默丢数据** |\n' "$d" "$b" "$a" "$delta" >> "$OUT_MD"
        warn "未覆盖的写入目录：/${d}（新增 ${delta} 个文件）"
        CRIT=1
    fi
done

# ------------------------------------------------------------------------------
#  结论
# ------------------------------------------------------------------------------
{
    echo
    echo '### 结论'
    echo
    if [ "$CRIT" -eq 0 ]; then
        echo '✅ 未检测到会破坏持久化的上游变更（数据仍全部落在持久化目录内）。'
    else
        echo '❌ 检测到关键漂移，需人工介入（详见上文）。'
    fi
} >> "$OUT_MD"

echo "$CRIT" > "$CRIT_FILE"
log "检测完成（关键漂移：${CRIT}），报告：${OUT_MD}"
