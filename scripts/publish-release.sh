#!/bin/bash
# Publishes a release from the Espalier.app Xcode exported (Distribute App ▸
# Direct Distribution, which notarizes and staples it) to the checkout's root:
# puts the app in a DMG, adds the DMG to the appcast, signed with Sparkle's
# key, uploads the DMG and then the appcast to the update bucket, reads both
# back through updates.abdeen.industries, and tags the release.
# docs/RELEASING.md has the whole release.
#
#   scripts/publish-release.sh
#
# The appcast starts from the one the feed serves, so its history doesn't
# depend on this checkout. After a failure, run it again: the DMG in dist/ is
# reused while it holds the same app, a DMG already uploaded is kept when it
# matches, and the appcast's entry for this version is replaced.
#
# The uploads run through the Railway CLI, signed in and with this checkout
# linked to the updates project, which gives them the bucket's credentials
# from the update host's service.
#
# Environment:
#   SPARKLE_ACCOUNT  The Keychain account of Sparkle's private key
#                    (default: espalier).
#   SPARKLE_BIN      The folder with Sparkle's generate_appcast and
#                    generate_keys (default: the newest in Xcode's
#                    DerivedData for Espalier).
#   FIRST_RELEASE=1  Starts a new appcast when the feed has none. Only for
#                    the first release.
#   UPLOAD=0         Makes the DMG and the signed appcast in dist/ and stops:
#                    no upload, no tag.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
# The update host (abdeen/industries/updates) answers /espalier/<file> with
# the bucket's object espalier/<file>.
app_key=espalier
base_url="https://updates.abdeen.industries/$app_key"
sparkle_account="${SPARKLE_ACCOUNT:-espalier}"
upload="${UPLOAD:-1}"

fail() {
  echo "error: $*" >&2
  exit 1
}

app="$root/Espalier.app"
[[ -f "$app/Contents/Info.plist" ]] ||
  fail "no Espalier.app in $root. Export it with Distribute App ▸ Direct Distribution and put it there."

work="$(mktemp -d)"
mount="$work/mount"
mkdir "$mount"
cleanup() {
  [[ -d "$mount/Espalier.app" ]] && hdiutil detach -quiet "$mount" || true
  rm -rf "$work"
}
trap cleanup EXIT

# Runs a command with the variables of the update host's service, from the
# Railway project this checkout is linked to (docs/RELEASING.md, One-time
# setup): BUCKET, ACCESS_KEY_ID, SECRET_ACCESS_KEY, and ENDPOINT, the
# bucket's.
with_bucket() {
  (cd "$root" && railway run --environment production --service updates -- "$@")
}

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# The hash of an app's signature, which covers everything in the bundle.
cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}

# The app.
version="$(read_plist "$app" CFBundleShortVersionString)"
build="$(read_plist "$app" CFBundleVersion)"
feed_url="$(read_plist "$app" SUFeedURL)"
public_key="$(read_plist "$app" SUPublicEDKey)"
dmg_name="Espalier-$version.dmg"
dmg="$dist/$dmg_name"
tag="v$version"

# MARKETING_VERSION of the app target's Release configuration (the one with
# the release bundle identifier).
project_version="$(awk '
  /buildSettings = \{/ { in_block = 1; version = ""; is_app = 0; next }
  in_block && /MARKETING_VERSION = / {
    version = $0
    sub(/.*MARKETING_VERSION = /, "", version); sub(/;.*/, "", version)
  }
  in_block && /PRODUCT_BUNDLE_IDENTIFIER = dev\.abdeen\.espalier;/ { is_app = 1 }
  in_block && /^[[:space:]]*\};/ {
    if (is_app && version != "") print version
    in_block = 0
  }
' "$root/Espalier.xcodeproj/project.pbxproj" | sort -u)"

[[ "$version" == "$project_version" ]] ||
  fail "the app is ${version:-unversioned}, but the project's Release version is ${project_version:-unreadable}. Export from the committed project."
[[ "$feed_url" == "$base_url/appcast.xml" ]] || fail "the app's SUFeedURL is ${feed_url:-missing}, not $base_url/appcast.xml"
[[ -n "$public_key" ]] || fail "the app has no SUPublicEDKey (docs/RELEASING.md, One-time setup)"
xcrun stapler validate -q "$app" || fail "the app isn't notarized and stapled. Export it with Distribute App ▸ Direct Distribution."
spctl --assess --type execute "$app" || fail "Gatekeeper rejects the app"

# The release is a pushed commit, and its tag can only name that commit.
[[ -z "$(git -C "$root" status --porcelain)" ]] ||
  fail "the checkout has changes or untracked files. Commit or remove them, so the release is exactly a commit."
