#!/usr/bin/env bash
#
# Scripts/test-linux.sh — prove that every portable test target actually runs tests on Linux.
#
# `swift test` exits successfully when a platform guard leaves a test target empty. That behaviour
# is useful for the macOS-only targets in this package, but would turn the Linux gate into a false
# positive if a portable target were accidentally guarded out. Discover the tests first and require
# at least one from every portable target before running the suite.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ]; then
    echo "test-linux.sh: this script verifies the Linux build; on macOS use Scripts/test-macos.sh." >&2
    exit 2
fi

portable_targets=(
    VigilProtocolsTests
    VigilBitstreamTests
    VigilRTSPTests
    VigilRTPTests
    VigilISAPITests
    VigilDiscoveryTests
    VigilPipelineTests
)

test_list=$(mktemp)
trap 'rm -f "$test_list"' EXIT

echo "== purity gate =="
swift build --product VigilPure

echo
echo "== discover portable tests =="
swift test list > "$test_list"

portable_count=0
for target in "${portable_targets[@]}"; do
    count=$(awk -v prefix="$target." 'index($0, prefix) == 1 { count++ } END { print count + 0 }' \
        "$test_list")
    if [ "$count" -eq 0 ]; then
        echo "test-linux.sh: $target reported zero tests" >&2
        exit 1
    fi
    printf '  %-28s %4d tests\n' "$target" "$count"
    portable_count=$((portable_count + count))
done

if [ "$portable_count" -eq 0 ]; then
    echo "test-linux.sh: portable targets reported zero tests" >&2
    exit 1
fi

echo
echo "== run tests =="
for target in "${portable_targets[@]}"; do
    echo
    echo "== $target =="
    # Several suites deliberately create their own task groups to verify gates, coalescing and
    # cancellation. Running every test case concurrently on top of that can starve those controlled
    # scenarios on the two-core Linux runner, so keep target isolation without adding a second
    # scheduler layer here.
    if timeout 300 swift test --no-parallel --filter "$target"; then
        continue
    else
        status=$?
        if [ "$status" -eq 124 ]; then
            echo "test-linux.sh: $target exceeded 300 seconds" >&2
        else
            echo "test-linux.sh: $target failed with status $status" >&2
        fi
        exit 1
    fi
done

echo
echo "test-linux: PASS ($portable_count portable tests discovered)"
