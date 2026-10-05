# AGENTS.md

Guidance for coding agents working in this repository.
Project type: SwiftPM agent runtime (Swift 6.2) + React/Vite dashboard + Apple client.

## Visual design and brand

- Read [Sloppy Visual Design](docs/dashboard-style.md) before creating or changing product UI, brand assets, websites, documentation visuals, or presentations. It is the canonical design reference, approved on 2026-10-05.
- Follow the approved editorial style: warm paper `#f5f2e9`, forest dark `#20261e`, ink `#242521`, soft mint `#c8e2ae`, and restrained coral `#d94e34`; use generous space, large sans-serif headings, flat compositions, and thin separators.
- Preserve the approved wordmark **`sloppy.`**: lowercase, terminal period, system sans-serif stack, `font-weight: 750`, and tracking `-1.2px` at `29px` (scale proportionally). On forest dark, use paper lettering and a mint period; on paper, use ink for the entire wordmark. Compare with the two reference images in the design document. Do not substitute a monospaced, rounded, or decorative logo font.
- Use sans-serif for interface and editorial text; reserve monospace for code and technical data. Avoid introducing the legacy acid-lime palette, hard offset shadows, or grids of decorative cards into new designs.
- Existing Dashboard/docs colors and typography are a legacy implementation, not the target visual identity. Apply the design within the requested change; keep native control behavior, accessibility, and feature-specific interaction rules.

## Scope and stack

- Package manager: SwiftPM (`Package.swift`) with local packages in `Packages/`
- Swift tools version: 6.2
- Core platform: macOS 14+; CI also builds/tests on Linux where supported
- Executables: `sloppy`, `SloppyNode`
- Core libraries: `Protocols`, `PluginSDK`, `AgentRuntime`, `ChannelPluginSupport`, `SloppyNodeCore`
- Built-in channel plugins: `ChannelPluginTelegram`, `ChannelPluginDiscord`
- Dashboard: `Dashboard/` (React 19, TypeScript/JS, Vite)
- Apple client: `Apps/Client/` (SwiftPM + XcodeGen project, AdaEngine/AdaUI, AdaMCP)
- Persistence: SQLite via `CSQLite3`, `SQLiteStore`, and `Sources/sloppy/Storage/schema.sql`
- Test framework: Swift Testing (`import Testing`, `@Test`, `#expect`)

## Build, lint, test, run

Run from repo root unless noted.

### Resolve dependencies

- `swift package resolve`

### Build (Swift)

- `swift build`
- `swift build -c release`
- `swift build -c release --product sloppy`
- `swift build -c release --product SloppyNode`
- `swift build --target ProtocolsTests`
- `swift build --target SloppyNodeCoreTests`

### Test (Swift)

- Full suite: `swift test`
- Parallel suite: `swift test --parallel`
- List tests: `swift test list`

### Run a single Swift test (important)

- By exact name:
  - `swift test --filter CoreRouterTests.postChannelMessageEndpoint`
- By test group:
  - `swift test --filter CoreRouterTests`
  - `swift test --filter sloppyTests`
  - `swift test --filter AgentRuntimeTests`
  - `swift test --filter SloppyNodeCoreTests`
- Note: `swift test --list-tests` is deprecated; use `swift test list`.

### Run executables

- `swift run sloppy`
- `swift run sloppy run`
- `swift run sloppy run --no-gui`
- `swift run sloppy run --config-path sloppy.json`
- `swift run sloppy run --generate-openapi docs/public/swagger.json`
- `swift run SloppyNode`

Useful `sloppy` commands:

- No subcommand opens the project-aware TUI.
- `run` starts the Core API and, unless disabled, the bundled dashboard.
- `service` installs/starts/stops the macOS launchd service.
- `agent`, `project`, `channel`, `providers`, `actor`, `plugin`, `mcp`, `visor`, and `skills` expose API-backed CLI workflows.

### Dashboard commands (inside `Dashboard/`)

- `npm install`
- `npm run dev`
- `npm run build`
- `npm run typecheck`
- `npm run preview`
- `npm run seed:happy-path`
- `npm run e2e:happy-path`

### Apple client commands (inside `Apps/Client/`)

- `swift build`
- `swift test`
- `xcodegen generate` (when `project.yml` changes and XcodeGen is available)

