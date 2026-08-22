#!/usr/bin/env bash
# ============================================================
# 技能元信息（Skill Manifest，遵循 E 节规范）
#   name       : detect_bt_release
#   description: 检测宝塔官方最新版本号——stable 从 installStable_12.sh 解析（fail-closed），
#                release 从官方接口双源（updateLinux 主源 + get_version 兜底）获取并做 semver 校验（fail-closed）；
#                在每周/每月定时、push 或手动触发时调用；手动可经 --force-tag 覆盖。
#   version    : 1.0.0
#   owner      : shared（stable/release 共用同一份逻辑，workflow 各自引用）
#   triggers   : (a) 定时 cron（见 workflow schedule）
#                (b) push paths（workflow 白名单）
#                (c) 手动 workflow_dispatch（可传 inputs.version -> --force-tag）
#                (d) 被 check-version job 作为子流程调用
#   幂等性     : 仅做"版本解析"，不触碰 DockerHub；标签是否已存在由 workflow 单独判断。
#
# 输入（parameters）：
#   --mode stable|release   (required, enum) 版本来源模式
#   --force-tag x.y.z       (optional, string) 手动指定版本，跳过一切网络探测
#   --install-sh PATH       (optional, path) stable 模式本地安装脚本路径（用于 mock/离线测试）
#   --update-base PATH|URL  (optional) 覆盖稳定版更新包探测基址（默认官方 update/ 目录）；
#                           本地目录模式（/path 开头）：文件存在即视为该版本已发布（离线 mock 用）
#   --out FILE              (optional, path) 追加 "version=x.y.z" 到该文件（兼容 $GITHUB_OUTPUT）
#   --verbose               (optional, bool) 打印详细决策日志
#   --version-src URL       (optional, string) 覆盖官方版本接口地址（默认 https://www.bt.cn/api/panel/updateLinux）
#
# 输出（I/O contract）：
#   标准输出  : version=x.y.z（仅一行，便于管道消费）
#   --out 文件: 追加 version=x.y.z（GitHub Actions outputs 格式 key=value）
#   退出码    : 0=解析成功；1=致命失败（fail-closed，已打印 ::error 与原因）
#   日志前缀  : [SKILL:detect_bt_release] 便于在 CI log 中过滤
#
# 错误处理（error handling）：
#   · 致命（fail-closed）：stable 的 panel6_ltd_*.zip 或更新包路径变更导致解析不出
#     有效版本、release 全源非 semver 时 -> ::error + exit 1，阻断整条流水线，绝不静默产出错误版本。
#   · 网络类步骤：curl 全部带 --max-time 且可重试（无网络时立即 fail-closed，不无限等待）。
# ============================================================
set -uo pipefail

# ---- 常量 ----
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
DEFAULT_INSTALL_SH_URL="https://download.bt.cn/install/installStable_12.sh"
DEFAULT_UPDATE_BASE="https://download.bt.cn/install/update/LinuxPanel-"
DEFAULT_VERSION_SRC="https://www.bt.cn/api/panel/updateLinux"

log()  { echo "[SKILL:detect_bt_release] $*" >&2; }
warn() { echo "::warning::[SKILL:detect_bt_release] $*" >&2; }
die()  { echo "::error::[SKILL:detect_bt_release] $*" >&2; exit 1; }

is_semver() { [[ "$1" =~ $SEMVER_RE ]]; }

# 带重试的 curl GET：网络类步骤不无限等待，失败即 fail-closed
curl_retry() { # $1=url $2=max_time(s) $3=retries
  local url="$1" mt="$2" tries="$3" i
  for ((i = 1; i <= tries; i++)); do
    if curl -s --max-time "$mt" "$url"; then return 0; fi
    [ "$i" -lt "$tries" ] && sleep 2
  done
  return 1
}

# ---- 参数解析 ----
MODE=""
FORCE_TAG=""
INSTALL_SH=""
UPDATE_BASE="$DEFAULT_UPDATE_BASE"
OUT_FILE=""
VERBOSE=false
VERSION_SRC="$DEFAULT_VERSION_SRC"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --force-tag) FORCE_TAG="$2"; shift 2 ;;
    --install-sh) INSTALL_SH="$2"; shift 2 ;;
    --update-base) UPDATE_BASE="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --version-src) VERSION_SRC="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) die "未知参数: $1（用法见脚本头部元信息）" ;;
  esac
done

