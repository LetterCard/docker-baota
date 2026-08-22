#!/usr/bin/env bash
# ============================================================
# 技能元信息（Skill Manifest，遵循 E 节规范）
#   name       : verify_baota_repo
#   description: 本地复现 CI 的静态校验与版本解析流程——双版本(稳定/正式)一致性、
#                脚本语法、compose/YAML 合法性、版本解析 mock 测试；在提交 PR 前调用，
#                也可在 CI 中作为 gate 前置步骤复用。
#   version    : 1.0.0
#   owner      : shared
#   triggers   : (d) 被维护者本地调用（手工）；可挂到 CI 前置 job 作为子流程
#   幂等性     : 只读校验，无副作用
#
# 输入：无（仓库内约定路径）；--quick 仅做静态校验跳过 mock 网络测试
# 输出：退出码 0=全部通过；非 0=列出失败项（::error）；每项 PASS/FAIL 打印
# 日志前缀：[SKILL:verify_baota_repo]
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

QUICK=false
[ "${1:-}" = "--quick" ] && QUICK=true

PASS=0
FAIL=0

ok()   { echo "[SKILL:verify_baota_repo] PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "::error::[SKILL:verify_baota_repo] FAIL  $1"; FAIL=$((FAIL + 1)); }

check() { # $1=描述  $2=命令(成功则 ok)
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# ---- 1. 脚本语法 ----
check "bash -n release/entrypoint.sh"      bash -n release/entrypoint.sh
check "bash -n stable/entrypoint.sh"       bash -n stable/entrypoint.sh
check "bash -n scripts/smoke.sh"           bash -n scripts/smoke.sh
check "bash -n scripts/detect_version.sh"  bash -n scripts/detect_version.sh
check "bash -n scripts/verify.sh"          bash -n scripts/verify.sh
[ -f scripts/open_failure_issue.sh ] && check "bash -n scripts/open_failure_issue.sh" bash -n scripts/open_failure_issue.sh
[ -f scripts/open_trivy_issue.sh ] && check "bash -n scripts/open_trivy_issue.sh" bash -n scripts/open_trivy_issue.sh

# ---- 2. 双版本一致性（C2：entrypoint 同源；C1：compose/.env/Dockerfile 结构一致）----
# 一致性比较口径：剥离注释行 + 版本号归一化 + 各版本故意的差异（安装脚本文件名、描述措辞）归一化。
# 注释是各版本说明性文字（正式版动态版本 vs 稳定版固定版本），属故意差异，不视为漂移。
check "entrypoint.sh 双版逐字节一致" diff -q release/entrypoint.sh stable/entrypoint.sh
check "docker-compose.yml 双版一致（归一化后）" bash -c '
  norm() { sed -E "s/^[[:space:]]*#.*$//" "$1" | sed "s/$2/12.0.0/g" | grep -v "^[[:space:]]*$"; }
  diff <(norm release/docker-compose.yml 13.0.0) <(norm stable/docker-compose.yml 12.0.0) >/dev/null'
check ".env.example 双版一致（归一化后）" bash -c '
  norm() { sed -E "s/^[[:space:]]*#.*$//" "$1" | sed "s/$2/12.0.0/g" | grep -v "^[[:space:]]*$"; }
  diff <(norm release/.env.example 13.0.0) <(norm stable/.env.example 12.0.0) >/dev/null'
check "Dockerfile 双版一致（归一化后）" bash -c '
  norm() {
    sed -E "s/^[[:space:]]*#.*$//" "$1" \
      | sed "s/$2/12.0.0/g" \
      | sed "s#install_panel\\.sh#<INSTALL_SH>#g; s#installStable_12\\.sh#<INSTALL_SH>#g" \
      | sed "s/正式版/<FLAVOR>/g; s/稳定版/<FLAVOR>/g" \
      | grep -v "^[[:space:]]*$"
  }
  diff <(norm release/Dockerfile 13.0.0) <(norm stable/Dockerfile 12.0.0) >/dev/null'

# ---- 3. compose / workflow YAML 合法性 ----
check "release compose config" docker compose -f release/docker-compose.yml config --quiet
check "stable  compose config" docker compose -f stable/docker-compose.yml config --quiet
check "workflow/dependabot YAML" \
  ruby -ryaml -e "ARGV.each{|f| YAML.load_file(f)}" .github/workflows/*.yml .github/dependabot.yml

# ---- 4. unbound 变量隐患（$VAR）紧跟多字节字符，见项目记忆）----
if grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]' release/entrypoint.sh scripts/smoke.sh scripts/detect_version.sh >/dev/null; then
  bad "存在 unbound 变量隐患（变量名紧贴多字节字符）"
else
  ok "无 unbound 变量隐患"
fi

# ---- 5. Actions uses: 版本清单（人工核对 Node24 兼容）----
echo "[SKILL:verify_baota_repo] INFO  Actions uses 清单（应含 trivy-action 等）："
grep -h 'uses:' .github/workflows/*.yml | sort -u | sed 's/^/  /'

# ---- 6. 版本解析 mock 测试（A1 fail-closed 正确性）----
if [ "$QUICK" = false ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # 6.1 stable 正常解析：构造含 panel6_ltd_12.zip 的 mock 脚本 + 本地 update-base 目录
  #     （离线确定化，不依赖 download.bt.cn 网络）——大版本 12 + patch 0 存在 => 12.0.0
  printf '#!/bin/bash\n# panel6_ltd_12.zip 下载地址\n' > "$TMP/install_ok.sh"
  mkdir -p "$TMP/updates"
  touch "$TMP/updates/LinuxPanel-12.0.0.zip"
  OUT=$(bash scripts/detect_version.sh --mode stable --install-sh "$TMP/install_ok.sh" --update-base "$TMP/updates" 2>/dev/null)
  if [ "$OUT" = "version=12.0.0" ]; then
    ok "stable mock 解析: $OUT"
  else
    bad "stable mock 解析失败: ${OUT:-空}"
  fi

  # 6.2 stable fail-closed：installStable_12.sh 结构变更（无 panel6_ltd_*）应报错退出而非静默产出版本
  printf '#!/bin/bash\n# renamed_zip_12.zip\n' > "$TMP/install_broken.sh"
  if bash scripts/detect_version.sh --mode stable --install-sh "$TMP/install_broken.sh" >/dev/null 2>&1; then
    bad "stable 结构变更未被 fail-closed（应退出非 0）"
  else
    ok "stable 结构变更 fail-closed 生效"
  fi

  # 6.3 手动覆盖：--force-tag 应直接生效且校验 semver
  OUT=$(bash scripts/detect_version.sh --mode release --force-tag 13.0.0 2>/dev/null)
  [ "$OUT" = "version=13.0.0" ] && ok "force-tag 手动覆盖: $OUT" || bad "force-tag 手动覆盖异常: $OUT"
  if bash scripts/detect_version.sh --mode release --force-tag abc >/dev/null 2>&1; then
    bad "force-tag 非法 semver 未被拒绝"
  else
    ok "force-tag 非法 semver 被拒绝"
  fi
else
  echo "[SKILL:verify_baota_repo] INFO  --quick 模式，跳过版本解析 mock 测试"
fi

echo ""
echo "[SKILL:verify_baota_repo] 结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
