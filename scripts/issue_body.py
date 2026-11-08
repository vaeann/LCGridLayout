#!/usr/bin/env python3
"""渲染上游更新提醒 issue 的正文。

用法：python3 scripts/issue_body.py <sha> <msg> <date> <synced>
输出：标准输出
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    sha = sys.argv[1] if len(sys.argv) > 1 else ""
    msg = sys.argv[2] if len(sys.argv) > 2 else ""
    date = sys.argv[3] if len(sys.argv) > 3 else ""
    synced = sys.argv[4] if len(sys.argv) > 4 else ""

    text = (ROOT / ".github" / "UPSTREAM_ISSUE.md").read_text(encoding="utf-8")
    for key, value in (
        ("SHA", sha),
        ("MSG", msg),
        ("DATE", date),
        ("SYNCED", synced or "未记录"),
    ):
        text = text.replace("{{" + key + "}}", value)

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
