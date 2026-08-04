#!/usr/bin/env bash
set -euo pipefail

# The repository predates swift-format. Keep legacy files buildable while making every Swift line
# changed by a PR obey the formatter; once the baseline is migrated this can become --recursive.
base=${1:-}
if [[ -z "$base" ]]; then
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
        base="origin/${GITHUB_BASE_REF}"
    elif git rev-parse HEAD^ >/dev/null 2>&1; then
        base=HEAD^
    else
        base=HEAD
    fi
fi

mapfile -t files < <(git diff --diff-filter=ACMR --name-only "$base"...HEAD -- '*.swift')
if ((${#files[@]} == 0)); then
    echo "swift-format: no changed Swift files"
    exit 0
fi

swift format lint --strict --configuration .swift-format "${files[@]}"
