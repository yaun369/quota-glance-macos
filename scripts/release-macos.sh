#!/bin/zsh
set -euo pipefail

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the Developer ID Application certificate name}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the Apple Developer team ID}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool keychain profile}"

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
public_repository="${PUBLIC_MAC_REPOSITORY:-yaun369/quota-glance-macos}"
version_config="${repo_root}/Config/Version.xcconfig"
release_version="$(awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$version_config")"
release_build="$(awk -F= '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$version_config")"
tag="v${release_version}"

[[ "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$release_build" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "Config/Version.xcconfig must contain a semantic version and positive build number"
  exit 64
}
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || {
  print -u2 "release checkout must be clean"
  exit 1
}
origin="$(git -C "$repo_root" remote get-url origin)"
[[ "$origin" == *"${public_repository}"* ]] || {
  print -u2 "official artifacts must be built from ${public_repository}; got $origin"
  exit 1
}
[[ "$(git -C "$repo_root" describe --tags --exact-match HEAD 2>/dev/null || true)" == "$tag" ]] || {
  print -u2 "HEAD must be the public source tag ${tag}"
  exit 1
}
git -C "$repo_root" merge-base --is-ancestor "$tag" HEAD

release_notes="${repo_root}/docs/releases/${release_version}.md"
[[ -s "$release_notes" ]] || { print -u2 "missing release notes: $release_notes"; exit 1; }
rg -q "${release_version}" "$release_notes" || { print -u2 "release notes do not mention ${release_version}"; exit 1; }

release_root="${repo_root}/build/macos-release/${release_version}-${release_build}"
archive_path="${release_root}/QuotaGlance.xcarchive"
derived_data="${release_root}/DerivedData"
export_path="${release_root}/export"
updates_path="${release_root}/updates"
dmg_name="QuotaGlance.dmg"
dmg_path="${updates_path}/${dmg_name}"
staging_path="$(mktemp -d "${TMPDIR:-/tmp}/quotaglance-dmg.XXXXXX")"
trap 'rm -rf -- "$staging_path"' EXIT

if [[ -e "$release_root" ]]; then
  print -u2 "release output already exists: $release_root"
  print -u2 "Move it aside before retrying; signed evidence is never overwritten."
  exit 1
fi
mkdir -p "$updates_path"

cd "$repo_root/Apps"
xcodegen generate
xcodebuild \
  -project QuotaPulse.xcodeproj \
  -scheme QuotaPulseMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "${repo_root}/scripts/ExportOptions-DeveloperID.plist"

app_path="${export_path}/QuotaGlance.app"
test -d "$app_path"
test -f "$app_path/Contents/embedded.provisionprofile"
codesign --verify --deep --strict --verbose=2 "$app_path"
[[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" == "$release_version" ]]
[[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" == "$release_build" ]]
[[ "$(plutil -extract SUFeedURL raw "$app_path/Contents/Info.plist")" == "https://raw.githubusercontent.com/${public_repository}/main/appcast.xml" ]]
lipo -archs "$app_path/Contents/MacOS/QuotaGlance" | grep -q arm64
lipo -archs "$app_path/Contents/MacOS/QuotaGlance" | grep -q x86_64
test -d "$app_path/Contents/Frameworks/Sparkle.framework"
test -x "$app_path/Contents/MacOS/claude-status-helper"

entitlements_path="${release_root}/signed-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$entitlements_path" 2>/dev/null
if plutil -p "$entitlements_path" | rg -q 'com.apple.security.app-sandbox.*=> 1'; then
  print -u2 "official direct build must not enable App Sandbox"
  exit 1
fi

ditto "$app_path" "$staging_path/QuotaGlance.app"
ln -s /Applications "$staging_path/Applications"
hdiutil create -volname QuotaGlance -srcfolder "$staging_path" -ov -format UDZO "$dmg_path"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg_path"
xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "${release_root}/notarization.json"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

cp "$release_notes" "${updates_path}/QuotaGlance.md"
cp "${repo_root}/appcast.xml" "${updates_path}/appcast.xml"
sparkle_bin="${derived_data}/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/generate_appcast" ]] || {
  print -u2 "Sparkle tools not found at deterministic package path: $sparkle_bin"
  exit 1
}

appcast_arguments=(
  --download-url-prefix "https://github.com/${public_repository}/releases/download/${tag}/"
  --link "https://github.com/${public_repository}/releases/tag/${tag}"
  --maximum-versions 5
  "$updates_path"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - "${appcast_arguments[@]}"
else
  "$sparkle_bin/generate_appcast" --account dev.yuanmeng.quotapulse "${appcast_arguments[@]}"
fi

cp "${updates_path}/appcast.xml" "${release_root}/appcast-candidate.xml"
print "Release candidate ready: $dmg_path"
print "Private evidence retained: ${archive_path}/dSYMs and ${release_root}/notarization.json"
print "Next, return to main and run: CONFIRM_PUBLIC_RELEASE=${tag} scripts/publish-macos-release.sh ${release_root}"
