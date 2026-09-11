#!/usr/bin/env python3
"""把报告注入 README 的标记区。

用法：report.py [报告路径] [标记名]
默认读取 .github/reports/report.md，注入 DAILY-VERIFY-REPORT 标记区。
标记名决定 START/END 注释：<!-- 标记名:START --> / <!-- 标记名:END -->。
报告首行若是 H1，则降级为 H3，避免 README 出现两个一级标题；验证报告与
漂移报告各自嵌在不同的 H2 章节下，互不冲突。CI 与本地复用同一份逻辑。
"""
import re
import sys
import pathlib


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

    # 报告首行是 H1，降级为 H3，避免 README 出现两个一级标题。
    # 不加 re.M：^ 只锚定整串开头，否则会命中正文代码块里的 "# 注释" 那一行
    report = re.sub(r'^# ', '### ', report, count=1)

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
