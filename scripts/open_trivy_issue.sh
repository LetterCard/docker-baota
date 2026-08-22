#!/usr/bin/env bash
# ============================================================
# 技能元信息（Skill Manifest，遵循 E 节规范）
#   name       : track_trivy_vulns
#   description: 解析 Trivy JSON 扫描结果，当存在"可修复(fixed_version 非空)"的 HIGH/CRITICAL
#                漏洞时自动开 issue 跟踪；同版本已开过则跳过（幂等）；在镜像推送后调用。
#   version    : 1.0.0
#   owner      : shared
#   triggers   : (d) 被 push job 的 Trivy 扫描后作为子流程调用
#   幂等性     : 按 "<flavor> v<version>" 标题查找 open issue，已存在则跳过，不重复开。
#
# 输入（parameters）：
#   --trivy-json FILE   (required, path) trivy --format json 输出文件
#   --version x.y.z     (required, string) 本次构建的镜像版本
#   --flavor stable|release (required, enum) 版本线，用于标题区分
#   --out FILE          (optional, path) 追加 "issue_opened=true|false" 到该文件
#
# 依赖（secrets/env）：
#   GITHUB_TOKEN  （GitHub 自动注入，需 workflow permissions: issues: write）
#   GITHUB_REPOSITORY（owner/repo）
#   GH_TITLE_PREFIX（可选，默认 "Trivy 可修复高危漏洞"）
#
# 输出：退出码 0=正常（无论是否开 issue）；日志前缀 [SKILL:track_trivy_vulns]
# 非阻塞：任何失败只 warn 不阻断（推送已完成，扫描为事后跟踪）。
# ============================================================
set -uo pipefail

TRIVY_JSON=""
VERSION=""
FLAVOR=""
OUT_FILE=""
TITLE_PREFIX="${GH_TITLE_PREFIX:-Trivy 可修复高危漏洞}"

while [ $# -gt 0 ]; do
  case "$1" in
    --trivy-json) TRIVY_JSON="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    *) echo "::error::[SKILL:track_trivy_vulns] 未知参数: $1"; exit 1 ;;
  esac
done

log()  { echo "[SKILL:track_trivy_vulns] $*" >&2; }
warn() { echo "::warning::[SKILL:track_trivy_vulns] $*" >&2; }

[ -n "${GITHUB_TOKEN:-}" ] || { warn "无 GITHUB_TOKEN，跳过 issue 跟踪"; exit 0; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { warn "无 GITHUB_REPOSITORY，跳过 issue 跟踪"; exit 0; }
[ -f "$TRIVY_JSON" ] || { warn "Trivy JSON 文件不存在: $TRIVY_JSON"; exit 0; }

API="https://api.github.com/repos/${GITHUB_REPOSITORY}"

# ---- 统计可修复（fixed_version 非空）的 HIGH/CRITICAL ----
COUNT=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL") | select(.FixedVersion != null and .FixedVersion != "")] | length' "$TRIVY_JSON" 2>/dev/null || echo 0)
log "可修复 HIGH/CRITICAL 漏洞数量: $COUNT"

echo "vuln_count=$COUNT"
[ -n "$OUT_FILE" ] && echo "vuln_count=$COUNT" >> "$OUT_FILE"

if [ "${COUNT:-0}" = "0" ] || [ "${COUNT:-0}" = "null" ]; then
  log "无可修复高危漏洞，无需开 issue"
  [ -n "$OUT_FILE" ] && echo "issue_opened=false" >> "$OUT_FILE"
  exit 0
fi

# ---- 幂等：按标题查找已存在的 open issue ----
TITLE="${TITLE_PREFIX}: ${FLAVOR} v${VERSION}"
log "检查是否已存在 issue: $TITLE"
if curl -s --max-time 20 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/issues?state=open&per_page=100" 2>/dev/null \
    | jq -e --arg t "$TITLE" 'any(.[]; .title == $t)' >/dev/null 2>&1; then
  log "已存在同版本 issue，跳过（幂等）"
  [ -n "$OUT_FILE" ] && echo "issue_opened=false" >> "$OUT_FILE"
  exit 0
fi

# ---- 生成漏洞清单（按包+严重度，最多 15 条防超长）----
BODY=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL") | select(.FixedVersion != null and .FixedVersion != "")] | sort_by(.Severity) | .[:15] | .[] | "- **\(.Severity)** `\(.PkgName)` -> 修复版本 `\(.FixedVersion)`（\(.VulnerabilityID)）"' "$TRIVY_JSON" 2>/dev/null)
BODY="自动跟踪：\`${FLAVOR}\` 镜像 v${VERSION} 的 Trivy 扫描发现 ${COUNT} 个可修复 HIGH/CRITICAL 漏洞。

修复方式：更新基础镜像依赖或等待上游 Debian 安全补丁进入下一次**强制重建**（release 每周一 / stable 每月 1 号）后自动拾取；若为镜像内自装组件，请人工评估升级。

可修复漏洞清单：
${BODY}

---
_由 [SKILL:track_trivy_vulns] 自动创建，同版本重复扫描会自动跳过。_"

PAYLOAD=$(jq -n --arg t "$TITLE" --arg b "$BODY" '{title:$t, body:$b, labels:["auto","security"]}')
HTTP=$(curl -s -o /tmp/trivy_issue_resp.json -w "%{http_code}" --max-time 30 \
  -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d "$PAYLOAD" "${API}/issues" 2>/dev/null)

if [ "$HTTP" = "201" ]; then
  ISSUE_URL=$(jq -r '.html_url' /tmp/trivy_issue_resp.json 2>/dev/null)
  log "已创建跟踪 issue: $ISSUE_URL"
  [ -n "$OUT_FILE" ] && echo "issue_opened=true" >> "$OUT_FILE"
  exit 0
else
  warn "创建 issue 失败（HTTP $HTTP）：$(head -c 300 /tmp/trivy_issue_resp.json 2>/dev/null)"
  [ -n "$OUT_FILE" ] && echo "issue_opened=false" >> "$OUT_FILE"
  exit 0
fi
