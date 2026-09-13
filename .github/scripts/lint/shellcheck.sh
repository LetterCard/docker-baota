#!/bin/bash
# ==============================================================================
#  统一的 shellcheck 接入（make lint 调用）
#
#  为什么需要独立脚本，而不是 make lint 里内联一段：
#  1) 之前 make lint 只在 `command -v shellcheck` 命中时才跑，没装就「静默跳过」——
#     结果 display/channel 这类未定义变量 bug 在 CI 上也没拦住（CI 同样没预装）。
#     这里改成：PATH 没有就自动下载到 .cache（版本钉死），保证一定跑。
#  2) .sh 脚本用 --source-path=. 让 `# shellcheck source=image/conf/defaults.env`
#     解析到真源，消除 defaults.env 配置变量的误报（SC2154）。
#  3) workflow 内嵌 run 块单独抽出来检查——这里曾是未定义变量 bug 的藏身处，
#     bash -n 只查语法查不到，必须上 shellcheck。GitHub 的 ${{ }} 模板会让
#     检查器误报 SC2296/SC2195/SC2050/SC2193，针对内嵌块排除之，
#     但保留 SC2154（未定义变量）—— 正是我们想拦的 bug 类。
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

# --- 1. 确保 shellcheck 可用（PATH 没有就下载到 .cache）---
SC_DIR=.cache/shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  SC_BIN=shellcheck
else
  mkdir -p "$SC_DIR"
  if [ ! -x "$SC_DIR/shellcheck" ]; then
    ver=v0.10.0
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    m=$(uname -m)
    # darwin 只有 x86_64 资产（Rosetta 可跑）；linux 按真实架构取 aarch64
    if [ "$os" = "linux" ] && [ "$m" = "aarch64" ]; then arch=aarch64; else arch=x86_64; fi
    url="https://github.com/koalaman/shellcheck/releases/download/${ver}/shellcheck-${ver}.${os}.${arch}.tar.xz"
    echo "  下载 shellcheck：${url}"
    curl -fsSL "$url" -o "$SC_DIR/shellcheck.tar.xz" \
      && tar -xf "$SC_DIR/shellcheck.tar.xz" -C "$SC_DIR" --strip-components=1 \
      && rm -f "$SC_DIR/shellcheck.tar.xz" \
      || { echo "  FAIL 下载 shellcheck 失败（网络问题？）"; exit 1; }
  fi
  SC_BIN="$SC_DIR/shellcheck"
fi
echo "  shellcheck：$("${SC_BIN}" --version | awk 'NR==2')"

# --- 2. .sh 脚本（--source-path=. 让 source 指令解析到仓库根真源）---
echo "--- shellcheck（.sh 脚本）---"
sh_files=()
while IFS= read -r f; do sh_files+=("$f"); done < <(find . -name '*.sh' -not -path './.git/*')
if "${SC_BIN}" -x --source-path=. -S warning "${sh_files[@]}"; then
  echo "  ok  全部 .sh 通过"
else
  echo "  FAIL shellcheck 在 .sh 脚本中发现问题"
  exit 1
fi

# --- 3. workflow 内嵌 run 块（这里曾是未定义变量 bug 的藏身处）---
echo "--- shellcheck（workflow 内嵌 run 块）---"
tmp=$(mktemp -d)
python3 - "$tmp" <<'PY'
import pathlib, sys, yaml
out = pathlib.Path(sys.argv[1])
for src in sorted(pathlib.Path('.github/workflows').glob('*.yml')):
    doc = yaml.safe_load(src.read_text(encoding='utf-8'))
    n = 0
    def walk(node):
        global n
        if isinstance(node, dict):
            for k, v in node.items():
                if k == 'run' and isinstance(v, str):
                    n += 1
                    (out / f"{src.stem}-{n:02d}.sh").write_text("#!/bin/bash\n" + v, encoding='utf-8')
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(doc)
PY
# 排除 GitHub ${{ }} 模板导致的误报；保留 SC2154（未定义变量）
if "${SC_BIN}" -S warning -e SC2296 -e SC2195 -e SC2050 -e SC2193 "$tmp"/*.sh; then
  echo "  ok  workflow 内嵌脚本通过"
else
  echo "  FAIL workflow 内嵌脚本中发现问题（重点查 SC2154 未定义变量）"
  rc=1
fi
rm -rf "$tmp"
[ "${rc:-0}" -eq 0 ]
