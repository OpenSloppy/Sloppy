---
name: sloppy-docs
description: Navigation guide for Sloppy source code, documentation, and architecture — use this skill whenever you need to understand, diagnose, or fix Sloppy itself.
userInvocable: false
---

# Sloppy Docs & Self-Repair Guide

Use this skill when the task involves understanding Sloppy internals, fixing a Sloppy bug, tracing a runtime issue, or answering "how does X work in Sloppy".

## Where to find information

### Primary references
- **AGENTS.md** (repo root) — canonical map of modules, recipes for common changes (add endpoint, add tool, add DB column, add dashboard view), CI parity commands, code style rules. **Always start here.**
- **docs/** — user-facing docs at https://docs.sloppy.team, also available locally:
  - `docs/index.md` — overview and quick start
  - `docs/install.md` — installation guide
  - `docs/guides/cli.md` — CLI reference
  - `docs/guides/models.md` — model providers setup
  - `docs/guides/plugins.md` — plugin system
  - `docs/guides/development-workflow.md` — dev workflow and build
  - `docs/channels/about.md` — channels overview
  - `docs/agents/runtime.md` — agent runtime internals
  - `docs/agents/memory.md` — memory system
  - `docs/agents/workspace.md` — workspace and file access
  - `docs/visor/overview.md` — visor supervision
  - `docs/api/reference.md` — HTTP API reference
- **.cursor/rules/** — contextual rules per subsystem (activated automatically by Cursor/Copilot for matching files):
  - `router-pattern.mdc` — HTTP router structure
  - `tool-pattern.mdc` — agent tool implementation
  - `api-models.mdc` — APIModels.swift conventions
  - `core-service.mdc` — CoreService domain map
  - `sqlite-store.mdc` — SQLite C API patterns and migrations
  - `tests.mdc` — Swift Testing framework usage
  - `dashboard.mdc` — React/Vite dashboard conventions
  - `agent-runtime.mdc` — AgentRuntime actor architecture

## Source code map for self-repair

### Core executable (`Sources/sloppy/`)
| Area | Key files |
|---|---|
| HTTP transport & API routing | `Gateway/`, `Gateway/Routers/CoreRouter+HTTPRoutes.swift`, `Gateway/Routers/CoreRouterRegistrar.swift` |
| Service facade | `CoreService*.swift` (split by domain: Agents, Projects, Providers, Skills, etc.) |
| Agent prompt assembly | `Sources/SloppyRuntime/AgentPromptComposer.swift`, `Sources/SloppyRuntime/Resources/Prompts/en/partials/` |
| Agent session lifecycle | `Agent/AgentSessionOrchestrator.swift` |
| Skills system | `Agent/AgentSkillsFileStore.swift`, `Skills/BuiltInSkillCatalog.swift`, `Skills/AutoRouteCatalog.swift` |
| Tools catalog | `Tools/ToolRegistry.swift`, `Tools/AgentTools/` |
| Model providers | `Providers/` (OpenAI, Anthropic, Gemini, Ollama, OpenRouter, OpenCode) |
| Persistence (SQLite) | `SQLiteStore.swift`, `CorePersistenceFactory.swift`, `Storage/schema.sql` |
| MCP / ACP | `MCP/`, `ACP/` |
| Memory | `Memory/` |
| TUI | `TUI/` |
| CLI commands | `CLI/Commands/` |

### Shared libraries
| Module | Purpose |
|---|---|
| `Sources/Protocols/APIModels.swift` | All wire models — start here when a field is missing or mistyped |
| `Sources/AgentRuntime/RuntimeSystem.swift` | Session management, channel bootstrap, worker execution |
| `Sources/PluginSDK/` | Plugin contracts and model-provider bridge |

### Tests
| Suite | Location |
|---|---|
| Core API, router, persistence | `Tests/sloppyTests/` |
| Runtime, worker, Visor | `Tests/AgentRuntimeTests/` |
| Protocol coding/compat | `Tests/ProtocolsTests/` |
| SloppyNode | `Tests/SloppyNodeCoreTests/` |

### Dashboard (`Dashboard/src/`)
| Area | Path |
|---|---|
| API client | `shared/api/coreApi.ts` |
| Routing | `app/routing/` |
| Feature views | `features/` |
| Route views | `views/` |
| Styles | `styles/` |

## Build & verify commands

```bash
# Swift — full suite
swift test --parallel

# Swift — narrow filter
swift test --filter CoreRouterTests

# Release build — catch link/symbol errors
swift build -c release --product sloppy
swift build -c release --product SloppyNode

# Dashboard
cd Dashboard && npm run typecheck && npm run build
```

## Self-repair workflow

1. **Read AGENTS.md** first — check the relevant recipe section (endpoint, tool, DB column, dashboard view, SloppyNode behavior).
2. **Locate the failing layer** using the source map above. Use `files.read` on the key file for that subsystem.
3. **Check `.cursor/rules/<area>.mdc`** for authoritative conventions before editing.
4. **Check `Tests/`** for existing coverage and write or update tests for changed behavior.
5. **Verify** with the narrowest relevant command first, then the CI-parity suite.
6. **Do not add new frameworks** without strong justification. Prefer extending existing patterns.

## Common repair recipes

### Add or fix an API endpoint
1. Model → `Sources/Protocols/APIModels.swift`
2. Service method → correct `CoreService*.swift`
3. Router → `Sources/sloppy/Gateway/Routers/`
4. Test → `Tests/sloppyTests/`
5. Verify → `swift test --filter XxxTests` then release build

### Add or fix an agent tool
1. File → `Sources/sloppy/Tools/AgentTools/XxxTool.swift` (conform to `CoreTool`)
2. Register → `ToolRegistry.makeDefault()` in `Sources/sloppy/Tools/ToolRegistry.swift`
3. Test → `Tests/sloppyTests/`
4. Verify → narrow test then release build

### Add or fix a SQLite column / table
1. Schema → `Sources/sloppy/Storage/schema.sql` + migration in `CorePersistenceFactory.swift`
2. CRUD → `SQLiteStore.swift` inside `#if canImport(CSQLite3)` guard
3. Protocol → `Stores/PersistenceStore.swift`
4. Model → `Sources/Protocols/APIModels.swift` if crossing API boundary

### Add or fix a dashboard view
1. Component → `Dashboard/src/features/` or `Dashboard/src/views/`
2. Route → `dashboardRouteAdapter.ts`, `useDashboardRoute.ts`, `App.tsx`
3. API → `Dashboard/src/shared/api/coreApi.ts`
4. Verify → `npm run typecheck && npm run build`

## Key conventions to preserve
- **Swift**: 4-space indent, `actor` for shared mutable state, `throws` for recoverable errors, no force-unwrap in production paths.
- **Concurrency**: actor isolation over locks, async/await end-to-end, no shared mutable globals.
- **Agent behavior**: never classify intent by keyword matching — use typed API fields, structured model output, or explicit runtime events.
- **Dashboard**: 2-space JS indent, semicolons, double quotes, `async/await`, custom `.actor-team-search` dropdown (never native `<select>`).
- **Tests**: Swift Testing macros (`@Test`, `#expect`), deterministic, isolated, behavior-focused.
