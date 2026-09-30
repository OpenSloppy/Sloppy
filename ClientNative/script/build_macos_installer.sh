#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.1.0}"
OUTPUT_DIR="${2:-$PROJECT_DIR/dist}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build/installer-derived-data}"
PROJECT_FILE="$PROJECT_DIR/SloppyClient.xcodeproj"

case "$VERSION" in
    v*) VERSION="${VERSION#v}" ;;
esac

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required (brew install xcodegen)" >&2
    exit 1
fi

if ! command -v pkgbuild >/dev/null 2>&1; then
    echo "error: pkgbuild is required and is only available on macOS" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

(
    cd "$PROJECT_DIR"
    xcodegen generate
)

xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "SloppyClient-macOS" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    INFOPLIST_KEY_CFBundleShortVersionString="$VERSION" \
    INFOPLIST_KEY_CFBundleVersion="$BUILD_NUMBER" \
    build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Sloppy.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built application was not found at $APP_PATH" >&2
    exit 1
fi

OUTPUT_PATH="$OUTPUT_DIR/SloppyClient-macos-universal-${VERSION}.pkg"
PACKAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
ditto --norsrc --noextattr "$APP_PATH" "$PACKAGE_ROOT/Sloppy.app"
rm -f "$OUTPUT_PATH"

pkgbuild \
    --component "$PACKAGE_ROOT/Sloppy.app" \
    --install-location /Applications \
    --identifier team.sloppy.client.installer \
    --version "$VERSION" \
    "$OUTPUT_PATH"

echo "$OUTPUT_PATH"
