#!/bin/zsh
# Draws Espalier's views to PNGs to look at: every capture, or those whose
# suite or name matches FILTER (a regular expression), in LOOK (Classic by
# default; "all" for each palette on the theme it's made for). Prints the
# folder.
#
#   scripts/capture.sh [--look LOOK] [--out FOLDER] [FILTER]
#
# LOOK is spelled as the settings store it: frost-iris, pop-magenta-fixel,
# islands-lagoon-warm, classic-sfmono. FOLDER defaults to .captures in
# the checkout; it's emptied first.

set -euo pipefail

root=${0:A:h:h}
look=classic
out=$root/.captures
filter=

while (( $# )); do
    case $1 in
        --look) look=$2; shift 2 ;;
        --out) out=${2:A}; shift 2 ;;
        -h|--help) sed -n '2,11p' $0 | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) filter=$1; shift ;;
    esac
done

if [[ $look == all ]]; then
    looks=(classic frost-iris frost-slate islands-lagoon islands-plum
        pop-tangerine pop-magenta pop-volt)
else
    looks=($look)
fi

rm -rf $out
mkdir -p $out
cd $root/Packages/EspalierKit
swift build --build-tests >&2
for each in $looks; do
    ESPALIER_CAPTURES=$out ESPALIER_CAPTURE_LOOK=$each \
        lockf -k /tmp/espalier-swift-test.lock \
        swift test --skip-build --filter "EspalierCaptures\\..*${filter}" >&2
done
print $out
