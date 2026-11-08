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

## v25 — 移除顶栏，入口统一为长按空白（2026-11-08）

需求：顶部「恢复原生」和「网格设置」两个按钮连占位一起去掉，下方元素上顶；
原生列表的「返回网格」浮动按钮也去掉；两个方向都改为长按空白处唤出菜单。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 类声明 | 删 `bar` / `returnButton` 属性；新增 `hostLongPress`；类补 `UIGestureRecognizerDelegate` |
| 同上 | `loadView` | 删除 `bar`（两个按钮 + `UIStackView`）与 `returnButton` 的创建；长按手势从 `collection` 改挂 `panel`；新建 `hostLongPress`（0.5s，默认禁用） |
| 同上 | `viewDidLayoutSubviews` | 删 `bar.frame` 与 `returnButton.frame`；`search.y` 由 `top+40` 改为 `top`；`headerHeight` 由 `40+(8 or 48)` 改为 `8 or 48`；末尾调 `lgEnsureHostPress` |
| 同上 | `applyMode` | 不再控制 `returnButton`；改为开关 `hostLongPress.enabled` 并重挂手势 |
| 同上 | `handleLongPress` | `indexPath == nil` 不再直接 return，改走空白分支：按住累计约 0.65s（0.3s 识别 + 0.35s 等待）或快速松手弹 `showSettings`，移动超过 6pt 取消；空白分支不出触感、不进入拖动 |
| 同上 | 新增 `LGIsInteractive` | 从命中视图向上找，遇到 `UIControl`/`UICollectionViewCell`/`UITableViewCell` 判为交互元素，遇到列表容器判为空白 |
| 同上 | 新增 `lgEnsureHostPress` | 把 `hostLongPress` 挂到宿主 `navigationController.view`，覆盖导航栏与整个列表区域（原生模式下我们的 panel 是隐藏的，收不到触摸） |
| 同上 | 新增 `gestureRecognizerShouldBegin:` | 命中交互元素时拒绝识别，保证原生按钮与列表行照常工作 |
| 同上 | 新增 `handleHostLongPress` / `showNativeSwitchMenu` | 原生模式长按空白 → 精简菜单（只有「切换到网格布局」+「取消」） |
| 同上 | `showSettings` | 末项改为动态切换文案与动作；iPad popover 锚点由 `bar` 改为 `view` |
| 同上 | `exportLog` | iPad popover 锚点由 `bar` 改为 `view` |
| 同上 | `dealloc` | 从宿主 view 移除 `hostLongPress` |
| `VERSION` | | 24 → 25 |

### 为什么没有改原生排序菜单

最初设想是在 LiveContainer 排序菜单（默认 / 名称升序 / 名称降序 / 上次打开 / 安装时间 / 自定义）
里加一项「网格布局」。查 `LCSS/LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` 后确认做不到：

```swift
Menu {
    Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
        ForEach(AppSortType.allCases, id: \.self) { ... }   // 编译期枚举
    }
}
```

选项来自 `AppSortType: CaseIterable`，运行时无法追加 case，SwiftUI 的 `Menu` 也没有
外部注入子项的 API。不改 IPA、不 hook 的前提下只能放弃，最终仍用长按。
