# macOS source mirroring, distribution, and updates

## Decision and repository boundary

QuotaGlance for Mac is distributed as a Developer ID-signed, Apple-notarized
DMG, not through the Mac App Store. The collector launches `codex app-server`
and reads local Claude/Codex configuration, so the official Release enables
Hardened Runtime but deliberately does not enable App Sandbox.

The private `yaun369/quota-pulse` repository remains the multi-platform
development source during phase one. The public
[`yaun369/quota-glance-macos`](https://github.com/yaun369/quota-glance-macos)
repository receives clean, manifest-controlled snapshots only. It owns Mac
tags, GitHub Releases, `QuotaGlance.dmg`, and `appcast.xml`; private branches,
tags, Git objects, mobile app targets, and signing material never cross the
boundary.

## Community and official configurations

- `Config/Community.xcconfig` is the default Debug configuration. It uses an
  unsigned community bundle identifier and disables CloudKit and Sparkle.
  Local Codex/Claude collection continues when CloudKit is unavailable.
- `Config/OfficialRelease.xcconfig` selects
  `dev.yuanmeng.quotapulse.mac`, production
  `iCloud.dev.yuanmeng.quotapulse`, the public Sparkle feed, and official
  signing. It keeps the existing OAuth Keychain service namespace unchanged.
- `Config/Version.xcconfig` is the only source of marketing version and build
  number for every target and the release scripts.

Developers may create ignored `Config/Local.xcconfig` overrides with their own
team, bundle ID, and optional CloudKit container. They must not use the
official container.

## Export a public snapshot

The exporter accepts only paths in `scripts/public-macos-export.txt`, reads
them from the committed `HEAD` with `git archive`, records the source SHA, and
runs filename/content safety checks. It refuses dirty source/destination
worktrees and unusually large deletions. Public README/community files,
workflow, release state, and `appcast.xml` are preserved after initialization.

```sh
git clone git@github.com:yaun369/quota-glance-macos.git ../quota-glance-macos
./scripts/sync-public-macos.sh ../quota-glance-macos --initialize # first snapshot only
# Later snapshots omit --initialize.
git -C ../quota-glance-macos diff --check
git -C ../quota-glance-macos status --short
```

Review and commit a normal snapshot in the public repository. Never use
`git push --mirror`, copy `.git`, or publish private branches/tags. The private
manual workflow uses a fine-grained `PUBLIC_MAC_REPO_TOKEN` limited to the
public repository's Contents permission and a protected
`public-macos-sync` environment. Pull requests never receive that token.

## One-time official release setup

1. Install a `Developer ID Application` certificate for team `YG579F4QU3`.
2. Create/install the Developer ID provisioning profile for
   `dev.yuanmeng.quotapulse.mac` with its CloudKit entitlement.
3. Store notarization credentials with `xcrun notarytool store-credentials`.
4. Keep the existing Sparkle private key in the login Keychain account
   `dev.yuanmeng.quotapulse` or a protected secret. Its committed public key is
   `TeHYVnUJ9hxMc1WTmxQevNuS9IoShE88sTu7YVuUDnM=`. Never rotate it merely for
   the repository move and never commit the private key.

## Release order

1. Update `Config/Version.xcconfig` and `docs/releases/X.Y.Z.md` in the private
   repository; run tests and a universal build.
2. Export the clean snapshot. Wait for public CI, then tag that public source
   commit `vX.Y.Z` and push the tag.
3. Check out the public tag and build from it:

   ```sh
   export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (YG579F4QU3)'
   export APPLE_TEAM_ID='YG579F4QU3'
   export NOTARY_PROFILE='QuotaGlance-notary'
   ./scripts/release-macos.sh
   ```

   This validates tag/version/build/release notes, uses the checkout-local
   Sparkle artifact path, archives a universal app, signs and notarizes the
   DMG, and produces an appcast candidate. dSYMs and the notarization JSON stay
   in ignored local release evidence.
4. Return the public checkout to `main`. The publish command requires an
   explicit confirmation and enforces asset-first ordering:

   ```sh
   CONFIRM_PUBLIC_RELEASE=vX.Y.Z \
     ./scripts/publish-macos-release.sh build/macos-release/X.Y.Z-BUILD
   ```

   It creates the public GitHub Release, uploads `QuotaGlance.dmg`, verifies
   anonymous download, and only then commits/pushes `appcast.xml`. This prevents
   clients from seeing an update whose asset still returns 404.

## Acceptance pass

Clone the public repository on a Mac without the private checkout. Run
`swift test`, generate the Mac-only project, and complete the unsigned
universal Release build. Confirm the generated project contains only
`QuotaPulseMac` and `ClaudeStatusHelper`, and that Sparkle.framework plus
`claude-status-helper` are embedded.

For distribution, install the previous notarized version in `/Applications`,
enable Launch at Login, then update through **Settings → Check for Updates…**.
Confirm version/build changes, relaunch, and login-item persistence. Restart,
disable the item in System Settings, confirm the in-app switch follows, and
restart once more to ensure the app stays closed. The legacy 0.2.0 has no
Sparkle, so the first update test starts from a manually installed 0.3.0 (or a
later Sparkle-enabled base build).
