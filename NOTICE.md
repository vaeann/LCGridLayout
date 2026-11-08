# NOTICE

## 本仓库的来源

本仓库是 [Kan9e/LCGridLayout](https://github.com/Kan9e/LCGridLayout) 的衍生作品（fork），
用于个人二次开发。

- 原始作品：LCGridLayout — LiveContainer 宿主侧图标网格插件
- 原始作者：Kan9e（<https://github.com/Kan9e>）
- 原始仓库：<https://github.com/Kan9e/LCGridLayout>
- 许可：**GNU Affero General Public License v3.0**，全文见 [LICENSE](LICENSE)
- 衍生维护：vaeann（<https://github.com/vaeann>），自 2026-11-08 起

`LICENSE` 保持 AGPL-3.0 原文，未做任何修改。本仓库对原始作品的改动见
[docs/FORK.md](docs/FORK.md)（AGPL-3.0 第 5(a) 条要求的修改标注与日期）。

## 上游声明

上游 README 明确：本插件依赖 LiveContainer 3.8.x 的界面结构，不 hook 任何方法、
不修改 IPA。这些约束在本仓库同样成立，二次开发时请勿破坏（否则与 LCFloatingMenu
这类插件共存的能力会消失）。

## 第三方组件

本插件不引入任何第三方库。编译时只链接系统框架：

```
Foundation  UIKit  QuartzCore  CoreGraphics  PhotosUI  LocalAuthentication
```

`scripts/verify_macho.py` 会校验产物只依赖 `/usr/lib/` 与
`/System/Library/Frameworks/` 下的库，出现其他依赖即拒绝出包。

## 分发义务

分发本仓库构建的二进制（dylib）时，必须同时提供对应源码。本仓库的
Release 说明里自动附上对应 commit 的源码链接，见
`.github/RELEASE_TEMPLATE.md`。
