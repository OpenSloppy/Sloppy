# Persistent memory lifecycle

Sloppy uses two complementary layers. Curated markdown provides a compact, editable
profile and reference notes. The SQLite memory store provides scoped, searchable
records. Reading configuration or starting a session must never regenerate curated
markdown from database rows: the two stores have different ownership and contents.

## Reading

- `AgentCatalogFileStore` loads `USER.md` and `MEMORY.md`, including existing per-user
  overrides. These documents remain the source of truth for their content.
- `RuntimeSystem.persistentMemoryContext` adds a separate session-start snapshot of
  semantic/procedural records explicitly scoped to the agent and current project.
  It prioritizes identity/preferences, importance, and recency; the default combined
  budget is 6,000 characters, divided between scopes, with at most 24 entries per scope.
- Before a response, semantic recall searches the agent, explicitly associated
  project, and current channel. Ranked hits share the existing eight-hit/6,000-character
  response-context budget. Project association comes from session metadata.
- Other sessions' channel-scoped records are not promoted to agent memory. Other
  agents, unrelated projects, and global scopes are not added automatically.
- Workspace-private project `.meta/MEMORY.md` is loaded even if the project has no
  repository. A project's memory is independent of whether it contains source code.

The initial snapshot is intentionally bounded. Search/get tools remain available for
specific details. Historical facts are not instructions; current corrections take
precedence and changeable claims require verification.

## Debug diagnostics

Dashboard **Debug → Session Context Inspector** exposes bootstrap selection checks, automatic recall, and
`memory.search` / `memory.recall` queries for the selected session. Each record includes
the query, source, scope, requested limit, monotonic retrieval duration, returned IDs,
scores, result character count, and estimated tokens. Hybrid retrieval also reports
provider, embedding, keyword, and graph stage durations/candidate counts and provider
errors (type/code, without raw provider response bodies), including failures followed by local fallback. Bootstrap
checks report listing candidates and bounded selection; their scores represent importance.
They may reuse an existing bootstrap, so the actual model snapshot remains the source
for what was sent. SQLite recall logs now store
the measured latency and the IDs actually returned.

The latest native runtime turn has a separate snapshot captured after context
preparation, before streaming. It contains ordered instructions (including tool
definitions), retained history, tool calls/results, and the pending user prompt.
The automatic memory block records its retrieval operation ID, included IDs, text,
size, and token estimate. Returned matches can exceed the final injected selection.
Images are represented by IDs and MIME/byte-count or URL metadata, without copying
binary image data. The snapshot is a runtime input view, not a provider wire payload
or a trace of subsequent provider-internal tool-loop requests. External ACP sessions
without this native turn path have no captured model context.

Diagnostics are process-local: the runtime retains the newest 200 recall requests
across all sessions and the latest input for up to 16 sessions. Statistics apply only
to the retained requests for the selected session. Query/hit text previews are capped;
context previews retain up to 500 entries and 128,000 text characters, with at most
16,000 characters per entry. Original sizes and truncation flags remain visible.
Token estimates are labeled separately from provider-reported usage. Debug reads do
not trigger recall, modify memory, or reconstruct a prompt from current documents.
The existing debug endpoint includes `memoryDiagnostics` and `contextLedger`:
`GET /v1/debug/session-context/:agentId/:sessionId`.

## Writing and review

The foreground agent is instructed to save preferences, corrections, environment
constraints, conventions, and verified lessons when they become clear, including in
short conversations. Personal facts belong in the current user's documents. Reusable
agent/project facts use explicit corresponding scopes; channel scope is reserved for
conversation-local knowledge. Full-document tools must preserve useful existing notes.
`memory.save(memory_id: ...)` updates the existing scoped record when a user corrects
a fact, retaining its ID and avoiding contradictory duplicates.

Background checkpoints retain the existing triggers (eight user turns, compaction,
explicit request, session transitions, and project task events). They read the current
user's documents and review the newest transcript within the existing budget, excluding
private thinking segments. The model receives only the checkpoint tool allowlist;
the invocation boundary independently enforces the same list. Ephemeral channel cleanup
also removes this allowlist and project association.

## Hermes comparison (local source inspection, 2026-09-05)

Hermes separates bounded `MEMORY.md` and `USER.md`, loads frozen prompt snapshots, and
supports add/replace/remove operations with live state returned by the memory tool.
Its `agent/system_prompt.py`, `agent/prompt_builder.py`, `agent/turn_context.py`, and
`agent/background_review.py` show proactive memory guidance plus a background review
triggered by a turn counter (default ten). Session history search and reusable skills
complement the small core memory.

Sloppy already had markdown, searchable storage, and checkpoints. The main gaps were
in the connections: database export overwrote curated markdown; automatic retrieval
searched only the current channel; checkpoint truncation discarded recent corrections;
checkpoint reads used root documents while writes could target a user override;
and projects without repositories lost their markdown on the read path.

## Verification boundary

Regression tests cover curated-file survival across config reads and new sessions,
agent/project recall in a fresh session, exclusion of unrelated scopes, bounded
snapshots, newest-transcript retention, project memory without a repository, and
retrieval after reopening SQLite. These establish the storage/context contract.
They do not measure how often a real model chooses to save or whether its summaries
are useful. That requires a live multi-session evaluation with user corrections,
project decisions, a fresh session, and checks for accurate reuse without prompting.

Validation on 2026-09-05: 33 focused tests passed, including checkpoint scheduling.
Release builds of `sloppy` and `SloppyNode` passed; `sloppy --version` and
`SloppyNode --help` launched successfully. The full parallel suite was attempted
with loopback access and stopped after failures in project-file fallback, review
settings, and Mesh authorization tests; it did not produce a completed suite result.
No live-model learning-quality measurement was performed.
