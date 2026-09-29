#!/usr/bin/env bash
set -euo pipefail

COMPANION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANION_VERSION="${1:-0.1.0}"
COMPANION_OUTPUT="${2:-$COMPANION_ROOT/dist}"
COMPANION_VERSION="${COMPANION_VERSION#v}"
COMPANION_DERIVED_DATA="${COMPANION_DERIVED_DATA:-$COMPANION_ROOT/.build/companion-release-derived-data}"
COMPANION_BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

command -v xcodegen >/dev/null
command -v xcodebuildmcp >/dev/null
mkdir -p "$COMPANION_OUTPUT"
(cd "$COMPANION_ROOT" && xcodegen generate >&2)
xcodebuildmcp macos build \
    --project-path "$COMPANION_ROOT/SloppyClient.xcodeproj" \
    --scheme SloppyDesktopCompanion --configuration Release \
    --derived-data-path "$COMPANION_DERIVED_DATA" \
    --extra-args CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
      "MARKETING_VERSION=$COMPANION_VERSION" "CURRENT_PROJECT_VERSION=$COMPANION_BUILD_NUMBER" >&2

COMPANION_APP="$COMPANION_DERIVED_DATA/Build/Products/Release/Sloppy Desktop Companion.app"
# Build tools may exit successfully even when xcodebuild reports failure. Verify the result itself.
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$COMPANION_APP/Contents/Info.plist" | \
    /usr/bin/grep -qx 'team.sloppy.desktop-companion'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$COMPANION_APP/Contents/Info.plist")" == "$COMPANION_VERSION" ]]
lipo "$COMPANION_APP/Contents/MacOS/Sloppy Desktop Companion" -verify_arch arm64 x86_64
[[ -d "$COMPANION_APP/Contents/Frameworks/Sparkle.framework" ]]
if [[ -n "${COMPANION_SIGNING_IDENTITY:-}" ]]; then
    "$COMPANION_ROOT/script/sign_macos_app.sh" "$COMPANION_APP" "$COMPANION_SIGNING_IDENTITY" >&2
fi
"$COMPANION_ROOT/script/package_sparkle_archive.sh" "$COMPANION_APP" "$COMPANION_VERSION" "$COMPANION_OUTPUT"
