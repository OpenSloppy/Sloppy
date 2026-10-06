# Coding Harness Reliability

- Date: `2026-10-06`
- Status: implementation complete; validation limitations recorded below
- Scope: Core tools, LSP, model-facing results, coding workers
- Related: [Agent Sessions, Tools, and Chat](agent-sessions-tools-chat.md)

## Purpose

Make coding work safer and easier to verify without replacing Sloppy's runtime,
worker scopes, or approval flow. Adopt the useful execution patterns from OpenCode
within Sloppy's Swift service boundaries. Behavioral decisions use typed fields,
never localized assistant prose.

## Delivery order

1. Safe file mutations: ambiguity checks, optimistic content hashes, serialized
   read/modify/write transactions, bounded diffs.
2. Automatic LSP feedback after successful edits and writes.
3. Durable tool output artifacts with bounded model-facing previews.
4. Artifact-aware context pruning before summarization, with active-model budgets.
5. Typed execution outcomes and reconciliation of interrupted calls.

Items 1–5 are implemented. Context and recovery checks are being validated in the second implementation slice.

## Safe file mutations

- `files.edit` and `files.write` share a service-owned mutation coordinator across
  all sessions and workers. Transactions serialize by canonical file path and
  atomically replace file contents. Independent paths may execute concurrently.
- `files.edit` rejects multiple matches with `ambiguous_match`, including a bounded
  list of candidate line positions. `all=true` explicitly permits multiple edits.
- Both tools accept optional `expectedContentHash` (SHA-256 of raw UTF-8 bytes).
  A mismatch returns `file_changed` without writing. Existing callers may omit it.
- A complete `files.read` returns `contentHash`; partial reads do not advertise a
  full-file hash. Successful mutations return the resulting `contentHash`.
- Mutations return a bounded diff, additions/deletions, and `diffTruncated`.
- Directory errors, write limits, protected agent documents, path permissions,
  and existing approval requirements remain enforced.
- No fuzzy text matching. Arbitrary shell/MCP writes and edits by other processes
  are outside the coordinator; hashes detect prior external changes, not all OS
  races. Future patch tools must use the same coordinator.

## LSP feedback

- After a successful mutation, synchronize the document with the matching
  configured server (`didOpen` first, then versioned `didChange`).
- Cache `publishDiagnostics` by document URI and version. Do not return an older
  diagnostic result as feedback for a newer edit.
- Add `diagnostics` to mutation results: `status` (`ready`, `pending`,
  `unavailable`), document version, bounded items with severity, message, file,
  line and character, and a truncation flag.
- Empty diagnostics are verified only when a current publication was received.
  No configured server or a server failure means `unavailable`; a bounded wait
  without current diagnostics means `pending`. The write still succeeds.
- LSP feedback does not count as build/test verification evidence. Explicit
  verification commands remain necessary where the task requires them.

## Tool output artifacts

- Preserve foreground process stdout/stderr to session-owned files while reading
  the pipes, before applying in-memory preview limits. Drain both streams fully.
- Return existing stdout/stderr fields and truncation flags for compatibility,
  plus artifact references and actual byte counts. Artifacts are UTF-8/binary raw
  output files, not model-generated summaries.
- ToolExecutionService also bounds large text fields in object-shaped built-in and MCP result payloads,
  retaining the full JSON payload as an artifact before returning a preview.
  Preserve `ok`, typed errors, and non-text verification metadata. Array-shaped
  catalogs and non-text payloads retain their schema; broader payload budgeting
  is part of the context work in item 4.
- Artifacts live under `.sloppy/tool-outputs/<agent SHA-256>/<session SHA-256>`, use generated names,
  and remain readable through the same session's file-read policy. They do not
  grant access to another session or expand writable roots.
- Artifact write failures are visible in result metadata; never claim a complete
  saved output when capture failed. Execution must not be silently repeated.
- Retain artifacts for seven days; cleanup must not remove active captures or
  follow symlinks outside the artifact directory. Client log viewers are a later
  UI slice; the initial contract supports scoped `files.read`.

## Model-visible context and compaction

- Persisted JSONL remains the complete audit history. Only the SDK transcript copy
  sent to the model is transformed.
- Before a model turn, estimate instructions, tool schemas, transcript, current
  user request and image placeholders. Reserve output capacity before deciding
  whether the model can accept the input.
- ModelProvider exposes optional numeric ModelContextLimits. Core model rows can
  set `contextWindowTokens`, `maxInputTokens`, and `maxOutputTokens`; routing uses
  the selected model's exact identifier. Unknown limits fall back to the configured
  compactor window, never guesses based on the model name.
- Native client configuration and Dashboard normalization retain these optional
  numbers when saving existing model rows. No new model settings UI is required.
