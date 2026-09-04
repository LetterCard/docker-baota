#!/usr/bin/env bash
# ==============================================================================
#  下载并详细分析两个通道的宝塔面板升级入口脚本
#
#  目的：用项目自己的安装法（debian:12 + 官方脚本原样执行）在一次性容器里
#  真装 stable（12.x）与 release（官方服务端决定的正式版，实测 13.0.0），
#  抓取 /www/server/panel/script/ 的全量清单与升级脚本内容，用于核对本项目
#  patch-panel.sh 的 UPDATE_TARGETS / TARGETS 是否完整、正确，以及排查是否存在
#  「非 upgrade/update 前缀」的隐藏自更新入口。
#
#  用法：bash .github/scripts/drift-check/analyze-versions.sh [stable|release]
#  输出：/tmp/analyze-12.txt（stable）与 /tmp/analyze-13.txt（release）
# ==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)" || exit 1
cd "$REPO_ROOT" || exit 1

S_URL=$(sed -n 's/^ARG INSTALL_URL=//p' stable/Dockerfile  | head -1 | tr -d '\r')
R_URL=$(sed -n 's/^ARG INSTALL_URL=//p' release/Dockerfile | head -1 | tr -d '\r')
[ -n "$S_URL" ] || { echo "::error::未能从 stable/Dockerfile 解析 INSTALL_URL"; exit 1; }
[ -n "$R_URL" ] || { echo "::error::未能从 release/Dockerfile 解析 INSTALL_URL"; exit 1; }

analyze() {
  local ch="$1" url="$2" out="$3"
  local c="baota-analyze-${ch}-$$"
  echo "===== [$ch] 启动容器，安装来源：${url} =====" >&2

  docker run -d --name "$c" --privileged debian:12 sleep infinity >/dev/null 2>&1
  docker exec -i "$c" bash -s <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y --no-install-recommends ca-certificates curl wget gnupg lsb-release >/dev/null 2>&1
EOS

  docker exec "$c" bash -c "cd /root && wget -q -O install.sh '${url}'" \
    || { echo "::error::[$ch] 下载安装脚本失败"; docker rm -f "$c" >/dev/null; return 1; }

  echo "===== [$ch] 执行官方安装（参数与 shared/build/panel.sh 一致） =====" >&2
  if ! docker exec "$c" bash -c \
      "cd /root && bash install.sh -y -P 8888 -u baota -p 'bt-probe-$$' --safe-path 'bt-probe-$$' --ssl-disable" \
      2>&1 | tail -n 5; then
    echo "::error::[$ch] 安装失败"; docker rm -f "$c" >/dev/null; return 1
  fi

  echo "===== [$ch] 抓取 script/ 详情 =====" >&2
  docker exec "$c" bash -s > "$out" <<'EOS'
PD=/www/server/panel
SD=$PD/script
echo "### panel version: $(cat $PD/data/version.pl 2>/dev/null || echo unknown)"
echo "### script/ 文件总数: $(ls -1 "$SD" 2>/dev/null | wc -l)"
echo
echo "===== FULL LISTING (size  name) ====="
ls -la "$SD" 2>/dev/null | awk 'NF>=9 {print $5, $9}' | sort -k2
echo
echo "===== 全目录内引用自更新机制的脚本（任意文件名，按项目信号 grep） ====="
grep -rlE 'panel_version|update_panel|UpdatePanel|autoUpdate|SetPanelUpdate|/www/server/panel/class' "$SD" 2>/dev/null \
  | sed "s#$SD/##" | sort
echo
echo "===== upgrade*/update* 前缀文件：头部 + 信号命中 ====="
for f in "$SD"/upgrade* "$SD"/update*; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  echo "----- $b ($(stat -c%s "$f") bytes) -----"
  head -40 "$f"
  echo
done
EOS

  docker rm -f "$c" >/dev/null
  echo "===== [$ch] 报告已写入 $out =====" >&2
}

# 可选参数：只分析单个通道（stable / release），便于分步执行与排查
ONLY="${1:-}"
run() {
  local ch="$1" url="$2" out="$3"
  [ -n "$ONLY" ] && [ "$ONLY" != "$ch" ] && return 0
  analyze "$ch" "$url" "$out"
}

run stable  "$S_URL" /tmp/analyze-12.txt
run release "$R_URL" /tmp/analyze-13.txt
echo "ALL DONE"