[ "$MODE" != "stable" ] && [ "$MODE" != "release" ] && die "--mode 必须为 stable 或 release（当前: ${MODE:-空}）"

# ---- 手动覆盖（workflow_dispatch inputs.version 映射至此）----
if [ -n "$FORCE_TAG" ]; then
  is_semver "$FORCE_TAG" || die "手动指定版本不是合法 semver: $FORCE_TAG"
  log "手动覆盖版本: $FORCE_TAG"
  echo "version=$FORCE_TAG"
  [ -n "$OUT_FILE" ] && echo "version=$FORCE_TAG" >> "$OUT_FILE"
  exit 0
fi

VER=""

# ============================================================
# 模式 stable：从官方安装脚本解析精确版本（fail-closed）
# ============================================================
if [ "$MODE" = "stable" ]; then
  if [ -n "$INSTALL_SH" ]; then
    [ -f "$INSTALL_SH" ] || die "指定的本地安装脚本不存在: $INSTALL_SH"
    log "使用本地安装脚本（mock）: $INSTALL_SH"
  else
    log "下载官方稳定版安装脚本: $DEFAULT_INSTALL_SH_URL"
    curl_retry "$DEFAULT_INSTALL_SH_URL" 20 2 > /tmp/installStable_12.sh || die "下载 installStable_12.sh 失败（网络或官方地址变更）"
    INSTALL_SH="/tmp/installStable_12.sh"
  fi

  # 1) 大版本：panel6_ltd_<major>.zip（只提取 "ltd_" 之后的数字，避免误取到 "panel6" 里的 6）。
  #    结构变更（改名/换路径）时取不到 -> fail-closed
  MAJOR=$(grep -oE "panel6_ltd_[0-9]+\.zip" "$INSTALL_SH" | sed -nE 's/.*ltd_([0-9]+)\.zip.*/\1/p' | head -1)
  if [ -z "$MAJOR" ]; then
    die "无法从 installStable_12.sh 解析出稳定版大版本（panel6_ltd_*.zip 命名/路径已变更？请人工核对官方脚本）"
  fi
  log "稳定版大版本: $MAJOR"

  # 2) 小版本：官方更新包探测 0-9。若更新包命名/路径变更导致全部 404 -> fail-closed，
  #    绝不静默回退到 ${MAJOR}.0.0（那可能是一个不存在的版本，会导致推送假版本）。
  #    --update-base 本地目录模式（/path 开头）：文件存在即视为该版本已发布（离线 mock）。
  VER=""
  for patch in 0 1 2 3 4 5 6 7 8 9; do
    cand="${MAJOR}.0.${patch}"
    if [[ "$UPDATE_BASE" == /* ]]; then
      code="404"
      [ -f "${UPDATE_BASE}/LinuxPanel-${cand}.zip" ] && code="200"
    else
      code=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" "${UPDATE_BASE}${cand}.zip" 2>/dev/null)
    fi
    if [ "$code" = "200" ]; then
      VER="$cand"
    else
      break   # 更新包 patch 连续递增，遇第一个不存在即取之前最大已存在版本
    fi
  done

  if [ -z "$VER" ]; then
    die "稳定版更新包探测全部失败（patch 0-9 均非 200；LinuxPanel-*.zip 命名/路径已变更？请人工核对官方更新源）"
  fi

# ============================================================
# 模式 release：官方接口双源 + semver 校验（fail-closed）
# ============================================================
else
  log "主源探测版本: $VERSION_SRC"
  VER=$(curl_retry "$VERSION_SRC" 8 2 | jq -r '.version' 2>/dev/null || true)
  if ! is_semver "${VER:-}"; then
    warn "主源返回非 semver（${VER:-空}），尝试兜底源 get_version ..."
    VER=$(curl -s --max-time 5 http://www.bt.cn/api/panel/get_version 2>/dev/null)
  fi
  if ! is_semver "${VER:-}"; then
    die "所有版本源均未返回合法 semver（主源 updateLinux / 兜底源 get_version 均失败）。版本源可能已失效，请改用 workflow_dispatch 手动传入 inputs.version 覆盖。"
  fi
fi

# ---- 输出 ----
is_semver "$VER" || die "解析结果非法 semver: $VER"
$VERBOSE && log "最终版本: $VER"
echo "version=$VER"
[ -n "$OUT_FILE" ] && echo "version=$VER" >> "$OUT_FILE"
log "解析完成: $VER"
exit 0
