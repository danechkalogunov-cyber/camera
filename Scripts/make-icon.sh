#!/usr/bin/env bash
# Compile the app icon into the .icns file consumed by Info.plist.
#
# ⛔ THE DEFAULT INPUT IS THE ASSET CATALOG, NOT A LOOSE .iconset — and it used to be
# `Resources/AppIcon.iconset`, a directory that has never existed in this repository. So this script
# failed on its first line of work every time it was run, and `Scripts/build-app.sh` looked in a
# third place (`Sources/VigilUI/Resources/AppIcon.iconset`) and quietly shipped the generic Dock
# icon. One source of truth now: the renditions live in the catalog, where SwiftUI also reads them.
#
# The catalog cannot be handed to `iconutil` directly. It names the 1× renditions `icon_16x16@1x.png`
# while `iconutil` insists on `icon_16x16.png`, so an `.appiconset` is staged into a temporary
# `.iconset` with the names it wants. A real `.iconset` is still accepted and used as-is.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
INPUT="$ROOT/Sources/VigilUI/Resources/Assets.xcassets/AppIcon.appiconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"
DRY_RUN=no

usage() {
    cat <<'EOF'
Usage: Scripts/make-icon.sh [--input DIR] [--output AppIcon.icns] [--dry-run]

Validate the complete macOS icon and compile it atomically with Apple's iconutil.

--input accepts either an .appiconset (the asset catalog's, which is the default and the one place
the renditions are kept) or a plain .iconset. The defaults match Resources/Info.plist and
docs/DESIGN.md section 11.1.
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

[ -d "$INPUT" ] || { echo "error: icon directory not found: $INPUT" >&2; exit 2; }

# One trap for every temporary this script makes, installed before the first one exists. Two
# `trap … EXIT` calls would not compose — the second replaces the first — and installing it later
# would leak the staged iconset on the `--dry-run` path, which exits in between.
STAGE=""
TEMP_OUTPUT=""
cleanup() {
    [ -n "$TEMP_OUTPUT" ] && rm -f "$TEMP_OUTPUT"
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    return 0
}
trap cleanup EXIT HUP INT TERM

# An `.appiconset` is staged into a temporary `.iconset`: same bytes, the names `iconutil` wants.
case "$INPUT" in
    *.appiconset)
        STAGE=$(mktemp -d)
        ICONSET="$STAGE/AppIcon.iconset"
        mkdir -p "$ICONSET"
        for size in 16x16 32x32 128x128 256x256 512x512; do
            # 1× loses the scale suffix, 2× keeps it. Copied rather than linked so a stale symlink
            # into a deleted temp directory can never end up in a shipped bundle.
            [ -s "$INPUT/icon_$size@1x.png" ] \
                && cp "$INPUT/icon_$size@1x.png" "$ICONSET/icon_$size.png"
            [ -s "$INPUT/icon_$size@2x.png" ] \
                && cp "$INPUT/icon_$size@2x.png" "$ICONSET/icon_$size@2x.png"
        done
        SOURCE="$ICONSET"
        ;;
    *)
        SOURCE="$INPUT"
        ;;
esac

missing=no
for file in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    if [ ! -s "$SOURCE/$file" ]; then
        echo "error: missing or empty icon rendition: $file (from $INPUT)" >&2
        missing=yes
    fi
done
[ "$missing" = no ] || exit 2

printf 'iconutil --convert icns --output %q %q\n' "$OUTPUT" "$SOURCE"
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
iconutil --convert icns --output "$TEMP_OUTPUT" "$SOURCE"
[ -s "$TEMP_OUTPUT" ] || { echo "error: iconutil produced an empty file" >&2; exit 4; }
mv -f "$TEMP_OUTPUT" "$OUTPUT"
printf 'Generated %s\n' "$OUTPUT"
