#!/usr/bin/env bash
# ============================================================
# 技能元信息（Skill Manifest，遵循 E 节规范）
#   name       : notify_ci_failure
#   description: 构建/冒烟流水线失败时自动开 issue 并 @维护者；同一版本连续失败达阈值后
#                降级为"仅告警不再新建 issue"；在各 workflow 的 on-failure job 中调用。
#   version    : 1.0.0
#   owner      : shared
#   triggers   : (d) 被 workflow 的 `if: failure()` job 作为子流程调用
#   幂等性     : 按 "<flavor> <workflow> v<version>" 查找 open issue：
#                · 不存在 -> 新建（body 含原因+修复建议，@维护者）
#                · 存在   -> 追加评论记录失败次数，连续失败达 FAIL_THRESHOLD 次后
#                            关闭新开（降级为 summary 告警），避免 issue 刷屏。
#
# 输入（parameters）：
#   --workflow NAME      (required, string) 失败的工作流名（如 docker-build-release）
#   --version x.y.z      (required, string) 本次版本（解析失败时为 unknown）
#   --flavor stable|release (required, enum)
#   --failed-job NAME    (optional, string) 失败的具体 job/step
#   --out FILE           (optional, path) 追加 "issue_opened=true|false" / "downgraded=true|false"
#
# 依赖（secrets/env）：
#   GITHUB_TOKEN / GITHUB_REPOSITORY / GITHUB_RUN_ID / GITHUB_SERVER_URL
#   MAINTAINER_HANDLE（可选，@的 GitHub 用户名，默认 bot 自身不 @）
#   FAIL_THRESHOLD（可选，默认 3；连续失败次数达到该值后不再新建 issue）
#
# 输出：退出码 0=正常；日志前缀 [SKILL:notify_ci_failure]；非阻塞（失败不阻断主流水线）。
# ============================================================
set -uo pipefail

WORKFLOW=""
VERSION="unknown"
FLAVOR=""
FAILED_JOB=""
OUT_FILE=""
THRESHOLD="${FAIL_THRESHOLD:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --failed-job) FAILED_JOB="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    *) echo "::error::[SKILL:notify_ci_failure] 未知参数: $1"; exit 1 ;;
  esac
done

log()  { echo "[SKILL:notify_ci_failure] $*" >&2; }
warn() { echo "::warning::[SKILL:notify_ci_failure] $*" >&2; }

[ -n "${GITHUB_TOKEN:-}" ] || { warn "无 GITHUB_TOKEN，跳过失败通知"; exit 0; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { warn "无 GITHUB_REPOSITORY，跳过失败通知"; exit 0; }

API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
TITLE="[CI 失败] ${FLAVOR} ${WORKFLOW} v${VERSION}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}"

# ---- 查找已存在的 open issue（幂等）----
log "检查是否已有失败 issue: $TITLE"
EXISTING=$(curl -s --max-time 20 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/issues?state=open&per_page=100" 2>/dev/null \
  | jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .number' | head -1)

if [ -z "$EXISTING" ]; then
  # ---- 新建 issue ----
  MENTION=""
  [ -n "${MAINTAINER_HANDLE:-}" ] && MENTION="请 @${MAINTAINER_HANDLE} 关注。"
  BODY="**工作流**：\`${WORKFLOW}\`（${FLAVOR}）
**版本**：\`${VERSION}\`
**失败环节**：\`${FAILED_JOB:-未知}\`
**运行链接**：${RUN_URL}

### 建议排查顺序
1. 版本解析失败？→ 检查官方版本源/安装脚本结构是否变更（见 scripts/detect_version.sh 的 fail-closed 报错）。
2. 构建失败？→ 查看 build step 日志（依赖下载、Dockerfile 缓存、网络）。
3. 冒烟失败？→ 本地复现：\`docker build -t baota-smoke:latest ${FLAVOR}/ && bash scripts/smoke.sh baota-smoke:latest\`。
4. 推送失败？→ 检查 DockerHub Token 是否过期（scoped access token）。

${MENTION}
_由 [SKILL:notify_ci_failure] 自动创建；同版本再次失败会在本 issue 追加评论，连续 ${THRESHOLD} 次后自动降级为仅告警。_"

  PAYLOAD=$(jq -n --arg t "$TITLE" --arg b "$BODY" '{title:$t, body:$b, labels:["auto","ci-failure"]}')
  HTTP=$(curl -s -o /tmp/fail_issue_resp.json -w "%{http_code}" --max-time 30 \
    -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$PAYLOAD" "${API}/issues" 2>/dev/null)

  if [ "$HTTP" = "201" ]; then
    log "已创建失败 issue: $(jq -r '.html_url' /tmp/fail_issue_resp.json 2>/dev/null)"
    [ -n "$OUT_FILE" ] && echo "issue_opened=true" >> "$OUT_FILE"
    exit 0
  fi
  warn "创建 issue 失败（HTTP $HTTP），降级为仅日志告警"
  [ -n "$OUT_FILE" ] && echo "issue_opened=false" >> "$OUT_FILE"
  exit 0
fi

# ---- 已存在：追加评论计数；达阈值则降级 ----
log "已存在 issue #${EXISTING}，追加失败记录"
# 统计已有评论中的 "fail#N" 计数
LAST_N=$(curl -s --max-time 20 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/issues/${EXISTING}/comments?per_page=100" 2>/dev/null \
  | jq -r '[.[] | .body | capture("fail#(?<n>[0-9]+)") | .n | tonumber] | max // 0' 2>/dev/null)
CUR=$((LAST_N + 1))

if [ "$CUR" -ge "$THRESHOLD" ]; then
  log "连续失败已达 ${CUR} 次（阈值 ${THRESHOLD}），降级：不再新建/追加 issue，仅 summary 告警"
  [ -n "$OUT_FILE" ] && { echo "issue_opened=false" >> "$OUT_FILE"; echo "downgraded=true" >> "$OUT_FILE"; }
  exit 0
fi

COMMENT="再次失败（fail#${CUR}）：运行 ${RUN_URL}，环节 \`${FAILED_JOB:-未知}\`"
curl -s --max-time 30 -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d "$(jq -n --arg b "$COMMENT" '{body:$b}')" \
  "${API}/issues/${EXISTING}/comments" >/dev/null 2>&1
log "已追加失败评论 fail#${CUR}"
[ -n "$OUT_FILE" ] && { echo "issue_opened=false" >> "$OUT_FILE"; echo "downgraded=false" >> "$OUT_FILE"; }
exit 0
