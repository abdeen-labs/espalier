#!/bin/bash
# Run by the app target's "Embed git" build phase.
#
# Copies Vendor/git into the app at Contents/Resources/git and signs every
# Mach-O inside it with the app's signing identity and the hardened runtime
# (plus a secure timestamp for Release). Git Credential Manager is a .NET app,
# so its executable also gets the JIT entitlements its runtime needs.
#
# Skips all work when the embedded copy already matches Vendor/git, the
# identity, and the configuration.

set -euo pipefail

: "${SRCROOT:?embed-git.sh runs from an Xcode build phase}"
: "${TARGET_BUILD_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}"

src="$SRCROOT/Vendor/git"
dest="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/git"
entitlements="$SRCROOT/scripts/git-credential-manager.entitlements"

if [[ ! -x "$src/bin/git" || ! -f "$src/.espalier-git" ]]; then
  echo "error: Vendor/git is missing. Run scripts/fetch-git.sh to install the bundled git, then build again." >&2
  exit 1
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" || -z "$identity" ]]; then
  identity="-"
fi

stamp="$(cat "$src/.espalier-git") identity=$identity configuration=${CONFIGURATION:-}"
if [[ -f "$dest/.espalier-embed" && "$(cat "$dest/.espalier-embed")" == "$stamp" ]]; then
  echo "Embedded git is up to date"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
ditto "$src" "$dest"

sign_args=(--force --sign "$identity" --options runtime)
if [[ "${CONFIGURATION:-}" == "Release" && "$identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi

machos="$(mktemp "${TMPDIR:-/tmp}/espalier-machos.XXXXXX")"
trap 'rm -f "$machos"' EXIT

while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then
    printf '%s\0' "$file" >> "$machos"
  fi
done < <(find "$dest" -type f -print0)

count="$(tr -cd '\0' < "$machos" | wc -c | tr -d ' ')"
echo "Signing $count Mach-O files in Resources/git"

xargs -0 -P 8 -n 1 /bin/bash -c '
  set -euo pipefail
  file="$1"
  if [[ "$(basename "$file")" == "git-credential-manager" ]]; then
    codesign '"$(printf '%q ' "${sign_args[@]}")"' --entitlements '"$(printf '%q' "$entitlements")"' "$file"
  else
    codesign '"$(printf '%q ' "${sign_args[@]}")"' "$file"
  fi
' _ < "$machos"

echo "$stamp" > "$dest/.espalier-embed"
echo "Embedded $("$dest/bin/git" --version) at Resources/git"
