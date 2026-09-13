#!/bin/bash
# ==============================================================================
#  配置真源唯一性：defaults.env 之外不许再有默认值副本
#
#  为什么要有这道检查
#    image/conf/defaults.env 是运行期配置的唯一真源（镜像构建期 COPY 到
#    /baota/defaults.env）。历史上各脚本还各留了一份 `VAR="${VAR:-默认值}"`
#    兜底，于是「改真源漏改副本」的漂移反复出现：曾经 services.sh 的目录列表
#    带 www、真源不带，镜像里凭空多出 data/system/www 空目录。
#
#    现在改成：脚本只用真源，读不到就明确报错/明确跳过（见各脚本头部注释）。
#    本检查负责守住这条约定 —— 谁再写回兜底副本，CI 立刻红。
#
#  检查方式
#    对每个受管变量，在脚本里搜「带非空默认值」的形式（`${VAR:-x}` / `${VAR-x}`）：
#    出现即失败（真源 defaults.env 自身除外）。
#    `${VAR:-}`（空默认）是「取不到就当空」的空值保护，不是默认值副本，允许。
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
)
VARS=(
    PERSIST_DATA_ROOT
    PERSIST_SYSTEM_ROOT
    PERSIST_SYSTEM_DIRS
    WWW_DATA_SUBDIRS
    PANEL_STATE_ROOT
    PANEL_STATE_SUBDIRS
    CRITICAL_DIRS
    DISK_MIN_AVAIL_MB
    DISK_MAX_USED_PCT
    AUTO_BACKUP_KEEP
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
