#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 <release-candidate-directory>"
  exit 64
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
candidate_root="${1:A}"
public_repository="${PUBLIC_MAC_REPOSITORY:-yaun369/quota-glance-macos}"
version_config="${repo_root}/Config/Version.xcconfig"
release_version="$(awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$version_config")"
tag="v${release_version}"
dmg_path="${candidate_root}/updates/QuotaGlance.dmg"
appcast_candidate="${candidate_root}/appcast-candidate.xml"
release_notes="${repo_root}/docs/releases/${release_version}.md"

[[ "${CONFIRM_PUBLIC_RELEASE:-}" == "$tag" ]] || {
  print -u2 "manual confirmation required: set CONFIRM_PUBLIC_RELEASE=${tag}"
  exit 1
}
[[ "$(git -C "$repo_root" branch --show-current)" == "main" ]] || {
  print -u2 "publish from the public repository's main branch after building the tag checkout"
  exit 1
}
[[ -z "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]] || {
  print -u2 "public main worktree must be clean"
  exit 1
}
origin="$(git -C "$repo_root" remote get-url origin)"
[[ "$origin" == *"${public_repository}"* ]] || { print -u2 "unexpected origin: $origin"; exit 1; }
git -C "$repo_root" rev-parse --verify "refs/tags/${tag}" >/dev/null
[[ -s "$dmg_path" && -s "$appcast_candidate" && -s "$release_notes" ]] || {
  print -u2 "candidate DMG, appcast, or release notes are missing"
  exit 1
}
rg -q "releases/download/${tag}/QuotaGlance.dmg" "$appcast_candidate" || {
  print -u2 "candidate appcast does not point at ${tag}/QuotaGlance.dmg"
  exit 1
}

if gh release view "$tag" --repo "$public_repository" >/dev/null 2>&1; then
  print -u2 "GitHub release ${tag} already exists; refusing to overwrite an asset"
  exit 1
fi

gh release create "$tag" "$dmg_path#QuotaGlance.dmg" \
  --repo "$public_repository" \
  --title "QuotaGlance ${release_version}" \
  --notes-file "$release_notes" \
  --verify-tag

asset_url="https://github.com/${public_repository}/releases/download/${tag}/QuotaGlance.dmg"
curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
  --output /dev/null "$asset_url"

cp "$appcast_candidate" "${repo_root}/appcast.xml"
git -C "$repo_root" add appcast.xml
git -C "$repo_root" commit -m "Publish Sparkle appcast for ${tag}"
git -C "$repo_root" push origin main

feed_url="https://raw.githubusercontent.com/${public_repository}/main/appcast.xml"
curl --fail --location --silent --show-error --retry 5 --retry-all-errors "$feed_url" | \
  rg -q "releases/download/${tag}/QuotaGlance.dmg"
print "Published ${tag}: asset first, then the verified Sparkle appcast."
