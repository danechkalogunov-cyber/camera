#!/usr/bin/env bash
# Compile the source AppIcon.iconset into the .icns file consumed by Info.plist.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
INPUT="$ROOT/Resources/AppIcon.iconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"
DRY_RUN=no

usage() {
    cat <<'EOF'
Usage: Scripts/make-icon.sh [--input AppIcon.iconset] [--output AppIcon.icns] [--dry-run]

Validate the complete macOS iconset and compile it atomically with Apple's iconutil.
The defaults match Resources/Info.plist and docs/DESIGN.md section 11.1.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --input) [ $# -ge 2 ] || { echo "error: --input requires a directory" >&2; exit 2; }; INPUT=$2; shift 2 ;;
        --output) [ $# -ge 2 ] || { echo "error: --output requires a file" >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -d "$INPUT" ] || { echo "error: iconset directory not found: $INPUT" >&2; exit 2; }

missing=no
for file in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    if [ ! -s "$INPUT/$file" ]; then
        echo "error: missing or empty icon rendition: $INPUT/$file" >&2
        missing=yes
    fi
done
[ "$missing" = no ] || exit 2

printf 'iconutil --convert icns --output %q %q\n' "$OUTPUT" "$INPUT"
[ "$DRY_RUN" = yes ] && exit 0

[ "$(uname -s)" = Darwin ] || {
    echo "error: iconutil is an Apple tool; run this script on macOS" >&2
    exit 3
}
command -v iconutil >/dev/null 2>&1 || {
    echo "error: iconutil is unavailable; install the Xcode command line tools" >&2
    exit 3
}

mkdir -p "$(dirname -- "$OUTPUT")"
TEMP_OUTPUT="$(dirname -- "$OUTPUT")/.AppIcon.$$.icns"
trap 'rm -f "$TEMP_OUTPUT"' EXIT HUP INT TERM
iconutil --convert icns --output "$TEMP_OUTPUT" "$INPUT"
[ -s "$TEMP_OUTPUT" ] || { echo "error: iconutil produced an empty file" >&2; exit 4; }
mv -f "$TEMP_OUTPUT" "$OUTPUT"
trap - EXIT HUP INT TERM
printf 'Generated %s\n' "$OUTPUT"
