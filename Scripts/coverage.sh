#!/usr/bin/env bash
#
# Scripts/coverage.sh — line coverage, split by the line that actually matters.
#
#   Scripts/coverage.sh              report only, always exits 0
#   Scripts/coverage.sh --enforce    also assert the floors, exits 1 below them
#   Scripts/coverage.sh --no-test    reuse an existing profile instead of re-running the suite
#
# docs/API_CONTRACT.md §5 names this file and sets two floors: 90 % for the pure layer, 70 % for
# the macOS layer. Two numbers and not one, because they are not comparable — the pure targets are
# exercised by 2 000-odd tests on every platform, while the macOS targets hold SwiftUI bodies and
# AppKit glue that no test executes and some of which cannot be executed headlessly at all. A
# single blended figure hides both facts and moves when the *ratio* of the two changes, which is
# the one thing nobody wants a coverage number to do.
#
# ⚠️ REPORTING IS THE DEFAULT AND `--enforce` IS OPT-IN, on purpose. These floors have never been
# measured against this tree. Wiring an unmeasured threshold into CI fails the next commit for a
# reason that has nothing to do with it, and the usual response to that is to lower the threshold
# until it passes — which leaves a number in a config file that means nothing. Run this, look at
# what the tree actually does, and set the floors from evidence; `Scripts/test-macos.sh` already
# takes the same position about the single figure it prints.
#
# Requires a Mac: `swift test --enable-code-coverage` and `xcrun llvm-cov`. On Linux the profile is
# produced by a different toolchain layout and this script does not try to guess it.

set -uo pipefail
cd "$(dirname "$0")/.."

enforce=0
run_tests=1
for arg in "$@"; do
    case "$arg" in
        --enforce)  enforce=1 ;;
        --no-test)  run_tests=0 ;;
        -h|--help)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "coverage.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

# The floors from the contract. Named here rather than inline so that changing them is a visible,
# reviewable edit rather than a number buried in a comparison.
PURE_FLOOR=90
APPLE_FLOOR=70

command -v xcrun >/dev/null 2>&1 || {
    echo "coverage.sh: needs xcrun (a Mac with the Command Line Tools)." >&2
    exit 2
}

if [ "$run_tests" -eq 1 ]; then
    echo "== test (with coverage) =="
    swift test --parallel --enable-code-coverage || {
        echo "coverage.sh: the suite failed; coverage of a red tree is not worth reading." >&2
        exit 1
    }
    echo
fi

bin=$(swift build --show-bin-path) || exit 2
prof="$bin/codecov/default.profdata"
[ -f "$prof" ] || {
    echo "coverage.sh: no profile at $prof — run without --no-test." >&2
    exit 2
}

# `export`, not `report`: the JSON is a stable contract, while the report's columns are formatted
# for humans and have moved between LLVM releases. Parsing the pretty output is how these scripts
# start silently reporting zero.
binaries=()
while IFS= read -r candidate; do
    binaries+=("$candidate")
done < <(find "$bin" -path '*PackageTests.xctest/Contents/MacOS/*' -type f -perm -111 2>/dev/null)

[ "${#binaries[@]}" -gt 0 ] || {
    echo "coverage.sh: found no test binaries under $bin." >&2
    exit 2
}

# Every binary after the first is passed as `-object=`; llvm-cov takes one positional and the rest
# as options. Spelled as a loop because the `${array[@]/#/prefix}` shorthand is zsh, and this file
# runs under bash.
extra=()
for binary in "${binaries[@]:1}"; do
    extra+=("-object=$binary")
done

xcrun llvm-cov export "${binaries[0]}" \
    ${extra[@]+"${extra[@]}"} \
    -instr-profile "$prof" \
    -ignore-filename-regex='(/Tests/|/\.build/)' 2>/dev/null \
| PURE_FLOOR="$PURE_FLOOR" APPLE_FLOOR="$APPLE_FLOOR" ENFORCE="$enforce" python3 - <<'PY'
import json, os, sys

# Which targets are the pure layer. Kept as the same list Package.swift's VigilPure product holds;
# a target added there and forgotten here would be silently measured against the wrong floor.
PURE = {"VigilProtocols", "VigilBitstream", "VigilRTSP", "VigilRTP", "VigilISAPI", "VigilDiscovery"}

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("coverage.sh: llvm-cov produced no JSON — is the profile from this build?",
          file=sys.stderr)
    sys.exit(2)

buckets = {"pure": [0, 0], "apple": [0, 0]}   # [covered, total]
per_target = {}

for export in data.get("data", []):
    for entry in export.get("files", []):
        path = entry.get("filename", "")
        if "/Sources/" not in path:
            continue
        target = path.split("/Sources/", 1)[1].split("/", 1)[0]
        summary = entry.get("summary", {}).get("lines", {})
        covered, total = summary.get("covered", 0), summary.get("count", 0)
        if not total:
            continue
        bucket = "pure" if target in PURE else "apple"
        buckets[bucket][0] += covered
        buckets[bucket][1] += total
        slot = per_target.setdefault(target, [0, 0, bucket])
        slot[0] += covered
        slot[1] += total


def percent(covered, total):
    return 100.0 * covered / total if total else 0.0


print("== coverage by target ==")
for target in sorted(per_target, key=lambda t: (per_target[t][2], t)):
    covered, total, bucket = per_target[target]
    print(f"  {bucket:5}  {target:<18} {percent(covered, total):6.2f} %  "
          f"({covered}/{total} lines)")

floors = {"pure": int(os.environ["PURE_FLOOR"]), "apple": int(os.environ["APPLE_FLOOR"])}
labels = {"pure": "pure layer (Linux-testable)", "apple": "macOS layer"}

print()
print("== against the contract's floors ==")
failed = []
for bucket in ("pure", "apple"):
    covered, total = buckets[bucket]
    value, floor = percent(covered, total), floors[bucket]
    verdict = "ok " if value >= floor else "LOW"
    print(f"  {verdict}  {labels[bucket]:<28} {value:6.2f} %   floor {floor} %")
    if value < floor:
        failed.append(f"{labels[bucket]} at {value:.2f} % against a {floor} % floor")

print()
if not failed:
    print("coverage.sh: both layers meet the floors.")
    sys.exit(0)

if os.environ["ENFORCE"] == "1":
    for line in failed:
        print(f"coverage.sh: FAIL — {line}", file=sys.stderr)
    sys.exit(1)

for line in failed:
    print(f"coverage.sh: below floor — {line}")
print("coverage.sh: reporting only. Re-run with --enforce to make this an error, but read the")
print("             header first: these floors are inherited from a manifest, not measured here.")
sys.exit(0)
PY
