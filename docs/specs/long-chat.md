# Long chat

Long chat is an opt-in, persistent session (`kind: long_chat`) per authenticated user and native-runtime agent. Ordinary chat modes and sessions remain available. The Dashboard entry is **Long chat**; Native exposes **Open long chat** above the composer. Child worker sessions are excluded from the top-level session listing.

The coordinator can discuss, read through explicitly permitted tools, save agent-local memory, and manage assignments. Core rejects writes, shell, unknown MCP tools and synchronous delegation before tool authorization or approval escalation. Worker tool scopes are calculated independently from the agent's original policy. `readOnly` defaults to whether the submitted resource list is empty. Read-only workers cannot use mutation or unknown-effect tools; mutating tasks need resource keys. Project scope supplies canonical project/checkout keys. Read-only tasks can run alongside mutations of the same resource. Recursive delegation, shared-memory writes and session messaging remain unavailable to workers.

`long_chat.delegate` accepts an `assignment` JSON string containing `requestKey`, `title`, `acceptanceCriteria`, and `tasks`. Each task has `key`, `title`, `objective`, `resourceKeys`, `dependsOn`, and optional `projectId`. Keys within an assignment must be unique and dependencies must form a DAG. The stable request key deduplicates delegation within its source message. Include exact links, paths, authorizations and relevant background in each objective; workers do not inherit the complete transcript.

Accepted messages and worker notifications use a persisted inbox. Delegation returns an assignment and task/attempt IDs immediately; session and runtime worker IDs appear when a queued task starts. Each conversation runs at most three workers. Resource locks span conversations, including workers waiting for input. The configured semantic model router evaluates individual worker turns, while the coordinator retains its own model selection.

Workers finish with `agent_delegate.finish`, including status, summary, evidence and artifact links. Plain text without a completed structured result is a failure. Completed results and input requests generate `long_chat_task` session events and separate coordinator turns. Repeated delivery uses stable event/response IDs. Clarifications are persisted and serialized after the current worker turn. Cancellation records its terminal state before stopping the session and runtime worker; resource locks are released after stopping. Retries retain previous attempts, with at most two automatic retries. Permission blockers and interrupted operations cannot be retried automatically.

A Core restart restores queued work and waiting input. In-flight operations are marked interrupted and require inspection/manual retry rather than replaying potentially completed external mutations. Assignment snapshots are supplied on every coordinator turn, independently of model context compaction. Long chat sessions and their worker histories are exempt from automatic session retention.

## API

- `POST /v1/agents/:agentId/long-chat`: atomically open/create the authenticated user's session. The legacy `userId` body field is ignored in favor of the authenticated identity, or `local` when identity auth is disabled.
- Existing session message POST: returns a receipt immediately for long chat; the server serializes coordinator turns.
- `GET /v1/agents/:agentId/sessions/:sessionId/long-chat`: assignments, tasks and attempts.
- `POST .../long-chat/cancel`: cancel all active tasks.
- `POST .../long-chat/tasks/:taskId/cancel` or `/retry`: manage one task.
- `POST .../long-chat/tasks/:taskId/messages`: clarification with `content` and optional `clientMessageId`.
- Existing child-session input-answer and approval APIs: answer the worker directly.

State is atomically stored under `workspace/long-chat/state.json`; conversations and detailed worker transcripts retain existing JSONL session storage. Corrupted state fails explicitly rather than replacing the assignment ledger with an empty one.

Telegram, Discord and TUI long-chat interfaces are deferred. ACP runtimes cannot enable this mode because their external built-in tools cannot be restricted by the Core coordinator policy.
