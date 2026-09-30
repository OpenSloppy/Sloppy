#!/bin/bash

set -euo pipefail

APP_PATH="${1:?usage: package_sparkle_archive.sh APP_PATH VERSION OUTPUT_DIR}"
VERSION="${2:?usage: package_sparkle_archive.sh APP_PATH VERSION OUTPUT_DIR}"
OUTPUT_DIR="${3:?usage: package_sparkle_archive.sh APP_PATH VERSION OUTPUT_DIR}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: application bundle was not found at $APP_PATH" >&2
    exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
case "$BUNDLE_IDENTIFIER" in
    team.sloppy.client) STAGED_APP_NAME="Sloppy.app"; ARCHIVE_PREFIX="SloppyClient-macos" ;;
    team.sloppy.desktop-companion) STAGED_APP_NAME="Sloppy Desktop Companion.app"; ARCHIVE_PREFIX="SloppyDesktopCompanion-macos" ;;
    *) echo "error: unsupported update bundle $BUNDLE_IDENTIFIER" >&2; exit 1 ;;
esac
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "error: app version $BUNDLE_VERSION does not match release version $VERSION" >&2
    exit 1
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "error: application bundle does not contain SUPublicEDKey" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP_PATH" "$STAGE/$STAGED_APP_NAME"

OUTPUT_PATH="$OUTPUT_DIR/${ARCHIVE_PREFIX}-${VERSION}.zip"
rm -f "$OUTPUT_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$STAGED_APP_NAME" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