### Lint/format status

No dedicated lint/format config is committed for SwiftLint, swift-format, ESLint, or Prettier.
When changing code, preserve local style and validate with:

- `swift test --parallel`
- `swift build -c release --product sloppy`
- `swift build -c release --product SloppyNode`
- `npm run build` (when dashboard files change)
- `npm run typecheck` (when dashboard TypeScript or shared types change)

## CI parity checklist

CI (`.github/workflows/ci.yml`) runs:

- `swift test --parallel` on Ubuntu (`swift:6.2-jammy`) and macOS
- `swift build -c release --product sloppy` on Ubuntu and macOS
- `swift build -c release --product SloppyNode` on Ubuntu and macOS
- `npm install` + `npm run build` in `Dashboard/`
- Dashboard happy path: Docker Compose from `utils/docker/docker-compose.yml`, then `npm run seed:happy-path` and `npm run e2e:happy-path`

CI (`.github/workflows/sloppy-node.yml`) also builds `SloppyNode` on macOS and Windows, builds `ProtocolsTests` / `SloppyNodeCoreTests`, and smoke-invokes `SloppyNode invoke --stdin`.

Keep local changes green for the smallest relevant command first, then the matching CI-parity commands.

## Releases and install from GitHub

Pushing a tag `v*` runs [`.github/workflows/release.yml`](.github/workflows/release.yml): Swift tests and release builds on Linux and macOS, Dashboard `npm run build` on both, tarballs uploaded to the GitHub Release together with `SHA256SUMS.txt` and `sloppy-version.json`, release notes from **GitHub auto-generated changelog** (`generate_release_notes: true`), prerelease when the version segment looks like alpha/beta/rc/preview/pre. The workflow then commits updated [`Casks/sloppy.rb`](Casks/sloppy.rb) (macOS) and [`Formula/sloppy.rb`](Formula/sloppy.rb) (Linuxbrew) on the repository default branch.

Install prebuilt binaries without building: [`scripts/install.sh`](scripts/install.sh) `--release` (uses `SHA256SUMS.txt` from the release). Set `SLOPPY_RELEASE_REPO`, `SLOPPY_RELEASE_TAG`, or `SLOPPY_LOCAL_ROOT` as needed.

## Code style guide

### Swift: imports and formatting

- Use 4-space indentation and no tabs.
- Keep imports minimal; place `Foundation` first when used.
- Follow existing multiline style and trailing commas.
- Keep files focused; extract helpers instead of large monolith methods.

### Swift: types and naming

- `UpperCamelCase` for types; `lowerCamelCase` for vars/functions.
- Prefer `struct` for DTO/protocol models; use `actor` for shared mutable state.
- Mark cross-target API explicitly with `public`.
- Add `Sendable` where values cross concurrency boundaries.
- Use enums for constrained state/actions (`RouteAction`, `WorkerMode`, etc.).
- For API-compatible values, use explicit raw values (snake_case when needed).

### Swift: error handling and resilience

- Use `throws` for recoverable boundary failures.
- In router/http boundaries, convert invalid payloads to stable 4xx responses.
- Prefer graceful fallback over crashing in runtime services.
- Avoid force unwraps and `fatalError` in production paths.
- Log operational failures with context and continue when safe.

### Swift: concurrency and architecture

- Prefer actor isolation to locking.
- Keep orchestration async end-to-end (`async`/`await`).
- Do not bypass actor boundaries with shared mutable globals.
- Maintain separation: transport (`CoreHTTPServer`) -> routing (`CoreRouter`) -> service (`CoreService`) -> runtime (`AgentRuntime`) -> persistence (`SQLiteStore`).

### Agent behavior and model output handling

- Do not implement language heuristics for agent behavior. This project builds agents; code must not guess what the model is going to answer from localized filler phrases or keyword arrays.
- Never classify state, progress, intent, completion, tool use, or branching by matching phrases such as `посмотрю`, `сейчас проверю`, `i'll inspect`, `let me check`, `looking into`, or similar English/Russian text fragments.
- Prefer typed signals: explicit API fields, runtime events, tool call records, planner intents, task state, structured model output, or persisted metadata.
- If a behavior decision depends on user or model intent, route it through an explicit semantic/structured layer and cover it with tests. Do not add another list of words.
- UI text may be displayed as text, but it must not become control flow unless it comes from a stable, documented protocol field.

