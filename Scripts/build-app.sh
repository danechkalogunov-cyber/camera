#!/usr/bin/env bash
#
# Scripts/build-app.sh — turn `swift build` output into a runnable Vigil.app.
#
# Implements the build contract in docs/ARCHITECTURE.md §12.1, the entitlement rules in §13, and
# the multicast-fallback requirement in docs/spec-discovery.md §9.5.
#
#   Scripts/build-app.sh [--configuration debug|release] [--arch native|arm64|x86_64|universal]
#                        [--sign IDENTITY|-] [--entitlements PATH] [--sandbox on|off]
#                        [--version X.Y.Z] [--build N] [--output DIR] [--dmg] [--notarize]
#
# Defaults: --configuration release --arch native --sign "$CODESIGN_IDENTITY" (else ad-hoc "-")
#           --sandbox on --output dist
#
# `--arch native` is the default because it is the only value that works with just the Command Line
# Tools. `universal` needs the full Xcode — see the note at the ARCH assignment below.
#
# Signing degrades on purpose. With no identity the bundle is ad-hoc signed, which is enough to
# launch on the machine that built it; it will not pass Gatekeeper anywhere else. If codesign
# rejects the managed multicast entitlement, the script re-signs with the no-multicast fallback and
# says so loudly rather than failing the build.
#
# Exit codes (docs/ARCHITECTURE.md §12.1): 2 toolchain, 3 dependencies, 4 compile, 5 bundle layout,
# 6 Info.plist, 7 resources, 8 entitlements, 9 signing, 10 disk image, 11 notarisation.
#
# THIS SCRIPT HAS NEVER BEEN EXECUTED. It was written in a Linux container that has no codesign, no
# xcrun and no macOS SDK, so only `bash -n` has been run against it. Steps that cannot be checked
# here are flagged with an "UNVERIFIED:" comment.
#
# Portability: macOS ships bash 3.2 at /bin/bash, so no associative arrays, no `${var,,}`, no
# `mapfile`, no `**` globstar.

set -euo pipefail

# MARK: - Locations

# Resolve the repository root from the script's own path, so the script works from any directory.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
cd "$REPO_ROOT"

# MARK: - Output helpers

# Bold only when stdout is a terminal, so piping into a file or CI log stays clean.
if [ -t 1 ]; then
    B=$(printf '\033[1m'); R=$(printf '\033[0m')
    YEL=$(printf '\033[33m'); RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
else
    B=""; R=""; YEL=""; RED=""; GRN=""
fi

