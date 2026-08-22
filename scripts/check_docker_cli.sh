#!/usr/bin/env bash
# ============================================================
# 技能元信息（Skill Manifest，遵循 E 节规范）
#   name       : check_docker_cli_version
#   description: 检查 Dockerfile 中写死的 DOCKER_CLI_VERSION（静态 docker CLI，Dependabot 无法
#                覆盖 ARG 值）是否落后于官方最新稳定版；落后时打印 ::warning + summary，
#                并可幂等开 issue 跟踪升级；在 release/stable 的 check-version job 中调用。
#   version    : 1.0.0
#   owner      : shared
#   triggers   : (d) 被 workflow check-version job 作为子流程调用（随定时/手动触发）
#   幂等性     : 仅告警；开 issue 时按标题去重（同版本已开过则跳过）。
#
# 输入（parameters）：
#   --dockerfile PATH  (optional, path) 默认 release/Dockerfile
#   --flavor stable|release (required, enum) 用于 issue 标题
#   --out FILE         (optional, path) 追加 latest_docker_cli=... / outdated=true|false
#
# 依赖：GITHUB_TOKEN / GITHUB_REPOSITORY（开 issue 用，缺失则仅告警）
# 输出：退出码 0=正常（非阻塞，不阻断流水线）；日志前缀 [SKILL:check_docker_cli_version]
# ============================================================
set -uo pipefail

DOCKERFILE="release/Dockerfile"
FLAVOR=""
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    *) echo "::error::[SKILL:check_docker_cli_version] 未知参数: $1"; exit 1 ;;
  esac
done

log()  { echo "[SKILL:check_docker_cli_version] $*" >&2; }
warn() { echo "::warning::[SKILL:check_docker_cli_version] $*" >&2; }

# ---- 读取当前固定版本 ----
CUR=$(grep -oE 'ARG DOCKER_CLI_VERSION="[0-9.]+"' "$DOCKERFILE" 2>/dev/null | grep -oE '[0-9.]+' | head -1)
[ -n "$CUR" ] || { warn "无法从 $DOCKERFILE 读取 DOCKER_CLI_VERSION"; exit 0; }
log "当前固定 docker CLI 版本: $CUR"

# ---- 查询官方最新稳定版（GitHub docker/docker-ce latest release）----
LATEST=$(curl -s --max-time 15 https://api.github.com/repos/docker/docker-ce/releases/latest 2>/dev/null \
  | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
[ -n "$LATEST" ] || { warn "查询官方最新版本失败（网络/API 变更），跳过本次检查"; exit 0; }
log "官方最新稳定版: $LATEST"
[ -n "$OUT_FILE" ] && echo "latest_docker_cli=$LATEST" >> "$OUT_FILE"

# ---- 数字版本比较（CUR >= LATEST 则最新）----
ver_ge() { # $1 $2 : 若 $1 >= $2 返回 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

if ver_ge "$CUR" "$LATEST"; then
  log "docker CLI 已是最新（$CUR），无需处理"
  [ -n "$OUT_FILE" ] && echo "outdated=false" >> "$OUT_FILE"
  exit 0
fi

warn "docker CLI 版本落后：固定 $CUR < 官方最新 $LATEST。升级方式：改 Dockerfile 的 ARG DOCKER_CLI_VERSION，并确认阿里云镜像两架构目录都存在该版本后重建。"
[ -n "$OUT_FILE" ] && echo "outdated=true" >> "$OUT_FILE"

# ---- 幂等开 issue（Dependabot 覆盖不到 ARG，故自行跟踪）----
[ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || { log "无 token/repo，仅告警"; exit 0; }
API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
TITLE="Docker CLI 版本落后：${FLAVOR} 固定 ${CUR} < 官方 ${LATEST}"

if curl -s --max-time 20 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/issues?state=open&per_page=100" 2>/dev/null \
    | jq -e --arg t "$TITLE" 'any(.[]; .title == $t)' >/dev/null 2>&1; then
  log "已存在相同升级 issue，跳过（幂等）"
  exit 0
fi

BODY="\`${FLAVOR}\` 镜像内静态 docker CLI 固定版本 \`${CUR}\` 落后于官方最新 \`${LATEST}\`（Dependabot 的 docker ecosystem 无法覆盖 Dockerfile 中 ARG 值）。

升级步骤：编辑 \`${FLAVOR}/Dockerfile\` 将 \`ARG DOCKER_CLI_VERSION\` 改为 \`${LATEST}\`，确认阿里云镜像 \`mirrors.aliyun.com/docker-ce/linux/static/stable/\` 下 x86_64/aarch64 均存在该版本，然后重建并跑冒烟。

_由 [SKILL:check_docker_cli_version] 自动创建；升级后同版本标题自动匹配即不再重复。_"
PAYLOAD=$(jq -n --arg t "$TITLE" --arg b "$BODY" '{title:$t, body:$b, labels:["auto","dependency"]}')
HTTP=$(curl -s -o /tmp/dockercli_issue_resp.json -w "%{http_code}" --max-time 30 \
  -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d "$PAYLOAD" "${API}/issues" 2>/dev/null)
[ "$HTTP" = "201" ] && log "已创建升级 issue: $(jq -r '.html_url' /tmp/dockercli_issue_resp.json 2>/dev/null)" \
  || warn "创建 issue 失败（HTTP $HTTP），仅告警"
exit 0
