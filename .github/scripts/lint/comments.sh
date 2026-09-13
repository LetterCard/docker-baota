#!/bin/bash
# ==============================================================================
#  注释体积检查（make lint 调用）
#
#  为什么要有它：注释的价值与长度成反比 —— 第 11 行没人会读，但每次改动都要
#  跟着改，是最容易过期、也最容易误导人的部分。约定里的「≤16 / ≤10 行」靠自觉
#  守不住，这里强制。
#
#  检查项（对应 docs/development.md「注释规范」）：
#    ① 文件头注释块 ≤ 16 行
#    ② 任何一段连续注释 ≤ 10 行
#
#  豁免：
#    · shebang（首行 #!）不计入
#    · 声明表 image/lines.conf 的字段说明块（它本身就是给人读的表格）单独放宽
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'PY'
import pathlib, sys

HEAD_MAX = 16
BLOCK_MAX = 10
# 这些文件的注释块本身就是「给人读的说明」，放宽到 30 行
LENIENT = {'image/lines.conf': 30}

SCAN = []
for d in ('image', '.github/scripts', '.github/workflows'):
    p = pathlib.Path(d)
    if p.exists():
        SCAN += [f for f in p.rglob('*')
                 if f.is_file() and f.suffix in {'.sh', '.yml', '.env', '.conf', '.service', ''}]
for name in ('docker-compose.yml', 'Makefile', '.dockerignore', '.editorconfig', '.shellcheckrc'):
    f = pathlib.Path(name)
    if f.exists():
        SCAN.append(f)

bad: list[str] = []
for f in sorted(set(SCAN)):
    try:
        lines = f.read_text(encoding='utf-8').splitlines()
    except (UnicodeDecodeError, OSError):
        continue
    if not lines:
        continue

    limit_head = LENIENT.get(str(f), HEAD_MAX)

    # 切出连续注释块：(起始行号, 长度)。首行 shebang 不计入。
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith('#') and not lines[i].startswith('#!'):
            j = i
            while j < len(lines) and (lines[j].lstrip().startswith('#')
                                      or (j == i and lines[j].startswith('#!'))):
                j += 1
            blocks.append((i, j - i))
            i = j
        else:
            i += 1
    if not blocks:
        continue

    start, n = blocks[0]
    if n > limit_head:
        bad.append(f'{f}:{start+1}: 文件头注释 {n} 行 > 上限 {limit_head} 行')

    limit_block = LENIENT.get(str(f), BLOCK_MAX)
    for start, n in blocks[1:]:
        if n > limit_block:
            bad.append(f'{f}:{start+1}: 注释块 {n} 行 > 上限 {limit_block} 行'
                       f'（长推导写进 docs/，这里留一行指针）')

if bad:
    for b in bad:
        print(f'  FAIL {b}')
    print('  注释规范见 docs/development.md「注释规范」')
    sys.exit(1)
print(f'  ok  注释体积（文件头 ≤{HEAD_MAX} 行、注释块 ≤{BLOCK_MAX} 行）')
PY
