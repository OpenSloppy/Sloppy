# Agent Sessions, Tools, and Chat Spec

## 1. Document Status
- Version: `0.1`
- Date: `2026-06-03`
- Status: `Draft for product and implementation alignment`
- Owners: `sloppy`, `Dashboard`, `TUI`
- Primary code areas: `Sources/sloppy/CoreService+Agents.swift`, `Sources/sloppy/CoreService+Sessions.swift`, `Sources/sloppy/Tools/*`, `Sources/sloppy/Gateway/Routers/AgentsAPIRouter.swift`, `Dashboard/src/views/ChannelSessionView.jsx`, `Dashboard/src/features/agents/AgentsView.tsx`

## 2. Product Context
Agent sessions are the main conversational execution surface in Sloppy. A session binds an agent, a workspace directory, model/provider settings, tool policy, transcript, attachments, runtime status, and live stream updates into one durable operator-visible conversation.

## 3. Goals
1. Support project-aware chat with agents from Dashboard, TUI, CLI, and channel gateways.
2. Keep tool-driven execution observable, policy-controlled, and recoverable.
3. Allow agents to request structured input instead of guessing when blocked.
4. Support session lifecycle operations: create, list, inspect, send message, control, delete, and checkpoint memory.
5. Provide a single API contract for UI and automation clients.

## 4. Non-goals
1. Guaranteeing identical behavior across all model providers.
2. Persisting unlimited transcripts forever.
3. Exposing unsafe tool execution without authorization policy.
4. Making sessions a replacement for project tasks; sessions may be linked to tasks but remain a chat/execution primitive.

## 5. Core Concepts
| Concept | Description |
| --- | --- |
| Agent | Configured persona/runtime profile with model, tools, skills, memory, and provider settings. |
| Session | Durable conversation instance for one agent and optional project/directory context. |
| Tool catalog | Available tools exposed to the model after policy filtering. |
| Tool policy | Allow/deny/approval rules for individual tools or tool groups. |
| Input request | Structured pause where the agent asks the operator to choose options or provide notes. |
| Stream update | Server-sent incremental state for messages, token usage, tool calls, and status. |

## 6. Functional Requirements

### FR-1: Agent management
- Operators can list, create, inspect, configure, and delete agents.
- Agent configuration includes model/provider settings, prompts/documents, skills, tool policies, and UI metadata such as pet/avatar where enabled.

### FR-2: Session lifecycle
- Operators can create sessions for an agent, list recent sessions, fetch full detail/history, and delete sessions.
- Sessions can carry current working directory and attachment context.
- Session IDs must be resolvable across Dashboard, TUI, and CLI.

### FR-3: Message execution
- Clients can post user messages into a session.
- Runtime appends user, assistant, tool, and system/control events to the transcript.
- Agent execution status should distinguish idle, running, waiting for input, failed, and completed/ready states.

### FR-4: Streaming
- Clients can subscribe to a session stream.
- Stream updates should be incremental and replay-tolerant.
- If streaming disconnects, clients can reload session detail as a fallback.

### FR-5: Tool invocation and approval
- Coding-specific mutation, diagnostics, output retention, and recovery requirements are defined in [Coding Harness Reliability](coding-harness.md).
- Tool catalog is generated from built-ins, MCP servers, skills, and plugin-provided tools.
- Tool policy is enforced before invocation.
- Dangerous or configured tools can create approval records; approved/rejected decisions are visible to the session.
- Tool loop guards prevent runaway repeated calls.

### FR-6: Input requests
- Agent can pause with structured questions and options.
- Clients answer by request ID.
- Answer is added to transcript and resumes execution when possible.

### FR-7: Control operations
- Clients can send session control messages such as continue/cancel/fail where supported.
- Control events must be persisted and visible in stream/history.

### FR-8: Memory checkpoint
- Operators can request a memory checkpoint for a session with a reason.
- Checkpoint stores compact facts in the configured memory scope without leaking oversized transcripts.

## 7. Public API Surface
Representative endpoints:
- `GET /v1/agents`
- `POST /v1/agents`
- `GET /v1/agents/{agentId}`
- `GET /v1/agents/{agentId}/config`
- `PUT /v1/agents/{agentId}/config`
- `GET /v1/agents/{agentId}/sessions`
- `POST /v1/agents/{agentId}/sessions`
- `GET /v1/agents/{agentId}/sessions/{sessionId}`
- `POST /v1/agents/{agentId}/sessions/{sessionId}/messages`
- `GET /v1/agents/{agentId}/sessions/{sessionId}/stream`
- `POST /v1/agents/{agentId}/sessions/{sessionId}/input-requests/{requestId}/answer`
- `POST /v1/agents/{agentId}/sessions/{sessionId}/control`
- `POST /v1/agents/{agentId}/sessions/{sessionId}/checkpoint`
- `GET /v1/agents/{agentId}/tools/catalog`
- `PUT /v1/agents/{agentId}/tools`
- `POST /v1/agents/{agentId}/tools/invoke`

