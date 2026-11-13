# 二次开发指南

面向要改 `Sources/LCGridLayout.m` 的人。读完这页你应该知道：**一个功能该改哪个函数、
改完怎么验证、哪些东西不能碰。**

---

## 0. 一句话架构

插件被 LiveContainer 宿主 dlopen 后，用 `NSTimer` 轮询找"我的应用"那个页面，
`addChildViewController` 挂一层**铺满宿主视图**的覆盖层（`hitTest` 穿透），
覆盖层自己画网格、读文件系统拿应用列表、调宿主的图标接口补图标。
**不 swizzle、不抢 key window、不改 IPA。**

---

## 1. 编译与部署回路

Windows 上没有 Xcode，编译只能交给 CI：

```
改代码 → python scripts/lint.py → git push
      → Actions「Build dylib」自动跑（约 2-4 分钟）
      → 下载 artifact 里的 LCGridLayout_vNN.dylib
      → LiveContainer → Tweaks → Import Tweak → 重签 → 完全退出重开
```

- 手动发版：Actions → **Build dylib** → Run workflow（勾 `create_release` 会发 Release）
- 本地有 Mac 时也能直接 `bash scripts/build.sh`，产物在 `dist/`
- 想看编译错误细节：artifact 里带 `logs/build.log`

**每次改完必须 bump `VERSION`。** 它决定产物文件名，也决定日志里打印的
"loaded" 名字——不 bump 你就分不清设备上跑的是哪一版。Tweaks 里**只能保留一个**
`LCGridLayout*`，多个副本会被同时加载。

### 本机网络（会卡住 push）

`github.com:443` 直连经常不通，但 `api.github.com` 通常正常。这台机器走局域网代理
`192.168.8.122:6152`（HTTP），SOCKS5 在 `:6153`。git 默认不读系统代理设置，所以要显式给：

```bash
git -c http.proxy=http://192.168.8.122:6152 push origin main
```

代理端口变了就改这个值。`curl` 同理加 `--proxy http://192.168.8.122:6152`。

彻底连不上时还有一条路：用 GitHub **Contents API** 单文件提交（需要 token 的
`workflow` scope），拿 `contents/<path>` 的 `sha` 后 PUT base64 内容即可——绕开 git 传输。

---

## 2. 加载链路（按执行顺序）

```
__attribute__((constructor)) LGInitialize            ← dylib 被 dlopen 时
  └─ LGHost()                                        门禁：是不是宿主、版本够不够
       ├─ NSUserDefaults 有 isLiveProcess / lcGuestAppId → 是来宾进程，退出
       ├─ lcMainBundle 版本 < 3.8.0 → 退出
       └─ NSClassFromString(@"LCUtils") 存在 → 通过
  └─ dispatch_async(main)                            注册默认值、打日志
       ├─ NSTimer 0.1s  → LGTick()                   稳态轮询
       └─ NSTimer 0.03s → LGTick()                   前 1.2s 的启动 burst，之后自毁
```

`LGTick()` 是心脏，每次做四件事：

1. 遍历所有 `UIWindowScene` 的 `UIWindow`（只认 `UIWindowLevelNormal`）
2. `LGFindList()` 从 `rootViewController` 往下找目标页：`UITabBarController` 取 selected →
   `UINavigationController` 要求**栈里只有 1 个 VC**、是 `*HostingController`、
   标题等于本地化的 `lc.appList.myApps`（或空）
3. 没挂过就 `addChildViewController` + 4 条边约束铺满；挂过就 `bringSubviewToFront`
4. 页面重新出现（`wasAway`）时 `refresh()` 重读应用列表

> 为什么用轮询而不是 hook：上游明确"不 hook 任何方法"才能和 LCFloatingMenu 共存。
> 轮询的代价是时序问题，所以有 30ms 的启动 burst——把"原生列表闪一帧"压到一个帧周期。

**找错页面时的调试**：连续 6 秒没挂上，`LGDumpWindows()` 会把整棵 VC 树（只含类名和标题）
写进日志。改 `LGFindList` 的判断条件前先看这份 dump。

---

## 3. 模块地图

