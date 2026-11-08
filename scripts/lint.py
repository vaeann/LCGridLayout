#!/usr/bin/env python3
"""LCGridLayout 源码静态自检。

在 Windows 上开发时没有 Xcode，唯一的编译验证是 CI 的 macOS runner（几分钟一轮）。
这个脚本把最容易犯、编译器才会发现的笔误提前到毫秒级抓出来：

  * 括号 / 大括号 / 方括号 未配对（单文件 1000+ 行手改最常漏）
  * @interface / @implementation / @protocol 与 @end 未闭合
  * 文件混入 CRLF（Windows 编辑器常见，会导致 CI 上 git apply / patch 失败）
  * VERSION 不是纯数字（build.sh 会拼进产物文件名）
  * 明显不该出现的东西（硬编码的绝对路径、TODO 占位）

用法：
    python3 scripts/lint.py            # 检查全部
    python3 scripts/lint.py --quiet    # 只报错

退出码 0 = 通过，1 = 有问题。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources" / "LCGridLayout.m"
VERSION_FILE = ROOT / "VERSION"

# 编译单元。以后拆成多个 .m 时在这里加。
SOURCES = [SOURCE]

PAIRS = {")": "(", "]": "[", "}": "{"}


class Stripper:
    """把注释 / 字符串 / 字符字面量换成空格，保留换行以便行号准确。

    ObjC 的 @"" 字符串里可以出现任意括号，注释里也是。不先剥掉会大量误报。
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.out: list[str] = []

    def run(self) -> str:
        text, i, n = self.text, 0, len(self.text)
        while i < n:
            ch = text[i]
            nxt = text[i + 1] if i + 1 < n else ""

            if ch == "/" and nxt == "/":
                while i < n and text[i] != "\n":
                    self._put(" ")
                    i += 1
            elif ch == "/" and nxt == "*":
                self._put(" ")
                self._put(" ")
                i += 2
                while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                    self._put("\n" if text[i] == "\n" else " ")
                    i += 1
                if i < n:
                    self._put(" ")
                    self._put(" ")
                    i += 2
            elif ch == '"' or ch == "'":
                quote = ch
                self._put(" ")
                i += 1
                while i < n and text[i] != quote:
                    if text[i] == "\\" and i + 1 < n:
                        self._put(" ")
                        i += 1
                    self._put("\n" if text[i] == "\n" else " ")
                    i += 1
                if i < n:
                    self._put(" ")
                    i += 1
            else:
                self._put(ch)
                i += 1
        return "".join(self.out)

    def _put(self, ch: str) -> None:
        self.out.append(ch)


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def check_brackets(clean: str, errors: list[str], name: str) -> None:
    stack: list[tuple[str, int]] = []
    for idx, ch in enumerate(clean):
        if ch in "([{":
            stack.append((ch, idx))
        elif ch in PAIRS:
            if not stack:
                errors.append(f"{name}:{line_of(clean, idx)}: 多余的 '{ch}'，没有对应的 '{PAIRS[ch]}'")
                continue
            top, top_idx = stack.pop()
            if top != PAIRS[ch]:
                errors.append(
                    f"{name}:{line_of(clean, idx)}: '{ch}' 与第 {line_of(clean, top_idx)} 行的 "
                    f"'{top}' 不匹配"
                )
    for ch, idx in stack:
        errors.append(f"{name}:{line_of(clean, idx)}: '{ch}' 没有闭合")


BLOCK_RE = re.compile(r"@(interface|implementation|protocol|end)\b")


def check_objc_blocks(clean: str, errors: list[str], name: str) -> None:
    """@interface / @implementation / @protocol 必须各自被 @end 关闭。

    类扩展 `@interface Foo ()` 同样需要一个 @end，所以不特殊处理——
    栈式配对天然正确。
    """
    stack: list[tuple[str, int]] = []
    for match in BLOCK_RE.finditer(clean):
        kind = match.group(1)
        if kind == "end":
            if not stack:
                errors.append(f"{name}:{line_of(clean, match.start())}: 多余的 @end")
                continue
            stack.pop()
        else:
            stack.append((kind, match.start()))
    for kind, idx in stack:
        errors.append(f"{name}:{line_of(clean, idx)}: @{kind} 没有对应的 @end")


def check_crlf(raw: bytes, errors: list[str], name: str) -> None:
    if b"\r\n" in raw:
        count = raw.count(b"\r\n")
        first = raw[: raw.index(b"\r\n")].count(b"\n") + 1
        errors.append(
            f"{name}:{first}: 混入 {count} 处 CRLF 行尾。仓库统一用 LF；"
            f"在 Windows 上请确认编辑器没有把行尾改掉（git config core.autocrlf 应为 false）"
        )


def check_version(errors: list[str]) -> None:
    if not VERSION_FILE.exists():
        errors.append("VERSION: 文件缺失，build.sh 会拒绝构建")
        return
    raw = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+", raw):
        errors.append(f"VERSION: 必须是纯数字（当前 '{raw}'），它会拼进 dylib 文件名")
    elif int(raw) < 1:
        errors.append(f"VERSION: 必须 >= 1（当前 {raw}）")


# 硬编码绝对路径在设备上必然失效；广告 / 兜底占位符不该进产物。
BAD_PATTERNS = [
    (re.compile(r'"/Users/[^"]*"'), "硬编码的 macOS 用户路径"),
    (re.compile(r'"/private/var/[^"]*"'), "硬编码的沙盒绝对路径（应走 NSFileManager）"),
    (re.compile(r"\bFIXME\b"), "FIXME 占位符"),
]


def check_patterns(clean: str, errors: list[str], name: str) -> None:
    for pattern, why in BAD_PATTERNS:
        for match in pattern.finditer(clean):
            errors.append(f"{name}:{line_of(clean, match.start())}: {why}: {match.group(0)}")


def main() -> int:
    quiet = "--quiet" in sys.argv
    errors: list[str] = []
    stats: list[str] = []

    missing = [p for p in SOURCES if not p.exists()]
    if missing:
        for p in missing:
            errors.append(f"{p.relative_to(ROOT)}: 源码文件缺失")
    else:
        for path in SOURCES:
            name = str(path.relative_to(ROOT)).replace("\\", "/")
            raw = path.read_bytes()
            check_crlf(raw, errors, name)
            text = raw.decode("utf-8")
            clean = Stripper(text).run()
            check_brackets(clean, errors, name)
            check_objc_blocks(clean, errors, name)
            check_patterns(clean, errors, name)
            stats.append(f"{name}: {text.count(chr(10)) + 1} 行")

    check_version(errors)

    if errors:
        print(f"静态检查失败：{len(errors)} 个问题\n", file=sys.stderr)
        for item in errors:
            print(f"  ✗ {item}", file=sys.stderr)
        print("\n修好再提交；CI 的 clang 只会在这些之后才报错。", file=sys.stderr)
        return 1

    if not quiet:
        print("静态检查通过")
        for item in stats:
            print(f"  ✓ {item}")
        print(f"  ✓ VERSION: {VERSION_FILE.read_text(encoding='utf-8').strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