step()  { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
note()  { printf '    %s\n' "$*"; }
warn()  { printf '%s[warning]%s %s\n' "$YEL" "$R" "$*" >&2; }

# A warning nobody scrolls past. Used for the two situations that change what the app can do.
loud() {
    printf '\n%s%s\n' "$YEL" "########################################################################"
    while [ $# -gt 0 ]; do printf '# %s\n' "$1"; shift; done
    printf '%s%s\n\n' "########################################################################" "$R"
} >&2

# die CODE MESSAGE...
die() {
    code=$1; shift
    printf '\n%s[error]%s %s\n' "$RED" "$R" "$1" >&2
    shift
    while [ $# -gt 0 ]; do printf '        %s\n' "$1" >&2; shift; done
    exit "$code"
}

# version_ge A B — true when dotted-numeric version A is greater than or equal to B.
version_ge() {
    awk -v a="$1" -v b="$2" '
        BEGIN {
            na = split(a, x, "."); nb = split(b, y, ".");
            n = (na > nb) ? na : nb;
            for (i = 1; i <= n; i++) {
                ai = (i <= na) ? x[i] + 0 : 0;
                bi = (i <= nb) ? y[i] + 0 : 0;
                if (ai > bi) exit 0;
                if (ai < bi) exit 1;
            }
            exit 0;
        }'
}

# MARK: - Arguments

CONFIGURATION="release"
# `native`, not `universal`. A universal binary needs `--arch arm64 --arch x86_64`, which SwiftPM can
# only do through XCBuild — and XCBuild.framework ships inside Xcode.app, NOT in the Command Line
# Tools. So the old default made the very first build on a CLT-only Mac fail with
#   error: xcbuild executable at '/Library/Developer/SharedFrameworks/XCBuild.framework/...'
#          does not exist or is not executable
# before compiling a single file, while `ЗАПУСК.md` promises `xcode-select --install` is enough.
# Someone running the app on their own Mac needs one architecture; two are for distribution, which is
# what `--arch universal` is now for, and it checks for Xcode before trying.
ARCH="native"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS=""
SANDBOX="on"
VERSION=""
BUILD_NUMBER=""
OUTPUT="dist"
MAKE_DMG="no"
NOTARIZE="no"

usage() {
    cat <<'USAGE'
Scripts/build-app.sh — assemble a runnable Vigil.app from swift build output.

  --configuration debug|release   default: release
  --arch native|arm64|x86_64|universal
                                 default: native (this Mac). 'universal' needs the full Xcode.
  --sign IDENTITY|-               default: $CODESIGN_IDENTITY, else "-" (ad-hoc)
  --entitlements PATH             default: chosen from --sandbox
  --sandbox on|off                default: on
  --version X.Y.Z                 default: CFBundleShortVersionString in Resources/Info.plist
  --build N                       default: git rev-list --count HEAD
  --output DIR                    default: dist
  --dmg                           also produce dist/Vigil-<version>.dmg
  --notarize                      submit to Apple and staple (needs a Developer ID identity)

Environment:
  CODESIGN_IDENTITY       signing identity to use when --sign is not given
  PROVISIONING_PROFILE    path to a .provisionprofile to embed (needed for multicast)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
        --arch)          ARCH="${2:-}";          shift 2 ;;
        --sign)          SIGN_IDENTITY="${2:-}"; shift 2 ;;
        --entitlements)  ENTITLEMENTS="${2:-}";  shift 2 ;;
        --sandbox)       SANDBOX="${2:-}";       shift 2 ;;
        --version)       VERSION="${2:-}";       shift 2 ;;
        --build)         BUILD_NUMBER="${2:-}";  shift 2 ;;
        --output)        OUTPUT="${2:-}";        shift 2 ;;
        --dmg)           MAKE_DMG="yes";         shift   ;;
        --notarize)      NOTARIZE="yes";         shift   ;;
        -h|--help)       usage; exit 0 ;;
        *) die 2 "Unknown option: $1" "Run $0 --help for the accepted flags." ;;
    esac
done

case "$CONFIGURATION" in
    debug|release) ;;
    *) die 2 "--configuration must be 'debug' or 'release', got '$CONFIGURATION'." ;;
esac
case "$ARCH" in
    native|arm64|x86_64|universal) ;;
    *) die 2 "--arch must be 'native', 'arm64', 'x86_64' or 'universal', got '$ARCH'." ;;
esac
case "$SANDBOX" in
    on|off) ;;
    *) die 2 "--sandbox must be 'on' or 'off', got '$SANDBOX'." ;;
esac

# MARK: - Step 1 — toolchain

step "Checking prerequisites"

if [ "$(uname -s)" != "Darwin" ]; then
    die 2 "This script assembles a macOS .app bundle and only runs on macOS." \
          "You are on $(uname -s). On Linux the portable half of Vigil still builds:" \
          "    swift build --product VigilPure" \
          "See README.md, 'Building on Linux'."
fi

if ! xcode-select --print-path >/dev/null 2>&1; then
    die 2 "Xcode command line tools not found — run: xcode-select --install" \
          "If Xcode is already installed, point the tools at it with:" \
          "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
fi

for tool in swift xcrun codesign iconutil; do
    command -v "$tool" >/dev/null 2>&1 || \
        die 2 "Required tool '$tool' is not on PATH." \
              "It ships with the Xcode command line tools — run: xcode-select --install"
done

[ -x /usr/libexec/PlistBuddy ] || \
    die 2 "/usr/libexec/PlistBuddy is missing." \
          "It is part of macOS itself; a missing PlistBuddy means a damaged system install."