- First replace old large tool outputs with existing complete artifact references,
  preserving `ok`, errors, verification evidence IDs, exit codes and pending-state
  metadata. If no artifact exists, archive the full result before pruning it.
- Keep instructions, the latest two user requests, recent entries, unresolved calls,
  and call/result pairs. In a long single coding turn, older completed results may
  be pruned while the original request remains verbatim.
- Summarization runs without tools and treats the history as data. Preserve goals,
  constraints, decisions, changed files, evidence IDs, artifact paths and approvals.
  The summarizer request and its result must also fit the same input/output limits.
- A protected context that cannot fit, missing archive, or failed summary produces
  an explicit context failure. Overflow recovery never silently resets to only the
  bootstrap prompt and replays the task without its known evidence.
- Context accounting records the prepared transcript and selected-model capacity.
  Preparation exposes before/after estimates, pruned output count and summary use.

## Typed execution and recovery

- `AgentRunStatusEvent.executionOutcome` and
  `AgentToolResultEvent.executionOutcome` are optional for legacy JSONL compatibility.
  States: completed, failed, cancelled, waiting_input, waiting_approval, interrupted.
  Failures carry category, code, retryability and reconciliation requirements.
- Worker runner results carry this outcome explicitly. Display text such as
  `Model provider error:` or `Everything is ready` cannot alter execution state.
  Missing runner results fail; they never complete the worker using its objective.
- Runtime exit reasons and explicit completion records determine terminal states.
  Approval presentation records waiting_approval without parsing UI labels.
- Tool results carry optional `callEventId`, supporting out-of-order completion of
  parallel calls. Legacy events without it retain FIFO matching by tool name.
- On recovering an inactive session, append a durable interrupted result for each
  unmatched call. It records unknown side effects and `retryable=false`; retain
  the call and its typed result in the reconstructed model transcript.
- Exact replay of an unresolved/interrupted call is blocked before side effects.
  Inspection with different read requests remains possible. A known completed or
  failed reconciled mutation is also not automatically repeated.
- Owner-facing endpoint:
  `POST /v1/agents/{agentId}/sessions/{sessionId}/tool-calls/{callEventId}/reconcile`.
  Body: `decision` (not_executed/completed/failed) and nonempty inspection `evidence`.
  It only records evidence; it never executes a tool. It is not an agent tool.
  Only confirmed not_executed releases the exact-replay block. Other decisions
  record known outcomes without granting another execution.
- Reconciliation is scoped to the original agent/session/call and rejects active
  or already reconciled calls. Recovery remains idempotent across repeated loads.

## Acceptance checks

- Ambiguous edits and stale hashes leave bytes unchanged.
- Concurrent edits to the same file retain both independent changes; concurrent
  hash-guarded writes produce one success and one `file_changed`.
- Relative paths and symlink aliases share the canonical transaction.
- Fake LSP integration proves didOpen/didChange ordering, current versioned
  errors, empty diagnostics, and pending/unavailable outcomes.
- Output exceeding preview limits remains byte-for-byte available in artifacts,
  including final pipe data, stderr, timeout output, and UTF-8 boundaries.
- Oversized MCP outputs retain typed errors and verification fields, and artifacts
  cannot be read by another session through the tool policy.
- Compare identical coding tasks on the same model after implementation: solve
  rate, retries, token usage, and conflicting mutations. Unit/integration tests
  are not a live-model quality benchmark.

## Validation boundary

- First-slice platform: macOS arm64, Apple Swift 6.2.4.
- Second slice: 134 focused tests in 7 suites pass, including the actual SDK
  transcript preparation path, result correlation, owner reconciliation and
  approval compatibility. Dashboard typecheck/build and model-limit round-trip
  checks pass; the native ModelConfig round trip is verified independently.
- Verification uses the first slice's isolated snapshot plus an audited phase-2
  patch. Concurrent chat/Visor changes remain preserved in the shared checkout.
- Optimized SloppyNode builds successfully. The full Swift suite and optimized
  sloppy dependency-resolution limitations are recorded in the phase-2 report.
- 76 focused tests in 12 suites pass, including 16 coding-harness scenarios.
- Checks use an isolated snapshot of commit `89aeb6834b427ad90825a15657de5d31824f093c`
  plus this task's patch, excluding unrelated concurrent session-messaging work.
- Full-suite and release-build results are recorded in the task validation report;
  focused tests alone do not establish that the full repository is green.
- The running Core was not restarted. Live-model coding quality and native-client
  log-viewer behavior have not been verified by these checks.

## References

- [OpenCode edit](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/edit.ts)
- [OpenCode output truncation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/truncate.ts)
- [OpenCode compaction](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/compaction.ts)
- [OpenCode processor](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/processor.ts)

These references describe the inspected `dev` implementation; they are not an
assertion of feature availability in a particular released OpenCode version.
