# Sloppy Desktop Companion

A separate macOS 26 app for requesting agent help at the mouse pointer. It has its own bundle identifier and does not enable computer control inside the sandboxed App Store client.

## Run locally

Build Sloppy Core with the `/v1/desktop-computer` endpoints and run it as usual. Then run:

```sh
./script/run_desktop_companion.sh
```

Use `--preview` to inspect the sphere and chat without connecting to Core. A normal launch automatically connects to the local instance configured in the Sloppy desktop app. Companion reads the desktop app's persisted connection preferences and reuses its Keychain-backed sign-in, including the exact host name and TLS fingerprint. There is no separate URL, username, password, or token form. If the desktop currently uses a remote server, Companion uses a saved local server or asks you to select one in Sloppy. Reconnect reloads credentials saved since the last attempt. Companion does not launch another Core process.

The menu-bar item opens settings, shows/hides the panel, and stops the agent. The persistent **Desktop Companion** chat appears in Sloppy's regular session list. Use **Open Sloppy** to sign in there, then **Reconnect** in Companion if necessary.

## Interaction

The orb uses a native Metal translation of the generated Aura WebGL shader: 20 volume samples, flowing cyan/blue/pearl ribbons, soft bloom, and grain. `MTKView` renders a transparent surface at 24–30 fps. It stops its display loop when hidden and shows a static frame with Reduce Motion. Voice amplitude comes from Companion's existing native recorder; the current recorder provides a volume level, so the shader's three frequency inputs use that same level. No browser or separate microphone capture is involved.

- Press **Option + Space** to open the action ring at the pointer. Click an action, press Escape to close, or press Option + Space again to dismiss it. Either Option key works; the Space is consumed instead of inserted into another app. This shortcut remains active when additional modifier gestures are enabled.
- The **Actions** button (four dots) below the orb, the orb's context menu, and the menu-bar item also open the ring. Use the Write button to open the composer directly.
- Enable **Modifier key gestures** in settings for additional controls: tap right Option or right Command to write, quickly double-tap the same modifier to hide, or hold it for 250 ms to open the action wheel. Move toward an action and release to select; release in the center to cancel. Ordinary keyboard/mouse combinations cancel these modifier gestures and continue normally.
- Select an area, capture a window, type a prompt, or record voice. Voice is transcribed into an editable draft before sending.
- The composer has one action button: Voice for an empty draft, Finish during recording, and Send when text is ready. Opening Sloppy hides the companion panel without interrupting the agent. Settings remain available from the menu-bar item and the orb's context menu.
- The orb sits in the center above a compact composer capsule. The + button selects a screen area; the circular primary action becomes a blue send arrow when text is ready. After a successful submission, the input folds into a small Write / Voice / Actions toolbar and a separate response bubble appears above the orb. History, Open in Sloppy, Settings, and Hide are available from the orb's context menu.
- Click the orb to expand/collapse, drag the orb or chat header to move its native window, or hide it from its menu. The chat uses system Liquid Glass and measures its content height. Hiding never interrupts an agent run. Stop revokes local commands immediately and interrupts the Core session.
- The settings allow choosing the shortcut mode and target agent. In modifier gesture mode, select left or right Option and enable/disable the additional right Command trigger.

Screen capture and microphone permissions are requested only when used. Option + Space uses a system global hotkey. Accessibility enables modifier key monitoring, semantic context, and computer input. Companion panels are excluded from captures. Rectangles use screen points; screenshot dimensions and per-axis scales describe the pixel mapping. Region selection stays on one monitor.

## Computer routing

The companion initiates authenticated requests to Core, polls for commands, and submits results. It does not expose a local control server. Every binding includes a random connection ID, stable device ID, agent ID, and session ID. Core durably remembers session/device assignments; expired or disconnected connections fail rather than execute on Core's host. Commands are serialized, expire, and are never automatically replayed after uncertain delivery.

The bridge uses the existing `computer.click`, `computer.type`, `computer.key`, and `computer.screenshot` tools. An agent's normal tool policy and approval flow still apply. Screenshots returned to tools describe display coordinates and scale; clients must not interpret cropped image pixels as absolute screen coordinates.

Delegated/forked sessions inherit the original-device restriction. In this first version, computer actions run in the connected parent chat; a delegated session without its own companion connection fails instead of controlling Core's computer.

## Distribution

Release this app independently with Developer ID signing, Hardened Runtime, notarization, and a stapled ticket, packaged in a DMG or ZIP. The local run script builds an unsigned development app. It does not publish or produce a notarized release. Do not add an executable downloader/installer to the App Store client. The companion integration must be disclosed to App Review; App Store acceptance is not guaranteed by this architecture.

## Magic Pointer

