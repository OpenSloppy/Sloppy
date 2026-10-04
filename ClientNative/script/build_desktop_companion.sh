#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$PROJECT_DIR/SloppyClient.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build/install-derived-data}"
ARCHITECTURE="$(uname -m)"

usage() {
    cat <<'EOF'
Build Sloppy Desktop Companion for this Mac.

Usage: script/build_desktop_companion.sh [options]

Options:
  --debug              Build the Debug configuration instead of Release.
  --release            Build the Release configuration (default).
  -h, --help           Show this help.

Environment:
  DERIVED_DATA         Override the Xcode DerivedData directory.

On success, the script prints the built .app path without installing or launching it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            CONFIGURATION="Debug"
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script can only build the macOS application" >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required; install Xcode first" >&2
    exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
    echo "==> Generating the Xcode project"
    (
        cd "$PROJECT_DIR"
        xcodegen generate
    )
elif [[ ! -d "$PROJECT_FILE" ]]; then
    echo "error: xcodegen is required to generate $PROJECT_FILE" >&2
    echo "Install it with: brew install xcodegen" >&2
    exit 1
else
    echo "==> xcodegen is unavailable; using the existing Xcode project"
fi

echo "==> Building SloppyDesktopCompanion ($CONFIGURATION)"
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme SloppyDesktopCompanion \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$ARCHITECTURE" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/Sloppy Desktop Companion.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: built application was not found at $APP_BUNDLE" >&2
    exit 1
fi

BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "team.sloppy.desktop-companion" ]]; then
    echo "error: unexpected companion application ($BUNDLE_ID)" >&2
    exit 1
fi

"$SCRIPT_DIR/sign_macos_app.sh" "$APP_BUNDLE" "${COMPANION_SIGNING_IDENTITY:-${MACOS_SIGNING_IDENTITY:-auto}}" \
    "$PROJECT_DIR/SupportingFiles/DesktopCompanion/SloppyDesktopCompanion.entitlements"

echo "Built: $APP_BUNDLE"