# `swift --version` prints e.g. "Apple Swift version 6.0.3 (swiftlang-6.0.3.1.10 ...)".
SWIFT_VERSION=$(swift --version 2>/dev/null | sed -n 's/.*[Ss]wift version \([0-9][0-9.]*\).*/\1/p' | head -1)
[ -n "$SWIFT_VERSION" ] || die 2 "Could not parse the output of 'swift --version'."
version_ge "$SWIFT_VERSION" "6.0" || \
    die 2 "Swift 6.0 or newer is required; found $SWIFT_VERSION." \
          "Vigil uses Swift 6 language mode and typed throws. Install Xcode 16 or newer."

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
[ -n "$SDK_VERSION" ] || \
    die 2 "No macOS SDK found (xcrun --sdk macosx --show-sdk-version failed)." \
          "Install Xcode, then: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
version_ge "$SDK_VERSION" "14.0" || \
    die 2 "macOS SDK 14.0 or newer is required; found $SDK_VERSION." \
          "Package.swift declares platforms: [.macOS(.v14)]."

note "swift $SWIFT_VERSION, macOS SDK $SDK_VERSION"

# MARK: - Step 2 — zero dependencies (constraint C1, docs/ARCHITECTURE.md §1.1)

# Package.resolved may legitimately be absent when the package has no dependencies at all. If it
# exists it must contain no pins; "identity" appears once per resolved dependency in both the v2
# and v3 file formats.
if [ -f Package.resolved ] && grep -q '"identity"' Package.resolved; then
    die 3 "Package.resolved lists dependencies, but Vigil is a zero-dependency package." \
          "See docs/ARCHITECTURE.md §1.1 constraint C1. Remove the dependency or amend the doc."
fi

# MARK: - Step 3 — compile

step "Building the Vigil executable ($CONFIGURATION, $ARCH)"

# `--arch`, repeated, is how SwiftPM produces a universal binary from a single invocation
# (docs/ARCHITECTURE.md §12.1 step 3). Note that Swift 6.1.2 hides `--arch` from `swift build
# --help` although it still accepts it; if a future toolchain removes it, the replacement is one
# `--triple arm64-apple-macosx14.0` build per slice followed by `lipo -create`.
SWIFT_ARGS="build -c $CONFIGURATION --product Vigil"
case "$ARCH" in
    native)
        # No `--arch` at all: SwiftPM builds for the host and uses its own native build system, so a
        # Mac with only the Command Line Tools can build. This is the default and the tested path.
        ;;
    universal)
        # Two architectures in one invocation is an XCBuild-only feature, and XCBuild.framework is
        # part of Xcode.app. Check for it and say so, rather than letting SwiftPM fail with a path
        # nobody can act on.
        if ! xcodebuild -version >/dev/null 2>&1; then
            die 4 "A universal binary needs the full Xcode, and only the Command Line Tools are installed." \
                  "SwiftPM builds two architectures in one pass through XCBuild, which ships inside" \
                  "Xcode.app rather than with the Command Line Tools." \
                  "" \
                  "Either drop the flag — 'Scripts/build-app.sh' alone builds for this Mac and is all" \
                  "you need to run Vigil here — or install Xcode from the App Store and retry."
        fi
        SWIFT_ARGS="$SWIFT_ARGS --arch arm64 --arch x86_64"
        ;;
    *)
        SWIFT_ARGS="$SWIFT_ARGS --arch $ARCH"
        ;;
esac

# Word splitting of $SWIFT_ARGS is intended here: the values are ours, fixed, and space-free.
# shellcheck disable=SC2086
swift $SWIFT_ARGS || \
    die 4 "swift build failed." \
          "If the errors above name missing methods or types in VigilTransport, VigilVideo," \
          "VigilRender, VigilCore or VigilUI, that is expected and useful: those targets are never" \
          "compiled in the Linux development container, so this is the first compiler they meet." \
          "Send the whole output. See docs/BUILD-VERIFICATION.md." \
          "" \
          "If instead the error names a missing tool or SDK, the code is not the problem — the" \
          "toolchain is. Check 'swift --version' and 'xcode-select -p'."

