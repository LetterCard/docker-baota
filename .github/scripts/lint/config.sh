#!/bin/bash
# ==============================================================================
#  配置真源一致性：shared/conf/defaults.env vs 各脚本里的兜底副本
#
#  为什么要有这道检查
#    defaults.env 是运行期配置的真源，但 init.sh / healthcheck.sh / backup.sh /
#    services.sh / entrypoint.sh 各自保留了一份 VAR="${VAR:-默认值}" 兜底（防止
#    拿不到真源时脚本全裸）。真源改了而某份兜底没跟着改，表现是「构建期按旧值
#    建目录 / 运行期按旧值算路径」—— 这类漂移静默、且现象离原因很远。
#
#    历史上真出过一次：services.sh 的目录列表兜底带 www、真源不带，结果镜像里
#    凭空多出 data/system/www 空目录（用户会以为站点数据在那）。改真源的人
#    不会想到还要改另外 4 个文件 —— 所以这个检查不是洁癖，是补上次事故的漏洞。
#
#  检查方式
#    对每个变量，用同样的方式从真源与各脚本里提取默认值，逐项比对。
#    只比对「两边都写了兜底」的变量：某个脚本选择不设兜底、完全依赖真源，
#    是合法设计，不参与比对。
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

TRUTH=shared/conf/defaults.env
FILES=(
    shared/scripts/init.sh
    shared/scripts/healthcheck.sh
    shared/scripts/backup.sh
    shared/build/services.sh
    shared/scripts/entrypoint.sh
)
VARS=(
    PERSIST_DATA_ROOT
    PANEL_STATE_ROOT
    PERSIST_SYSTEM_ROOT
    PERSIST_SYSTEM_DIRS
    CRITICAL_DIRS
    WWW_DATA_SUBDIRS
    PANEL_STATE_SUBDIRS
    # 下面三个也有兜底副本：磁盘水位在 healthcheck.sh，快照保留份数在
    # entrypoint.sh。漏掉它们等于这两处抄错了没人管
    DISK_MIN_AVAIL_MB
    DISK_MAX_USED_PCT
    AUTO_BACKUP_KEEP
)

[ -f "$TRUTH" ] || { echo "  FAIL 真源不存在：$TRUTH"; exit 1; }

# 从 VAR="${VAR:-默认值}" 里取出「默认值」一段；取不到则输出空
extract_default() {
    local file="$1" var="$2"
    grep -m1 "^${var}=" "$file" 2>/dev/null \
        | sed -e "s/^${var}=//" -e 's/^"[^"]*:-//' -e 's/}"$//' || true
}

rc=0
for v in "${VARS[@]}"; do
    want=$(extract_default "$TRUTH" "$v")
    [ -n "$want" ] || continue

    for f in "${FILES[@]}"; do
        [ -f "$f" ] || continue
        got=$(extract_default "$f" "$v")
        [ -n "$got" ] || continue

        if [ "$got" != "$want" ]; then
            # 变量一律写成 ${x}：bash 的全角字符也算变量名的一部分，
            # 写成 "$f：" 会被当成变量名 f：，真出漂移时报错信息毫无用处
            echo "  FAIL ${f}：${v} 兜底值『${got}』≠ 真源『${want}』"
            rc=1
        fi
    done
done

if [ "$rc" -eq 0 ]; then
    echo "  ok  各脚本兜底值与 $(basename "$TRUTH") 一致（${#VARS[@]} 个变量）"
else
    echo '  改真源 shared/conf/defaults.env 时，请同步上面列出的兜底副本'
fi
exit "$rc"
