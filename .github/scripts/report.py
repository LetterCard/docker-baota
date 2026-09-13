#!/usr/bin/env python3
"""把报告注入 README 的标记区。

用法：report.py [报告路径] [标记名]
默认读取 .github/reports/report.md，注入 DAILY-VERIFY-REPORT 标记区。
标记名决定 START/END 注释：<!-- 标记名:START --> / <!-- 标记名:END -->。
报告要嵌在 README 的 H2 章节下，因此整篇标题统一降 2 级（H1→H3、H2→H4…，H6 封顶）：
只降首行的话，报告内部的 H2 会与 README 的章节标题同级，显示成一样大的字（层级看起来是乱的），
首行的 H1 也会让 README 多出一个一级标题。CI 与本地复用同一份逻辑。
"""
import re
import sys
import pathlib

# 报告嵌在 README 的 H2 章节下，标题整体降几级
DEMOTE = 2


def demote_headings(text: str) -> str:
    """把报告里的标题整体降 DEMOTE 级（H6 封顶）。

    跳过围栏代码块：报告里含 bash / 日志片段，`# 注释` 那一行不是标题，
    跟着降级会把代码内容改坏。
    """
    out = []
    fenced = False
    for line in text.splitlines():
        if re.match(r'^\s*(```|~~~)', line):
            fenced = not fenced
            out.append(line)
            continue
        m = None if fenced else re.match(r'^(#{1,6})(\s.*)$', line)
        if m:
            line = '#' * min(len(m.group(1)) + DEMOTE, 6) + m.group(2)
        out.append(line)
    return '\n'.join(out)


def main() -> int:
    root = pathlib.Path(".")
    readme_path = root / "README.md"
    report_path = root / (sys.argv[1] if len(sys.argv) > 1 else ".github/reports/report.md")
    marker = sys.argv[2] if len(sys.argv) > 2 else "DAILY-VERIFY-REPORT"
    START = f"<!-- {marker}:START -->"
    END = f"<!-- {marker}:END -->"

    if not readme_path.exists():
        sys.exit("README.md 不存在")
    if not report_path.exists():
        sys.exit(f"{report_path} 不存在")

    readme = readme_path.read_text(encoding="utf-8")
    report = report_path.read_text(encoding="utf-8")

    # 整篇标题降 2 级，让报告严格嵌在 README 的 H2 章节之下（见 demote_headings）
    report = demote_headings(report)

    pat = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    if not pat.search(readme):
        sys.exit(f"README.md 缺少报告注入标记 {marker}，请先添加 {marker}:START/END 标记区")

    # 用 lambda 而非替换字符串：报告里含 bash / 日志片段，若出现 \1、\g<n>
    # 之类序列会被当成反向引用，轻则替换错乱、重则直接抛 re.error
    readme = pat.sub(lambda m: f"{START}\n{report.strip()}\n{END}", readme)
    readme_path.write_text(readme, encoding="utf-8")
    print(f"已注入 README 报告区（{marker}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