| 区域 | 函数 / 类 | 职责 |
|---|---|---|
| 门禁 | `LGHost` / `LGVersionAtLeast` | 宿主识别、版本比较（数字语义，`3.8.11 > 3.8.2`） |
| 日志 | `LGLog` / `LGLogPath` | 写 `Library/Logs/LCGridLayout.log`，超 128KB 重写（不写应用名/容器路径） |
| 数据 | `LGReadApps` | 扫两个目录，产出 `NSArray<LGEntry *>` |
| 状态判定 | `LGStateFor` / `LGEntryStateFor` | 一个应用是 OK / 隐藏 / 损坏，**唯一真源**，模糊即 fail-closed |
| 图标 | `LGFastIcon` / `requestIconForEntry` / `generateIconForEntry` | 先 bundle PNG 占位，再逐个换宿主主题图标 |
| 单元格 | `LGCell` | 图标 + 名称 + 锁标；`layoutSubviews` 里算尺寸 |
| 覆盖层 | `LGPassView` | `hitTest` 返回 nil，让触摸穿透到宿主 |
| 主控 | `LGGridController` | 全部 UI、交互、持久化 |
| 挂载 | `LGTick` / `LGFindList` / `LGDumpWindows` | 找页、挂载、置顶、诊断 |
| 搜索压制 | `lgSuppressNativeSearch:` / `LGCollectSearchBars` | 网格模式把宿主 search bar 设为 `hidden` + 关交互，每 0.5s 复查一次（SwiftUI 会重建） |
| 双击守卫 | `lgEnsureNavGuard` / `gestureRecognizer:shouldReceiveTouch:` | 在 `nav.view` 上吞掉导航区空白处的双击，避开按钮；否则 LC 的 searchable 会盖住整页 |

### 主控里的分区

| 区域 | 方法 | 说明 |
|---|---|---|
| 构建 | `loadView` | 一次性搭完 panel / 背景 / 工具条 / 搜索 / collection / footer |
| 几何 | `viewDidLayoutSubviews` / `lgTopInset` / `lgSyncLayout` | 全部手算 frame，**不用 Auto Layout** |
| 数据刷新 | `refresh` → `filter` | 重读列表 → 过滤 → reloadData |
| 图标 | `cellForItemAtIndexPath` → `iconKeyForEntry` → `requestIconForEntry` | 缓存键 = 路径 + 深浅色 |
| 启动 | `didSelectItemAtIndexPath` | 组 `livecontainer-launch?bundle-name=` URL 交给系统 |
| 长按 | `handleLongPress` | 0.3s 起手，移动 >6pt 转拖动，不动 0.35s 弹菜单 |
| 菜单 | `showActionsForEntry` / `showAlertTitle` / `presentAlert` | 隐藏 / 卸载 / 取消 |
| 隐藏 | `hideEntry` | 写 `LCAppInfo.plist` 的 `isHidden` |
| 卸载 | `containerFoldersForEntry` → `confirmUninstallEntry` → `askDeleteDataForEntry` → `performUninstallEntry` | 双重确认 + 可选删容器 |
| 排序 | `saveOrder` / `moveItemAtIndexPath` | 存 folder 名数组；宿主已选 custom 时同步镜像 |
| 解锁 | `footerTapped` / `setHiddenUnlocked` | 三击 → `LAContext` 认证 |
| 设置 | `showSettings` + `LGSheetController` | 卡片式 sheet（medium/large detent）：分段控件管列数与间距，开关管名称，按钮管背景与日志 |
| 设置入口 | `showSettings` / `LGSheetController` | 右下角唯一悬浮按钮（齿轮）→ 分组卡片面板；`nativeMode=YES` 时只渲染「切换到宫格布局」+ 取消 |
| 布局切换 | `handleSheetAction:` 的 `SwitchMode` / `SwitchToGrid` | 从面板底部按钮触发，不再有独立的悬浮切换按钮。**不要试图改宿主 navigationItem——SwiftUI 自绘，塞进去不显示** |
| 图标 | `LGFastIcon` / `requestIconForEntry:` / `lgShowIcon:animated:` | 先给 bundle 里的 PNG，再淡入宿主渲染的图标；`prefetchIcons` 在 refresh 后预取，占位是中性色块而不是 `app.fill` |
| 启动 | `didSelectItemAtIndexPath:` → `lgLaunchEntry:` | `bundle-name` + `container-folder-name`（`LCDataUUID`，缺失时用 `LCContainers` 唯一项）。优先 `LCSharedUtils.launchToGuestAppWithURL:`，openURL 兜底；`lgContainerExists:` 先查容器目录，不存在就明说 |
| 覆盖范围 | — | 网格只覆盖 `host.view`（= 搜索栏 + app 列表）。导航栏在 `nav.view` 上，天然不被覆盖 |
| 背景 | `chooseBackground` / `applyBackground` / `removeBackground` | PHPicker，最长边压到 2200px 存 JPEG |

