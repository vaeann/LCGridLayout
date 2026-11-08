#!/usr/bin/env python3
"""把 .github/RELEASE_TEMPLATE.md 渲染成 Release 说明。

单独放成脚本而不是写在 workflow 的 `run: |` 里，是因为 YAML 块标量会把缩进
一起写进正文：heredoc 的 Python 代码会带 10 个空格前缀，直接 IndentationError；
写成 Markdown 又会被渲染成代码块。

用法：python3 scripts/render_release_notes.py <version> <commit> <run> [note]
输出：标准输出（workflow 里重定向到文件）
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    version = sys.argv[1] if len(sys.argv) > 1 else ""
    commit = sys.argv[2] if len(sys.argv) > 2 else ""
    run = sys.argv[3] if len(sys.argv) > 3 else ""
    note = sys.argv[4] if len(sys.argv) > 4 else ""

    template = ROOT / ".github" / "RELEASE_TEMPLATE.md"
    text = template.read_text(encoding="utf-8")
    for key, value in (("VERSION", version), ("COMMIT", commit), ("RUN", run)):
        text = text.replace("{{" + key + "}}", value)

    if note.strip():
        text = text.rstrip() + "\n\n---\n\n" + note.strip() + "\n"

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
