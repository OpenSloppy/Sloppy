---
layout: doc
title: Agent memory
---

# Agent memory

Sloppy gives agents two complementary ways to remember: a **hybrid memory store** (SQLite-backed, searchable entries) and **markdown documents** on disk (`USER.md`, `FRIEND_REMINDER.md`, `MEMORY.md`, and optional project `.meta/MEMORY.md`). Together they let an agent keep facts, preferences, and narrative context across sessions and restarts.

This page describes how both layers work, how they show up in the Dashboard, which tools update them, and how **memory checkpoints** refresh long-form `MEMORY.md` without polluting the chat.

## Two layers: hybrid store vs markdown files

| Layer | What it is | Where you see it |
| --- | --- | --- |
| **Hybrid memory** | Structured entries (note, summary, kind, class, scope, edges). Indexed for recall and search. | **Memory → Memories** tab (list and graph). SQLite in your workspace. |
| **Agent markdown** | Plain files in the agent catalog: `USER.md` (identity/instructions), `FRIEND_REMINDER.md` (short per-turn reminders), `MEMORY.md` (long-form narrative the model reads). | **Memory → Memories** for `MEMORY.md`; **Agents → Agent files** for other documents. Files under `.sloppy/agents/<agent>/` on disk. |
| **Project meta memory** | Optional workspace-private `.meta/MEMORY.md` under `~/.sloppy/projects/<projectId>/.meta/MEMORY.md`. | On disk; updated via tools when the agent targets a project. |

These are **not** the same list: saving a hybrid entry does **not** automatically rewrite `MEMORY.md`, and editing `MEMORY.md` does **not** create hybrid rows unless a workflow explicitly does both.

## Import memory from another assistant

Open **Memory → Memories**, choose the destination agent, and select **Import memory**. Copy the export prompt, send it to the previous assistant, then upload its `.md` or `.markdown` files. Inputs must be UTF-8 text: up to 20 files, 1 MB per file and 5 MB total. The destination agent needs a configured native model.

Import is a durable background job. The server copies the inputs into the workspace's `memory-imports` archive before acknowledging the job. The archive is independent of session attachments and survives deletion of the original file or chat. It contains complete source snapshots; deliberately deleting the archive or workspace data also removes that evidence.

The server divides every source into bounded UTF-8 parts and processes small batches. A model extracts self-contained facts with evidence quotes and explicit dispositions for every part. A separate model session reviews each batch for omitted details, unsupported claims, unjustified discards and provenance text in notes. Missing coverage or a rejected review causes another extraction attempt; after three unsuccessful attempts the job reports a concrete error and retains its progress. A model's free-form final answer cannot complete or stop the worker.

Accepted decisions are checkpointed before writing. Each write has a stable import item key and is checked in canonical storage and scoped recall. Retries recover previously saved items instead of recreating them. A job reaches **completed** only after every source part has a reviewed disposition and all its writes are verified. Configured memory providers and embeddings still use the existing hybrid retrieval pipeline.

The Dashboard displays verified coverage, saved records, duplicates, excluded parts and errors. **Coverage report** shows each part's disposition, reason and record IDs. **Resume remaining work** continues failed/cancelled jobs from their checkpoints; queued/running jobs resume when the server restarts. Cancellation stops further work while preserving the source archive and confirmed progress.

To upgrade an earlier manual import, use **Continue previous import from saved attachments**, or ask in that same chat: `Use @memory-import to import these attachments completely`. The skill invokes `memory.import` and the server checks earlier records as possible duplicates. For local files, use `memory.import` with `operation: start` and `paths`; local paths must be readable in the agent's permitted roots. The job imports into the current agent's scope and does not silently substitute that scope for a requested project/global import.

New notes contain the knowledge itself. Filename, SHA-256 hash, evidence quote and byte range are stored as metadata. **Open archived source** reads the snapshot through the authenticated API; an agent can use `memory.source(memory_id: ...)`, which starts near that record's evidence. Reviewed duplicate relationships also connect legacy records to the new archive without rewriting their existing text. A note remains usable by recall without opening its source.

The API exposes start/list/get/resume/cancel under `/v1/agents/:agentId/memory-imports`, migration under `/from-session/:sessionId`, and archived source reads under `/:jobId/sources/:sourceId`. Only the worker can mark a job complete; no agent-facing completion operation exists. `USER.md` and `MEMORY.md` remain separate from imported searchable entries.

## Recovering from invalid memory arguments

For a new record, omit `memory_id` or pass null. Empty and whitespace-only IDs also create a record. A nonempty ID always means update: an unknown ID, or an ID belonging to another scope, fails without creating a replacement.

Memory argument errors include `argumentRecovery.invalidFields` and optional contextual field names, plus a hint. The runtime checks those fields instead of the entire note: changing the note while retaining an invalid ID cannot bypass the guard. A corrected request can proceed, but a second failure in the same argument-error family exhausts the single correction attempt and returns `tool_loop_detected`.

