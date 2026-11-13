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

## 0.0.1 beta9 — 关掉自动安全区补偿，收紧首行间距（2026-11-13）

beta8 顶部锚点正确了（标题紧贴按钮行），但标题与第一行图标之间多出约 52pt。

原因是 `UICollectionView` 的 `contentInsetAdjustmentBehavior` 默认 `.automatic`：
我们的视图挂在 safeArea 很大的宿主里，UIKit 自动补了一次顶部安全区，相当于又加了一条
大标题的高度。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `loadView` | `collection.contentInsetAdjustmentBehavior = .never`（布局我们自己控制） |
| 同上 | `lgLayoutContentWithWidth:` | 标题与网格间距 8 → 6；`sectionInset.top` 12 → 4，贴近原生首行位置 |
| 同上 | 同上 | 加一次性日志 `Layout top=… title=… grid=… inset=…` 便于核对 |
| `VERSION` | | 不变（0.0.1） |

## 0.0.1 beta8 — 顶部锚点改用按钮行（2026-11-13）

beta7 扫描 `UINavigationBar` 子视图找「高度 38–52 的一行」，在 iOS 26 的新层级里没命中，
退回旧估算，于是「原生搜索展开后切宫格」仍留一条空白。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `lgTopInset` / `lgNavButtonBottomInBar:` | 改为在导航栏里遍历所有 `UIControl`（排除类名含 Search 的），取**最小 maxY**＝按钮行底边，+4 作为标题起点。按钮行不随大标题、搜索展开移动 |
| 同上 | 兜底 | 扫不到时用 `窗口 safeArea.top + 44`（iPad 50） |
| 同上 | `lgAdoptHostDoubleTaps:` | 已接管的手势记进弱集合，不重复 `requireGestureRecognizerToFail:`；日志每会话一条 |
| 同上 | `LGTick` / `refresh` | `wasAway` 抖动不再每次触发重扫（离开 >0.4s 才刷）；`Loaded N app(s)` 仅在数量变化时记录 |
| `VERSION` | | 不变（0.0.1） |

## 0.0.1 beta7 — 顶部锚点改按钮行、运行状态角标（2026-11-13）

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `lgTopInset` | 不再用「整条 bar 高度 - 52」的估算。改为扫描 `UINavigationBar` 子视图，取高度 38–52、宽度 ≥70% 的那一行的**最小底边**＝按钮行。大标题展开、搜索展开都不会再留白 |
| 同上 | `LGRunningGuest` / `LGCanCloseGuests` / `LGCloseGuestEntry` | 运行状态取 `LCSharedUtils.getContainerUsingLCSchemeWithFolderName:`（非空＝容器被占用）；关闭走 `LCOrbitMultitask closeGuest:error:`，不存在该类的 LC 上不显示红叉 |
| 同上 | `LGCell` | 新增 `runningLight`（12pt，绿核 + 呼吸光晕，`UIAccessibilityReduceMotion` 时停动画）与 `closeBadge`（自绘红底白叉，24pt 热区）；位置分别是图标右下 / 右上 |
| 同上 | `scrollViewDidScroll` 之外的 `lgSyncLayout` | 每 1s 刷新可见 cell 的运行状态 |
| 同上 | `gestureRecognizer:shouldReceiveTouch:` | 长按落在红叉上时不再触发拖动/菜单 |
| `VERSION` | | 不变（0.0.1，beta 序号 +1） |

## 0.0.1 beta6 — 单按钮双手势、标题加粗上移、日志行去卡片（2026-11-13）

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `switchButton` 取代 `settingsButton` | 悬浮按钮合并：点按 `toggleMode` 切布局，长按 `handleSwitchLongPress:`（0.45s + 轻触感）开设置；图标显示目标模式（网格→`list.bullet`，原生→`square.grid.3x3.fill`） |
| 同上 | `lgTopInset` | 宿主大标题展开时导航栏高 ~96；减去 52 的文字带，让我们自绘的「App」紧贴按钮行，不再留一段空档 |
| 同上 | `titleLabel.font` | `preferredFontForTextStyle` 不保证粗体，改为 `systemFontOfSize:34 weight:bold` 再经 `UIFontMetrics` 缩放 |
| 同上 | `LGSheetController` | 「导出调试日志」从卡片里拿出来，直接放底色上（16pt 缩进、52pt 高） |
| `VERSION` | | 不变（0.0.1，beta 序号 +1） |