Magic Pointer is enabled by default. Double-tap **Left Option** (two short complete presses, at most 300 ms apart) to start a voice conversation across macOS apps. Move the pointer while speaking: a soft blue Metal ribbon follows it and fades over 900 ms. The overlay is nonactivating and click-through; the system cursor remains available. Normal clicks, dragging and scrolling continue in the working app.

Repeat the double tap to close the conversation and submit the current nonempty voice turn. **Escape** cancels the current unsent turn and closes the overlay. Closing the voice mode leaves accepted agent work running; **Stop Agent** also interrupts the session and revokes local computer commands. The menu bar provides **Magic Pointer**, **Finish utterance**, and the existing chat/actions/settings entries.

While enabled, Left Option is reserved for Magic Pointer: it does not also invoke the legacy single-tap composer, hold wheel or double-tap Hide action. Option+Space and the other configured modifiers remain available. Choosing another action from the action ring cancels the current voice mode. Disable Magic Pointer in settings to restore the existing modifier behavior.

The conversation uses sequential turns: recording → transcription → the selected agent → a local Apple speech reply → listening again. Recording pauses during the agent's work and speech playback. A sustained voice level followed by 800 ms of silence ends a turn; empty bounded recordings are discarded. Settings control spoken replies and the speech language. This version does not provide full-duplex voice interruption.

Each submitted turn contains the transcription, its full timestamped pointer path, up to four clean screen frames with separately annotated copies, and available AX element context. The visual tail's lifetime does not limit the archived path. Raw path metadata is uploaded as JSON; normal Core attachment context gives the agent the file paths for `files.read` or structured parsing. Screen and document content is labeled untrusted. Normal agent tool policies and approvals continue to apply.

Frames describe their screen rectangle and actual resized image dimensions/scales. Display changes create a new geometry revision and path segment; points from another revision are never painted onto a frame. Frame selection preserves the beginning and distinct recent targets, with omissions reported in the metadata. JSON is bounded to 256 KiB and the complete attachment set to 8 MiB.

The companion uses separate recorders for composer dictation and Magic Pointer so cancellation of an older voice callback cannot stop a new composer recording. Failed transcription or local validation retains the turn for an explicit retry in settings. A submission with an uncertain HTTP result is retained but never automatically replayed; inspect the chat first, then discard the pending turn before starting another conversation.

On first use macOS may request Accessibility, Screen Recording, Microphone, Speech Recognition for local fallback, and Keychain access to the existing Sloppy sign-in. The development bundle is unsigned; macOS can request Keychain access again after its executable changes.

### Native visual preview

```sh
./script/run_desktop_companion.sh --preview-pointer
```

This opens a native Metal reference window without connecting to Core, recording the microphone or capturing the desktop. The debug app also supports `--pointer-snapshot-path /absolute/path.png` together with `--preview --preview-pointer`: it saves its own reference window and a JSON report of GPU frames and actual overlay window properties. The report exercises the gesture router directly; it does not prove a physical global keyboard gesture.

## GitHub builds and updates

The `Desktop Companion` workflow tests and builds a universal macOS ZIP on relevant pushes and pull requests. Its development artifact uses build number 1; it is not a signed release feed. Tagged `v*` releases use the release workflow's build number and publish:

- `SloppyDesktopCompanion-macos-<version>.zip`
- `companion-appcast.xml`
- entries for both files in `SHA256SUMS.txt`

Companion embeds Sparkle and reads its own channel at `https://github.com/TeamSloppy/Sloppy/releases/latest/download/companion-appcast.xml`. The existing public Ed25519 key is embedded in the app; the existing `SPARKLE_PRIVATE_KEY` GitHub secret signs update archives through the appcast generator. Main Sloppy Client keeps its separate `appcast.xml`. The current release publication gate is preserved.

The menu bar includes **Check for Updates…**. Automatic checks are enabled; Sparkle manages the user's download/install preferences. Checks and relaunch are blocked while a conversation, agent task or pending interaction is active. Application shutdown stops local capture/control before an update relaunch.

Build locally with:

```sh
./script/build_desktop_companion_release.sh 0.1.0 /absolute/output/directory
```

The script verifies both architectures, bundle ID, version and embedded Sparkle before packaging. Set `COMPANION_SIGNING_IDENTITY` to a Developer ID Application identity to sign the app and nested Sparkle code. The existing GitHub repository currently supplies the Sparkle archive-signing secret; Developer ID certificate provisioning and notarization are separate distribution setup. An EdDSA-signed archive does not by itself prove Developer ID signing or notarization.

To generate the Companion feed using the same tools as the main client, set `SPARKLE_APPCAST_FILENAME=companion-appcast.xml` when running `script/generate_sparkle_appcast.sh`. Keep exported private key files outside the repository; never commit them.
