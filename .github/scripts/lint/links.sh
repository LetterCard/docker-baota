#!/bin/bash
# ==============================================================================
#  文档内部链接与锚点检查
#
#  为什么需要：文档一多，「改了标题忘了改链接」几乎必然发生（本仓库最近一次
#  重构就挪过好几个文件）。这里按 GitHub 的 slug 规则（小写、去掉标点、空格转 -）
#  校验 `[文字](路径#锚点)` 的目标是否存在，让 `make lint` 就能拦住死链。
#
#  只检查仓库内的相对链接；http(s) 外链不探测（避免 CI 依赖第三方可用性）。
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import pathlib, re, sys

def slug(text: str) -> str:
    """近似 GitHub 的标题 slug：小写 → 去掉标点 → 空白转 -"""
    s = text.strip().lower()
    s = re.sub(r'[^\w\s\u4e00-\u9fff-]', '', s)   # 标点直接删（不是替换成 -）
    s = re.sub(r'\s+', '-', s)
    return s.strip('-')

def anchors(path: pathlib.Path):
    out = set()
    for line in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        if line.startswith('#'):
            out.add(slug(line.lstrip('#').strip()))
    return out

bad = []
docs = [p for p in pathlib.Path('.').glob('**/*.md')
        if not any(x in str(p) for x in ('.git/', 'data/', '.tmp-repro/'))]

for f in docs:
    for m in re.finditer(r'\]\(([^)#\s]+)(?:#([^)]*))?\)', f.read_text(encoding='utf-8', errors='ignore')):
        target, anchor = m.group(1), m.group(2)
        if target.startswith(('http://', 'https://', 'mailto:')):
            continue
        p = (f.parent / target).resolve()
        if not p.exists():
            bad.append(f'{f}: 链接目标不存在 → {target}')
            continue
        if anchor and p.suffix == '.md' and anchor not in anchors(p):
            bad.append(f'{f}: 锚点不存在 → {target}#{anchor}')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    sys.exit(1)
print(f'  ok  文档内部链接与锚点有效（{len(docs)} 篇）')
PY
