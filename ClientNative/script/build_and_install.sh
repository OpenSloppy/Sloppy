#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$PROJECT_DIR/SloppyClient.xcodeproj"
SCHEME="SloppyClient-macOS"
CONFIGURATION="Release"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build/install-derived-data}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SHOULD_LAUNCH=1
ARCHITECTURE="$(uname -m)"

usage() {
    cat <<'EOF'
Build and install Sloppy and Sloppy Desktop Companion on this Mac.

Usage: script/build_and_install.sh [options]

Options:
  --debug              Build the Debug configuration instead of Release.
  --release            Build the Release configuration (default).
  --install-dir PATH   Install into PATH instead of /Applications.
  --no-launch          Do not launch either app after installation.
  -h, --help           Show this help.

Environment:
  DERIVED_DATA         Override the Xcode DerivedData directory.
  INSTALL_DIR          Override the installation directory.
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
        --install-dir)
            if [[ $# -lt 2 ]]; then
                echo "error: --install-dir requires a path" >&2
                exit 2
            fi
            INSTALL_DIR="$2"
            shift 2
            ;;
        --no-launch)
            SHOULD_LAUNCH=0
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
    echo "error: this script can only install the macOS application" >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required; install Xcode first" >&2
    exit 1
fi

# The companion build also generates the shared Xcode project.
COMPANION_CONFIGURATION_FLAG="--release"
if [[ "$CONFIGURATION" == "Debug" ]]; then
    COMPANION_CONFIGURATION_FLAG="--debug"
fi
DERIVED_DATA="$DERIVED_DATA" "$SCRIPT_DIR/build_desktop_companion.sh" "$COMPANION_CONFIGURATION_FLAG"

echo "==> Building $SCHEME ($CONFIGURATION)"
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$ARCHITECTURE" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
CLIENT_APP=""
for PRODUCT_NAME in Sloppy.app SloppyClient-macOS.app SloppyClient.app; do
    if [[ -d "$PRODUCTS_DIR/$PRODUCT_NAME" ]]; then
        CLIENT_APP="$PRODUCTS_DIR/$PRODUCT_NAME"
        break
    fi
done
if [[ -z "$CLIENT_APP" ]]; then
    echo "error: built application was not found in $PRODUCTS_DIR" >&2
    exit 1
fi

"$SCRIPT_DIR/sign_macos_app.sh" "$CLIENT_APP" "${MACOS_SIGNING_IDENTITY:-auto}" \
    "$PROJECT_DIR/SupportingFiles/macOS/SloppyClient.entitlements"

SOURCE_APPS=("$CLIENT_APP" "$PRODUCTS_DIR/Sloppy Desktop Companion.app")
APP_NAMES=("Sloppy" "Sloppy Desktop Companion")
BUNDLE_IDS=("team.sloppy.client" "team.sloppy.desktop-companion")

# Validate both products before replacing either installed app.
for INDEX in "${!SOURCE_APPS[@]}"; do
    BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${SOURCE_APPS[$INDEX]}/Contents/Info.plist")"
    if [[ "$BUNDLE_ID" != "${BUNDLE_IDS[$INDEX]}" ]]; then
        echo "error: refusing to install an unexpected application ($BUNDLE_ID)" >&2
        exit 1
    fi
done

USE_SUDO=0

if [[ ! -d "$INSTALL_DIR" ]]; then
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        USE_SUDO=1
    fi
elif [[ ! -w "$INSTALL_DIR" ]]; then
    USE_SUDO=1
fi

if [[ $USE_SUDO -eq 1 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "error: $INSTALL_DIR is not writable and sudo is unavailable" >&2
    exit 1
fi

run_install_command() {
    if [[ $USE_SUDO -eq 1 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

cleanup() {
    set +e
    run_install_command rm -rf "$TEMP_APP"
    if [[ $INSTALL_COMPLETE -eq 0 && ! -e "$DESTINATION_APP" && -e "$BACKUP_APP" ]]; then
        run_install_command mv "$BACKUP_APP" "$PREVIOUS_APP"
    fi
    if [[ $INSTALL_COMPLETE -eq 1 ]]; then
        run_install_command rm -rf "$BACKUP_APP"
    fi
}

for INDEX in "${!SOURCE_APPS[@]}"; do
    APP_NAME="${APP_NAMES[$INDEX]}"
    DESTINATION_APP="${INSTALL_DIR%/}/$APP_NAME.app"
    PREVIOUS_APP="$DESTINATION_APP"
    LEGACY_APP="${INSTALL_DIR%/}/SloppyClient.app"
    if [[ "$INDEX" -eq 0 && ! -e "$DESTINATION_APP" && -d "$LEGACY_APP" ]]; then
        LEGACY_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$LEGACY_APP/Contents/Info.plist")"
        if [[ "$LEGACY_BUNDLE_ID" == "${BUNDLE_IDS[$INDEX]}" ]]; then
            PREVIOUS_APP="$LEGACY_APP"
        fi
    fi
    TEMP_APP="${INSTALL_DIR%/}/.$APP_NAME.install.$$"
    BACKUP_APP="${INSTALL_DIR%/}/.$APP_NAME.backup.$$"
    INSTALL_COMPLETE=0
    trap cleanup EXIT

    echo "==> Installing $DESTINATION_APP"
    run_install_command mkdir -p "$INSTALL_DIR"
    run_install_command rm -rf "$TEMP_APP" "$BACKUP_APP"
    run_install_command /usr/bin/ditto --norsrc --noextattr "${SOURCE_APPS[$INDEX]}" "$TEMP_APP"

    # User data lives outside the application bundles and is not touched.
    if [[ "$INDEX" -eq 0 ]]; then
        pkill -x "Sloppy" >/dev/null 2>&1 || true
        pkill -x "SloppyClient" >/dev/null 2>&1 || true
        pkill -x "SloppyClient-macOS" >/dev/null 2>&1 || true
    else
        pkill -x "Sloppy Desktop Companion" >/dev/null 2>&1 || true
    fi

    if [[ -e "$PREVIOUS_APP" ]]; then
        run_install_command mv "$PREVIOUS_APP" "$BACKUP_APP"
    fi
    run_install_command mv "$TEMP_APP" "$DESTINATION_APP"
    INSTALL_COMPLETE=1
    run_install_command rm -rf "$BACKUP_APP"
    trap - EXIT

    echo "Installed: $DESTINATION_APP"
done

if [[ $SHOULD_LAUNCH -eq 1 ]]; then
    for APP_NAME in "${APP_NAMES[@]}"; do
        echo "==> Launching $APP_NAME"
        /usr/bin/open "${INSTALL_DIR%/}/$APP_NAME.app"
    done
fi
