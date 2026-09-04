#!/usr/bin/env bash
# ==============================================================================
#  [漂移检测] 在一次性容器中原样执行官方安装脚本，检测两类会破坏本项目的上游变更：
#
#   1) 目录漂移：安装产生的文件是否仍只落在已知的 overlay 持久化目录集合内。
#      落到集合之外 = 那部分数据不会被持久化（静默丢数据）。
#   2) 升级入口漂移：shared/scripts/patch-panel.sh 依赖的面板升级脚本集合
#      是否被上游改名 / 删除 / 新增。一旦漏掉新入口，面板就会绕过禁用逻辑
#      自行升级，破坏「面板版本由镜像决定」这条核心契约。
#
#  做法与 docs/persistence.md 的实测一致：装前快照 → 装 → 装后快照 → 比对。
#  注意前置软件包必须在「装前快照」之前装完，否则 apt 自身写入的文件会被
#  误算成宝塔的写入。
#
#  入参（环境变量）：
#    INSTALL_URL    官方安装脚本地址（必填）
#    BASE_IMAGE     基础镜像（默认 debian:12，与 stable/Dockerfile 的默认值一致）
#    OUT_MD         markdown 报告输出路径（默认 drift.md）
#    CRIT_FILE      关键标记输出路径，内容 1 表示存在关键漂移
#    TARGETS_OUT    升级入口集合输出路径（每行一个文件名，供基线比对）
#
#  退出码：安装失败等非预期错误为 1。检测到漂移不改变退出码，由 CRIT_FILE 表达，
#          由工作流据此决定是否提醒。
# ==============================================================================
set -euo pipefail

INSTALL_URL="${INSTALL_URL:?未指定 INSTALL_URL}"
BASE_IMAGE="${BASE_IMAGE:-debian:12}"
OUT_MD="${OUT_MD:-drift.md}"
CRIT_FILE="${CRIT_FILE:-drift-critical}"
TARGETS_OUT="${TARGETS_OUT:-drift-targets.txt}"

# 已知 overlay 持久化目录集合（须与 shared/scripts/init-mounts.sh 保持一致）
KNOWNS='www etc usr var root opt home srv'

# shared/scripts/patch-panel.sh disable_update() 的目标列表（须保持一致）
TARGETS='upgrade_panel.py
upgrade_panel_optimized.py
upgrade_py313.py
update_prep_script.sh
update_prep_script_v1.sh
upgrade_py313.sh
upgrade_py313_bundle.sh
local_fix.sh'

# patch-panel.sh 刻意保持原样的依赖 / 插件升级脚本（见其 disable_update 注释：
# 「其余升级脚本（gevent / flask / 防火墙 / 流量统计）保持原样」）。
# 它们升级的是 Python 库与插件、不碰面板程序版本，不破坏「版本由镜像决定」，
# 不应被当成新增升级入口误报
EXEMPT='upgrade_gevent.sh
upgrade_flask.sh
upgrade_firewall.py'

# 内容分类的静态特征（启发式，仅作报告提示，不做安全判定）
# 正向上游特征难跟上宝塔变化，故绝不据其自动豁免：命中②也只转人工确认，
# 宁可多一次人工、不可静默放过（误豁免 = 面板自更新、破坏版本契约）
# ① 面板自身升级：命中任一 → 记为「疑似面板升级入口」，转人工确认
PANEL_UPDATE_SIGNALS='panel_version|update_panel|updateLinux|/www/server/panel/class|更新面板|面板升级|安装面板'
# ② 依赖 / 插件升级：命中仅作提示，仍转人工确认（确认后加入 EXEMPT）
DEP_PLUGIN_SIGNALS='pyenv/bin/pip|pip3? install|panel/plugin|gevent|flask|防火墙|流量统计'

# 隐藏升级入口的内容特征（比 PANEL_UPDATE_SIGNALS 更紧，专抓名字不带
# upgrade/update 前缀、却会触发面板升级的脚本，如 local_fix.sh：下载 update6.sh
# 把面板升到最新版）。这类入口会被文件名模式漏掉，必须靠内容特征兜底
HIDDEN_SIGNALS='update6\.sh|将面板升级|升级至最新|upgrade_panel'

PANEL_SCRIPT_DIR=/www/server/panel/script
AUTO_UPDATE_PL=/www/server/panel/data/autoUpdate.pl
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

is_target() {
    local n="$1" t
    # shellcheck disable=SC2086
    for t in $TARGETS; do [ "$t" = "$n" ] && return 0; done
    return 1
}

is_exempt() {
    local n="$1" e
    # shellcheck disable=SC2086
    for e in $EXEMPT; do [ "$e" = "$n" ] && return 0; done
    return 1
}

