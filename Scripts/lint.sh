#!/usr/bin/env bash
#
# Scripts/lint.sh — the documented entry point for the static gate.
#
#   Scripts/lint.sh
#
# ⚠️ A shim, deliberately. docs/API_CONTRACT.md §5 names this file and describes the checks it
# performs; those checks live in `Scripts/lint.py`, which was written first and has grown rules
# that the manifest predates — the `@MainActor` conformance-isolation rule, the theme-isolation
# rule, the argument-order rule, and the cross-file `private` rule. Writing a second
# implementation in bash to match the manifest's file name would give this project two linters
# that disagree, and the one CI ran would quietly become the only one that mattered.
#
# So: one implementation, two names. `swift format lint --strict` is *not* run here — the project
# has no swift-format configuration and adding one is a separate decision, recorded in
# ЧТО-НЕ-СДЕЛАНО.md rather than faked with a passing exit code.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== static rules =="
python3 Scripts/lint.py || fail=1

echo
echo "== localisations =="
python3 Scripts/check-localizations.py || fail=1

echo
[ $fail -eq 0 ] && echo "lint.sh: PASS" || echo "lint.sh: FAIL"
exit $fail