### Tests

- Use Swift Testing macros (`@Test`, `#expect`).
- Write behavior-focused tests with clear arrange/act/assert flow.
- Keep tests deterministic and isolated.
- For endpoint logic, test via router/service with realistic payloads.

### Dashboard (React)

- Use function components and hooks.
- Use named exports for components/utilities.
- Keep state local; derive computed values with `useMemo` when useful.
- Use `async/await` and handle non-OK responses explicitly.
- Match existing JS formatting: 2-space indent, semicolons, double quotes.
- Keep route parsing and navigation behavior in `Dashboard/src/app/routing/`.
- Use `Dashboard/src/shared/api/coreApi.ts` as the main Core API client surface; `Dashboard/src/api.ts` re-exports that surface for legacy callers.
- For dropdown/select UI, always use the custom `.actor-team-search` dropdown pattern (see `ActorsView.tsx` and `actors.css`) — never use native `<select>` elements.

## Module map

### Swift targets

- `Sources/Protocols`: shared domain and wire models (`APIModels`, runtime models, ACP/node payloads, JSON helpers, event envelopes). This is the bottom dependency for runtime-facing modules.
- `Sources/PluginSDK`: plugin contracts and model-provider bridge points (`GatewayPlugin`, `ToolPlugin`, `MemoryPlugin`, `ModelProviderPlugin`, AnyLanguageModel integration, provider auth helpers).
- `Sources/ChannelPluginSupport`: shared support for built-in and external channel plugins.
- `Sources/ChannelPluginTelegram`: built-in Telegram gateway plugin.
- `Sources/ChannelPluginDiscord`: built-in Discord gateway plugin.
- `Sources/AgentRuntime`: runtime actors and orchestration primitives: channels, branches, workers, compaction, memory, event bus, visor, payload budgeting, and `RuntimeSystem`.
- `Sources/sloppy`: main executable, Core API, CLI, TUI, persistence, tools, model providers, channels, projects, tasks, memory, MCP/ACP, Visor, Swarm, and dashboard serving.
- `Sources/NodeCore`: reusable local computer-control node daemon logic.
- `Sources/Node` (product: `SloppyNode`): standalone node executable.
- `Sources/CSQLite3`: system SQLite module map for SwiftPM.

### Core executable layout

- `Sources/sloppy/CLI/Commands`: ArgumentParser command tree for `sloppy`.
- `Sources/sloppy/Gateway` and `Sources/sloppy/Gateway/Routers`: NIO HTTP transport, API routers, OpenAPI generation, dashboard HTTP serving.
- `Sources/sloppy/CoreService*.swift`: service facade split by domain (`Agents`, `Projects`, `Providers`, `TaskSync`, `Visor`, `Tools`, etc.).
- `Sources/sloppy/Agent`: agent catalogs, sessions, orchestration, prompt composition, skills/tools file stores, pets, cron tasks.
- `Sources/sloppy/Tools`: tool catalog, approval/pre-hook services, execution services, loop guards, and subagent delegation.
- `Sources/sloppy/Tools/AgentTools`: user-visible agent tools grouped by domain (`Agents`, `Files`, `MCP`, `Memory`, `Project`, `Sessions`, `SystemTools`, `Visor`, `Web`).
- `Sources/sloppy/Providers`: OpenAI/Anthropic/Gemini/Ollama/OpenRouter/OpenCode provider factories, OAuth flows, catalog probing, proxy session factory.
- `Sources/sloppy/MCP` and `Sources/sloppy/ACP`: external tool/server registry and ACP session management.
- `Sources/sloppy/Memory`: hybrid memory, embeddings, outbox indexing, memory provider glue.
- `Sources/sloppy/Projects`: project context loading, file indexing, and change watching.
- `Sources/sloppy/TaskSync`: GitHub Projects sync provider and token crypto.
- `Sources/sloppy/Visor`: scheduling and typed task planning for Visor.
- `Sources/sloppy/Swarm`: multi-agent coordination and planning.
- `Sources/sloppy/TUI`: project-aware terminal UI, slash commands, timeline display, token parsing, undo/redo, theme.
- `Sources/sloppy/Terminal`: dashboard terminal service.
- `Sources/sloppy/Storage/schema.sql`: canonical SQLite schema; keep it aligned with `CorePersistenceFactory` and `SQLiteStore`.

