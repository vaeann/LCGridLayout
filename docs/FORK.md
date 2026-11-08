# 本仓库相对上游的改动

AGPL-3.0 第 5(a) 条要求衍生作品标注修改并给出日期。以下是本 fork 相对
[Kan9e/LCGridLayout](https://github.com/Kan9e/LCGridLayout) 的**全部**差异。

同步上游时不要删除本文件，也不要删掉 `.github/upstream-state.json`。

## 基础设施（2026-11-08）

上游只提供 `scripts/build.sh`，需要本机装完整 Xcode。本仓库在 Windows 上开发，
因此补齐了「没有 Mac 也能出包」的链路。

| 日期 | 文件 | 改动 |
|---|---|---|
| 2026-11-08 | `.github/workflows/build.yml` | 新增。macOS runner 上跑 `build.sh`，校验 Mach-O 后上传 artifact；手动触发时可自动发 Release。runner 固定 `macos-26-intel`（arm64 runner 排队 15 分钟会被系统放弃） |
| 2026-11-08 | `.github/workflows/guard.yml` | 新增。push 即跑的秒级守卫：LICENSE 哈希、敏感文件、静态自检、衍生声明完整性、关键文件存在性、LF 行尾 |
| 2026-11-08 | `.github/workflows/check-upstream.yml` | 新增。每天比对上游 commit，有新提交就开 issue（不重复开） |
| 2026-11-08 | `.github/RELEASE_TEMPLATE.md` | 新增。Release 说明模板，自动附对应 commit 的源码链接（AGPL 分发义务） |
| 2026-11-08 | `.github/UPSTREAM_ISSUE.md` | 新增。上游更新 issue 的正文模板 |
| 2026-11-08 | `.github/upstream-state.json` | 新增。记录本地已同步到的上游 commit，`check-upstream` 靠它判断 |
| 2026-11-08 | `scripts/lint.py` | 新增。Windows 本地可跑的毫秒级检查：括号 / `@end` 配对、CRLF 混入、VERSION 合法性、硬编码路径 |
| 2026-11-08 | `scripts/setup.sh` | 新增。新 clone 后一次配置：`core.autocrlf=false`、`merge.ours.driver`、upstream 远程 |
| 2026-11-08 | `scripts/render_release_notes.py` | 新增。渲染 Release 说明（避免把 heredoc 写进 YAML 块标量） |
| 2026-11-08 | `scripts/issue_body.py` | 新增。渲染上游提醒 issue 正文 |
| 2026-11-08 | `.gitattributes` | 新增。全仓库强制 LF（Windows 的 `core.autocrlf=true` 会把 1000+ 行单文件变成整篇 diff）；自有文件标记 `merge=ours` |
| 2026-11-08 | `.gitignore` | 追加 fork 本地目录忽略规则 |
| 2026-11-08 | `NOTICE.md` | 新增。衍生作品署名、上游声明、第三方组件清单 |
| 2026-11-08 | `docs/FORK.md` | 新增。本文件 |
| 2026-11-08 | `docs/DEVELOPING.md` | 新增。架构地图与二次开发入口 |
| 2026-11-08 | `README.md` | 顶部加入衍生作品声明与改动入口 |

## 业务源码

**`Sources/LCGridLayout.m` 在本时间点未做任何修改**，与上游 v24 一致。
构建产物与上游 Release 行为相同。

（二次开发开始后，在这张表里追加每个版本改了哪个函数、为什么改。）
