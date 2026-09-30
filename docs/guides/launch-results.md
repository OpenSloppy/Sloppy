# Play for agent results

Play in the macOS chat toolbar runs a saved launch recipe on the chat's originating Core host. A recipe identifies the exact checkout/worktree, subproject and target; Play builds the current files, including uncommitted changes. Select other targets from the adjacent menu. Explicit selection survives agent recommendations and Core restarts.

For an existing chat without a recipe, choose **Prepare launch**. The agent receives a message in that chat and can save configurations with `session.launch.configure`. Preparation preserves the composer draft. Libraries without an application need no recipe.

## Agent tool

`session.launch.configure` takes a `configuration` JSON string. Example for a web subproject:

```json
{
  "name": "Dashboard",
  "target": "dashboard",
  "platform": "web",
  "checkoutPath": "/absolute/path/to/task-worktree",
  "workingDirectory": "Dashboard",
  "build": [{"executable": "npm", "arguments": ["run", "build"]}],
  "launch": {"executable": "npm", "arguments": ["run", "dev", "--", "--host", "127.0.0.1", "--port", "5173"]},
  "webPort": 5173,
  "webPath": "/"
}
```

Save each runnable target separately. Re-registering the same checkout/subproject/target/platform updates its recipe; supplying its `id` explicitly also updates it. The most recently registered recipe is recommended. Register the target relevant to the result last. Core assigns chat/project/host identity and validates allowed directories and command guardrails.

Apple recipes require at least one build command to rebuild the current checkout. Interpreted/static web targets can omit build steps; the UI shows “not required”. Apple recipes use `platform: "macOS"` or `"iOSSimulator"`, build commands, and `appPath` relative to the checkout. Simulator recipes also need `bundleID`; the toolbar lets the user choose and remember an available iOS Simulator if `simulatorID` is omitted. Core validates the built app's bundle identity before installation. Apple adapters handle opening/installing the app; `launch` is required for web only.

Optional `verificationEvidenceIDs` must refer to successful verification records in the current chat turn. Core copies those actual records into the recipe. Saving a recipe does not itself count as build/run verification.

ACP agents can register the same typed recipe through `sloppy agent session launch configure <agentId> <sessionId> --file launch.json --url <originating-Core-URL>`. The ACP prompt supplies the scoped IDs and Core endpoint; authentication uses the existing CLI credentials. `sloppy agent session launch list` reads selection/history.

## API

Base: `/v1/agents/:agentId/sessions/:sessionId/launch` on the originating Core instance.

| Method | Suffix | Result |
| --- | --- | --- |
| GET | — | Configurations, selection, recent run status and bounded logs |
| POST | `/configurations` | Save a `LaunchConfigurationRequest` |
| POST | `/selection` | Select `configurationID`, optionally with `simulatorID` |
| DELETE | `/configurations/:configurationId` | Stop owned runs and release this recipe |
| POST | `/configurations/:configurationId/start` | Start deterministic build and launch |
| POST | `/runs/:runId/stop` | Stop this run's owned processes/app |
| GET | `/simulators` | Available iOS Simulators on the Core Mac |
| POST | `/archive` | Set `isArchived`; archive stops runs and releases checkout retention |
| WebSocket | `/runs/:runId/preview/ws` | Authenticated raw TCP preview transport, base64 frames |

Build failure prevents launch. Duplicate starts return 409; use Stop then Start for Restart. Launch status distinguishes preparing/building/launching/running/completed/stopped/failed, with separate `buildSucceeded` and `launchSucceeded`. Logs retain the latest 256 KiB and history retains 20 completed runs plus active runs. Closing logs does not stop the target. Ordinary configuration updates retain active launches; changing the Core storage/workspace stops them.

Web previews use a client loopback listener and authenticated Core stream to the run's registered loopback port. The raw stream preserves assets and WebSocket traffic over direct, node mesh relay and managed remote connections. Stopping the run closes preview streams. Occupied ports produce an error rather than opening another server.

Simulator Play restarts the selected application on that device after building. Only one managed run may own a bundle/device pair; stop the earlier run or choose another Simulator. Cancellation during launch also cleans up the selected app before its PID is published.

For remote macOS/Simulator targets, the application window opens on the execution Mac. Screen streaming and copying a checkout to another machine are outside v1. After Core restart, stale active runs become failed; the service never assumes old PIDs are still owned. A process surviving an abnormal Core exit may need to be stopped on that host before its port can be reused.

Saved active recipes retain worktrees through task approval and prevent automatic reclaim. Removing a recipe, archiving/deleting its chat, or session retention cleanup releases the reference. A manually missing checkout is reported explicitly; Play never falls back to the main checkout.

## Validation

Focused tests: `swift test --filter launch` in Sloppy and `swift test --filter Launch` in ClientNative. Native smoke tests are opt-in using `SLOPPY_PLAY_MAC_CHECKOUT`/`SLOPPY_PLAY_MAC_APP` or `SLOPPY_PLAY_IOS_CHECKOUT`/`SLOPPY_PLAY_IOS_APP`/`SLOPPY_PLAY_SIMULATOR`/`SLOPPY_PLAY_IOS_BUNDLE`, with app paths relative to their checkout roots. They verify LaunchRunService's real platform adapters rather than equating a build with a running application.
