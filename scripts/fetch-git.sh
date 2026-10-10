#!/bin/bash
# Installs the bundled git at Vendor/git.
#
# Downloads desktop's prebuilt git (dugite-native, which includes Git LFS and
# Git Credential Manager) for the release pinned in scripts/git-version,
# verifies the tarball against scripts/git-checksums, and installs it at
# Vendor/git. Espalier requires macOS 27, which runs only on Apple silicon,
# so only the arm64 build is used.
#
# Idempotent: exits early when Vendor/git already holds the pinned build.
# Tarballs are cached in ~/Library/Caches/dev.abdeen.espalier.build (override
# with ESPALIER_BUILD_CACHE), so other worktrees install without the network.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tag="$(tr -d '[:space:]' < "$root/scripts/git-version")"
checksums="$root/scripts/git-checksums"
dest="$root/Vendor/git"
cache="${ESPALIER_BUILD_CACHE:-$HOME/Library/Caches/dev.abdeen.espalier.build}/dugite-native/$tag"
stamp="$tag arm64"

if [[ -f "$dest/.espalier-git" && "$(cat "$dest/.espalier-git")" == "$stamp" ]]; then
  echo "Vendor/git is up to date ($stamp)"
  exit 0
fi

asset="$(awk '$2 ~ /-macOS-arm64\.tar\.gz$/ { print $2 }' "$checksums")"
expected="$(awk -v name="$asset" '$2 == name { print $1 }' "$checksums")"
if [[ -z "$asset" || -z "$expected" ]]; then
  echo "error: scripts/git-checksums has no macOS-arm64 entry" >&2
  exit 1
fi

mkdir -p "$cache"
if [[ ! -f "$cache/$asset" ]]; then
  echo "Downloading $asset"
  curl --fail --location --silent --show-error --retry 3 \
    --output "$cache/$asset.partial" \
    "https://github.com/desktop/dugite-native/releases/download/$tag/$asset"
  mv "$cache/$asset.partial" "$cache/$asset"
fi

actual="$(shasum -a 256 "$cache/$asset" | awk '{ print $1 }')"
if [[ "$actual" != "$expected" ]]; then
  rm -f "$cache/$asset"
  echo "error: checksum mismatch for $asset" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/espalier-git.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
# Extract into a subdirectory: mktemp's own directory is private (0700).
mkdir "$staging/git"
tar -xzf "$cache/$asset" -C "$staging/git"

"$staging/git/bin/git" --version > /dev/null
echo "$stamp" > "$staging/git/.espalier-git"

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$staging/git" "$dest"

echo "Installed $("$dest/bin/git" --version) ($stamp) at Vendor/git"
