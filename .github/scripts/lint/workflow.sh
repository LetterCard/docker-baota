#!/bin/bash
# ==============================================================================
#  workflow 内嵌脚本的语法检查
#
#  为什么需要：`.github/workflows/*.yml` 里的大段 `run: |` 是真正的 bash，
#  但 `bash -n` 看不到它们、`yaml.safe_load` 也不检查内容 —— 只有等 CI 真跑
#  起来才会炸（而且往往炸在发布流程的中途）。这里把每个 `run:` 块抽出来交给
#  `bash -n`，本地 `make lint` 就能拦住。
#
#  只做语法检查（不执行）；`if:`/`${{ }}` 之类的表达式按原样保留即可 ——
#  bash 解析 `${{ ... }}` 时不会报错。
#
#  相关：docs/development.md「注释与文档规范」
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

rc=0
for f in .github/workflows/*.yml; do
    [ -f "$f" ] || continue
    tmp=$(mktemp -d)
    if ! python3 - "$f" "$tmp" <<'PY'
import pathlib, sys, yaml
src, out = sys.argv[1], pathlib.Path(sys.argv[2])
doc = yaml.safe_load(pathlib.Path(src).read_text(encoding='utf-8'))
n = 0

def walk(node):
    global n
    if isinstance(node, dict):
        for k, v in node.items():
            if k == 'run' and isinstance(v, str):
                n += 1
                (out / f"{n:02d}.sh").write_text(v, encoding='utf-8')
            else:
                walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(doc)
PY
    then
        echo "  FAIL ${f}：解析失败（YAML 或内嵌脚本抽取出错）"
        rc=1
        rm -rf "$tmp"
        continue
    fi

    bad=0
    for s in "$tmp"/*.sh; do
        [ -f "$s" ] || continue
        bash -n "$s" || { echo "  FAIL ${f}：第 $(basename "$s" .sh) 个 run 块不是合法 bash"; bad=1; rc=1; }
    done
    [ "$bad" -eq 0 ] && echo "  ok  ${f}（内嵌 run 块语法正确）"
    rm -rf "$tmp"
done

[ "$rc" -eq 0 ] || echo '  修 workflow 里的 run 块后重跑 make lint'
exit "$rc"
