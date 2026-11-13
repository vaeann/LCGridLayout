# LCGridLayout v{{LABEL}}

{{BETA_NOTE}}

LiveContainer 宿主侧图标网格插件，**未签名 dylib**，需在 LiveContainer 内用当前证书重签后使用。

## 安装

1. LiveContainer → **Tweaks** → 全局根目录 → **Import Tweak** 导入 `LCGridLayout_v{{VERSION}}.dylib`
2. 点 Tweaks 页的签名按钮重签
3. Settings 底部连点版本号 5 次 → Developer Settings → 打开 **Load Tweaks to LiveContainer Itself**
4. 完全退出 LiveContainer 再打开

> 全局 Tweaks 只有 1 个条目时，上游 `TweakLoader` 会跳过加载，目录里至少保留两个条目。

## 校验

```
sha256sum LCGridLayout_v{{VERSION}}.dylib   # 见附件 SHA256SUMS.txt
```

产物为 iOS arm64、`MH_DYLIB`、ad hoc 签名；平台/架构/依赖已由 `scripts/verify_macho.py` 校验。

## 源码

对应源码（含构建脚本与全部改动）：

https://github.com/vaeann/LCGridLayout/tree/{{COMMIT}}

本仓库是 [Kan9e/LCGridLayout](https://github.com/Kan9e/LCGridLayout) 的衍生作品，
按 **AGPL-3.0** 分发；改动记录见 [docs/FORK.md](https://github.com/vaeann/LCGridLayout/blob/main/docs/FORK.md)。
