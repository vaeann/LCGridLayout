#!/usr/bin/env python3
"""把 .github/RELEASE_TEMPLATE.md 渲染成 Release 说明。

单独放成脚本而不是写在 workflow 的 `run: |` 里，是因为 YAML 块标量会把缩进
一起写进正文：heredoc 的 Python 代码会带 10 个空格前缀，直接 IndentationError；
写成 Markdown 又会被渲染成代码块。

用法：python3 scripts/render_release_notes.py <version> <commit> <label> <is_beta> [note]
  version  0.0.1 —— 产物文件名用的版本号，测试版和正式版都一样
  label    0.0.1 beta1（测试版）或 0.0.1（正式版）—— 只用于标题展示
  is_beta  "true" 时额外插入测试版提示
输出：标准输出（workflow 里重定向到文件）
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

BETA_NOTE = (
    "> **测试版**：功能和交互仍在调整，可能随时变动。"
    "装机前确认 Tweaks 里只保留一个 `LCGridLayout*`。\n"
)


def main() -> int:
    argv = sys.argv
    version = argv[1] if len(argv) > 1 else ""
    commit = argv[2] if len(argv) > 2 else ""
    label = argv[3] if len(argv) > 3 else version
    is_beta = len(argv) > 4 and argv[4].strip().lower() == "true"
    note = argv[5] if len(argv) > 5 else ""

    template = ROOT / ".github" / "RELEASE_TEMPLATE.md"
    text = template.read_text(encoding="utf-8")
    for key, value in (
        ("VERSION", version),
        ("COMMIT", commit),
        ("LABEL", label),
        ("BETA_NOTE", BETA_NOTE if is_beta else ""),
    ):
        text = text.replace("{{" + key + "}}", value)

    if note.strip():
        text = text.rstrip() + "\n\n---\n\n" + note.strip() + "\n"

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