git -C "$root" fetch --quiet origin || fail "can't fetch origin"
head="$(git -C "$root" rev-parse HEAD)"
[[ "$head" == "$(git -C "$root" rev-parse origin/main)" ]] || fail "HEAD isn't origin/main. Push main, or check out what's pushed."
if local_tag="$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}")" && [[ "$local_tag" != "$head" ]]; then
  fail "$tag already names another commit."
fi
# An annotated tag's commit is its peeled ("^{}") line.
remote_tag="$(git -C "$root" ls-remote --tags origin | awk -v ref="refs/tags/$tag" '
  $2 == ref "^{}" { peeled = $1 }
  $2 == ref { plain = $1 }
  END { print (peeled != "" ? peeled : plain) }
')"
[[ -z "$remote_tag" || "$remote_tag" == "$head" ]] || fail "$tag on origin names another commit."

if [[ "$upload" == 1 ]]; then
  command -v railway >/dev/null || fail "the uploads need the Railway CLI (brew install railway). UPLOAD=0 stops before uploading."
  with_bucket /bin/sh -c '[ -n "$BUCKET" ] && [ -n "$ACCESS_KEY_ID" ] && [ -n "$SECRET_ACCESS_KEY" ]' ||
    fail "Railway didn't give the bucket's credentials. Sign in with railway login, link this checkout (docs/RELEASING.md, One-time setup), and run again."
fi

# Sparkle's tools come with the Sparkle package, which Xcode resolves into
# DerivedData when it opens the project.
sparkle_bin="${SPARKLE_BIN:-}"
if [[ -z "$sparkle_bin" ]]; then
  derived="$HOME/Library/Developer/Xcode/DerivedData"
  newest="$(ls -t "$derived"/Espalier-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null | head -n 1 || true)"
  [[ -z "$newest" ]] || sparkle_bin="$(dirname "$newest")"
fi
[[ -n "$sparkle_bin" && -x "$sparkle_bin/generate_appcast" && -x "$sparkle_bin/generate_keys" ]] ||
  fail "can't find Sparkle's tools. Open Espalier.xcodeproj in Xcode so it resolves Sparkle, or set SPARKLE_BIN."
echo "Sparkle's tools: $sparkle_bin"

# Signing with any other key would break updates for every installed copy.
keychain_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p)" ||
  fail "the Keychain has no Sparkle key under the account \"$sparkle_account\""
[[ "$keychain_key" == "$public_key" ]] ||
  fail "the Keychain's Sparkle key ($keychain_key) isn't the app's SUPublicEDKey ($public_key). Restore the right key; don't change SUPublicEDKey."

# The feed as it is.
appcast="$work/appcast.xml"
status="$(curl --silent --show-error --location --output "$appcast" --write-out '%{http_code}' "$base_url/appcast.xml")" ||
  fail "can't reach $base_url/appcast.xml"
case "$status" in
  200) ;;
  403 | 404)
    [[ "${FIRST_RELEASE:-0}" == 1 ]] ||
      fail "$base_url/appcast.xml doesn't exist. For the first release only, run with FIRST_RELEASE=1."
    rm -f "$appcast"
    ;;
  *) fail "$base_url/appcast.xml answered $status" ;;
esac

