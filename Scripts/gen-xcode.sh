#!/usr/bin/env bash
# Generate the optional Xcode project from the repository's checked-in XcodeGen specification.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
SPEC="$ROOT/project.yml"
OUTPUT="$ROOT"
DRY_RUN=no

usage() {
    cat <<'EOF'
Usage: Scripts/gen-xcode.sh [--spec FILE] [--output DIRECTORY] [--dry-run]

Generate Vigil.xcodeproj with XcodeGen. The generated project is disposable and git-ignored;
project.yml remains its source of truth.

Options:
  --spec FILE         XcodeGen specification (default: <repository>/project.yml)
  --output DIRECTORY  directory in which to generate (default: repository root)
  --dry-run           print the command after validating arguments; do not run it
  -h, --help          show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --spec) [ $# -ge 2 ] || { echo "error: --spec requires a file" >&2; exit 2; }; SPEC=$2; shift 2 ;;
        --output) [ $# -ge 2 ] || { echo "error: --output requires a directory" >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -f "$SPEC" ] || { echo "error: XcodeGen spec not found: $SPEC" >&2; exit 2; }
mkdir -p "$OUTPUT"
OUTPUT=$(cd -- "$OUTPUT" && pwd -P)
SPEC_DIR=$(cd -- "$(dirname -- "$SPEC")" && pwd -P)
SPEC="$SPEC_DIR/$(basename -- "$SPEC")"

printf 'xcodegen generate --spec %q --project %q\n' "$SPEC" "$OUTPUT"
[ "$DRY_RUN" = yes ] && exit 0

command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen is required (install it with: brew install xcodegen)" >&2
    exit 3
}

xcodegen generate --spec "$SPEC" --project "$OUTPUT"
PROJECT="$OUTPUT/Vigil.xcodeproj"
[ -f "$PROJECT/project.pbxproj" ] || {
    echo "error: xcodegen completed without creating $PROJECT/project.pbxproj" >&2
    exit 4
}
printf 'Generated %s\n' "$PROJECT"
