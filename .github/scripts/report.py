#!/usr/bin/env python3
# ==============================================================================
#  📝 把报告注入 README 的标记区（整篇标题降 2 级，代码块内标题不动）
#
#  为什么：报告本身用 H1 写，直接塞进 README 会跟章节标题同级、目录里冒出重复项。
#
#  相关：docs/development.md#标题层级
# ==============================================================================

import re, sys, pathlib

DEMOTE = 2

def demote_headings(text: str) -> str:
    out, fenced = [], False
    for line in text.splitlines():
        if re.match(r'^\s*(```|~~~)', line):
            fenced = not fenced
            out.append(line)
            continue
        m = None if fenced else re.match(r'^(#{1,6})(\s.*)$', line)
        out.append('#' * min(len(m.group(1)) + DEMOTE, 6) + m.group(2) if m else line)
    return '\n'.join(out)

readme_path = pathlib.Path('README.md')
report_path = pathlib.Path((sys.argv[1] if len(sys.argv) > 1 else '') or '.github/reports/report.md')
marker = (sys.argv[2] if len(sys.argv) > 2 else '') or 'DAILY-VERIFY-REPORT'
if not readme_path.exists():
    sys.exit('README.md 不存在')
if not report_path.exists():
    sys.exit(f'{report_path} 不存在')
start = f'<!-- {marker}:START -->'
end = f'<!-- {marker}:END -->'
readme = readme_path.read_text(encoding='utf-8')
report = demote_headings(report_path.read_text(encoding='utf-8'))
pat = re.compile(re.escape(start) + r'.*?' + re.escape(end), re.S)
if not pat.search(readme):
    sys.exit(f'README.md 缺少报告注入标记 {marker}，请先添加 {marker}:START/END 标记区')
readme = pat.sub(lambda m: f'{start}\n{report.strip()}\n{end}', readme)
readme_path.write_text(readme, encoding='utf-8')
print(f'已注入 README 报告区（{marker}）')
