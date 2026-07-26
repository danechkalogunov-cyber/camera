#!/usr/bin/env bash
#
# Scripts/run.sh — build Vigil.app, launch it, and stream its log to this terminal.
#
# The point of this script is that a connection failure should be readable here, in the window you
# started the app from, without opening Console.app and hunting for a process. Vigil logs through
# OSLog on subsystem com.vigil.app with the fixed categories in docs/ARCHITECTURE.md §8.1, so a
# single predicate captures everything the app has to say.
#
#   Scripts/run.sh                          build, launch, tail everything
#   Scripts/run.sh --category rtsp          only the RTSP category
#   Scripts/run.sh --category rtsp,rtp      several categories
#   Scripts/run.sh --level info             quieter (default: debug)
#   Scripts/run.sh --no-build               launch what is already in dist/
#   Scripts/run.sh --logs-only              do not launch; attach to a running instance
#   Scripts/run.sh -- --sandbox off         everything after -- goes to Scripts/build-app.sh
#
# Ctrl-C stops the log stream. It does not quit the app; quit it normally with Cmd-Q.
#
# THIS SCRIPT HAS NEVER BEEN EXECUTED — it was written on Linux, which has no `log`, no `open` and
# no Vigil.app. Only `bash -n` has been run against it.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
cd "$REPO_ROOT"

if [ -t 1 ]; then
    B=$(printf '\033[1m'); R=$(printf '\033[0m'); DIM=$(printf '\033[2m')
else
    B=""; R=""; DIM=""
fi
step() { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
die()  { printf '\n[error] %s\n' "$1" >&2; shift; while [ $# -gt 0 ]; do printf '        %s\n' "$1" >&2; shift; done; exit 1; }

# MARK: - Arguments

SUBSYSTEM="com.vigil.app"
CATEGORIES=""
LEVEL="debug"
DO_BUILD="yes"
DO_LAUNCH="yes"
OUTPUT="dist"
BUILD_ARGS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --category)  CATEGORIES="${2:-}"; shift 2 ;;
        --level)     LEVEL="${2:-}";      shift 2 ;;
        --output)    OUTPUT="${2:-}";     shift 2 ;;
        --no-build)  DO_BUILD="no";       shift   ;;
        --logs-only) DO_BUILD="no"; DO_LAUNCH="no"; shift ;;
        --)          shift; BUILD_ARGS="$*"; break ;;
        -h|--help)   sed -n '3,20p' "$SCRIPT_DIR/run.sh" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *) die "Unknown option: $1" "Run $0 --help for the accepted flags." ;;
    esac
done

case "$LEVEL" in
    default|info|debug) ;;
    *) die "--level must be 'default', 'info' or 'debug', got '$LEVEL'." ;;
esac

[ "$(uname -s)" = "Darwin" ] || \
    die "Scripts/run.sh runs the macOS app and only works on macOS." \
        "On Linux, the portable half is exercised by: Scripts/check.sh"

command -v log >/dev/null 2>&1 || \
    die "/usr/bin/log is missing." "It is part of macOS; a missing 'log' means a damaged install."

# MARK: - Build

if [ "$DO_BUILD" = "yes" ]; then
    # Word splitting of $BUILD_ARGS is intended: it is the caller's own argument list.
    # shellcheck disable=SC2086
    "$SCRIPT_DIR/build-app.sh" --output "$OUTPUT" $BUILD_ARGS
fi

APP="$OUTPUT/Vigil.app"

if [ "$DO_LAUNCH" = "yes" ] && [ ! -d "$APP" ]; then
    die "$APP does not exist." \
        "Build it first:  Scripts/build-app.sh" \
        "Or attach to an already-running instance:  Scripts/run.sh --logs-only"
fi

# MARK: - Log predicate

# Categories are the fixed enum in docs/ARCHITECTURE.md §8.1: app discovery rtsp rtp bitstream
# isapi transport video render core storage ui perf.
PREDICATE="subsystem == \"$SUBSYSTEM\""
if [ -n "$CATEGORIES" ]; then
    clause=""
    # bash 3.2 has no readarray; split on commas with the field separator instead.
    saved_ifs=$IFS
    IFS=,
    for category in $CATEGORIES; do
        [ -n "$category" ] || continue
        if [ -z "$clause" ]; then
            clause="category == \"$category\""
        else
            clause="$clause OR category == \"$category\""
        fi
    done
    IFS=$saved_ifs
    [ -z "$clause" ] || PREDICATE="$PREDICATE AND ($clause)"
fi

# MARK: - Stream, then launch

# The stream starts first and the app is launched a moment later, so the launch and first-connect
# messages — the ones that explain a failure — are not lost in the startup race.
LOG_PID=""
cleanup() {
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

step "Streaming log: $PREDICATE (level $LEVEL)"
printf '%s    OSLog replaces %%@ arguments with <private> unless the format specifier says\n' "$DIM"
printf '    %%{public}@. If a field you need shows as <private>, that is the logging call site,\n'
printf '    not this script — see docs/ARCHITECTURE.md §8.6 for what is redacted on purpose.%s\n\n' "$R"

log stream --style compact --level "$LEVEL" --predicate "$PREDICATE" &
LOG_PID=$!

if [ "$DO_LAUNCH" = "yes" ]; then
    # A short pause so `log stream` is attached before the process starts. Without it the first
    # hundred milliseconds of launch logging is routinely missed.
    sleep 1
    step "Launching $APP"
    # `open` goes through LaunchServices, which registers the bundle's vigil:// URL scheme and its
    # exported UTIs. Running Contents/MacOS/Vigil directly skips that registration, so deep links
    # and drag-and-drop between apps would not work.
    open "$APP" || die "open refused to launch $APP." \
        "If macOS reports the app is damaged, it is Gatekeeper rejecting the ad-hoc signature." \
        "Clear the quarantine flag:  xattr -dr com.apple.quarantine \"$APP\""
    step "Running. Ctrl-C stops this log stream; the app keeps running (quit it with Cmd-Q)."
    echo
fi

# Block on the log stream. It only ends when the user interrupts, or when `log` itself exits.
wait "$LOG_PID"