# --show-bin-path must be given the same configuration and architecture flags, or it reports a
# different products directory than the one just built into. UNVERIFIED: that a multi-`--arch`
# invocation reports the merged .build/apple/Products directory could not be checked on Linux, so
# there is an explicit fallback below rather than a silent wrong answer.
# shellcheck disable=SC2086
BIN_DIR=$(swift $SWIFT_ARGS --show-bin-path 2>/dev/null || true)

if [ -z "$BIN_DIR" ] || [ ! -f "$BIN_DIR/Vigil" ]; then
    # SwiftPM writes universal products to .build/apple/Products/<Configuration>.
    CONFIG_DIR=$(echo "$CONFIGURATION" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$CONFIGURATION" | cut -c2-)
    for candidate in ".build/apple/Products/$CONFIG_DIR" ".build/$CONFIGURATION"; do
        if [ -f "$candidate/Vigil" ]; then BIN_DIR="$candidate"; break; fi
    done
fi

[ -n "$BIN_DIR" ] && [ -d "$BIN_DIR" ] || \
    die 4 "Could not locate the SwiftPM products directory." \
          "swift build --show-bin-path returned '$BIN_DIR'."
[ -f "$BIN_DIR/Vigil" ] || \
    die 4 "swift build reported success but produced no executable at $BIN_DIR/Vigil."

note "products: $BIN_DIR"

# MARK: - Version and build number

if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
fi
if [ -z "$BUILD_NUMBER" ]; then
    # A monotonic build number that needs no state file. Falls back to 1 outside a git checkout.
    BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
fi
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# MARK: - Steps 4-5 — bundle skeleton and executable

APP="$OUTPUT/Vigil.app"
step "Assembling $APP"

mkdir -p "$OUTPUT" || die 5 "Cannot create output directory '$OUTPUT'."
# Remove any previous bundle so a stale nested file cannot survive into the new signature.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" \
    || die 5 "Cannot create the bundle directory layout under '$APP'."

cp "$BIN_DIR/Vigil" "$APP/Contents/MacOS/Vigil" || die 5 "Cannot copy the executable into the bundle."
chmod 755 "$APP/Contents/MacOS/Vigil" || die 5 "Cannot set the executable bit on Contents/MacOS/Vigil."

# MARK: - Step 6 — Info.plist

APP_PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$APP_PLIST" || die 6 "Cannot copy Resources/Info.plist into the bundle."

# plist_put ENTRY TYPE VALUE — set an existing key, or add it when it is not there yet.
plist_put() {
    if /usr/libexec/PlistBuddy -c "Set $1 $3" "$APP_PLIST" >/dev/null 2>&1; then
        return 0
    fi
    /usr/libexec/PlistBuddy -c "Add $1 $2 $3" "$APP_PLIST" >/dev/null 2>&1 \
        || die 6 "PlistBuddy could not write $1 into $APP_PLIST."
}

plist_put ":CFBundleShortVersionString" string "$VERSION"
plist_put ":CFBundleVersion" string "$BUILD_NUMBER"

# Sanity-check the two keys that make discovery work, because a plist edit that drops them produces
# an app that runs perfectly and finds no cameras at all.
for required in ":NSLocalNetworkUsageDescription" ":NSBonjourServices"; do
    /usr/libexec/PlistBuddy -c "Print $required" "$APP_PLIST" >/dev/null 2>&1 \
        || die 6 "$required is missing from Resources/Info.plist." \
                 "Without it macOS returns no discovery results and shows no error."
done

# Step 7 — the classic four bytes. No trailing newline: the file is exactly eight characters.
printf 'APPL????' > "$APP/Contents/PkgInfo" || die 6 "Cannot write Contents/PkgInfo."

# MARK: - Step 8 — SwiftPM resource bundles

# These carry Assets.car, the .lproj folders and the .metal shader sources. Forgetting them yields
# an app with no icons, no localised strings and no shader source to compile at runtime — which
# looks like a rendering bug, not a packaging bug. Per docs/API_CONTRACT.md §2 R-38 there is no
# default.metallib: SwiftPM never invokes the Metal compiler, and VigilRender compiles the shader
# text at first use instead.
step "Copying SwiftPM resource bundles"

BUNDLE_COUNT=0
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/" || die 7 "Cannot copy $bundle into the bundle."
    note "$(basename "$bundle")"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done

if [ "$BUNDLE_COUNT" -eq 0 ]; then
    warn "no *.bundle found in $BIN_DIR."
    warn "Expected Vigil_VigilUI.bundle and Vigil_VigilRender.bundle. The app will launch but has"
    warn "no asset catalog, no localisations and no shader sources."
fi

# MARK: - Step 9 — app icon

# SwiftPM already compiled Assets.xcassets into the resource bundle above, so actool is never
# invoked here. A standalone .icns is still needed because CFBundleIconFile is what the Dock reads
# on the very first launch, before the catalog is registered.
ICONSET="Sources/VigilUI/Resources/AppIcon.iconset"
if [ -d "$ICONSET" ]; then
    iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET" \
        || die 7 "iconutil failed on $ICONSET."
    note "AppIcon.icns"
else
    warn "$ICONSET does not exist yet — the Dock will show the generic application icon."
fi

# MARK: - Step 10 — choose entitlements

if [ -n "$ENTITLEMENTS" ]; then
    :
elif [ "$SANDBOX" = "on" ]; then
    ENTITLEMENTS="Resources/Vigil.entitlements"
else
    ENTITLEMENTS="Resources/Vigil-Dev.entitlements"
    loud "UNSANDBOXED DEVELOPMENT BUILD" \
         "" \
         "This bundle is signed with Resources/Vigil-Dev.entitlements: no app sandbox, and" \
         "get-task-allow set so a debugger can attach. It must never be distributed." \
         "VigilDevBuild=true is stamped into Info.plist so the About window can show it."
    plist_put ":VigilDevBuild" bool true
fi

[ -f "$ENTITLEMENTS" ] || \
    die 8 "Entitlements file '$ENTITLEMENTS' does not exist." \
          "The repository ships Resources/Vigil.entitlements (sandboxed shipping)," \
          "Resources/Vigil-nomulticast.entitlements (fallback) and Resources/Vigil-Dev.entitlements."

# An embedded provisioning profile is what makes the managed multicast entitlement real. Supply one
# with PROVISIONING_PROFILE=/path/to/Vigil.provisionprofile.
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
    [ -f "$PROVISIONING_PROFILE" ] || \
        die 8 "PROVISIONING_PROFILE is set to '$PROVISIONING_PROFILE', which does not exist."
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile" \
        || die 8 "Cannot embed the provisioning profile."
    note "embedded.provisionprofile"
fi

# MARK: - Steps 11-12 — sign, with graceful degradation

step "Signing"

if [ "$SIGN_IDENTITY" = "-" ]; then
    note "ad-hoc signature (no CODESIGN_IDENTITY set)"
    note "the app will launch on this Mac; Gatekeeper will refuse it anywhere else"
    # An ad-hoc signature cannot carry a trusted timestamp, and passing --timestamp would both fail
    # and require network access, which the contract forbids for a plain build.
    TIMESTAMP_FLAG="--timestamp=none"
else
    note "identity: $SIGN_IDENTITY"
    TIMESTAMP_FLAG="--timestamp"
fi

# sign_with ENTITLEMENTS_FILE — sign nested bundles inside-out, then the app itself.
# Prints codesign's own output on failure; returns codesign's status.
sign_with() {
    ent="$1"

    # Nested bundles first: a signature over the app covers its contents, so anything inside must
    # already be sealed.
    #
    # But only bundles that actually CONTAIN CODE get their own signature. A resource bundle holding
    # no Mach-O is sealed as ordinary data by the app's own signature, through the
    # Contents/_CodeSignature/CodeResources manifest — signing it separately is unnecessary, and when
    # the bundle is malformed it is impossible:
    #   Vigil_VigilRender.bundle: bundle format unrecognized, invalid, or unsuitable
    # which is what stopped the first Mac build, twice, including the entitlement fallback path. The
    # earlier comment here asserted that `--deep --strict` "still expects them to be signed"; that was
    # a guess written without a Mac and it was wrong in the direction that costs a build.
    #
    # shellcheck disable=SC2086  # TIMESTAMP_FLAG is one deliberate, space-free word.
    for nested in "$APP/Contents/Resources"/*.bundle; do
        [ -d "$nested" ] || continue
        if find "$nested" -type f -print0 2>/dev/null \
             | xargs -0 file 2>/dev/null | grep -q 'Mach-O'; then
            codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP_FLAG "$nested" || return $?
            note "signed $(basename "$nested") (contains code)"
        else
            note "$(basename "$nested"): no Mach-O inside — sealed by the app signature, not signed separately"
        fi
    done

    # --options runtime      hardened runtime, no exceptions (docs/ARCHITECTURE.md §13.5)
    # --generate-entitlement-der   DER entitlement blob, required from macOS 12 onwards
    # shellcheck disable=SC2086
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        $TIMESTAMP_FLAG \
        --entitlements "$ent" \
        --generate-entitlement-der \
        "$APP"
}

MULTICAST_FALLBACK="no"
SIGN_LOG="$OUTPUT/.codesign.log"

# UNVERIFIED: the exact codesign failure text for a missing multicast provisioning profile could
# not be reproduced here. The fallback therefore triggers on *any* signing failure while the chosen
# entitlements request multicast, and prints the original error so the real cause stays visible.
if ! sign_with "$ENTITLEMENTS" >"$SIGN_LOG" 2>&1; then
    cat "$SIGN_LOG" >&2

    FALLBACK_ENT="Resources/Vigil-nomulticast.entitlements"
    # Match the key element, not any mention of the string: the fallback file names the entitlement
    # in a comment, and matching that would make it "retry" with the file it is already using.
    if grep -q "<key>com.apple.developer.networking.multicast</key>" "$ENTITLEMENTS" 2>/dev/null \
        && [ -f "$FALLBACK_ENT" ]; then

        loud "CODE SIGNING FAILED WITH THE MULTICAST ENTITLEMENT — RETRYING WITHOUT IT" \
             "" \
             "com.apple.developer.networking.multicast is a managed entitlement. Apple grants it" \
             "per team on request, and it needs a matching provisioning profile embedded in the" \
             "app. Re-signing with $FALLBACK_ENT." \
             "" \
             "The app still builds and runs. Discovery degrades to a unicast sweep:" \
             "  * SADP and WS-Discovery multicast probes are skipped" \
             "  * the subnet sweep starts immediately and runs wider instead" \
             "  * cameras on a DIFFERENT SUBNET become invisible — including a factory-fresh" \
             "    camera still on 192.168.1.64 while this Mac is on another network" \
             "  * discovery takes roughly 4-6 s on a /24 instead of about 1.5 s" \
             "" \
             "See docs/spec-discovery.md §9.5. To get multicast: request the entitlement from" \
             "Apple, then rebuild with PROVISIONING_PROFILE=/path/to/Vigil.provisionprofile."

        if ! sign_with "$FALLBACK_ENT" >"$SIGN_LOG" 2>&1; then
            cat "$SIGN_LOG" >&2
            die 9 "Signing failed with the fallback entitlements too." \
                  "Check that the identity '$SIGN_IDENTITY' exists: security find-identity -v -p codesigning"
        fi
        ENTITLEMENTS="$FALLBACK_ENT"
        MULTICAST_FALLBACK="yes"
    else
        die 9 "codesign failed (output above)." \
              "With a real identity, confirm it exists:  security find-identity -v -p codesigning" \
              "With the ad-hoc default, re-run without CODESIGN_IDENTITY set."
    fi
fi
rm -f "$SIGN_LOG"

note "signed with $ENTITLEMENTS"

# Verification. --deep --strict must pass even for an ad-hoc signature.
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' \
    || die 9 "codesign --verify rejected the bundle it just produced." \
             "That normally means something was written into $APP after signing."

# Gatekeeper assessment is expected to fail for an ad-hoc signature; that is not a build failure.
if ! spctl --assess --type execute "$APP" >/dev/null 2>&1; then
    if [ "$SIGN_IDENTITY" = "-" ]; then
        note "spctl: rejected, as expected for an ad-hoc signature (fine for local use)"
    else
        warn "spctl rejected the bundle. Distribution requires notarisation (--notarize)."
    fi
fi

# MARK: - Step 13 — disk image

if [ "$MAKE_DMG" = "yes" ]; then
    step "Creating disk image"
    DMG="$OUTPUT/Vigil-$VERSION.dmg"
    hdiutil create -volname Vigil -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null \
        || die 10 "hdiutil failed to create $DMG."
    note "$DMG"
fi

# MARK: - Step 14 — notarisation

if [ "$NOTARIZE" = "yes" ]; then
    step "Notarising"
    [ "$SIGN_IDENTITY" != "-" ] || \
        die 11 "Notarisation needs a real Developer ID identity; an ad-hoc signature cannot be notarised." \
               "Set CODESIGN_IDENTITY, or pass --sign 'Developer ID Application: ...'."
    # Requires a stored keychain profile:
    #   xcrun notarytool store-credentials VigilNotary --apple-id ... --team-id ... --password ...
    NOTARY_ZIP="$OUTPUT/Vigil-$VERSION-notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP" || die 11 "ditto failed to archive the app."
    xcrun notarytool submit --wait --keychain-profile VigilNotary "$NOTARY_ZIP" \
        || die 11 "notarytool rejected the submission." \
                  "Run: xcrun notarytool log <submission-id> --keychain-profile VigilNotary"
    xcrun stapler staple "$APP" || die 11 "stapler could not attach the notarisation ticket."
    rm -f "$NOTARY_ZIP"
    note "notarised and stapled"
fi

# MARK: - Step 15 — manifest and summary

APP_ABS="$REPO_ROOT/$APP"
[ "${APP#/}" = "$APP" ] || APP_ABS="$APP"   # honour an absolute --output

ARCH_LIST=$(lipo -info "$APP/Contents/MacOS/Vigil" 2>/dev/null | sed 's/.*: //' || echo "$ARCH")
APP_SIZE=$(du -sh "$APP" 2>/dev/null | cut -f1 || echo "?")

cat > "$OUTPUT/build-manifest.json" <<EOF
{
  "product": "Vigil",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "commit": "$COMMIT",
  "configuration": "$CONFIGURATION",
  "architectures": "$ARCH_LIST",
  "entitlements": "$ENTITLEMENTS",
  "multicastFallbackUsed": $( [ "$MULTICAST_FALLBACK" = "yes" ] && echo true || echo false ),
  "sandbox": "$SANDBOX",
  "signingIdentity": "$SIGN_IDENTITY",
  "swift": "$SWIFT_VERSION",
  "macosSDK": "$SDK_VERSION",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

step "Summary"
note "version      $VERSION ($BUILD_NUMBER), commit $COMMIT"
note "architecture $ARCH_LIST"
note "entitlements $ENTITLEMENTS"
note "identity     $SIGN_IDENTITY"
note "size         $APP_SIZE"
echo
echo "Entitlements actually embedded:"
codesign -d --entitlements - "$APP" 2>/dev/null | sed 's/^/    /' || true
echo

if [ "$MULTICAST_FALLBACK" = "yes" ]; then
    warn "built WITHOUT multicast — discovery will use a unicast sweep (see the warning above)"
fi

printf '%s%sBuilt: %s%s\n' "$GRN" "$B" "$APP_ABS" "$R"
printf '       open it with:  open "%s"\n' "$APP_ABS"
