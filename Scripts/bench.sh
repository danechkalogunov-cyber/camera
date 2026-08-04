#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/bench.sh [--smoke] [--trace PATH]

Validate the permanent performance signposts, or inspect an exported xctrace JSON document.
--smoke checks the instrumentation contract without launching the macOS application.
EOF
}

mode=smoke
trace=
while (($#)); do
    case "$1" in
        --smoke) mode=smoke ;;
        --trace) shift; trace=${1:?--trace requires a path}; mode=trace ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

readonly names=(launch launchToFirstFrame describe setup firstRTP firstKeyframe decode render snapshot recordStart paletteOpen timelineDraw)
source_file=Sources/Vigil/VideoSignposts.swift

for name in "${names[@]}"; do
    rg -q "emitEvent\(\"${name}\"\)" "$source_file" || {
        echo "missing signpost emission: $name" >&2
        exit 1
    }
done

if [[ $mode == trace ]]; then
    [[ -f $trace ]] || { echo "trace not found: $trace" >&2; exit 1; }
    for name in "${names[@]}"; do
        rg -q "\b${name}\b" "$trace" || { echo "trace is missing: $name" >&2; exit 1; }
    done
fi

echo "PASS: ${#names[@]} permanent signposts (${mode})"
