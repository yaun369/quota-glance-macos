# macOS 源码镜像、分发与更新

## 仓库边界

QuotaGlance for Mac 通过 Developer ID 签名 + Apple 公证的 DMG 直接分发，不走 Mac
App Store。采集器要启动 `codex app-server` 并读取本地 Claude/Codex 配置，因此正式
Release 启用 Hardened Runtime，但**刻意不启用 App Sandbox**。

- 私仓 `yaun369/quota-pulse`：多平台开发源码。
- 公开仓库 [`yaun369/quota-glance-macos`](https://github.com/yaun369/quota-glance-macos)：
  只接收白名单快照，拥有 Mac 的 tag、GitHub Release、`QuotaGlance.dmg` 和
  `appcast.xml`。

私有分支、tag、Git 对象、移动端 target、签名材料一律不过界。禁止
`git push --mirror`、禁止拷贝 `.git`。

## 构建配置

| 文件 | 用途 |
| --- | --- |
| `Config/Community.xcconfig` | 默认 Debug 配置。未签名的社区 bundle ID，关闭 CloudKit 和 Sparkle；CloudKit 不可用时本地采集照常工作。 |
| `Config/OfficialRelease.xcconfig` | 正式发布。`dev.yuanmeng.quotapulse.mac`、生产容器 `iCloud.dev.yuanmeng.quotapulse`、公开 Sparkle 源、官方签名。OAuth Keychain 命名空间保持不变。 |
| `Config/Version.xcconfig` | 所有 target 和发布脚本唯一的版本号与 build 号来源。 |

开发者可以建被忽略的 `Config/Local.xcconfig` 覆盖 team、bundle ID 和自己的
CloudKit 容器，但不得使用官方容器。

## 公开快照导出

导出器只接受 `scripts/public-macos-export.txt` 里的路径，用 `git archive` 从已提交
的 `HEAD` 读取，记录源 SHA，并做文件名/内容安全检查。源和目标工作区不干净、或删除
量异常时它会拒绝执行。公开仓库自有的 README、社区文件、workflow、发布状态和
`appcast.xml` 在初始化之后会被保留。

私仓 `main` 的每次 push 都会在 CI 里跑同一个导出器并推到公开 `main`，所以合并 PR
就等于发布其白名单路径，无需手动操作。workflow 也支持手动 dispatch 重跑，并且串行
执行，两次合并不会竞争。想在快照上线前先本地检查，或要初始化一个空仓库时，才手动跑：

```sh
git clone git@github.com:yaun369/quota-glance-macos.git ../quota-glance-macos
./scripts/sync-public-macos.sh ../quota-glance-macos --initialize  # 仅首次
./scripts/sync-public-macos.sh ../quota-glance-macos               # 后续
git -C ../quota-glance-macos status --short
```

workflow 使用细粒度的 `PUBLIC_MAC_REPO_TOKEN`（权限仅限公开仓库的 Contents）和受保
护的 `public-macos-sync` environment。PR 永远拿不到这个 token。

## 一次性凭据准备

这几步是**创建**凭据；每次发布由下面清单的 Phase 0 负责校验。

1. 安装 team `YG579F4QU3` 的 `Developer ID Application` 证书。
2. 为 `dev.yuanmeng.quotapulse.mac` 创建并安装带 CloudKit 权限的 **Developer ID**
   描述文件。
3. `xcrun notarytool store-credentials` 保存公证凭据。
4. Sparkle 私钥放在登录钥匙串的 `dev.yuanmeng.quotapulse` 账户下。已提交的公钥是
   `TeHYVnUJ9hxMc1WTmxQevNuS9IoShE88sTu7YVuUDnM=`。**永不轮换，永不提交私钥**——
   丢了它，所有已安装版本将永远无法再更新。

## 发布清单

每次发布固定走六个阶段。每个阶段有一个「闸门」，没看到闸门就不要进下一阶段。下文
`X.Y.Z` 代表版本号，`BUILD` 代表 build 号。

> 线上 Sparkle 源是**公开仓库**的 `appcast.xml`。私仓根目录那份只是初始化公开仓库
> 用的空模板，改它不会发布任何更新。

### Phase 0 · 机器前置条件

换机器时全查一遍；证书、描述文件、工具链变动后重查。

- [ ] Developer ID 证书已安装：
      `security find-identity -v -p codesigning | grep 'Developer ID Application'`
- [ ] Developer ID 描述文件已安装：`~/Library/Developer/Xcode/UserData/Provisioning Profiles`
      里存在 `Mac Team Direct Provisioning Profile: dev.yuanmeng.quotapulse.mac`。
      同 bundle ID 的**开发**描述文件不能替代，构建会断言内嵌描述文件而失败。
- [ ] 公证凭据可用：`xcrun notarytool history --keychain-profile QuotaGlance-notary`
- [ ] Sparkle 私钥在钥匙串：`security find-generic-password -s 'https://sparkle-project.org'`
- [ ] `xcodegen`、`rg`、已登录的 `gh` 都在 `PATH` 上（`gh auth status`）——三个脚本都要用。

### Phase 1 · 私仓：版本号与发版说明

- [ ] `Config/Version.xcconfig` 提升 `MARKETING_VERSION`。
- [ ] **同时提升 `CURRENT_PROJECT_VERSION`。** Sparkle 比对的是这个 build 号，重复
      的话即使 marketing 版本变了，已安装的客户端也收不到更新。
- [ ] 写 `docs/releases/X.Y.Z.md`。必须非空且包含字面量 `X.Y.Z`，发布脚本会 grep 校
      验。这个文件同时是 GitHub Release 正文和 Sparkle 的发版说明页。
- [ ] `swift test` 通过。
- [ ] 合入私仓 `main`。

**闸门**：私仓 `main` 已带上新版本号和发版说明。

### Phase 2 · 公开快照

私仓 `main` 每次 push 都会触发 `Sync public macOS source`。

- [ ] `gh run list --workflow sync-public-macos.yml --limit 1` 对应该合并提交为 `success`。
- [ ] 公开仓库的 `Config/Version.xcconfig` 已经是 `X.Y.Z`：
      `gh api repos/yaun369/quota-glance-macos/contents/Config/Version.xcconfig --jq .content | base64 -d`

**闸门**：公开快照没带上版本号之前绝不打 tag——否则 tag 指向旧版本源码，构建会在版
本校验处直接中止。

### Phase 3 · 给公开源码打 tag

在公开仓库的独立 checkout 里操作。已有的本地 checkout 如果陈旧、不干净、或初始化到
一半，直接重新 clone，不要修——构建脚本和发布脚本都拒绝不干净的工作区。

```sh
git clone git@github.com:yaun369/quota-glance-macos.git ../quota-glance-macos
cd ../quota-glance-macos
git tag vX.Y.Z && git push origin vX.Y.Z
```

- [ ] tag 指向那个带 `X.Y.Z` 的同步提交。

### Phase 4 · 构建、签名、公证（在 tag 上）

```sh
cd ../quota-glance-macos
git checkout vX.Y.Z
export DEVELOPER_ID_APPLICATION='Developer ID Application: mengmeng yuan (YG579F4QU3)'
export APPLE_TEAM_ID='YG579F4QU3'
export NOTARY_PROFILE='QuotaGlance-notary'
./scripts/release-macos.sh
```

- [ ] `build/macos-release/X.Y.Z-BUILD` 尚不存在。签名证据不覆盖，重试前把上一次的
      目录挪走。
- [ ] 脚本跑完并打印候选 DMG 路径。

脚本会先要求工作区干净、`origin` 是公开仓库、`HEAD` 正好是该 tag，然后归档通用二进
制、用 Developer ID 导出，并断言：内嵌描述文件、`arm64` 与 `x86_64` 双架构、版本号
与 build 号、公开的 `SUFeedURL`、内嵌 `Sparkle.framework` 与 `claude-status-helper`、
以及**未**启用 App Sandbox。随后签名、公证、staple、`spctl` 评估，并用钥匙串里的
Sparkle 私钥生成 appcast 候选。dSYM 和 `notarization.json` 作为证据留在被忽略的本地
发布目录里。

### Phase 5 · 发布（先资产，后更新源）

```sh
cd ../quota-glance-macos
git checkout main
CONFIRM_PUBLIC_RELEASE=vX.Y.Z \
  ./scripts/publish-macos-release.sh build/macos-release/X.Y.Z-BUILD
```

- [ ] 命令报告已发布的 tag。

它先创建公开 GitHub Release、上传 `QuotaGlance.dmg`、验证匿名下载成功，**之后**才提
交并推送 `appcast.xml` 和根目录的 `QuotaGlance.md`，最后再校验两个 raw URL。顺序是
刻意的：资产还不存在就先广播更新，等于把所有客户端送去 404。同一个 tag 脚本只允许跑
一次，出错的补救方式是发新版本，不是覆盖。

### Phase 6 · 验收

源码侧（在没有私仓 checkout 的 Mac 上）：

- [ ] clone 公开仓库，`swift test`，生成仅 Mac 的工程，完成未签名的通用 Release 构建。
- [ ] 生成的工程只含 `QuotaPulseMac` 和 `ClaudeStatusHelper`，且内嵌了
      `Sparkle.framework` 与 `claude-status-helper`。

分发侧（从上一个已发布的公证版本装进 `/Applications` 开始；0.2.0 早于 Sparkle，所以
起点用 0.3.0 或更新）：

- [ ] 打开「登录时启动」，然后走 **设置 → 检查更新…**，版本号和 build 号都变成新版本。
- [ ] 重新启动 App，登录项仍在。
- [ ] 重启系统，在系统设置里关掉该登录项，确认 App 内的开关跟着变。
- [ ] 再重启一次，确认 App 不会自启。