# 对未纳入补丁目标的候选脚本做内容分类（仅作提示，安全判定一律转人工）：panel / dep / unknown
classify_entry() {
    local name="$1" content
    content=$(docker exec "$CNAME" cat "${PANEL_SCRIPT_DIR}/${name}" 2>/dev/null || true)
    if printf '%s\n' "$content" | grep -Eq "$PANEL_UPDATE_SIGNALS"; then
        echo panel
    elif printf '%s\n' "$content" | grep -Eq "$DEP_PLUGIN_SIGNALS"; then
        echo dep
    else
        echo unknown
    fi
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
: > "$TARGETS_OUT"
echo 0 > "$CRIT_FILE"

# ------------------------------------------------------------------------------
#  0. 起容器并装前置包（清单与 shared/build/base.sh install_packages 一致）
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
    net-tools iproute2 iputils-ping dnsutils traceroute \
    curl wget \
    tar xz-utils zip unzip gzip bzip2 p7zip-full cpio rsync \
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

SECRET="bt-probe-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
log '执行官方安装脚本（参数与 shared/build/panel.sh 保持一致）'
docker exec "$CNAME" bash -c "cd /root && wget -q -O install.sh '${INSTALL_URL}'" \
    || die "下载安装脚本失败：${INSTALL_URL}"

# 参数故意不加引号：官方脚本要求逐个参数传入（与 panel.sh 一致）
docker exec "$CNAME" bash -c \
    "cd /root && bash install.sh -y -P 8888 -u baota -p '${SECRET}' --safe-path '${SECRET}' --ssl-disable" \
    || { docker exec "$CNAME" bash -c "tail -n 80 '${INSTALL_LOG}'" >&2 || true
         die '官方安装脚本执行失败'; }
log '安装完成，开始比对'

AFTER=$(snapshot)

declare -A BEFORE_MAP=() AFTER_MAP=()
while read -r d n; do [ -n "${d:-}" ] && BEFORE_MAP["$d"]="$n"; done <<< "$BEFORE"
while read -r d n; do [ -n "${d:-}" ] && AFTER_MAP["$d"]="$n"; done <<< "$AFTER"

{
    echo '### 1. 目录漂移检测'
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
#  2. 升级入口脚本集合检测
# ------------------------------------------------------------------------------
if docker exec "$CNAME" bash -c "test -d '${PANEL_SCRIPT_DIR}'" >/dev/null 2>&1; then
    mapfile -t ENTRIES < <(docker exec -e "SD=${PANEL_SCRIPT_DIR}" -i "$CNAME" bash -s <<'EOS'
for f in "$SD"/*; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "$(basename "$f")" "$(sha256sum "$f" | awk '{print $1}')"
done
EOS
)

    declare -A FOUND=()
    for line in "${ENTRIES[@]:-}"; do
        [ -n "${line:-}" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        [ -n "${1:-}" ] && [ -n "${2:-}" ] && FOUND["$1"]="$2"
    done

    MISSING=()
    # shellcheck disable=SC2086
    for t in $TARGETS; do
        [ -z "${FOUND[$t]:-}" ] && MISSING+=("$t")
    done

    # 先收集全部文件名再落盘，避免管道把各分类数组的赋值困在子 shell 里
    ALL_NAMES=()
    ADDED_PANEL=()
    UNKNOWN=()
    EXEMPT_FOUND=()
    HIDDEN_PANEL=()
    declare -A HINT=()
    for name in "${!FOUND[@]}"; do
        ALL_NAMES+=("$name")
        is_target "$name" && continue
        if is_exempt "$name"; then
            EXEMPT_FOUND+=("$name")
            continue
        fi
        case "$name" in
            upgrade*.py|upgrade*.sh|update*.sh|update*.py) ;;
            *) continue ;;
        esac
        kind=$(classify_entry "$name")
        case "$kind" in
            panel)   ADDED_PANEL+=("$name") ;;
            *)       UNKNOWN+=("$name"); HINT["$name"]="$kind" ;;
        esac
    done

    # 隐藏入口扫描：名字不带 upgrade/update 前缀、却仍含面板升级触发特征的脚本。
    # 仅按文件名模式（upgrade*/update*）会漏掉这类入口（如 local_fix.sh 会下载
    # update6.sh 把面板升到最新版），必须靠内容特征兜底，否则面板仍可绕过禁用逻辑
    # 自行升级。已知依赖 / 插件升级脚本（gevent / flask / 防火墙）不含这些特征，不误报。
    for name in "${!FOUND[@]}"; do
        is_target "$name" && continue
        is_exempt "$name" && continue
        case "$name" in upgrade*|update*) continue ;; esac
        if docker exec "$CNAME" bash -c "grep -qE '$HIDDEN_SIGNALS' '${PANEL_SCRIPT_DIR}/${name}'" 2>/dev/null; then
            HIDDEN_PANEL+=("$name")
        fi
    done
    if [ ${#ALL_NAMES[@]} -gt 0 ]; then
        printf '%s\n' "${ALL_NAMES[@]}" | sort -u > "$TARGETS_OUT"
    fi

    {
        echo
        echo '### 2. 升级入口检测'
        echo
        echo '| `patch-panel.sh` 目标 | 状态 |'
        echo '|---|---|'
    } >> "$OUT_MD"
    # shellcheck disable=SC2086
    for t in $TARGETS; do
        if [ -n "${FOUND[$t]:-}" ]; then
            printf '| `%s` | ✅ 存在（`%s…`） |\n' "$t" "${FOUND[$t]:0:12}" >> "$OUT_MD"
        else
            printf '| `%s` | ❌ 上游已不存在 |\n' "$t" >> "$OUT_MD"
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        warn "上游已移除升级入口：${MISSING[*]}"
        CRIT=1
    fi

    if [ ${#EXEMPT_FOUND[@]} -gt 0 ]; then
        {
            echo
            echo '✅ 已知豁免的依赖 / 插件升级脚本（设计上保持原样，不视为漂移）：'
            echo
            for n in "${EXEMPT_FOUND[@]}"; do echo "- \`$n\`"; done
        } >> "$OUT_MD"
    fi

    if [ ${#ADDED_PANEL[@]} -gt 0 ]; then
        {
            echo
            echo '❌ 内容判定为「面板自身升级入口」，但不在 `patch-panel.sh` 的 targets：'
            echo
            for n in "${ADDED_PANEL[@]}"; do echo "- \`$n\`"; done
            echo
            echo '需加入 targets，否则面板会绕过禁用逻辑自行升级，破坏「版本由镜像决定」的约定。'
        } >> "$OUT_MD"
        warn "未纳入补丁的面板升级入口：${ADDED_PANEL[*]}"
        CRIT=1
    fi

    if [ ${#UNKNOWN[@]} -gt 0 ]; then
        {
            echo
            echo '⚠️ 未纳入补丁目标与 EXEMPT 的升级脚本（需人工确认，宁误报不漏报）：'
            echo
            for n in "${UNKNOWN[@]}"; do
                echo "- \`$n\`"
                if [ "${HINT[$n]:-}" = "dep" ]; then
                    echo '    （内容命中依赖 / 插件升级特征，疑似依赖或插件升级；确认后加入 EXEMPT 而非 targets）'
                fi
            done
            echo
            echo '确认是依赖 / 插件升级 → 加入本脚本的 EXEMPT；是面板升级入口 → 加入 patch-panel.sh 的 targets。'
        } >> "$OUT_MD"
        warn "需人工确认的升级脚本：${UNKNOWN[*]}"
        CRIT=1
    fi

    if [ ${#HIDDEN_PANEL[@]} -gt 0 ]; then
        {
            echo
            echo '🚨 隐藏的面板升级入口（名字不带 upgrade/update 前缀，却含升级触发特征，如 local_fix.sh）：'
            echo
            for n in "${HIDDEN_PANEL[@]}"; do echo "- \`$n\`"; done
            echo
            echo '这类入口会被文件名模式漏掉，必须加入本脚本的 TARGETS（与 patch-panel.sh 的 UPDATE_TARGETS 保持一致）。'
        } >> "$OUT_MD"
        warn "隐藏的面板升级入口：${HIDDEN_PANEL[*]}"
        CRIT=1
    fi
else
    {
        echo
        echo '### 2. 升级入口检测'
        echo
        echo "❌ 未找到面板脚本目录 \`${PANEL_SCRIPT_DIR}\`，上游路径可能已变更。"
        echo
        echo '   `shared/scripts/patch-panel.sh` 会在此直接失败，必须更新路径。'
    } >> "$OUT_MD"
    warn "未找到 ${PANEL_SCRIPT_DIR}"
    CRIT=1
fi

# ------------------------------------------------------------------------------
#  3. 自动更新标记（信息项）
# ------------------------------------------------------------------------------
if docker exec "$CNAME" bash -c "test -f '${AUTO_UPDATE_PL}'" >/dev/null 2>&1; then
    AUTO_FLAG='安装后存在（补丁会在启动期删除，属正常）'
else
    AUTO_FLAG='安装后不存在（上游默认未开启自动更新）'
fi
{
    echo
    echo '### 3. 自动更新标记'
    echo
    echo "\`${AUTO_UPDATE_PL}\`：${AUTO_FLAG}"
} >> "$OUT_MD"

# ------------------------------------------------------------------------------
#  结论
# ------------------------------------------------------------------------------
{
    echo
    echo '### 结论'
    echo
    if [ "$CRIT" -eq 0 ]; then
        echo '✅ 未检测到会破坏本项目的上游变更。'
    else
        echo '❌ 检测到关键漂移，需人工介入（详见上文）。'
    fi
} >> "$OUT_MD"

echo "$CRIT" > "$CRIT_FILE"
log "检测完成（关键漂移：${CRIT}），报告：${OUT_MD}"
