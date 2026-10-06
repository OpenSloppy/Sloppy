# Runtime

The Sloppy runtime is the orchestration layer that receives messages, decides what to do with them, and coordinates all the work that follows — model calls, background tasks, memory updates, supervision, and event emission. It runs as a set of isolated concurrent actors that each own one responsibility.

## Core components

| Component | What it does |
|---|---|
| **Channels** | Holds message history, estimates context usage, decides how to respond |
| **Workers** | Executes background tasks: coding, research, file operations, compaction |
| **Branches** | Focused sub-task forks that load relevant memory before working |
| **Compactor** | Monitors context usage and triggers summarization when needed |
| **Visor** | Supervises everything: timeouts, health signals, memory maintenance, bulletins |
| **Event Bus** | Internal pub-sub that connects all components and exposes activity to subscribers |
| **Memory** | Stores and recalls knowledge across sessions |

All of these are coordinated through a single entry point. The HTTP service layer talks to this entry point; everything downstream is handled internally.

## How a message is processed

When a message arrives in a channel, the runtime:

1. Appends it to the channel's message history.
2. Estimates how full the context window is.
3. Decides how to respond (inline reply, spawn a branch, or spawn a worker).
4. Executes the response path.
5. Checks whether context compaction should run.

After the response is sent, the compactor evaluates the updated context usage and schedules a summarization job if a threshold has been crossed.

## Channels

A channel is the container for a conversation. The runtime keeps the full message history in memory, along with the set of active workers attached to that channel and the current context utilization estimate.

