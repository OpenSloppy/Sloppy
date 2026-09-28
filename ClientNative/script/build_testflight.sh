#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:?usage: build_testflight.sh VERSION BUILD_NUMBER OUTPUT_DIR [--upload]}"
BUILD_NUMBER="${2:?BUILD_NUMBER is required}"
OUTPUT_DIR="${3:?OUTPUT_DIR is required}"
MODE="${4:-}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build/testflight-derived-data}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: use a numeric VERSION and positive BUILD_NUMBER" >&2
    exit 1
fi
if [[ -n "$MODE" && "$MODE" != "--upload" ]]; then
    echo "error: the only supported option is --upload" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE_PATH="$OUTPUT_DIR/SloppyClient-${VERSION}-${BUILD_NUMBER}.xcarchive"
EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"

(cd "$PROJECT_DIR" && xcodegen generate)
xcodebuild \
    -project "$PROJECT_DIR/SloppyClient.xcodeproj" \
    -scheme SloppyClient-TestFlight \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/SloppyClient-TestFlight.app"
codesign --verify --deep --strict "$APP_PATH"
if [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "error: TestFlight archive must not contain Sparkle" >&2
    exit 1
fi

DESTINATION=export
if [[ "$MODE" == "--upload" ]]; then
    DESTINATION=upload
fi
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DESTINATION</string>
    <key>teamID</key><string>8PYCRS3EA3</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict></plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR/export" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates
