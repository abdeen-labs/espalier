#!/bin/bash
# Makes the README's images in .github/readme: the app icon, and History
# from the Showcase captures in Classic, Orchard, Islands, and Pop, light
# and dark. Each window gets rounded corners, a hairline, and a shadow, so
# it stands apart from GitHub's page.
#
#   scripts/readme-images.sh
#
# Needs Xcode (for Icon Composer's ictool), ImageMagick, and cwebp
# (brew install imagemagick webp).

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
out="$root/.github/readme"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for tool in magick cwebp; do
  command -v "$tool" >/dev/null || { echo "error: $tool isn't installed (brew install imagemagick webp)" >&2; exit 1; }
done
[[ -x "$ictool" ]] || { echo "error: no Icon Composer in /Applications/Xcode.app" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

# frame <png> <appearance> <framed png>: the window with 16-point corners, a
# hairline, and a shadow, on a transparent background. Captures are drawn
# at 2x, so a point is two pixels.
frame() {
  local w h hairline shadow
  read -r w h < <(magick identify -format '%w %h\n' "$1")
  if [[ "$2" == dark ]]; then
    hairline='rgba(255,255,255,0.16)' shadow=60
  else
    hairline='rgba(0,0,0,0.14)' shadow=28
  fi
  magick "$1" -alpha set \
    \( -size "${w}x$h" xc:none -fill white -draw "roundrectangle 0,0 $((w - 1)),$((h - 1)) 32,32" \) \
    -compose DstIn -composite -compose Over \
    -fill none -stroke "$hairline" -strokewidth 2 -draw "roundrectangle 1,1 $((w - 2)),$((h - 2)) 31,31" \
    \( +clone -background black -shadow "${shadow}x40+0+16" \) +swap \
    -background none -layers merge +repage "$3"
}

# Classic is the README's large window; the other themes sit in a row below it.
looks=(classic orchard-clay islands-lagoon pop-magenta)
for look in "${looks[@]}"; do
  "$root/scripts/capture.sh" --look "$look" --out "$work/$look" ShowcaseCaptures >/dev/null
  theme="${look%%-*}"
  width=960
  [[ "$theme" == classic ]] && width=2000
  for appearance in light dark; do
    frame "$work/$look/$look/Showcase/history-$appearance.png" "$appearance" "$work/$theme-$appearance.png"
    cwebp -quiet -q 82 -m 6 -sharp_yuv -resize "$width" 0 "$work/$theme-$appearance.png" -o "$out/$theme-$appearance.webp"
  done
done

for rendition in Default Dark; do
  "$ictool" "$root/Espalier/AppIcon.icon" --export-image --output-file "$work/icon-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 >/dev/null
done
cwebp -quiet -q 90 -resize 256 256 "$work/icon-Default.png" -o "$out/icon-light.webp"
cwebp -quiet -q 90 -resize 256 256 "$work/icon-Dark.png" -o "$out/icon-dark.webp"

echo "Wrote $(ls "$out" | wc -l | tr -d ' ') images to .github/readme"
