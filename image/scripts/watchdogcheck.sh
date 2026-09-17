#!/usr/bin/env bash
# 验证「任务看门狗 vs shim 改名 python-real」修复是否生效
# 在构建推送后的容器内运行：
#   /baota/watchdogcheck.sh          静态检查补丁是否在位
#   /baota/watchdogcheck.sh --watch  静态检查 + 监听日志 120s，期间到面板装任意软件
#
# 静态：面板主程序与守卫基准副本都已含 cmdline 补丁；
# 监听：窗口内 error.log 不再刷「不是面板任务」、script_logs 有新条目即修复生效。
set -euo pipefail

panel_dir="${PANEL_DIR:-/www/server/panel}"
origin_dir="/baota/origin"
err_file="${panel_dir}/logs/error.log"
script_log_dir="${panel_dir}/logs/script_logs"

if [ ! -d "$panel_dir" ]; then
    echo "请在【容器内】运行：docker exec baota /baota/watchdogcheck.sh"
    exit 2
fi

# 补丁后的看门狗判定才会出现的子串（未补丁时只有 'not in comm:'）
marker="not in cmdline"

patched=0
for f in "${panel_dir}"/BT-P*; do
    [ -f "$f" ] || continue
    if grep -qF "$marker" "$f"; then patched=1; fi
done
origin_patched=0
for f in "${origin_dir}"/BT-P*; do
    [ -f "$f" ] || continue
    if grep -qF "$marker" "$f"; then origin_patched=1; fi
done

echo "面板主程序补丁:   $([ "$patched" = 1 ] && echo OK || echo 缺失)"
echo "守卫基准副本补丁: $([ "$origin_patched" = 1 ] && echo OK || echo 缺失)"

if [ "$patched" != 1 ]; then
    echo "FAIL: 看门狗补丁未生效，安装软件仍会失败"
    exit 1
fi

# shim 改名核对：解释器应指向 shim，且 python-real 存在（看门狗冲突的前提）
py="${panel_dir}/pyenv/bin/python3"
if [ -e "$py" ]; then
    link="$(readlink -f "$py" 2>/dev/null || true)"
    case "$link" in
        *shim*) echo "解释器入口: shim（守卫生效） OK" ;;
        *)      echo "解释器入口: $link（未走 shim，看门狗冲突前提不成立，但补丁无害）" ;;
    esac
    [ -e "${panel_dir}/pyenv/bin/python-real" ] \
        && echo "真解释器: python-real 存在 OK" \
        || echo "WARN: python-real 不存在"
fi

if [ "${1:-}" != "--watch" ]; then
    echo "静态检查通过。做端到端验证请加 --watch，再到面板装个软件。"
    exit 0
fi

secs="${2:-120}"
echo "监听 ${secs}s：请在面板里安装任意软件（nginx / 环境库…）"
echo "判定：窗口内 error.log 不再刷「不是面板任务」且 script_logs 有新增 = 修复生效"

start="$(date +%s)"
bad=0
while [ "$(( $(date +%s) - start ))" -lt "$secs" ]; do
    if grep -q "不是面板任务" "$err_file" 2>/dev/null; then bad=1; fi
    sleep 3
done

if [ "$bad" = 1 ]; then
    echo "FAIL: 窗口内仍出现「不是面板任务」，看门狗在误杀任务"
    exit 1
fi
if [ -d "$script_log_dir" ] \
   && [ -n "$(find "$script_log_dir" -newermt "-${secs} seconds" 2>/dev/null)" ]; then
    echo "PASS: 窗口内 script_logs 有新增，且未出现误杀日志 —— 修复端到端生效"
else
    echo "提示: 未检测到 script_logs 新增（窗口内可能没装东西）；静态补丁已确认在位。"
fi
