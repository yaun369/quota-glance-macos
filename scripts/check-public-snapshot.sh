#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 <snapshot-directory>"
  exit 64
fi

snapshot="${1:A}"
[[ -d "$snapshot" ]] || { print -u2 "not a directory: $snapshot"; exit 66; }
command -v rg >/dev/null || { print -u2 "required command not found: rg"; exit 69; }

# Build caches may contain third-party fixtures (including Sparkle test keys)
# and are never exported or committed. Scan the snapshot, not ignored output.
find_prune=(
  -path '*/.git' -o
  -path '*/.build' -o
  -path '*/.swiftpm' -o
  -path '*/build' -o
  -path '*/DerivedData' -o
  -path '*/Apps/QuotaPulse.xcodeproj'
)

blocked_names="$({
  find "$snapshot" \( "${find_prune[@]}" \) -prune -o -type f \( \
    -name '*.p8' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o \
    -name '*.mobileprovision' -o -name '*.provisionprofile' -o \
    -name '.env' -o -name '.env.*' \
  \) -print
} 2>/dev/null)"
if [[ -n "$blocked_names" ]]; then
  print -u2 "blocked credential/profile filename in public snapshot:"
  print -u2 -- "$blocked_names"
  exit 1
fi

large_files="$(find "$snapshot" \( "${find_prune[@]}" \) -prune -o -type f -size +20M -print 2>/dev/null)"
if [[ -n "$large_files" ]]; then
  print -u2 "unexpected file larger than 20 MiB in public snapshot:"
  print -u2 -- "$large_files"
  exit 1
fi

secret_pattern='-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}'
if rg -n --hidden \
  --glob '!.git/**' --glob '!.build/**' --glob '!.swiftpm/**' \
  --glob '!build/**' --glob '!DerivedData/**' \
  --glob '!Apps/QuotaPulse.xcodeproj/**' --glob '!check-public-snapshot.sh' \
  -e "$secret_pattern" "$snapshot"; then
  print -u2 "possible credential material found in public snapshot"
  exit 1
fi

if find "$snapshot" \( "${find_prune[@]}" \) -prune -o -type l -print | grep -q .; then
  print -u2 "symbolic links are not allowed in the exported source snapshot"
  exit 1
fi

print "Public snapshot safety checks passed."