---

## 4. 数据模型

```objc
@interface LGEntry : NSObject
@property NSURL    *url;       // .app 目录
@property NSString *name;      // CFBundleDisplayName ?: CFBundleName ?: 文件夹名
@property NSString *folder;    // 目录名，启动 URL 用的就是它
@property NSString *bundleId;
@property BOOL      locked;    // LCAppInfo.plist 的 isLocked
@property BOOL      shared;    // 来自 App Group 目录（共享应用）
@property BOOL      hidden;
@end
```

应用来源（两个根，按顺序扫）：

1. `Documents/Applications/*.app` —— 本地应用
2. `<AppGroup>/LiveContainer/Applications/*.app` —— 共享应用

过滤规则（`LGReadApps` 里，**改这里要非常小心**）：

- 同名文件夹出现在两个根 → 判为 ambiguous，**整个丢弃**（启动 URL 只认文件夹名，
  有歧义就可能启动错的应用）
- 没有 `Info.plist`，或有 `LCAppInfo.plist` 但读不出来 → damaged，丢弃
- `isHidden`（两个 plist 任一处为真）→ 计数，未解锁时不进列表

排序：先 `LCGridLayout.order` 里记录的 rank，未记录的按名称 `localizedStandardCompare`，
隐藏应用永远排最后。

---

## 5. 持久化

全部走 `NSUserDefaults.standardUserDefaults`，不加密：

| 键 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `LCGridLayout.columns` | NSInteger | 4 | 列数，只接受 4 或 5 |
| `LCGridLayout.showNames` | BOOL | YES | 是否显示应用名 |
| `LCGridLayout.nativeList` | BOOL | NO | YES = 回原生列表（覆盖层 panel 隐藏） |
| `LCGridLayout.compactTop` | BOOL | YES | 顶部间距紧凑（减掉大标题留白） |
| `LCGridLayout.order` | NSArray\<NSString\*> | 无 | 拖动排序后的 folder 名顺序 |

背景图不在 defaults 里：`Library/Application Support/LCGridLayout/background.jpg`。

加新键时同时改 `LGInitialize` 里的 `registerDefaults:`，否则 `boolForKey:` 一律返回 NO。

---

## 6. 布局（全手算，没有 Auto Layout）

```
panel       = view.bounds                    ← 铺满，盖住标签栏毛玻璃
  backgroundView / dimView = panel.bounds    ← 背景图 + 35% 黑色遮罩
  （导航栏与大标题在 host.view 之外，网格不覆盖）
  search      = (4, top, w-8, 48)            ← 宿主有原生搜索框时隐藏
  collection  = (0, top+headerHeight, w, 剩余高度)
  footer      = 贴底，距标签栏 14pt
```

`headerHeight` = 48；检测到宿主原生搜索框时改用 8。v25 起顶部没有工具栏，
网格直接贴着导航栏，不再留 40pt 的工具条空档。

`top` 的来源：优先用 `navigationBar` 底边（`lgTopInset`），因为 `safeAreaInsets.top`
包含大标题区域，直接用会留一大块空白。`compactTop` 再减 44pt。

**大标题收起时不会触发 `viewDidLayoutSubviews`**（bounds 没变），所以 `LGTick` 每轮调
`lgSyncLayout` 比较 `top` / safeArea / 原生搜索框位置，变了才 `setNeedsLayout`。

---

## 7. 交互细节

**长按**（`minimumPressDuration = 0.3`）：

```
按下 ──┬─ 移动 > 6pt ────────────→ beginInteractiveMovement（拖动排序）
       ├─ 停住 0.35s ───────────→ 弹 action sheet（不用松手）
       └─ 0.35s 内松手 ─────────→ 也弹 action sheet
```

`menuToken` 是取消机制：每次状态切换 `++`，延迟 block 里对不上号就放弃。
改时序时这行别丢，否则会出现"拖完还弹菜单"。

**底部三击解锁**：`LAContext` 走 `LAPolicyDeviceOwnerAuthentication`（Face ID 或密码）。
密码都没设时（`LAErrorPasscodeNotSet`）直接放行。解锁状态只在内存里，
重启 LiveContainer 自动上锁。

**原生搜索镜像**：监听 `UITextFieldTextDidChangeNotification`，判断这个 textField
不是自己的、类名含 `Search`、且自己的搜索栏是隐藏的，才把文字同步进来。

---

## 8. 常见二开目标 → 改哪里

| 想做的事 | 改哪里 | 注意 |
|---|---|---|
| 支持 6 列 / 自适应列数 | `sizeForItemAtIndexPath` + `showSettings` 里的 `@[@4,@5]` | 同时改 `LGColumns` 的合法值判断；iPad 留白问题就是这里按屏宽均分导致的 |
| 改图标大小 / 圆角 | `LGCell layoutSubviews` | `size * 0.2237` 是 iOS 圆角比例 |
| 调长按手感 | `longPress.minimumPressDuration` + `handleLongPress` 里的 `0.35` 和 `6` | 也是 `docs/TESTING.md` 的验收项 |
| 背景遮罩透明度可调 | `loadView` 里 `dimView` 的 `alpha:0.35` + `showSettings` 加选项 | 需要新 defaults 键 |
| 加排序方式（名称/安装时间） | `LGReadApps` 末尾的 `sortUsingComparator` | 安装时间可用 `.app` 目录的 creationDate |
| 长按菜单加一项 | `showActionsForEntry` | 卸载项对共享应用是隐藏的，别破坏这个判断 |
| 换空状态文案 / 加引导 | `loadView` 里 `self.empty` | |
| 想把顶部按钮加回来 | v25 已删除；要恢复就在 `loadView` 建 `UIStackView`，并把 `viewDidLayoutSubviews` 里 `search` 的 y 改回 `top+40`、`headerHeight` 加回 40 |
| 改启动方式（不走 URL） | `didSelectItemAtIndexPath` | 上游说明：内存模型调不到，只能走 `livecontainer-launch` URL |
| 兼容新版 LiveContainer | `LGHost` 的版本门禁 + `LGFindList` 的页面识别 | 先看日志里的 view hierarchy dump |

---

## 9. 硬约束（破坏这些会出事）

1. **不 swizzle、不抢 key window、不挂全局手势。** 这是和 LCFloatingMenu 共存的前提。
2. **`LGPassView.hitTest` 必须继续穿透**（返回 nil），否则宿主页面点不动。
3. **覆盖层必须铺满 `host.view`**，包括标签栏毛玻璃下方；只盖安全区会透出原生行。
4. **`LGStateFor` 是唯一真源，模糊情况必须 fail-closed。** 宁可少显示一个应用，
   也不能给用户一个会启动错应用的图标。
5. **不注入、不重签、不改原始 IPA。**
6. **不引入第三方库**（AGPL 兼容性 + 插件体积）。只链接系统框架，
   `verify_macho.py` 会卡这个。
7. **日志里不写应用名、bundle id、容器路径。** 插件日志是用户会导出分享的。

---

## 10. 调试

| 手段 | 怎么做 |
|---|---|
| 插件日志 | `Library/Logs/LCGridLayout.log`，或在「齿轮 → 导出调试日志」 |
| 确认加载 | 日志第一行必须是 `Host gate passed: LiveContainer <版本> ...; LCGridLayout_vNN.dylib loaded` |
| 确认挂载 | 必须有 `Mounted on native app-list hosting controller after N ms`；只有第一行不算成功 |
| 没挂上 | 等 6 秒，日志会附 view hierarchy dump，改 `LGFindList` 前先看它 |
| 图标不出来 | 日志里搜 `Host icon provider failed`，说明宿主接口签名变了 |
| 启动没反应 | 日志里 `Native launch URL accepted/rejected`；accepted 只代表 URL 被接收，不代表来宾起来了 |

日志上限 128KB，超了直接重写（不是追加），所以复现问题要**先清空再看**。

---

## 11. 提交前自检

```bash
python3 scripts/lint.py     # 括号、@end、CRLF、VERSION
```

CI 的 `Guard` 还会查：LICENSE 未被改、没有 `.dylib`/`.ipa`/证书进仓库、
README 保留上游链接与 AGPL 声明、`docs/FORK.md` 存在。

改了功能就在 `docs/FORK.md` 的表格里追加一行——AGPL 要求标注修改，
而且三个月后你会需要它。
