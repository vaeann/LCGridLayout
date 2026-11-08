上游 [Kan9e/LCGridLayout](https://github.com/Kan9e/LCGridLayout) 有新提交。

- commit: `{{SHA}}`
- 说明: {{MSG}}
- 时间: {{DATE}}
- 本地同步点: `{{SYNCED}}`

## 同步步骤

```bash
git fetch upstream
git merge upstream/main        # 或 git rebase upstream/main
python3 scripts/lint.py        # 先过静态检查，再 push 让 CI 编译
```

冲突时优先保留本仓库的改动（`.gitattributes` 已给自有文件标记 `merge=ours`，
前提是跑过 `bash scripts/setup.sh`）。

同步完成后更新 `.github/upstream-state.json` 的 `synced_commit` 和 `synced_at`，再关闭本 issue。
