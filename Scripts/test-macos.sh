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

# Both of the things this script needs beyond a compiler — the `#Preview` macro plugin and the
# `Testing` module — ship inside Xcode.app, not with the Command Line Tools. Without them the build
# emits the same two errors once per preview and once per test file, which is thousands of lines
# that all mean "wrong toolchain". Say it once, here, instead.
#
# `Scripts/build-app.sh` does not hit either: it builds `-c release`, where every `#if DEBUG` block —
# and so every `#Preview` — is compiled out. That is why `Scripts/run.sh` can succeed on a Mac where
# this script cannot, and why debug-only code reaches a compiler for the first time right here.
DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
case "$DEVELOPER_DIR" in
    *CommandLineTools*|"")
        echo "test-macos.sh: this needs the full Xcode, not just the Command Line Tools." >&2
        echo >&2
        echo "  xcode-select -p  ->  ${DEVELOPER_DIR:-(nothing)}" >&2
        echo >&2
        echo "  The #Preview macro plugin (PreviewsMacros) and the swift-testing 'Testing' module" >&2
        echo "  both live in Xcode.app. Without it every #Preview fails to expand and every test" >&2
        echo "  file fails to import, neither of which says anything about this code." >&2
        echo >&2
        echo "  Install Xcode from the App Store, then point the toolchain at it:" >&2
        echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        echo >&2
        echo "  To build and run the app without Xcode, use Scripts/run.sh — a release build" >&2
        echo "  compiles no previews and needs no macro plugin." >&2
        exit 2
        ;;
esac

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
