#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANION_DERIVED_DATA="${COMPANION_DERIVED_DATA:-$ROOT_DIR/.build/desktop-companion-derived}"
MODE="${1:-run}"
APP_BUNDLE="$COMPANION_DERIVED_DATA/Build/Products/Debug/Sloppy Desktop Companion.app"

case "$MODE" in
  run|--preview|--preview-pointer|--verify) ;;
  *) echo "usage: $0 [run|--preview|--preview-pointer|--verify]" >&2; exit 2 ;;
esac

command -v xcodegen >/dev/null
command -v xcodebuildmcp >/dev/null
cd "$ROOT_DIR"
xcodebuildmcp macos stop --app-name "Sloppy Desktop Companion" >/dev/null 2>&1 || true
xcodegen generate
xcodebuildmcp macos build \
  --project-path "$ROOT_DIR/SloppyClient.xcodeproj" \
  --scheme SloppyDesktopCompanion \
  --configuration Debug \
  --derived-data-path "$COMPANION_DERIVED_DATA" \
  --extra-args CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

"$ROOT_DIR/script/sign_macos_app.sh" "$APP_BUNDLE" "${COMPANION_SIGNING_IDENTITY:-${MACOS_SIGNING_IDENTITY:-auto}}" \
  "$ROOT_DIR/SupportingFiles/DesktopCompanion/SloppyDesktopCompanion.entitlements"

if [[ "$MODE" == "--preview-pointer" ]]; then
  xcodebuildmcp macos launch --app-path "$APP_BUNDLE" --json '{"args":["--preview","--preview-pointer"]}'
elif [[ "$MODE" == "--preview" ]]; then
  xcodebuildmcp macos launch --app-path "$APP_BUNDLE" --json '{"args":["--preview"]}'
else
  xcodebuildmcp macos launch --app-path "$APP_BUNDLE"
fi
if [[ "$MODE" == "--verify" ]]; then
  sleep 2
  pgrep -f "$APP_BUNDLE/Contents/MacOS/" >/dev/null
fi