## 0.0.1 beta5 — 顶部对齐原生：App 大标题 + 下拉搜索（2026-11-13）

需求：宫格页除了内容区以外，视觉要与原生一致——顶部有「App」大标题，搜索栏平时藏着、下拉才出来。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 新增 `titleLabel` | `UIFontTextStyleLargeTitle`（34pt 粗体）、左 16pt、栏下 8pt，与宿主大标题同款；宫格模式下宿主大标题被覆盖，所以这里复刻一份 |
| 同上 | `loadView` | 搜索栏默认 `hidden = YES`；占位符改成「搜索」；输入框底色 `tertiarySystemFillColor`，贴近原生 search field |
| 同上 | `lgLayoutContentWithWidth:height:top:safe:` | 布局拆成独立方法：标题 → 搜索（展开时占 48pt）→ 网格，展开/收起只动这三块 |
| 同上 | `setSearchRevealed:animated:` | 0.22s 动画；收起时清空输入并重过滤 |
| 同上 | `scrollViewDidScroll:` | 下拉超过 24pt 展开、上滑超过 12pt 收起；0.35s 冷却避免改帧本身触发回弹 |
| 同上 | `viewDidLayoutSubviews` | 不再依赖 `hasNativeTopSearch`（原生搜索已被压制隐藏），`top` 只跟导航栏下沿走 |
| `VERSION` | | 不变（0.0.1，beta 序号 +1） |

## 0.0.1 beta4 — 冻结宿主列表，断掉搜索展开的源头（2026-11-13）

截图确认：展开出来的空白是**导航栏被拉高**，我们的面板跟着 `navBarBottom` 一起下移。
真正触发它的是原生列表自己的手势（双击 / 滚到顶），那层在覆盖层**下面**，
挂在 `nav.view` 上的守卫根本不在同一条链路上——所以之前两版都没拦住。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 新增 `lgFreezeHostContent:` | 宫格显示期间，把 `host.view` 里除自己以外的子视图 `userInteractionEnabled = NO`，并关掉 `host.view` 上的所有手势；切回原生/卸载时逐项恢复。列表在覆盖层下本来就不该接收输入 |
| 同上 | 新增 `lgFreezeScrollViewsIn:` | 递归找出 `scrollsToTop == YES` 的滚动视图并关掉。这是独立于触摸的系统通路，「滚到顶」正是展开搜索框的动作 |
| 同上 | `applyMode` / `lgSyncLayout` / `dealloc` | 分别做初始冻结、每 0.5s 复审（SwiftUI 会重建列表）、恢复 |
| `VERSION` | | 不变（0.0.1，beta 序号 +1） |

保留 beta3 的 `requireGestureRecognizerToFail:` 与 `searchController.active = NO` 作为第二层兜底。

## 0.0.1 beta3 — 搜索彻底压死、启动链路对齐微珠（2026-11-13）

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `lgAdoptHostDoubleTaps:` | 遍历导航区里的双击手势，`requireGestureRecognizerToFail:` 我们自己的守卫。`cancelsTouchesInView` 只挡触摸投递、挡不住别的识别器，这才是双击仍会唤起 LC 搜索的原因 |
| 同上 | `lgCollapseHostSearchIfNeeded` | 兜底：若 `navigationItem.searchController.isActive` 仍为真，直接置回 NO，不留空白展开页 |
| 同上 | `lgLaunchEntry:` | 优先调用 `LCSharedUtils.launchToGuestAppWithURL:`（进程内，和微珠一致），失败再走 `UIApplication openURL:` |
| 同上 | `lgContainerExists:` + 启动前检查 | 数据目录 `Documents/Data/Application/<uuid>`（及 group 侧）不存在时，弹窗说明「容器不存在」，可点「仍然尝试」。LC 原生列表对这类 app 同样失败，错误文案是裸文件名 |
| 同上 | `LGReadApps` | 没有 `LCDataUUID` 时，从 `LCContainers` 推断（仅当只有一个容器） |
| 同上 | `LGInitialize` | 启动探针 30ms → 16ms，窗口 1.2s → 1.6s。原生列表闪一下是挂载时机，不是注入失败；不 hook `viewDidAppear` 就只能缩短，不能消除 |
| `VERSION` | | 不变（仍 0.0.1，beta 序号自动 +1） |

