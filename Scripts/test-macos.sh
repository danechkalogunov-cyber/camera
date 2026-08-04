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
# question. Two `swiftc -typecheck` runs on two-line files cost a second.
#
# ⛔ NEITHER PROBE STOPS THE RUN, and the `Testing` one used to. A bare `swiftc` searches the
# toolchain's default paths; SwiftPM passes its own, so `import Testing` can fail here and succeed
# under `swift test`. Turning that into an exit meant declining to run 688 tests on the strength of
# a proxy — the probe is evidence, the run is the answer. A missing preview plugin turns into
# `-DVIGIL_NO_PREVIEWS`, which compiles the previews out and runs everything else; a genuinely
# missing `Testing` is recognised in the log afterwards. See README §"Building on a Mac without
# Xcode".
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

say_where_the_plugins_live() {
    echo "  These ship inside Xcode.app rather than with the Command Line Tools." >&2
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
}

# Word-split deliberately, and safe to: the value is either empty or two space-free tokens. An
# array would be tidier but `${arr[@]}` under `set -u` is an error on the bash 3.2 macOS ships.
preview_flags=""

# ⚠️ ADVISORY, NOT FATAL — and it used to be fatal, which was a bug in this script.
#
# `swiftc -typecheck` on a bare file searches the toolchain's default paths. SwiftPM does not: it
# passes its own search paths for the testing library, so `swift test` can resolve `import Testing`
# on a toolchain where this probe cannot. Refusing to run on the strength of the probe means
# refusing to run the 688 tests because of a *proxy* for whether they can run — exactly the kind of
# claim this project does not make without executing it. So the probe informs and `swift test`
# decides; the guidance below is printed only if the real thing actually fails on the import.
if [ "$has_testing" = no ]; then
    echo "test-macos.sh: 'import Testing' does not resolve for a bare swiftc." >&2
    echo >&2
    echo "  swift --version  ->  $(swift --version 2>&1 | head -1)" >&2
    echo "  xcode-select -p  ->  $(xcode-select -p 2>/dev/null || echo '(nothing)')" >&2
    echo >&2
    echo "  That may be a false alarm: SwiftPM adds search paths this probe does not have, so" >&2
    echo "  swift test can still find the module. Running it to find out." >&2
    echo >&2
fi

# ⚠️ A missing preview plugin is survivable and a missing test framework is not, which is why they
# stopped being one branch. Every `#Preview` in VigilUI sits inside `#if DEBUG && !VIGIL_NO_PREVIEWS`
# precisely so this script can compile the debug configuration — fixtures, `#if DEBUG` helpers and
# all 688 tests — on a Mac that has only the Command Line Tools. What is skipped is the previews
# themselves, and previews are checked by eye in Xcode's canvas, which such a Mac does not have
# either.
if [ "$has_previews" = no ]; then
    preview_flags="-Xswiftc -DVIGIL_NO_PREVIEWS"
    echo "test-macos.sh: the PreviewsMacros plugin is not installed, so #Preview cannot expand." >&2
    echo "  Building with -DVIGIL_NO_PREVIEWS: everything compiles and every test runs, but the" >&2
    echo "  #Preview blocks are compiled out and nothing here checks them." >&2
    echo >&2
    say_where_the_plugins_live
    echo >&2
fi

fail=0
echo "== build =="
# shellcheck disable=SC2086
swift build $preview_flags || fail=1

echo
echo "== test =="
# Tee'd, so the run is visible live *and* can be examined afterwards for the one failure mode that
# has a fix outside this repository. `set -o pipefail` at the top is what keeps the exit status the
# compiler's rather than `tee`'s.
log="$probe_dir/test.log"
if [ "$coverage" -eq 1 ]; then
    # shellcheck disable=SC2086
    swift test --parallel --enable-code-coverage $preview_flags 2>&1 | tee "$log" || fail=1
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
    # shellcheck disable=SC2086
    swift test --parallel $preview_flags 2>&1 | tee "$log" || fail=1
fi

# The one failure this script can explain rather than just report. Everything else in the log is
# about this code and belongs to whoever changed it.
if [ $fail -ne 0 ] && grep -q "no such module 'Testing'" "$log"; then
    echo >&2
    echo "test-macos.sh: swift-testing really is missing — SwiftPM could not find it either." >&2
    echo >&2
    say_where_the_plugins_live
    echo >&2
    echo "  There is no flag for this one: without swift-testing there is no test suite to run." >&2
    echo "  Scripts/run.sh still builds and launches the app — a release build imports no test" >&2
    echo "  module — but it runs none of the 688 tests, which is the point of this script." >&2
fi

echo
[ $fail -eq 0 ] && echo "test-macos: PASS" || echo "test-macos: FAIL"
exit $fail
