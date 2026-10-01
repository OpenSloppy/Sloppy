#!/bin/bash
set -euo pipefail

PACKAGING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$PACKAGING_TEST_ROOT"' EXIT
PACKAGING_TEST_APP="$PACKAGING_TEST_ROOT/Fixture.app"
mkdir -p "$PACKAGING_TEST_APP/Contents/MacOS" "$PACKAGING_TEST_APP/Contents/Resources"
cat > "$PACKAGING_TEST_ROOT/main.c" <<'C'
int main(void) { return 0; }
C
clang -arch arm64 -arch x86_64 "$PACKAGING_TEST_ROOT/main.c" -o "$PACKAGING_TEST_APP/Contents/MacOS/Fixture"
cat > "$PACKAGING_TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>team.sloppy.client</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.3.0</string>
<key>CFBundleVersion</key><string>31</string>
<key>SUPublicEDKey</key><string>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</string>
</dict></plist>
PLIST
printf 'sealed fixture\n' > "$PACKAGING_TEST_APP/Contents/Resources/fixture.txt"

# Reproduce the linker-signed Mach-O without a sealed .app bundle.
if "$PACKAGING_SCRIPT_DIR/package_sparkle_archive.sh" "$PACKAGING_TEST_APP" 2.3.0 "$PACKAGING_TEST_ROOT/unsigned" > "$PACKAGING_TEST_ROOT/path" 2> "$PACKAGING_TEST_ROOT/error"; then
    echo "error: unsigned app was accepted" >&2
    exit 1
fi
[[ ! -s "$PACKAGING_TEST_ROOT/path" ]]
[[ ! -e "$PACKAGING_TEST_ROOT/unsigned/SloppyClient-macos-2.3.0.zip" ]]

codesign --force --sign - --identifier team.sloppy.client "$PACKAGING_TEST_APP"
ARCHIVE_PATH="$("$PACKAGING_SCRIPT_DIR/package_sparkle_archive.sh" "$PACKAGING_TEST_APP" 2.3.0 "$PACKAGING_TEST_ROOT/signed")"
[[ "$ARCHIVE_PATH" == "$PACKAGING_TEST_ROOT/signed/SloppyClient-macos-2.3.0.zip" ]]
ditto -x -k "$ARCHIVE_PATH" "$PACKAGING_TEST_ROOT/extracted"
codesign --verify --deep --strict --all-architectures "$PACKAGING_TEST_ROOT/extracted/Sloppy.app"

printf 'tampered fixture\n' > "$PACKAGING_TEST_APP/Contents/Resources/fixture.txt"
if "$PACKAGING_SCRIPT_DIR/package_sparkle_archive.sh" "$PACKAGING_TEST_APP" 2.3.0 "$PACKAGING_TEST_ROOT/tampered" > "$PACKAGING_TEST_ROOT/path" 2> "$PACKAGING_TEST_ROOT/error"; then
    echo "error: tampered app was accepted" >&2
    exit 1
fi
[[ ! -s "$PACKAGING_TEST_ROOT/path" ]]
printf 'Sparkle packaging rejects unsigned/tampered apps and preserves a valid universal signature.\n'
