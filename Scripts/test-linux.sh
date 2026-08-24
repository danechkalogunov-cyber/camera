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
    # cancellation. An unbounded test worker count starves those controlled scenarios, while the
    # Linux Swift Testing runner can stall before the first filtered test in fully serial mode.
    #
    # ⚠️ DIAGNOSTIC (temporary): VigilISAPITests hangs to the 300 s timeout with two workers and no
    # log names the culprit. Run it with a single worker so the serial pass/fail lines stop exactly
    # at the offending test — and if a single worker makes it pass, the hang is worker starvation,
    # not a logic deadlock. Revert to two workers once the cause is found.
    workers=2
    [ "$target" = "VigilISAPITests" ] && workers=1
    if timeout 300 swift test --parallel --num-workers "$workers" --filter "$target"; then
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
