# SloppyClient

Native macOS/iOS client for Sloppy. Built on AdaEngine + AdaUI.

Current status: internal-first Apple client workspace with connection setup, local server discovery, deep-link connection, chat, websocket-backed notifications, and settings/config editing foundations.

## Build

```bash
cd ClientNative
swift build
```

## Build and install on this Mac

Build SloppyClient and Sloppy Desktop Companion in Release, replace their local
copies in `/Applications`, and launch both:

```bash
cd ClientNative
./script/build_and_install.sh
```

The script asks for an administrator password only when the destination is not
writable. Use `--no-launch` to install without opening either app, or
`--install-dir "$HOME/Applications"` to install for the current user only.
Use `--debug` to build both apps in Debug. `DERIVED_DATA` overrides their shared
build directory.

To build only Desktop Companion:

```bash
./script/build_desktop_companion.sh
```

This prints the `.app` path without installing or launching it. It also accepts
`--debug` and `DERIVED_DATA`.

## Generate Xcode project

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ClientNative
xcodegen generate
open SloppyClient.xcodeproj
```

## macOS updates

The macOS target embeds Sparkle 2.9.6. It checks the signed feed at
`https://github.com/TeamSloppy/Sloppy/releases/latest/download/appcast.xml` and
also exposes **Check for Updates…** in the application menu. Updates are offered
to the user but are not installed automatically.

Tag releases package a Sparkle ZIP alongside the macOS installer and publish a
signed `appcast.xml`. The release workflow reads the private EdDSA key from the
`SPARKLE_PRIVATE_KEY` GitHub Actions secret. Keep that key in the `TeamSloppy`
Sparkle Keychain account for local signing; never commit an exported key.

For a local feed validation, point `SPARKLE_TOOLS_DIR` at the `bin` directory
from the Sparkle release, then run:

```bash
./script/package_sparkle_archive.sh /path/to/SloppyClient-macOS.app 0.1.0 /tmp/sloppy-update
SPARKLE_TOOLS_DIR=/path/to/Sparkle/bin \
  ./script/generate_sparkle_appcast.sh \
  /tmp/sloppy-update/SloppyClient-macos-0.1.0.zip \
  0.1.0 \
  /tmp/sloppy-update/feed
```

## macOS TestFlight

Use Xcode 26 or later with the Sloppy Apple developer account configured in
Xcode Settings. The `SloppyClient-TestFlight` scheme enables App Sandbox and
omits Sparkle and the update menu. It uses the same application bundle ID as
the standalone client.

Build and export an App Store Connect package:

```bash
./script/build_testflight.sh 2.1.0 28 /tmp/sloppy-testflight
```

Add `--upload` to archive and upload directly through the Xcode account:

```bash
./script/build_testflight.sh 2.1.0 28 /tmp/sloppy-testflight --upload
```

Both release schemes build for Apple Silicon and Intel. Version and build number
come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. An accepted upload
still needs Apple processing before the build becomes available in TestFlight.

## Workspace Notes

`ClientNative` is the Apple client workspace. It is built independently from
the root server package and has its own package boundaries plus generated Xcode
project flow.

## Structure

```
ClientNative/
  Package.swift          # Standalone SwiftPM package (SloppyClient)
  project.yml            # XcodeGen spec for .xcodeproj generation
  Sources/
    SloppyClient/        # App entry point and product screens
```

## Current Feature Status

Implemented now:

- splash and connection setup flow
- saved server retry and local network discovery
- manual host/port connection
- `sloppy://connect` deep-link handling
- chat UI with session streaming
- notification socket integration and in-app banners
- settings and server config editing surfaces

Still on the roadmap:

- review and diff flows
- APNs device registration and push delivery
- release/distribution hardening

## Notes

- AdaEngine is vendored as a git submodule at `Vendor/AdaEngine` (see ADR 0002).
- Requires macOS 15.0+ (driven by AdaEngine's minimum platform requirement).
- Push notification entitlements are already stubbed in `project.yml` per ADR 0005.
- More implementation status is tracked in [Apps/docs/current-state.md](../docs/current-state.md).

## Updating the pinned engine revision

The submodule is pinned to a specific commit. To update it:

```bash
cd Vendor/AdaEngine
git fetch origin
git checkout <target-commit-or-tag>
cd ../..
git add Vendor/AdaEngine
git commit -m "chore: bump AdaEngine to <commit>"
```

To initialize the submodule after a fresh clone:

```bash
git submodule update --init --recursive
```

Ownership rules for changes: see [ADR 0002](../docs/adr/0002-adaengine-fork-and-submodule.md).
