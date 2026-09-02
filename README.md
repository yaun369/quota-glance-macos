# QuotaGlance for macOS

QuotaGlance is a native macOS menu-bar app that shows the remaining usage
windows for Codex and Claude. This repository contains the independently
buildable Mac app, shared Swift package, tests, and direct-distribution tools.

[简体中文](README.zh-CN.md) · [Download the notarized DMG](https://github.com/yaun369/quota-glance-macos/releases/latest/download/QuotaGlance.dmg)

## Build the community edition

Requirements: macOS 14 or later, Xcode 16 or later, Swift 5.10, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test
cd Apps
xcodegen generate
xcodebuild -project QuotaPulse.xcodeproj \
  -scheme QuotaPulseMac \
  -configuration Debug \
  -destination 'platform=macOS' build
```

The Debug configuration is unsigned and disables the official CloudKit
container and Sparkle update channel. Local quota collection still works.
To test your own signed CloudKit setup, create the ignored
`Config/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = com.example.quotaglance
CODE_SIGNING_ALLOWED = YES
QUOTA_CLOUDKIT_ENABLED = YES
QUOTA_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.com.example.quotaglance
```

Create that iCloud container in your Apple Developer account and add it to the
Mac target before signing. Do not use the official QuotaGlance identifiers.

## Repository boundary

The private multi-platform repository remains the development source during
the first phase. A manifest-controlled, snapshot-only export copies the Mac
files here. `SOURCE_COMMIT` records the source revision; no private Git history,
iOS app, watchOS app, Widget target, signing key, certificate, profile, or
notarization credential is included.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request and
[docs/macos-distribution.md](docs/macos-distribution.md) for the official
release procedure.

## License

Source code is MIT licensed. Product names and brand assets have separate use
terms in [BRAND-ASSETS.md](BRAND-ASSETS.md).