## 0.0.1 beta2 — 单按钮、图标与启动修复、搜索压制（2026-11-13）

四条实测反馈：布局切换按钮多余、图标首帧闪一块纯色、个别 app 点了报「未能打开文件」、
网格下双击顶部会弹出 LC 的原生搜索并把我们的搜索框盖住。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 删除 `returnButton` / `lgUpdateSwitchButton` / `toggleMode` | 右下角只留齿轮；布局切换并入设置面板底部 |
| 同上 | `LGSheetAction` 新增 `SwitchToGrid`；`LGSheetController.nativeMode`；`buildNativeBranchInRoot:` | 原生模式下只渲染「切换到宫格布局」+ 取消，不显示看不见效果的网格设置 |
| 同上 | `LGFastIcon` | 除 Apple 固定文件名外，再读 `CFBundleIcons` / `CFBundleIconFiles`，最后扫 bundle 根目录里名字含 icon 的 PNG |
| 同上 | `LGCell` 的 `lgShowIcon:animated:` / `lgShowPlaceholder` | 真实图标淡入；占位从 `app.fill`（实心块，就是那块「纯色」）换成中性色块 |
| 同上 | `prefetchIcons` / `generateIconForEntry:` | refresh 后预取全部图标；生成完成后原地淡入可见 cell，不再 `reloadItems` |
| 同上 | `didSelectItemAtIndexPath:` | 启动 URL 补 `container-folder-name`（`LCAppInfo.plist` 的 `LCDataUUID`）；缺它时 LC 会用别的 app 的容器，报「未能打开文件」 |
| 同上 | `lgSuppressNativeSearch:` / `LGCollectSearchBars` | 网格模式隐藏宿主 search bar 并关掉交互，每 0.5s 复查（SwiftUI 会重建）；切回原生恢复 |
| 同上 | `lgEnsureNavGuard` / `gestureRecognizer:shouldReceiveTouch:` | 在 `nav.view` 上吞掉导航区空白处的双击（按钮除外），阻止 LC 的 searchable 被唤起；离开网格模式时移除 |
| 同上 | `viewDidLayoutSubviews` | 去掉 `compactTop` 的 `-44`（它会把我们的搜索框顶进导航栏）；紧凑＝紧贴栏底，宽松＝+24 |
| `VERSION` | | 保持 0.0.1（测试阶段不升版本号，只加 beta 序号） |

## 版本与发布标记（2026-11-13）

`VERSION` 用语义化三段数字（`主.次.修订`），当前从 **0.0.1** 起步。产物名只带版本号：
`LCGridLayout_v0.0.1.dylib`。Release tag 分两种：

| 阶段 | tag | 标题 | 说明 |
|---|---|---|---|
| 测试版 | `v0.0.1-beta1`、`-beta2` … | `LCGridLayout v0.0.1 beta1` | 标为 pre-release；**`VERSION` 不动**，只有 beta 序号递增 |
| 正式版 | `v0.0.1` | `LCGridLayout v0.0.1` | 去掉 beta，标记为 latest；之后改动才把 `VERSION` 升到 0.0.2 |

**规则**：只要 0.0.1 还没正式发布，所有测试包都叫 `v0.0.1-betaN`。
版本号只在**发布正式版之后**才往上走（0.0.2、0.0.3 …），不要每改一轮就升版本。

beta 序号由 `build.yml` 的「计算发布标记」步骤现算：取现存 `v{版本}-betaN` 里最大的 N 加一。
**不能用 `github.run_number`**——那是仓库级累计值，跟版本无关，几十次无关构建会把
0.0.1 的首个测试版顶成 `beta30`（已踩过）。

发布时勾选「测试版」走 beta，取消勾选就是正式版（同一份代码，只是标记不同）。

历史：2026-11-13 清空过全部 Release / tag / run / artifact；下文 v25–v34 的记录
作为上一轮迭代保留，其产物已删除。

## v30 — 手势全部移除，改为导航栏按钮（2026-11-08）

用户决定：不再用手势切布局。原生 ↔ 网格统一由导航栏右侧一个按钮负责；只保留
「网格长按空白开设置」，双击、原生长按全部删除。