## 8. Dashboard UX
1. Agent list shows configured agents and system agents when allowed.
2. Chat surface shows transcript, running state, tool calls, approvals, input requests, and errors.
3. Directory/attachment controls make current workspace context visible before sending.
4. Tool approvals are actionable from notifications and session context.
5. Token usage and provider status should be visible enough for debugging cost/performance issues.

## 9. Edge Cases
- A deleted agent with existing sessions should either preserve read-only session history or clearly report that the agent no longer exists.
- If provider credentials expire during a run, the session should fail with actionable provider status.
- If a tool approval is rejected, execution should receive a structured denial result rather than hanging.
- Attachment paths must be workspace-safe and not escape configured roots.
- Concurrent messages to a running session must be queued, rejected, or routed by a documented policy.

## 10. Acceptance Criteria
1. A user can create an agent session, send a message, watch streamed progress, and reload the session after refresh.
2. A tool requiring approval blocks, creates an approval request, and resumes or fails cleanly after decision.
3. An input request can be answered from Dashboard or API and appears in history.
4. Tool policy changes affect the exposed catalog before the next run.
5. Session checkpoint stores a compact memory entry and reports success/failure.

## 11. Tests / Verification
- Backend: agent CRUD, session file store, transcript builder, tool registry, tool approvals, loop guard, input requests, token usage.
- Dashboard: session status rendering, notification navigation, chat timeline composition.
- Manual: run a session with a file tool call, approval, input request, and memory checkpoint; reload UI and verify continuity.

## Agent collaboration and session mentions

`sessions.list` accepts `scope: current|all` (default `current`), optional `agentId`, `projectId`, `query`, `limit` (default 50, max 500), and `offset`. It includes worker sessions. `sessions.history` and `sessions.status` accept an optional target `agentId`; another agent requires an explicit `sessionId`. History defaults to the last 100 events, accepts `limit` up to 500 and `beforeEventId`, and returns `hasMore` and an earlier-page cursor alongside the existing detail fields.

`messages.send` (alias `sessions.send`) accepts `agentId`, `sessionId`, `content`, and optional UUID `messageId` for retries. It returns an immediate receipt with the message ID, target and delivery state. Sender provenance is assigned by Core from the invoking agent/session; a `userId` argument cannot impersonate a human. The recipient processes the message after its current turn. Pending approval/input is not answered or bypassed by a peer message. Queued messages are excluded from restored model context until their turn starts. Self-messaging is rejected; the current session can respond directly. Replies use an explicit send; ordinary assistant output stays in the recipient's session.

Ordinary sessions use the atomic `session-messages/inbox.json` queue; Conversations and their active workers use their existing durable inbox. Retries with the same message ID do not add another message; conflicting payloads fail. On restart, queued messages resume and messages that were processing are marked interrupted instead of replayed. Peer message chains retain server provenance across sessions and allow at most eight deliveries. User interruption cancels pending ordinary-session deliveries.

A completed worker can answer a peer in a separate communication turn in the same session. Core limits that turn to previously permitted reading and session communication, without shell, writes, recursive delegation, task completion, task reopening or resource locks. Ordinary delegated workers persist their original tool overlay in `session-messages/worker-scopes.json`. Legacy completed workers without a saved overlay can only inspect session history/status and exchange messages. Missing Conversation assignment state fails explicitly.

Native and Dashboard `@` suggestions include Sessions, Files and Skills. Session rows show title, agent, project and a short ID; current-project rows sort first within the search results. Selecting a session inserts `[@Title](sloppy://session?agent=AGENT&id=SESSION)`. The address uses IDs and the current connection, so duplicate titles and later renames are safe. Clicking opens the target session. Selecting or mentioning it does not send it a message.

Message requests and persisted messages optionally carry `sessionReferences: [{agentId, sessionId}]`; canonical links pasted into message text are also recognized. Before the model turn, Core adds title, agent, state, and the last six messages, limited to 800 characters per message, 6,000 characters per reference and 18,000 characters overall. Both native and ACP execution receive this context. Missing/deleted references are reported as unavailable without rejecting the rest of the message. The model can read earlier history with `sessions.history`. Peer messages and reference excerpts are contextual evidence, not user authorization; their provenance survives transcript restoration. Older messages decode without the optional collaboration fields.

`GET /v1/agent-sessions` retains its ordinary listing by default and accepts `includeWorkers=true`, `query`, `agentId`, `projectId`, `limit` and `offset` for mention search.