In the native runtime, loop detection stops the current model turn, reports an interrupted run, and suppresses automatic completion/empty-response retries. Already completed operations are retained. A new user turn resets the argument-correction budget; automatic goal turns do not. Independent scopes have separate correction budgets.

## Character limits (markdown files)

The API and tools enforce size limits (character counts) on bundled agent documents:

| Resource | Limit (characters) |
| --- | ---: |
| `USER.md` | 2000 |
| `FRIEND_REMINDER.md` | 2000 |
| `MEMORY.md` (agent) | 3000 |
| `.meta/MEMORY.md` (project) | 3000 |

If generated or submitted text exceeds a limit, the update may be rejected or skipped with a warning—avoid treating markdown files as unlimited storage.

## Dashboard: Memory

For retrieval diagnostics, open **Debug → Session Context Inspector**, choose an
agent and session, and inspect **Memory requests** and **Model context**. The view
refreshes every five seconds. It shows bootstrap selection checks, the query and scope, mean/p95 latency,
hit rate, backend failures, individual stage timings, returned records, and the memory
text actually inserted into the latest native model turn. Expand context entries to
inspect the prepared instructions, tool definitions, retained history, and user prompt.
`MEMORY.md` is also included in the document size breakdown.

Metrics cover a bounded process-local buffer (200 requests across sessions), reset on
restart, and do not include older persisted requests. Context snapshots show the start
of the latest native turn; provider-internal follow-up requests and external ACP inputs
are not captured. Token counts are estimates; long previews are explicitly marked as
truncated. Inspecting this screen does not run another memory search.

- **Overview** — shows the saved provider, embedding and Autodream configuration and the total number of active records.
- **Memories** — browses all records, shared memory, or a selected agent/project. Agent and project scopes retain their list and graph views. Agent scope also exposes the separate read-only `MEMORY.md` document and Markdown import.
- **Dreams** — configures Autodream scheduling and its model.
- **Settings** — configures the memory provider, retrieval weights, retention, maintenance, merging and embeddings. These settings use the existing runtime configuration and Apply action.

Old `/agents/:id/memories` and `/projects/:id/memory` links open the new Memory section with the same scope.
- **Agent files → `FRIEND_REMINDER.md`** — a user-editable short reminder appended to every runtime user turn when non-empty. It is meant for tactical, current constraints rather than unlimited memory.
- **Memory → Memories → agent scope → `MEMORY.md`** — often labeled as **auto-generated** or read-only in the UI when the server maintains that file from checkpoints or refresh logic. Prefer updating via **`agent.documents.set_memory_markdown`** (or checkpoints) rather than expecting ad-hoc hybrid saves to appear here.

::: tip
`memory.search` and `memory.recall` / `memory.get` **only read** the hybrid store. They do not create rows and do not edit `MEMORY.md`.
:::

## Scopes and the Memories list

Hybrid entries are **scoped**. The **Memory → Memories** view defaults to all scopes, including shared memory. Choosing an agent restricts the list to entries that belong to **this agent**:

- **`agent`** scope with id equal to the agent id, or  
- **`channel`** scope whose channel id looks like `agent:<agentId>:session:<sessionId>`.

Entries saved as **`global`** (or other scopes that do not match the rules above) **do not** appear under that agent’s Memories tab, even though they exist in the database.

## Tools (runtime)

Agents use tools to read and write memory. Policy may hide some tools depending on configuration.

| Tool | Purpose |
| --- | --- |
| `memory.save` | Create a hybrid memory entry. **You must set scope** (see below). |
| `memory.search` | Keyword search over the index. |
| `memory.recall` / `memory.get` | Semantic-style recall with a query. |
| `agent.documents.set_user_markdown` | Update `USER.md` (validated limits). |
| `agent.documents.set_memory_markdown` | Update agent `MEMORY.md` (validated limits). |
| `project.meta_memory_set` | Write workspace-private project `.meta/MEMORY.md`; no repo path is required. |
| `visor.status` | Read Visor readiness and latest bulletin digest (operational snapshot, not a substitute for long-term hybrid memory). |

Direct **`files.write` / `files.edit`** on agent `USER.md` / `MEMORY.md` paths are blocked—use the `agent.documents.*` tools instead.

### `memory.save` and scope

The **caller (the model)** must attribute every save:

- Either **`scope_type` + `scope_id`** together, or  
- A **`scope`** object with **`type`** and **`id`** (and optional `channel_id`, `project_id`, `agent_id` when needed).

Examples:

- Current chat, visible under **Memories** for this agent:  
  `scope_type: channel`, `scope_id: agent:<agentId>:session:<sessionId>`
- Agent-wide fact:  
  `scope_type: agent`, `scope_id: <agentId>`

Omitting scope causes the call to fail validation—there is no silent default to “this session”.

## Memory checkpoints (shadow)

