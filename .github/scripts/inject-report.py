#!/usr/bin/env python3
"""把 report.md 注入 README 的标记区（DAILY-VERIFY-REPORT:START / END）。

用法：inject-report.py [report.md 路径]
默认读取仓库根目录的 report.md，写入 README.md 的标记区块之间。
CI 与本地复用同一份逻辑，保证「网页内嵌」的报告内容与根目录 report.md 一致。
"""
import re
import sys
import pathlib

REPORT_TITLE = "# 📊 已发布镜像每日验证报告"
START = "<!-- DAILY-VERIFY-REPORT:START -->"
END = "<!-- DAILY-VERIFY-REPORT:END -->"


def main() -> int:
    root = pathlib.Path(".")
    readme_path = root / "README.md"
    report_path = root / (sys.argv[1] if len(sys.argv) > 1 else "report.md")

    if not readme_path.exists():
        sys.exit("README.md 不存在")
    if not report_path.exists():
        sys.exit(f"{report_path} 不存在")

    readme = readme_path.read_text(encoding="utf-8")
    report = report_path.read_text(encoding="utf-8")

    # 报告首行是 H1，降级为 H3，避免 README 出现两个一级标题
    report = report.replace(REPORT_TITLE, "### 📊 已发布镜像每日验证报告", 1)

    pat = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    if not pat.search(readme):
        sys.exit("README.md 缺少报告注入标记，请先添加 DAILY-VERIFY-REPORT 标记区")

    readme = pat.sub(f"{START}\n{report.strip()}\n{END}", readme)
    readme_path.write_text(readme, encoding="utf-8")
    print("已注入 README 报告区")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
