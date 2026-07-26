#!/usr/bin/env bash
# The full local gate. Run before declaring a wave done.
#
#   Scripts/check.sh
#
# On Linux this proves the pure layer; the macOS-only targets are compiled as empty modules and
# must be checked on a Mac. See docs/BUILD-VERIFICATION.md.
set -uo pipefail
cd "$(dirname "$0")/.."
SWIFT=.vigil/swift
[ -x "$SWIFT" ] || SWIFT=swift
fail=0

echo "== lint =="
python3 Scripts/lint.py || fail=1

echo
# Localisations get their own pass because their failure mode is silence: a malformed .stringsdict
# does not break the build, it just stops resolving, and the app shows raw `%#@frames@` at runtime.
# This checks specifier arity and types across every key/value pair, that en and ru cover the same
# key set, and that every key still resolves to a real literal in the source.
echo "== localisations =="
python3 Scripts/check-localizations.py || fail=1

echo
echo "== purity gate: the pure targets must build without any platform framework =="
$SWIFT build --product VigilPure --scratch-path .build-check 2>&1 \
  | grep -vE "unhandled resource|Invalid Resource" | tail -2 || fail=1

echo
echo "== full package on Linux (macOS targets compile to empty modules) =="
$SWIFT build --scratch-path .build-check 2>&1 \
  | grep -vE "unhandled resource|Invalid Resource" | tail -2 || fail=1

echo
echo "== pure tests =="
$SWIFT test --scratch-path .build-check 2>&1 | grep -E "Test run with|✘|error:" | tail -8 || fail=1

echo
[ $fail -eq 0 ] && echo "check: PASS" || echo "check: FAIL"
exit $fail
