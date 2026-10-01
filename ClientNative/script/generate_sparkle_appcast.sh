#!/bin/bash

set -euo pipefail

ARCHIVE_PATH="${1:?usage: generate_sparkle_appcast.sh ARCHIVE_PATH VERSION OUTPUT_DIR}"
VERSION="${2:?usage: generate_sparkle_appcast.sh ARCHIVE_PATH VERSION OUTPUT_DIR}"
OUTPUT_DIR="${3:?usage: generate_sparkle_appcast.sh ARCHIVE_PATH VERSION OUTPUT_DIR}"
TOOLS_DIR="${SPARKLE_TOOLS_DIR:?SPARKLE_TOOLS_DIR must point to the Sparkle bin directory}"
GENERATOR="$TOOLS_DIR/generate_appcast"
APPCAST_FILENAME="${SPARKLE_APPCAST_FILENAME:-appcast.xml}"
case "$APPCAST_FILENAME" in
    appcast.xml|companion-appcast.xml) ;;
    *) echo "error: unsupported appcast filename $APPCAST_FILENAME" >&2; exit 1 ;;
esac

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "error: update archive was not found at $ARCHIVE_PATH" >&2
    exit 1
fi
if [[ ! -x "$GENERATOR" ]]; then
    echo "error: Sparkle generate_appcast was not found at $GENERATOR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$ARCHIVE_PATH" "$OUTPUT_DIR/$(basename "$ARCHIVE_PATH")"
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/TeamSloppy/Sloppy/releases/download/v${VERSION}/}"
SIGNING_ARGS=(--account "${SPARKLE_KEY_ACCOUNT:-TeamSloppy}")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    if [[ ! -r "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
        echo "error: SPARKLE_PRIVATE_KEY_FILE is not readable" >&2
        exit 1
    fi
    SIGNING_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi

"$GENERATOR" \
    "${SIGNING_ARGS[@]}" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-deltas 0 \
    --maximum-versions 10 \
    --embed-release-notes \
    -o "$OUTPUT_DIR/$APPCAST_FILENAME" \
    "$OUTPUT_DIR" >&2

if ! grep -q "sparkle:edSignature=" "$OUTPUT_DIR/$APPCAST_FILENAME"; then
    echo "error: generated appcast is missing an EdDSA signature" >&2
    exit 1
fi
printf '%s\n' "$OUTPUT_DIR/$APPCAST_FILENAME"
