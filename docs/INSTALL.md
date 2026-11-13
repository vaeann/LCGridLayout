# LCGridLayout 安装与使用

适用：LiveContainer **3.8.0 及以上**（含 3.8.2 / 3.8.11 等 nightly），越狱无关的 JIT-Less / 侧载环境。

产物：从 [Releases](https://github.com/Kan9e/LCGridLayout/releases) 下载 `LCGridLayout_v24.dylib`，SHA-256 `4e60db13e272f186e8d322103e9412d91a6f1bdac6af481e8235051bedc636ab`。

---

## 一、装之前先确认

1. LiveContainer 版本是 **3.8.0**。插件的宿主门禁写死了 `CFBundleShortVersionString == 3.8.0`，其他版本会直接退出（这是故意的，避免在不认识的 UI 上乱盖）。
2. 已导入 JIT-Less 证书（Settings → 证书相关项），否则 Tweaks 页不会出现签名按钮，dylib 重签不了。
3. 全局 Tweaks 文件夹里**至少有两个条目**。LiveContainer 3.8.0 的 `TweakLoader` 在“全局条目 ≤ 1 且没有应用专用文件夹”时会直接 return，什么都不加载——这是上游行为，不是你装错了。保留原有的 LCFloatingMenu 就能满足。
4. 如果之前装过旧版 LCGridLayout，先在 Tweaks 页删掉，避免两个副本都被 dlopen。

## 二、安装（4 步）

1. **导入 dylib**
   LiveContainer → **Tweaks** 标签 → 停在全局根目录（不要进某个应用专用子文件夹）→ 右上角 “Import Tweak” → 选带版本号的文件，例如 `LCGridLayout_v24.dylib`。**先删掉设备上旧的 `LCGridLayout*`**，多个副本会被同时加载。

2. **重签**
   停在 Tweaks 页 → 点签名按钮（`signature` 图标，文案是 “Sign”）。ad hoc 签名在设备上过不了校验，这一步必须做。

3. **打开宿主注入**
   Settings → 滚到底部 → 连续点击版本号文字 **5 次** → 出现 “Developer Settings” → 打开 **“Load Tweaks to LiveContainer Itself”**。

4. **重启并验证**
   从多任务里完全划掉 LiveContainer，重新打开。
   看到 “我的应用” 页变成图标网格即成功；如果没变，看下面第四节。

## 三、怎么用

- **网格 / 原生列表切换**：点右下角那个胶囊按钮——网格时写「原生布局」，原生时写「宫格布局」，点了立即切换。它右边还有一个齿轮按钮，点开就是网格设置。两个按钮并排、都在 tab bar 上方。顶部没有工具栏，导航栏（➕ / ❓ / 🔗 / 排序）与「App」大标题保持可见可点。原列表里添加、管理、容器选择、隐藏应用解锁全部照旧。
- **长按图标**（0.3 秒，带触感）：
  - 按住后移动：直接拖动排序，松手即保存
  - 按住后保持不动约 0.35 秒：不用松手，菜单自动从底部弹出；长按后快速松手也会弹出
    - **隐藏**：写入应用元数据后从网格消失（静默，无弹窗）；建议重启 LiveContainer 让原生列表同步
    - **卸载**（仅非共享应用）：确认后删除应用包，并询问是否同时删除数据容器；不可撤销
- **解锁隐藏应用**：网格底部“共 N 个 App”连点 3 次 → 系统面容/密码认证 → 隐藏应用显示在末尾；重启 LiveContainer 自动上锁
- **网格设置**：点右下角齿轮 → 分组卡片面板 → 4/5 列、显示/隐藏应用名称、顶部间距（紧凑/宽松）、选择/更换/移除背景、导出调试日志、切换到原生列表。设置存 `NSUserDefaults`，冷启动保留。
- **自定义背景**：“齿轮 → 背景图片 → 选择” → 系统相册选一张图 → 自动裁切填充并叠 35% 黑遮罩。图片存在 `Library/Application Support/LCGridLayout/background.jpg`（最长边压到 2200px），重启、切标签都保留；移除在 “齿轮 → 恢复默认底色”。不需要相册权限，也不会把图片写进 LiveContainer 的应用目录。
- **刷新**：下拉刷新会重扫应用目录；从原生列表切回网格也会自动刷新。
- **搜索**：顶部搜索框按应用名过滤，清空即恢复。
- **加锁应用**：图标右下角有锁标，点按后仍由 LiveContainer 弹解锁流程。
- **失败反馈**：缺少 URL scheme 或系统拒绝启动时，会弹 “无法启动” 提示，不再静默无反应。

## 四、排错

拿到日志的三种方式：

- **最简单（插件已加载时）**：网格 → 齿轮 → “导出调试日志” → 系统分享面板里选 AirDrop（发到 Mac）或“存储到文件”。
- **插件没加载、进不了网格**：Xcode → Window → Devices and Simulators → 选设备 → Installed Apps 里的 LiveContainer → 齿轮/⋯ → Download Container → 解压 `.xcappdata` → `AppData/Library/Logs/LCGridLayout.log`。
- **看实时输出**：Mac 的 Console.app 选中设备，过滤 `LCGridLayout`。

日志路径：LiveContainer 沙盒内的 `Library/Logs/LCGridLayout.log`（上限 128 KB，超出会重写）。第一行附近的 `Host gate passed ... LCGridLayout_vN.dylib loaded` 就是当前加载的版本。

| 现象 | 日志特征 | 判断与处理 |
|---|---|---|
| 完全没反应，日志文件都没有 | 无任何 `[LCGridLayout]` | dylib 没被加载：检查第 1 步目录是否全局、第 2 步是否重签成功、第 3 步开关是否开、全局 Tweaks 是否 ≥ 2 条目 |
| 只有 `Host gate passed: LiveContainer 3.8.0` | 无 `Mounted ...` | 门禁过了但没找到宿主页：6 秒后日志会附 `view hierarchy`（只有类名和标题）。把这段和 iOS 版本一起回传，说明当前 SwiftUI 层级/标题和识别条件不一致 |
| 出现 `No host matched after 6s; view hierarchy:` | 附带的层级树 | 正常诊断信息；如果此时你停在设置/来源页，切回“我的应用”等一秒即可 |
| 选了背景但没变化 | `Background image updated` 缺失 | 看是否有 “背景图片保存失败” 提示；确认设备剩余空间，或换一张普通 JPEG/PNG（HEIC 也可，会转成 JPEG） |
| 隐藏/卸载后原生列表还显示 | — | 预期行为：直接改文件不会刷新 LiveContainer 内存模型，完全退出重开即可 |
| 卸载项看不到 | — | 共享应用不提供卸载，请在原生列表操作 |
| 解锁后点隐藏应用没反应 | — | v22 之前是插件守卫误拦截，升级即可；若仍失败，再确认 LC 未开「严格隐藏」 |
| 网格少显示某个应用 | `Loaded N app(s); skipped hidden=… ambiguous=… damaged=…` | 点齿轮打开网格设置看计数：隐藏=隐藏应用；冲突=本地/共享同名文件夹被有意排除；异常=plist 损坏。原生列表能看到但网格没有，把这一行发我 |
| 出现 `Mounted on native app-list hosting controller` 但看不到网格 | — | 检查是否之前切到了原生列表并被持久化：点右下角「宫格布局」 |
| 图标全是系统占位图 | `Host icon provider failed` | 宿主图标接口异常，功能不受影响；记录 iOS 版本 |
| 点击无反应并弹 “无法启动” | `no native URL scheme` / `Native launch URL rejected` | 用原生列表启动；把日志回传 |
| 打开就闪退 | — | 关掉 “Load Tweaks to LiveContainer Itself” 重启即可回到干净状态，再回传崩溃日志 |

## 五、回退与删除

按侵入性从低到高：

1. **只是不想看网格**：网格里点 “原生列表 / 管理”。
2. **暂停加载（保留文件）**：关掉 Settings → Developer Settings → “Load Tweaks to LiveContainer Itself”，重启 LiveContainer。
3. **停用但保留文件**：把 `LCGridLayout.dylib` 改名成 `LCGridLayout.dylib.disabled`（TweakLoader 会跳过 `.disabled`），或干脆放回别处。
4. **彻底删除**：Tweaks 页左滑删除该文件 → 重启；再删 `Library/Logs/LCGridLayout.log` 与 `Library/Application Support/LCGridLayout/`（后者只存自定义背景）。
   `NSUserDefaults` 里只剩 `LCGridLayout.columns`、`LCGridLayout.showNames`、`LCGridLayout.nativeList` 三个键，无副作用，不影响 LiveContainer 本身。

全程不需要改 IPA、不需要重装 LiveContainer。LCFloatingMenu 的设置与文件不受影响。

## 六、首次试用的建议顺序

1. 先只验证“挂载”：打开后看日志有没有 `Mounted ...`，网格有没有出现。
2. 再验证“启动”：点一个普通应用 → 能进；返回后再点一个加锁应用 → 走解锁。
3. 再验证“共存”：双指长按调出 LCFloatingMenu，确认还能用；切到原生列表再切回。
4. 再试背景：选图 → 切到别的标签再回来 → 退出重开，确认背景还在；最后用 “移除背景” 还原。
5. 最后跑 [TESTING.md](TESTING.md) 里的兼容性项（横竖屏、多任务、隐藏应用、20 次切换）。

任何一步不符合预期，停在那里把日志和截图留好——不要为了“看起来成功”继续往下点。