When responding inline, the runtime assembles a prompt from the last 80 messages in the channel and injects the latest memory bulletin (a Visor-generated digest of the agent's current context) as additional background. This means the model has both the recent conversation and relevant long-term memory available on every response.

## Workers

Workers are the runtime's unit of asynchronous work. When a task is too complex to answer inline — a coding task, a research job, a file operation — the runtime creates a worker and hands it a task specification: what to do, which tools to use, and how to behave when done.

### Worker modes

**Fire-and-forget** — the worker runs to completion without waiting for external input. Used for autonomous tasks, compaction jobs, and background operations. The result is saved as an artifact when the worker finishes.

**Interactive** — the worker pauses after its initial execution and waits for a route message from the conversation. Used for user-facing tasks where the agent needs clarification, approval, or step-by-step guidance. The conversation can send structured commands to continue, complete, or fail the worker.

### Worker lifecycle

A worker starts in a queued state, transitions to running when its executor picks it up, and ends in either completed or failed. Interactive workers have an additional waiting state between cycles. The runtime maintains a snapshot of each worker's status, start time, tools, and latest report — these are visible in the Dashboard and used by Visor for health monitoring.

### Artifacts

When a worker completes, it writes an artifact: a titled, typed piece of output with a preview and full content. Artifacts are persisted to SQLite and remain accessible after a restart.

## Branches

A branch is a short-lived, memory-aware sub-task. When a message benefit from deep analysis — for example, a complex question that needs to pull in past decisions and goals — the runtime can spawn a branch instead of responding inline.

Before starting work, the branch recalls up to eight memories that are relevant to the task. This gives the executor focused context without loading the entire conversation history. When the branch concludes, its summary is saved as a new memory (linked back to the memories that informed it) and appended to the channel as a system message.

Branches are supervised by Visor. Any branch that doesn't conclude within the configured timeout (default: 60 seconds) is force-concluded.

## Visor

Visor is the runtime's supervision and self-awareness layer. It runs a periodic tick loop and watches for problems.

**Worker lifecycle** — elapsed runtime does not cancel workers. Long builds and tool calls remain active until completion, failure or an explicit stop.

**Branch timeouts** — branches that haven't concluded within the branch timeout are force-concluded by Visor directly.

**Channel health signals** — if a channel accumulates too many worker failures in a short window (default: 3 failures within 10 minutes), Visor emits a "channel degraded" signal. This can trigger alerts or automatic recovery logic.

**Idle detection** — if the system receives no messages for a long period (default: 30 minutes), Visor emits an idle signal. Useful for heartbeat scheduling or auto-shutdown.

**Memory maintenance** — on a separate schedule (default: every hour), Visor runs the importance decay, pruning, and optional merge passes on the memory store. See the [Memory](./memory.md) article for details.

**Bulletin generation** — Visor periodically generates a compact digest of the agent's current state: recent activity, active workers, top memories by category. This bulletin is injected into every LLM prompt, giving the model ambient awareness of what's happening without requiring explicit memory queries. If the state hasn't changed since the last bulletin, the cached version is reused.

## Event Bus

Every significant action in the runtime is published to an internal event bus as a timestamped envelope. Subscribers receive a live stream of events as they happen.

| Event | Emitted by | Meaning |
|---|---|---|
| `channelMessageReceived` | Channels | A message was appended |
| `channelRouteDecided` | Channels | A route decision was made |
| `workerSpawned` | Workers | A new worker was created |
| `workerProgress` | Workers | A worker reported a status update |
| `workerCompleted` | Workers | A worker finished successfully |
| `workerFailed` | Workers | A worker failed or was cancelled |
| `branchSpawned` | Branches | A branch was created |
| `branchConclusion` | Branches | A branch concluded with a summary |
| `compactorThresholdHit` | Compactor | A context utilization threshold was crossed |
| `compactorSummaryApplied` | Compactor | A compaction job completed |
| `visorBulletinGenerated` | Visor | A new state bulletin was generated |
| `visorBranchTimeout` | Visor | A branch was force-concluded |
| `visorSignalChannelDegraded` | Visor | Too many failures in a channel |
| `visorSignalIdle` | Visor | System has been idle |
| `visorMemoryMaintained` | Visor | Decay/prune maintenance completed |
| `visorMemoryMerged` | Visor | Memory merge pass completed |

Events are buffered for late subscribers (up to 256 events). The WebSocket gateway and any registered webhook URLs receive all events in real time.

## Agent configuration

### Runtime type

Each agent runs in one of two modes, set in its `config.json`:

**Native** — the agent runs inside Sloppy's own runtime using a configured model provider. This is the standard mode for agents managed by Sloppy. You select which model the agent uses by setting `selectedModel` in the agent's config.

**ACP** — the agent delegates its execution to an external process running the ACP protocol. Sloppy acts as a proxy: it forwards messages to the external process and relays the responses back. Useful for integrating agents built outside of Sloppy.

### Heartbeat

The heartbeat triggers a background session for the agent on a recurring schedule. During each heartbeat, the agent reads a prompt template from its `HEARTBEAT.md` file and executes it autonomously — for example, checking for new tasks, sending status summaries, or doing proactive maintenance.

The heartbeat is disabled by default. You can enable it and set the interval in the agent's config.

| Setting | Default | What it controls |
|---|---|---|
| `heartbeat.enabled` | `false` | Whether the heartbeat is active |
| `heartbeat.intervalMinutes` | `5` | How often the heartbeat fires |

### Friend reminder

Each agent also has an optional `FRIEND_REMINDER.md` file. It is empty by default. When it contains text, Sloppy appends it to every user message before sending that turn to the model:

```md
User request text

#[FRIEND_REMINDER.md]
- Do not use MCPs
- Always run git pull
```

This differs from bootstrap files such as `AGENTS.md`, `USER.md`, `SOUL.md`, and `MEMORY.md`: those shape the session background context, while `FRIEND_REMINDER.md` is deliberately placed next to the current user request. Use it for short, high-salience constraints that should be refreshed every turn.

The same behavior applies to gateway-backed channel sessions (for example Telegram or Discord) when the channel is linked to an agent.

### Channel session auto-close

By default, channel sessions stay open indefinitely. You can configure them to close automatically after a period of inactivity.

| Setting | Default | What it controls |
|---|---|---|
| `channelSessions.autoCloseEnabled` | `false` | Whether idle sessions close automatically |
| `channelSessions.autoCloseAfterMinutes` | `30` | How long a session must be idle before closing |

### Visor settings

| Setting | Default | What it controls |
|---|---|---|
| `visor.tickIntervalSeconds` | `30` | How often the supervision loop runs |
| `visor.workerTimeoutSeconds` | `600` | Legacy compatibility field, ignored; workers have no runtime limit from Visor |
| `visor.branchTimeoutSeconds` | `60` | Maximum runtime for a branch before force-conclusion |
| `visor.maintenanceIntervalSeconds` | `3600` | How often memory maintenance runs |
| `visor.channelDegradedFailureCount` | `3` | Worker failures needed to trigger a degraded signal |
| `visor.channelDegradedWindowSeconds` | `600` | Time window for counting failure events |
| `visor.idleThresholdSeconds` | `1800` | Inactivity period before an idle signal is emitted |
| `visor.bootstrapBulletin` | `true` | Whether a bulletin is generated on startup |
| `visor.bulletinMaxWords` | `300` | Maximum length of a generated bulletin |
| `visor.mergeEnabled` | `false` | Whether similar memories are automatically merged |
| `visor.mergeSimilarityThreshold` | `0.80` | Minimum recall score to consider two memories for merging |
| `visor.mergeMaxPerRun` | `10` | Maximum merges per maintenance pass |

## Recovery after restart

When the Sloppy process restarts, the runtime replays all persisted state from SQLite in a deterministic order: channels are recreated, artifacts are restored, and events are replayed. Workers that have no matching event in the log are restored directly from the task table. This means a crash or a controlled restart does not lose in-progress context.