### Tests

- `Tests/ProtocolsTests`: protocol/model coding and compatibility.
- `Tests/AgentRuntimeTests`: runtime flow, event payload budgets, worker execution, stream tracking, Visor runtime behavior.
- `Tests/sloppyTests`: Core API/router/config, CLI, persistence, providers, tools, projects/tasks, TUI, channel plugins, MCP/ACP, memory, sync, and service behavior.
- `Tests/SloppyNodeCoreTests`: node daemon request handling and local-control payloads.

### Client app (SloppyClient)

- `Apps/Client/`: Apple client app built with AdaEngine/AdaUI (iOS, iPadOS, macOS, visionOS).
- SwiftPM products: `SloppyClient`, `SloppyClientCore`, `SloppyClientUI`, `SloppyFeatureOverview`, `SloppyFeatureProjects`, `SloppyFeatureAgents`, `SloppyFeatureSettings`, `SloppyFeatureChat`.
- Xcode project is generated from `Apps/Client/project.yml`.
- Depends on `AdaEngine` from `Vendor/AdaEngine` by default, or `/Users/vlad-prusakov/Developer/AdaEngine` when `ADAENGINE_LOCAL=1`.
- Embeds `AdaMCPPlugin` from `Vendor/AdaMCP` for runtime inspection.

### Debugging the client with AdaMCP

The client embeds `AdaMCP` (`Vendor/AdaMCP`) — an MCP server that exposes the live AdaEngine runtime for inspection.
When debugging UI or runtime issues in the client, use the `XcodeBuildMCP` and `AdaMCP` MCP servers:

- `XcodeBuildMCP` — build, run, and read Xcode logs/diagnostics.
- `AdaMCP` — inspect the running app: UI tree (`ui.get_tree`, `ui.find_nodes`, `ui.hit_test`), render capture (screenshots), world/entity/component/resource introspection, and safe UI actions (tap, scroll, focus traversal).

Typical debugging flow:

1. Build and launch the client via `XcodeBuildMCP`.
2. Connect to the running app's MCP endpoint (default `127.0.0.1:2510/mcp`).
3. Use AdaMCP tools to inspect the UI tree, capture screenshots, and locate the problem.
4. Target nodes by `accessibilityIdentifier` for stable references.

### Frontend/docs/support

- `Dashboard/src/App.tsx`: dashboard shell and top-level view composition.
- `Dashboard/src/app`: dependency creation and routing.
- `Dashboard/src/features`: feature-owned dashboard surfaces (`agents`, `actors`, `config`, `notifications`, `project-chats`, `terminal`, `updates`, `visor`, etc.).
- `Dashboard/src/views`: larger route views and project subviews.
- `Dashboard/src/shared`: API clients and shared browser-side types/utilities.
- `Dashboard/src/styles`: global and feature CSS.
- `docs/`: VitePress docs site; specs live in `docs/specs`, guides in `docs/guides`, architecture notes in `docs/architecture`, and internal PRDs in `docs/product`.
- `Apps/docs/adr`: app/client-specific ADRs.
- `Packages/SloppyComputerControl`: local computer-control package used by core and client.
- `Packages/TauTUI`: local TUI package used by `sloppy`.
- `utils/docker/`: Dockerfiles and Compose assets for CI happy-path and local server/dashboard runs.
- `scripts/`: install, release, and support scripts.

## Common recipes

### Add a new API endpoint

1. **Model** — add `XxxRequest` / `XxxRecord` structs to `Sources/Protocols/APIModels.swift` under the relevant `// MARK:` section.
2. **Service method** — add the method to `Sources/sloppy/CoreService.swift` in the correct domain section. Use a typed error enum.
3. **Router** — add the route to the appropriate `XxxAPIRouter` in `Sources/sloppy/Gateway/Routers/`. If creating a new router, register it through `CoreRouter+HTTPRoutes.swift` / `CoreRouterRegistrar.swift`.
4. **Test** — add a test in `Tests/sloppyTests/` using Swift Testing macros (`@Test`, `#expect`).
5. **Verify** — `swift test --filter XxxTests` then `swift build -c release --product sloppy`.

