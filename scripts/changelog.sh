#!/bin/bash
# Prints one version's release notes from CHANGELOG.md: the Markdown under
# its "## [<version>] - <date>" heading, up to the next "## " heading or the
# link references at the end, without HTML comments or blank lines around it.
# publish-release.sh puts it in the appcast, where Sparkle's update window
# shows it.
#
#   scripts/changelog.sh <version> [CHANGELOG.md]
#
# Prints nothing and fails when there's no changelog or no section for the
# version.

set -euo pipefail

version="${1:?usage: changelog.sh <version> [CHANGELOG.md]}"
changelog="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"

[[ -f "$changelog" ]] || { echo "changelog.sh: no $changelog" >&2; exit 1; }

body="$(awk -v version="$version" '
  /^## / {
    name = ""
    if (match($0, /\[[^]]*\]/)) name = substr($0, RSTART + 1, RLENGTH - 2)
    if (name == version) { inside = 1; next }
    if (inside) exit
    next
  }
  inside && /^\[[^]]+\]:[[:space:]]/ { exit }
  inside { print }
' "$changelog" | awk '
  # HTML comments, including ones over several lines; a line that held
  # only a comment goes with it.
  {
    line = $0; out = ""; commented = in_comment
    while (1) {
      if (in_comment) {
        i = index(line, "-->")
        if (i == 0) { line = ""; break }
        line = substr(line, i + 3); in_comment = 0
      } else {
        i = index(line, "<!--")
        if (i == 0) { out = out line; break }
        out = out substr(line, 1, i - 1); line = substr(line, i + 4); in_comment = 1; commented = 1
      }
    }
    if (commented && out ~ /^[[:space:]]*$/) next
    print out
  }
' | awk '
  # Blank lines before the first line and after the last.
  { lines[NR] = $0 }
  NF { if (!first) first = NR; last = NR }
  END { if (last) for (i = first; i <= last; i++) print lines[i] }
')"

[[ -n "$body" ]] || { echo "changelog.sh: no notes for $version in $changelog" >&2; exit 1; }
printf '%s\n' "$body"