起因是三个实测问题：双击工具栏空白仍会让 LC 的搜索展开（内容被推挤，即使搜索框已不可见）；
网格内长按只有列表下方的空白有效，导航栏那一行完全没反应。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | 删除 | `navDoubleTap`、`hostLongPress`、`lgEnsureHostPress`、`lgGestureAllowsTouch`、两个 delegate 方法、`handleNavDoubleTap`、`confirmSwitchToNative`、`handleHostLongPress`、`showNativeSwitchMenu`、`LGIsInteractive`、`LGCardAlertController`（接口+实现）、`UIGestureRecognizerDelegate` 遵循、以及 `footerPress` 这个只有声明没有实现的死属性 |
| 同上 | 新增 `lgInstallSwitchButton` / `toggleMode` | 导航栏右侧一个按钮，图标显示**目标**模式（网格时 `list.bullet`、原生时 `square.grid.2x2`）；`item.target` 每次重挂，`lgSyncLayout` 每 tick 补挂 |
| 同上 | `lgSuppressNativeSearch:` | 从 `alpha = 0` 改为 `hidden = YES`。前者虽然看不见，展开动画和占位还在，双击顶部仍会把内容推下去 |
| 同上 | `loadView` | 长按手势挂回 `panel`（此前挂在 `collection`，所以只有列表内部空白有效） |
| `VERSION` | | 29 → 30 |

净减约 400 行（1692 → 1328）。

## v29 — 面板从导航栏下沿开始，原生搜索栏压暗（2026-11-08）

实测 v28：网格模式下「App」大标题消失，双击空白仍会叫出 LiveContainer 的搜索。

两个问题同一个根因：`edgesForExtendedLayout` 让 `host.view` 延伸到了导航栏下方，
面板铺满全屏（`panel = view.bounds`），把大标题那块一起盖住了；`compactTop` 的 `-44`
又把我方搜索框顶进导航栏底下，于是双击落点和视觉都对不上。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `viewDidLayoutSubviews` | `panel` 改为 `(0, top, w, h-top)`，即从导航栏下沿开始，不再覆盖导航栏；所有子视图改到面板坐标系，`footer` / `collection` 用 `panelHeight` 计算 |
| 同上 | 同上 | 去掉 `compactTop` 的 `-44`（大标题可见后这个补偿会把搜索框推上去）；紧凑 = 紧贴栏底，宽松 = 再加 24pt |
| 同上 | 新增 `LGCollectSearchBars` / `lgSuppressNativeSearch:` | 遍历窗口收集 LC 的 search bar，网格模式下 `alpha = 0` + 禁用交互（保留布局，比 `hidden` 温和），并记入 weak 表以便恢复 |
| 同上 | `lgSyncLayout` | 每 tick 重新压制一次，防止 SwiftUI 切 tab 重建搜索栏后入口复活 |
| 同上 | `lgGestureAllowsTouch:` | 网格双击区域改为「面板内任意空白」（`0 <= y <= panelHeight`）；面板已不覆盖导航栏，负值就代表落在栏上，交给 LC |
| `VERSION` | | 28 → 29 |

## v28 — 网格只覆盖搜索栏与列表，保留导航栏（2026-11-08）

需求：原生页顶部有一排按钮（➕ / ❓ / 🔗 / 排序）和「App」大标题，网格模式下这些不要被覆盖，
只覆盖原生搜索栏和 app 列表。v27 为了躲开 LC 的搜索把整个导航栏藏了，等于把有用的东西一起扔了。

| 文件 | 位置 | 改动 |
|---|---|---|
| `Sources/LCGridLayout.m` | `applyMode` | 删除 `setNavigationBarHidden:YES`，导航栏始终保持可见 |
| 同上 | `viewDidLayoutSubviews` | 删除维持隐藏态的调用；覆盖范围回到 `host.view`（= 搜索栏 + 列表），导航栏在 `nav.view` 上天然不被覆盖 |
| 同上 | `LGTick` / `dealloc` | 删除配套的恢复调用 |
| 同上 | 删除 `lgSetNavigationBarHidden:` | 连同声明与 4 处调用一起清掉 |
| 同上 | `lgGestureAllowsTouch:` | 网格的双击区域从「搜索框以上」放宽到「面板内任意空白」。顶栏可见后搜索框上方只剩几个点，限死在那里等于按不到；导航栏本身仍在 `panel` 之外（`inPanel.y >= 0` 拦住），不会被双击误触 |
| `VERSION` | | 27 → 28 |

保留 v27 的成果：居中卡片（`LGCardAlertController`）、设置卡片面板、手势排除逻辑。

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
