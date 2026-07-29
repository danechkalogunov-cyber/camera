#!/usr/bin/env bash
#
# Scripts/test-macos.sh — the whole suite, on the only platform that can run it.
#
#   Scripts/test-macos.sh [--coverage]
#
# Every target compiles here. On Linux the macOS-only files are wrapped in `#if os(macOS)` and
# vanish, which is why the hundreds of tests in VigilCore, VigilUI, VigilVideo, VigilTransport and
# VigilRender have never executed — see docs/BUILD-VERIFICATION.md. This script is what runs them.
set -uo pipefail
cd "$(dirname "$0")/.."

coverage=0
for arg in "$@"; do
    case "$arg" in
        --coverage) coverage=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ]; then
    echo "test-macos.sh: this needs a Mac; on Linux use Scripts/check.sh, which proves the"
    echo "portable half and says so rather than reporting a pass it did not earn." >&2
    exit 2
fi

# MARK: - Preflight
#
# Two things this script needs beyond a compiler — the `#Preview` macro plugin and the `Testing`
# module — do not ship with every toolchain. When either is missing the build emits the same error
# once per preview and once per test file: thousands of lines that all mean "wrong toolchain" and
# none of which say anything about this code. So each is *probed* rather than inferred, because
# where they live has moved between releases and `xcode-select -p` does not actually answer the
# question. Two `swiftc -typecheck` runs on two-line files cost a second and cannot be wrong.
#
# `Scripts/build-app.sh` needs neither: it builds `-c release`, where every `#if DEBUG` block — and
# so every `#Preview` — is compiled out before the compiler sees it. That is why `Scripts/run.sh`
# succeeds on a Mac where this script cannot, and why debug-only code reaches a compiler for the
# first time right here.

probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT

has_testing=yes
printf 'import Testing\n@Test func probe() {}\n' > "$probe_dir/testing.swift"
swiftc -typecheck "$probe_dir/testing.swift" >/dev/null 2>&1 || has_testing=no

has_previews=yes
printf '#if canImport(SwiftUI)\nimport SwiftUI\n#Preview { Text(verbatim: "probe") }\n#endif\n' \
    > "$probe_dir/preview.swift"
swiftc -typecheck "$probe_dir/preview.swift" >/dev/null 2>&1 || has_previews=no

if [ "$has_testing" = no ] || [ "$has_previews" = no ]; then
    echo "test-macos.sh: this toolchain cannot build the debug configuration." >&2
    echo >&2
    echo "  swift --version  ->  $(swift --version 2>&1 | head -1)" >&2
    echo "  xcode-select -p  ->  $(xcode-select -p 2>/dev/null || echo '(nothing)')" >&2
    [ "$has_testing"  = no ] && echo "  ✗ swift-testing: 'import Testing' does not resolve" >&2
    [ "$has_previews" = no ] && echo "  ✗ #Preview: the PreviewsMacros plugin is not installed" >&2
    [ "$has_testing"  = yes ] && echo "  ✓ swift-testing" >&2
    [ "$has_previews" = yes ] && echo "  ✓ #Preview" >&2
    echo >&2
    echo "  Both ship inside Xcode.app rather than with the Command Line Tools." >&2
    found=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -5)
    if [ -n "$found" ]; then
        echo >&2
        echo "  Xcode appears to be installed. Point the toolchain at it:" >&2
        for app in $found; do
            echo "      sudo xcode-select -s $app/Contents/Developer" >&2
        done
    else
        echo >&2
        echo "  No Xcode.app was found in /Applications. Install it from the App Store, then:" >&2
        echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    fi
    echo >&2
    echo "  Meanwhile Scripts/run.sh still builds and launches the app: a release build compiles" >&2
    echo "  no previews and imports no test module. What it cannot check is debug-only code —" >&2
    echo "  the #if DEBUG fixtures behind every preview — which is exactly what this script is for." >&2
    exit 2
fi

fail=0
echo "== build =="
swift build || fail=1

echo
echo "== test =="
if [ "$coverage" -eq 1 ]; then
    swift test --parallel --enable-code-coverage || fail=1
    echo
    echo "== coverage =="
    # Reported, not gated. docs/API_CONTRACT.md §5 sets floors of 90 % pure / 70 % macOS for a
    # `Scripts/coverage.sh` that does not exist yet; printing the number without asserting it is
    # honest, whereas asserting a floor nobody has measured would fail the first run for a reason
    # that has nothing to do with the change under test.
    bin=$(swift build --show-bin-path)
    prof="$bin/codecov/default.profdata"
    if [ -f "$prof" ]; then
        xcrun llvm-cov report "$bin"/*PackageTests.xctest/Contents/MacOS/*PackageTests \
            -instr-profile "$prof" -ignore-filename-regex='(Tests|\.build)/' 2>/dev/null \
            | tail -1
    else
        echo "no profile written at $prof"
    fi
else
    swift test --parallel || fail=1
fi

echo
[ $fail -eq 0 ] && echo "test-macos: PASS" || echo "test-macos: FAIL"
exit $fail
