# SloppyRuntimePortable

This SwiftPM package exposes Sloppy's portable runtime modules to iOS hosts. Its
`Sources` entries are relative symlinks to the same source directories used by
the desktop Sloppy package, so runtime logic is maintained in one place.

The package intentionally excludes the desktop Core executable, HTTP router,
TUI, relay, process tools, and CodexBar. Mobile hosts import `SloppyRuntime`
and provide their own project directory, credentials, and tool capabilities.

Build the iOS target from the Sloppy repository root with a compatible iOS SDK:

```sh
swift build --package-path Packages/SloppyRuntime --target SloppyRuntime \
  --triple arm64-apple-ios18.0-simulator --sdk <iPhoneSimulator.sdk>
```