### Add a new agent tool

1. **File** — create `Sources/sloppy/Tools/AgentTools/XxxTool.swift` conforming to `CoreTool`.
2. **Implement** — define `name`, `domain`, `title`, `status`, `description`, `parameters`, and `invoke(arguments:context:)`.
3. **Register** — add `XxxTool()` to the array in `ToolRegistry.makeDefault()` in `Sources/sloppy/Tools/ToolRegistry.swift`.
4. **Test** — add a test in `Tests/sloppyTests/` using `ToolContext` with injected fakes.
5. **Verify** — `swift test --filter XxxToolTests` then `swift build -c release --product sloppy`.

### Add a new SQLite table or column

1. **Schema** — update `Sources/sloppy/Storage/schema.sql` and any migration/bootstrap logic in `Sources/sloppy/CorePersistenceFactory.swift`.
2. **CRUD methods** — add the read/write methods to `Sources/sloppy/SQLiteStore.swift` inside the `#if canImport(CSQLite3)` guard with a matching in-memory fallback.
3. **Protocol** — add the method signature to the `PersistenceStore` protocol in `Sources/sloppy/Stores/PersistenceStore.swift`.
4. **Models/API** — update `Sources/Protocols/APIModels.swift` if the persisted data crosses the API/runtime boundary.
5. **Verify** — `swift test --filter SQLite` or the narrow affected test, then `swift build -c release --product sloppy`.

### Add a Dashboard view

1. **Component** — add the view under `Dashboard/src/features/...` for feature-owned surfaces or `Dashboard/src/views/...` for route-level/project views.
2. **Route** — update `Dashboard/src/app/routing/dashboardRouteAdapter.ts`, `useDashboardRoute.ts`, and `Dashboard/src/App.tsx` as needed.
3. **API** — add fetch/mutation functions to `Dashboard/src/shared/api/coreApi.ts`; update `Dashboard/src/api.ts` only if legacy re-exports are needed.
4. **CSS** — add or extend files in `Dashboard/src/styles/` or the established feature stylesheet. Keep 2-space JS/TS formatting, semicolons, and double quotes.
5. **Verify** — `cd Dashboard && npm run typecheck && npm run build`.

### Add or change SloppyNode behavior

1. **Core** — put reusable request handling in `Sources/NodeCore`.
2. **Executable** — keep CLI/process wiring in `Sources/Node`.
3. **Protocol** — update shared request/response models in `Sources/Protocols` when payloads change.
4. **Test** — add focused tests in `Tests/SloppyNodeCoreTests`.
5. **Verify** — `swift test --filter SloppyNodeCoreTests` then `swift build -c release --product SloppyNode`.

### Add or change an Apple client feature

1. **Core models/API** — place shared client networking and models in `Apps/Client/Sources/SloppyClientCore`.
2. **UI primitives** — reuse `Apps/Client/Sources/SloppyClientUI` for common styling/components.
3. **Feature** — put feature screens in the matching `SloppyFeature...` target.
4. **Project** — update `Apps/Client/project.yml` when targets, resources, entitlements, or schemes change; regenerate the Xcode project with XcodeGen when available.
5. **Verify** — run `swift test` and the narrow client build/test command from `Apps/Client/`.

## Cursor/Copilot rules status

Contextual rules for specific file areas live in `.cursor/rules/`:

- `router-pattern.mdc` — HTTP router structure and patterns
- `tool-pattern.mdc` — agent tool implementation
- `api-models.mdc` — APIModels.swift conventions
- `core-service.mdc` — CoreService domain map and patterns
- `sqlite-store.mdc` — SQLite C API patterns and migrations
- `tests.mdc` — Swift Testing framework usage
- `dashboard.mdc` — React/Vite dashboard conventions
- `agent-runtime.mdc` — AgentRuntime actor architecture

These rules are activated automatically when working with matching files and take precedence over the general guidance above.

## Agent execution expectations

- Make small, targeted edits aligned with existing module boundaries.
- Avoid introducing new frameworks without strong justification.
- Keep API behavior backward-compatible unless task explicitly allows breaking change.
- Update/add tests when changing behavior.
- Run the smallest relevant verification first, then CI-parity checks.
