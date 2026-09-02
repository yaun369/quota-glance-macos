# QuotaGlance 码量 macOS 版

QuotaGlance（码量）是一款原生 macOS 菜单栏应用，用于查看 Codex 与 Claude
额度窗口。本仓库包含可独立构建的 Mac App、共享 Swift Package、测试和直接
分发工具。

[English](README.md) · [下载已公证 DMG](https://github.com/yaun369/quota-glance-macos/releases/latest/download/QuotaGlance.dmg)

## 构建 Community 版本

需要 macOS 14 或更高版本、Xcode 16 或更高版本、Swift 5.10，以及
[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
swift test
cd Apps
xcodegen generate
xcodebuild -project QuotaPulse.xcodeproj \
  -scheme QuotaPulseMac \
  -configuration Debug \
  -destination 'platform=macOS' build
```

Debug 配置不签名，默认关闭官方 CloudKit 容器与 Sparkle 更新源，本地额度采集
仍可使用。如需测试自己的 CloudKit，请新建已被忽略的
`Config/Local.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = com.example.quotaglance
CODE_SIGNING_ALLOWED = YES
QUOTA_CLOUDKIT_ENABLED = YES
QUOTA_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.com.example.quotaglance
```

请在自己的 Apple Developer 账号创建对应 iCloud 容器并为 Mac target 配置
权限，不要使用 QuotaGlance 官方标识符。

## 仓库边界

第一阶段仍以私有多平台仓库作为开发源，通过清单控制的源码快照单向同步到本
仓库。`SOURCE_COMMIT` 记录来源版本；同步不包含私有 Git 历史、iOS/watchOS/
Widget App target、签名密钥、证书、profile 或公证凭据。

提交 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，正式发布流程见
[docs/macos-distribution.md](docs/macos-distribution.md)。

## 许可证

源码使用 MIT 许可证；产品名称与品牌资产的使用规则见
[BRAND-ASSETS.md](BRAND-ASSETS.md)。
