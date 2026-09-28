#!/bin/bash

set -euo pipefail

APP_PATH="${1:?usage: sign_macos_app.sh APP_PATH SIGNING_IDENTITY}"
IDENTITY="${2:?a Developer ID Application identity is required}"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
VERSION="$FRAMEWORK/Versions/Current"

# Sign Sparkle helpers before their containing framework and application.
for PATH_TO_SIGN in \
    "$VERSION/XPCServices/Downloader.xpc" \
    "$VERSION/XPCServices/Installer.xpc" \
    "$VERSION/Autoupdate" \
    "$VERSION/Updater.app" \
    "$FRAMEWORK" \
    "$APP_PATH"; do
    if [[ ! -e "$PATH_TO_SIGN" ]]; then
        echo "error: signing input was not found at $PATH_TO_SIGN" >&2
        exit 1
    fi
    codesign --force --timestamp --options runtime \
        --preserve-metadata=identifier,entitlements \
        --sign "$IDENTITY" "$PATH_TO_SIGN"
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