if [[ -f "$appcast" ]]; then
  # A republished version replaces its entry: generate_appcast keys entries
  # by build number, and a second entry for the same DMG would never verify.
  awk -v version="$version" '
    /<item>/ { item = $0 "\n"; inside = 1; drop = 0; next }
    inside {
      item = item $0 "\n"
      if (index($0, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>")) drop = 1
      if (index($0, "</item>")) {
        if (!drop) printf "%s", item
        inside = 0
      }
      next
    }
    { print }
  ' "$appcast" >"$appcast.pruned"
  mv "$appcast.pruned" "$appcast"

  # Sparkle offers an update only when its build number is higher.
  newest="$(sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' "$appcast" | sort -V | tail -n 1)"
  if [[ -n "$newest" ]]; then
    higher="$(printf '%s\n%s\n' "$newest" "$build" | sort -V | tail -n 1)"
    if [[ "$newest" == "$build" || "$higher" != "$build" ]]; then
      fail "build $build isn't higher than the feed's newest, $newest. Raise CURRENT_PROJECT_VERSION."
    fi
  fi
fi

# The DMG: the app and a link to Applications. LZMA (ULMO) makes the bundled
# git about a quarter smaller than zlib (UDZO). A DMG from an earlier run is
# kept when it holds this same app, so a run after a failure uploads the
# same file.
mkdir -p "$dist"
if [[ -f "$dmg" ]]; then
  diskutil image attach --readOnly --nobrowse --mountPoint "$mount" "$dmg" >/dev/null
  dmg_hash="$(cdhash "$mount/Espalier.app")"
  hdiutil detach -quiet "$mount"
  [[ "$dmg_hash" == "$(cdhash "$app")" ]] || rm -f "$dmg"
fi
if [[ -f "$dmg" ]]; then
  echo "dist/$dmg_name already holds this app."
else
  stage="$work/dmg"
  mkdir "$stage"
  ditto "$app" "$stage/Espalier.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname Espalier -srcfolder "$stage" -fs HFS+ -format ULMO "$dmg"
  echo "Made dist/$dmg_name."
fi

# generate_appcast signs the DMG, its entry, and the appcast (the app sets
# SURequireSignedFeed). Release notes come from a file named like the DMG.
archives="$work/archives"
mkdir "$archives"
cp "$dmg" "$archives/"
if "$root/scripts/changelog.sh" "$version" >"$archives/Espalier-$version.md" 2>/dev/null; then
  echo "Release notes: CHANGELOG.md's $version."
else
  rm -f "$archives/Espalier-$version.md"
  echo "warning: CHANGELOG.md has no section for $version; the update shows no notes." >&2
fi
"$sparkle_bin/generate_appcast" \
  --account "$sparkle_account" \
  --embed-release-notes \
  --download-url-prefix "$base_url/" \
  -o "$appcast" \
  "$archives"
grep -q "url=\"$base_url/$dmg_name\"" "$appcast" || fail "the new appcast has no entry for $dmg_name"
cp "$appcast" "$dist/appcast.xml"

if [[ "$upload" != 1 ]]; then
  echo "UPLOAD=0: dist/$dmg_name and the signed dist/appcast.xml are ready. Nothing was uploaded or tagged."
  exit 0
fi

# Uploads a file to the bucket's espalier/<name>. Only the upload sees the
# bucket's credentials, and the key pair goes to curl on stdin, so the secret
# never shows in ps.
put() {
  with_bucket /bin/bash -c '
    set -euo pipefail
    file="$1" key="$2" type="$3" cache="$4"
    endpoint="${ENDPOINT:-https://t3.storageapi.dev}"
    endpoint="${endpoint#https://}"
    endpoint="${endpoint%%/*}"
    headers=(--header "Content-Type: $type")
    [[ -z "$cache" ]] || headers+=(--header "Cache-Control: $cache")
    printf "user = \"%s:%s\"\n" "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY" |
      curl --config - --fail-with-body --silent --show-error \
        --aws-sigv4 "aws:amz:auto:s3" \
        "${headers[@]}" \
        --upload-file "$file" \
        "https://$BUCKET.$endpoint/$key"
  ' put "$1" "$app_key/$2" "$3" "${4:-}"
}

# Whether the update host serves exactly this file as <name>.
served() {
  curl --fail --silent --show-error --location "$base_url/$1" | cmp -s - "$2"
}

# The DMG first: the appcast must never point at a file that isn't there.
status="$(curl --silent --show-error --location --head --output /dev/null --write-out '%{http_code}' "$base_url/$dmg_name")" ||
  fail "can't reach $base_url/$dmg_name"
case "$status" in
  200)
    served "$dmg_name" "$dmg" ||
      fail "$base_url/$dmg_name is already published and isn't dist/$dmg_name. Bump the version rather than replace a published DMG."
    echo "$dmg_name is already uploaded."
    ;;
  403 | 404)
    echo "Uploading $dmg_name"
    put "$dmg" "$dmg_name" application/octet-stream || fail "uploading $dmg_name failed"
    served "$dmg_name" "$dmg" || fail "$base_url/$dmg_name doesn't serve the DMG just uploaded"
    ;;
  *) fail "$base_url/$dmg_name answered $status" ;;
esac

echo "Uploading appcast.xml"
put "$appcast" appcast.xml application/xml no-cache || fail "uploading appcast.xml failed"
served appcast.xml "$appcast" || fail "$base_url/appcast.xml doesn't serve the appcast just uploaded"

git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
  git -C "$root" tag --annotate --message "Espalier $version" "$tag" "$head"
git -C "$root" push --quiet origin "refs/tags/$tag"

echo
echo "Published Espalier $version:"
echo "  Feed:     $base_url/appcast.xml"
echo "  Download: $base_url/$dmg_name"
echo "  Tag:      $tag ($head)"
