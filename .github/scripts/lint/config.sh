#!/bin/bash
# ==============================================================================
#  配置真源唯一性：defaults.env 之外不许再有默认值副本
#
#  为什么：defaults.env 是运行期配置的唯一真源。只要还有脚本留一份
#    `VAR="${VAR:-默认值}"` 兜底，就会出现「改真源漏改副本」的漂移，而且现象离
#    原因很远 —— 例如目录清单一边带 www、一边不带，镜像里凭空多出空目录。
#    所以约定：脚本只用真源，读不到就明确报错或明确跳过。
#
#  检查方式：对每个受管变量，在脚本里搜带非空默认值的 `${VAR:-x}` / `${VAR-x}`，
#    出现即失败（真源自身除外）。新增受管变量要同步加进下面的 VARS。
#    `${VAR:-}`（空默认）是空值保护、不是默认值副本，允许。
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

TRUTH=image/conf/defaults.env
FILES=(
    image/scripts/init.sh
    image/scripts/entrypoint.sh
    image/scripts/backup.sh
    image/scripts/healthcheck.sh
    image/scripts/guard.sh
    image/build/services.sh
    .github/scripts/check/core.sh
    .github/scripts/check/degrade.sh
    .github/scripts/check/upgrade.sh
    .github/scripts/check/published.sh
    .github/scripts/drift/install.sh
)
VARS=(
    PERSIST_DATA_ROOT
    PERSIST_SYSTEM_ROOT
    PERSIST_SYSTEM_DIRS
    WWW_DATA_SUBDIRS
    WWW_OPTIONAL_SUBDIRS
    META_VERSION_FILE
    META_BOOT_FILE
    PANEL_STATE_ROOT
    PANEL_STATE_SUBDIRS
    CRITICAL_DIRS
    DISK_MIN_AVAIL_MB
    DISK_MAX_USED_PCT
    AUTO_SNAPSHOT_KEEP
)

[ -f "$TRUTH" ] || { echo "  FAIL 真源不存在：$TRUTH"; exit 1; }

# 真源必须为每个受管变量提供默认值（否则脚本拿到空值，行为不可预期）
rc=0
for v in "${VARS[@]}"; do
    grep -qE "^${v}=\"\\\$\{${v}:-.+\}\"$" "$TRUTH" \
        || { echo "  FAIL 真源缺少默认值：${TRUTH} 里的 ${v}"; rc=1; }
done

# 其它脚本不许再写默认值副本
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    for v in "${VARS[@]}"; do
        # 只认「非空默认值」：`${VAR:-}` 这种空值保护放行
        if grep -nE "\\\$\{${v}:?-[^}]" "$f" > /dev/null 2>&1; then
            # 变量一律写成 ${x}：bash 会把全角冒号当成变量名的一部分
            echo "  FAIL ${f}：${v} 又写了默认值副本（真源只能是 ${TRUTH}）"
            grep -nE "\\\$\{${v}:?-[^}]" "$f" | head -3 | sed 's/^/       /'
            rc=1
        fi
    done
done

if [ "$rc" -eq 0 ]; then
    echo "  ok  配置真源唯一（${#VARS[@]} 个变量只在 $(basename "$TRUTH") 里定义默认值）"
else
    echo '  改配置请只改 image/conf/defaults.env，脚本里不要再写兜底副本'
fi
exit "$rc"