A **checkpoint** is a background pass that can refresh **`MEMORY.md`** (and optionally project meta memory) using a dedicated model turn on an **ephemeral channel**, so tool calls do **not** append to the visible chat transcript. Tool invocations during a checkpoint do **not** write tool-call rows into the session JSONL as normal user-visible events.

Typical triggers include:

- Starting a **new session** with a reference to the previous session id (e.g. Dashboard **New session** / `/new` flow).  
- **Stopping** generation (e.g. `/stop`) when the client requests a checkpoint before interrupt.  
- After enough **user turns** since the last checkpoint (server-side counter; resets after a successful checkpoint).  
- **Context compactor** threshold events for agent session channels.  
- **Gateway** channel sessions closed by inactivity (when the channel id maps to an agent session).

Checkpoints use an allowlisted set of tools (for example Visor status, agent document setters, project meta memory). They are designed to consolidate durable facts into markdown files rather than spamming hybrid entries.

## How hybrid memory works (recap)

When something worth remembering happens, a hybrid entry can be created with a note, optional summary, kind, class, scope, and metadata. Entries live in **SQLite** in your workspace. Retrieval blends semantic, keyword, and graph signals when embeddings and graph edges are available—see [Configuration reference](#configuration-reference).

### What a memory represents (kind)

| Kind | What it is |
| --- | --- |
| Fact | General knowledge: names, versions, tech choices |
| Preference | What the user prefers or avoids |
| Goal | An objective the agent or user is working toward |
| Decision | A choice that was made and should be remembered |
| Todo | An action item |
| Identity | Who the agent is working with |
| Event | Something that happened at a point in time |
| Observation | Something the agent noticed |

Kinds can be inferred from text or set explicitly on save.

### How long a class lives (memory class)

| Class | Role | Default lifespan |
| --- | --- | --- |
| Semantic | Long-term knowledge | No automatic expiry |
| Procedural | Goals, decisions, todos | No automatic expiry |
| Episodic | Time-bound events | 90 days (configurable) |
| Bulletin | System / Visor digests | 180 days (configurable) |

### Scope types (hybrid)

| Scope | Typical use |
| --- | --- |
| Global | Shared across many contexts (does **not** show on a single agent’s Memories tab unless you filter elsewhere). |
| Project | Scoped to one project |
| Channel | One channel id (for agent chat, use `agent:…:session:…`) |
| Agent | One agent id |

## How recall works

Sloppy combines **semantic** search (when embeddings or an external provider is configured), **keyword** search (SQLite FTS), and **graph expansion** over linked entries. Weights are configurable under `memory.retrieval`—defaults favor semantic recall. See the table below.

## Memory relationships

Entries can link to each other (support, contradict, derive, supersede, and so on). Branch conclusions and merges can create or update links so future recall surfaces related context.

## Automatic maintenance

Decay, pruning, and optional merge runs are driven by **Visor** on a schedule. Bulletins and merge behavior are described in [Visor: memory and bulletins](/visor/memory) and [Visor overview](/visor/overview).

## Connecting an external memory service

You can use **local embeddings**, an **HTTP** provider, or an **MCP** provider while keeping SQLite canonical. See the configuration keys below.

## Configuration reference

All memory settings live under the `memory` key in `sloppy.json`.

### Provider settings (`memory.provider`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `mode` | `local` | Where semantic indexing happens: `local`, `http`, or `mcp` |
| `endpoint` | — | URL of the external HTTP memory service (required for `http` mode) |
| `mcpServer` | — | ID of the MCP server to use (required for `mcp` mode) |
| `timeoutMs` | `2500` | Timeout in milliseconds for external provider calls |
| `apiKeyEnv` | — | Name of the environment variable holding the API key for the HTTP provider |

### Retrieval weights (`memory.retrieval`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `topK` | `8` | How many results to return per recall query |
| `semanticWeight` | `0.55` | Weight for semantic / vector search |
| `keywordWeight` | `0.35` | Weight for full-text keyword search |
| `graphWeight` | `0.10` | Weight for graph-expanded neighbors |

### Retention (`memory.retention`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `episodicDays` | `90` | Episodic memory retention |
| `todoCompletedDays` | `30` | Completed todo retention |
| `bulletinDays` | `180` | Bulletin retention |

### Embeddings (`memory.embedding`)

| Setting | Default | What it controls |
| --- | --- | --- |
| `enabled` | `false` | Compute and store local vectors |
| `model` | `text-embedding-3-small` | Embedding model id |
| `dimensions` | `1536` | Vector size (must match the model) |
| `endpoint` | — | Embeddings API URL |
| `apiKeyEnv` | — | Env var for the embeddings API key |

## Related

- [Visor: memory and bulletins](/visor/memory) — bulletins vs hybrid memory, maintenance, `visor.status`
- [Context compactor](/agents/context-compactor) — compaction thresholds (checkpoint trigger)
- [Visor overview](/visor/overview) — supervision, bulletins, dashboard
