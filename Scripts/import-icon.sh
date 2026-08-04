#!/usr/bin/env bash
#
# Scripts/import-icon.sh — turn one square PNG into the app's ten icon renditions.
#
#   Scripts/import-icon.sh ~/Downloads/vigil-icon.png
#   Scripts/import-icon.sh --dry-run ~/Downloads/vigil-icon.png
#
# Writes into Sources/VigilUI/Resources/Assets.xcassets/AppIcon.appiconset, which is the one place
# the icon lives: SwiftUI reads it from the compiled catalog, and Scripts/make-icon.sh stages it
# into the .icns the Dock reads on first launch. Nothing else needs updating afterwards.
#
# ⚠️ THE SOURCE MUST BE 1024×1024 AND SQUARE. Everything below is a downscale, so a smaller source
# is upscaled into a soft 512 @2x and a non-square one is distorted — `sips` will resample happily
# and say nothing. Both are refused here instead.
#
# macOS only: `sips` is an Apple tool. This script is what a designer's PNG goes through, so it is
# deliberately the only step between a file and a committed icon.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
DESTINATION="$ROOT/Sources/VigilUI/Resources/Assets.xcassets/AppIcon.appiconset"
DRY_RUN=no
SOURCE=""

usage() {
    cat <<'EOF'
Usage: Scripts/import-icon.sh [--dry-run] [--destination DIR] SOURCE.png

Rewrites the ten macOS renditions in the asset catalog from one 1024×1024 PNG.
Run Scripts/build-app.sh afterwards to see it on the Dock.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=yes; shift ;;
        --destination)
            [ $# -ge 2 ] || { echo "error: --destination requires a directory" >&2; exit 2; }
            DESTINATION=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)  [ -z "$SOURCE" ] || { echo "error: one source only" >&2; exit 2; }
            SOURCE=$1; shift ;;
    esac
done

[ -n "$SOURCE" ] || { usage >&2; exit 2; }
[ -f "$SOURCE" ] || { echo "error: no such file: $SOURCE" >&2; exit 2; }
[ -d "$DESTINATION" ] || { echo "error: no such directory: $DESTINATION" >&2; exit 2; }

[ "$(uname -s)" = Darwin ] || { echo "error: sips is an Apple tool; run this on macOS" >&2; exit 3; }
command -v sips >/dev/null 2>&1 || { echo "error: sips is unavailable" >&2; exit 3; }

width=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')
[ -n "$width" ] && [ -n "$height" ] || { echo "error: $SOURCE is not an image sips can read" >&2; exit 2; }
if [ "$width" != "$height" ]; then
    echo "error: $SOURCE is ${width}×${height}; the icon must be square" >&2
    exit 2
fi
if [ "$width" -lt 1024 ]; then
    echo "error: $SOURCE is ${width}×${width}; 1024×1024 is the smallest that fills 512@2x" >&2
    exit 2
fi

# name:pixels — the ten renditions macOS asks for, at the sizes Contents.json already declares.
RENDITIONS="
icon_16x16@1x:16
icon_16x16@2x:32
icon_32x32@1x:32
icon_32x32@2x:64
icon_128x128@1x:128
icon_128x128@2x:256
icon_256x256@1x:256
icon_256x256@2x:512
icon_512x512@1x:512
icon_512x512@2x:1024
"

for entry in $RENDITIONS; do
    name=${entry%%:*}
    pixels=${entry##*:}
    if [ "$DRY_RUN" = yes ]; then
        printf 'sips -s format png -z %s %s %q --out %q\n' \
            "$pixels" "$pixels" "$SOURCE" "$DESTINATION/$name.png"
        continue
    fi
    sips -s format png -z "$pixels" "$pixels" "$SOURCE" --out "$DESTINATION/$name.png" >/dev/null
    printf '  %-22s %s×%s\n' "$name.png" "$pixels" "$pixels"
done

[ "$DRY_RUN" = yes ] && exit 0

echo
echo "Wrote 10 renditions to ${DESTINATION#"$ROOT"/}"
echo "Next: Scripts/build-app.sh   (make-icon.sh compiles these into AppIcon.icns)"
