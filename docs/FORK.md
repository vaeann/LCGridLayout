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

## v27 — 网格独占全屏，双击改道，原生菜单居中（2026-11-08）

实测反馈：网格模式下双击顶部空白会把 LiveContainer 的搜索界面叫出来，整页网格被盖住；
同时双击切换本身没有生效。根因是网格模式下宿主导航栏仍显示，双击落在了它的地盘上。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 新增 `lgSetNavigationBarHidden:` | 网格模式隐藏宿主导航栏（`setNavigationBarHidden:YES`），原生模式恢复；`applyMode`、`viewDidLayoutSubviews` 各调一次（后者是因为 `applyMode` 时视图还没进导航栈），`LGTick` 在页面失活时、`dealloc` 时兜底恢复 |
| 同上 | `viewDidLayoutSubviews` | 导航栏隐藏时忽略宿主搜索框、且不再做 `compactTop` 的 `-44` 补偿（没有大标题就没有幻影留白），`top` 直接取 `safeAreaInsets.top` |
| 同上 | `lgGestureAllowsTouch:` | 双击区域改成两段：网格 = 面板坐标 `y < 搜索框顶部`（即灵动岛下方那片）；原生 = `y > lgTopInset + 64`（搜索框以下的列表空白），彻底避开 LiveContainer 的导航栏 |
| 同上 | 删除 `lgTopBlankLimitInView:` | 区域判断内联到上面，原方法不再需要 |
| 同上 | 新增 `LGCardAlertController` | 居中卡片：半透明遮罩 + 300pt 圆角卡片 + 标题/说明/主按钮/取消，视觉与设置面板一致 |
| 同上 | `showNativeSwitchMenu` | 从底部 action sheet 换成 `LGCardAlertController` |
| `VERSION` | | 26 → 27 |

网格模式下不再有任何原生导航栏元素，双击也不会再触发 LiveContainer 的搜索。

## v26 — 双击切换布局、设置面板改卡片（2026-11-08）

需求：原生 ↔ 网格支持双击直接切换（带「是 / 否」确认，双击区域限定在搜索框上方的顶部空白，
即灵动岛下方那一条）；长按呼出设置的行为保持不变、整页空白都生效；弹出的设置菜单原来是一条
细长的 action sheet，改成规整的卡片面板。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 新增 `LGSheetAction` + `LGSheetController` | 卡片式设置面板：标题 + 摘要、列数分段、名称开关、顶部间距分段、背景选择/移除、导出日志、切换到原生列表；`UISheetPresentationController` 的 medium/large detent，可上拉放大 |
| 同上 | 新增 `navDoubleTap` | 一个双击手势挂在宿主 `nav.view`，两种模式共用，按 `nativeMode` 决定方向 |
| 同上 | `lgTopBlankLimitInView:` | 算出「顶部空白」的下边界：我们的搜索框顶部 → 宿主搜索框顶部 → 导航栏底部，逐级回退 |
| 同上 | `lgGestureAllowsTouch:` / `gestureRecognizer:shouldReceiveTouch:` | 用 `shouldReceiveTouch` 在触摸开始就排除 `UIControl` / cell，并给双击加上顶部区域限制。这一步放在 `shouldReceiveTouch` 而不是 `shouldBegin`，是为了不让单击图标的启动被双击判定拖慢 |
| 同上 | `handleNavDoubleTap` / `confirmSwitchToNative:` | 双击后弹「确定切换到…吗？是 / 否」，确认后才切 |
| 同上 | `showSettings` / `handleSheetAction:` | 从 action sheet 改为呈现 `LGSheetController`；列数、名称、间距改完面板不关闭、背后网格实时更新，背景与日志在面板关闭后再弹选择器 |
| 同上 | `lgEnsureHostPress` | 同时挂 `hostLongPress` 与 `navDoubleTap` |
| `VERSION` | | 25 → 26 |

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
