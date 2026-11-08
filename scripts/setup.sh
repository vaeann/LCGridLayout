#!/bin/bash
# 本地环境一次配置。新克隆的仓库跑一次即可；换机器、换 clone 也要重跑。
#
#   bash scripts/setup.sh              # 只配置，不动工作区
#   bash scripts/setup.sh --fix-eol    # 顺带把已被 CRLF 污染的文件归一化（会丢弃未提交改动）
#
# 为什么需要：仓库在 Windows 上开发、在 macOS runner 上构建。Windows 全局
# core.autocrlf=true 会把 LF 改成 CRLF，单文件 1000+ 行源码立刻变成"整篇重写"的 diff。
set -euo pipefail

cd "$(dirname "$0")/.."
FIX_EOL=0
[[ "${1:-}" == "--fix-eol" ]] && FIX_EOL=1

say() { printf '  %s\n' "$*"; }

echo "== 1/4 行尾策略 =="
git config core.autocrlf false
git config core.eol lf
say "core.autocrlf=false, core.eol=lf"

echo "== 2/4 merge=ours 驱动 =="
# .gitattributes 里标了 merge=ours 的文件需要这个 driver 才会真正生效。
git config merge.ours.driver true
say "merge.ours.driver=true（同步上游时，本仓库自有文件不被覆盖）"

echo "== 3/4 upstream 远程 =="
if git remote get-url upstream >/dev/null 2>&1; then
  say "upstream 已存在：$(git remote get-url upstream)"
else
  git remote add upstream https://github.com/Kan9e/LCGridLayout.git
  say "已添加 upstream -> https://github.com/Kan9e/LCGridLayout.git"
fi

echo "== 4/4 工具检查 =="
command -v git >/dev/null || { echo "缺少 git"; exit 1; }
say "git $(git --version | awk '{print $3}')"
if command -v python3 >/dev/null; then
  say "python3 $(python3 -V 2>&1 | awk '{print $2}')"
elif command -v python >/dev/null; then
  say "python $(python -V 2>&1 | awk '{print $2}')（脚本里用 python3 的场合请自行替换）"
else
  echo "  ! 没找到 python。scripts/lint.py 和 verify_macho.py 需要它。" >&2
fi

if [[ $FIX_EOL -eq 1 ]]; then
  echo "== 归一化行尾 =="
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区有未提交改动，已中止。请先 stash 或提交。" >&2
    exit 1
  fi
  git rm --cached -r . >/dev/null
  git reset --hard >/dev/null
  say "已按 .gitattributes 重新检出，行尾统一为 LF"
fi

echo
echo "完成。构建前的本地自检："
echo "  python3 scripts/lint.py"
