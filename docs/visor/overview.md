# Visor

Visor is the system's supervision and self-awareness layer. It runs silently in the background from the moment Sloppy starts, watching over workers, channels, and memory — and periodically producing a concise summary of everything that's happening so that agents always have relevant context at their fingertips.

Think of Visor as the part of the runtime that asks "is everything healthy?" and "what should the system know right now?" on a continuous basis.

## What Visor does

### Health monitoring

Visor does not cancel workers based on elapsed runtime. Conversation and autopilot workers can continue through long builds and tool calls until completion, failure or an explicit stop. Branches (short-lived focused sub-task contexts) that do not conclude within their own timeout are force-closed by Visor directly.

### Signal detection

Beyond individual timeouts, Visor also detects systemic problems:

**Channel degradation** — if too many workers fail inside one channel within a short window of time (for example, three failures in ten minutes), Visor emits a "channel degraded" signal. This indicates the channel may have a problem worth attention, and can be used to trigger alerts or automatic recovery via webhooks.

**System idle** — if the entire system receives no messages for an extended period, Visor emits an idle signal. This is useful for heartbeat checks, auto-shutdown scripts, or any external process that wants to know whether the system is actively in use.

### Memory maintenance

Memory grows over time, and not all of it stays relevant. Visor runs periodic maintenance to keep the memory store healthy:

- **Decay** — older memories gradually become less important. Each day, the importance score of non-identity memories decreases slightly. Memories that haven't been touched recently fade naturally rather than cluttering recall results.

- **Pruning** — memories that have decayed below a minimum importance threshold and are old enough are soft-deleted. They remain in the database for audit purposes but are excluded from future recall.

- **Merge** (optional) — when enabled, Visor scans for pairs of memories that cover the same ground and consolidates them into a single, better entry. The originals are soft-deleted and a history link is preserved. If a model is configured, the merge produces a synthesized note; otherwise the two texts are joined.

Maintenance runs on its own separate interval (default: every hour), independent of the main supervision tick.

### Bulletins

A bulletin is a compact digest of the system's current state. Visor generates bulletins on a regular schedule (default: every 5 minutes) and whenever one is explicitly requested.

**How a bulletin is built:**

1. Visor collects a snapshot of what's happening: how many channels and workers are active, recent decisions, active goals, recent memories, and recent events.
2. If an LLM model is configured, Visor sends this data to the model and asks it to synthesize a concise briefing — a readable paragraph that captures what any conversation should know right now. If no model is configured, a plain-text summary is assembled from the collected data.
3. The finished bulletin is persisted for operators (including SQLite bulletin history where configured), published as a runtime event, and kept in Visor’s own bulletin list. Bulletins are **operational digests**, not a substitute for user-curated hybrid memories or agent `MEMORY.md` files.

If the state hasn't changed since the last bulletin — same number of channels, same workers, same task status — Visor skips the synthesis step and returns the cached version. This avoids unnecessary model calls.

**How bulletins affect agents:**

Every time the runtime responds to a message, it injects the latest bulletin digest into the LLM prompt as background context. This means agents always have ambient awareness of what's going on in the system — what's running, what was recently decided, what the current workload looks like — without needing to ask or recall explicitly.

Recent bulletins are visible in the Dashboard Visor area. For how bulletins relate to **hybrid memory**, **Agents → Memories**, and **`MEMORY.md`**, see [Visor: memory and bulletins](/visor/memory) and [Agent memory](/agents/memory). Agents can call **`visor.status`** to read readiness and the latest digest without treating it as long-term stored user facts.

### Task intent recognition

Visor includes a task planner that recognizes task-management commands in messages. Both slash commands and natural-language phrasing are supported:

- `/task create Fix the login bug` — creates a new task
- `/task cancel task-123` — cancels an existing task
- `/task assign task-456 to actor alice` — assigns a task
- `/task mark task-789 done` — updates task status
- `/task split task-101: Write tests; Deploy to staging` — splits a task into subtasks

Natural-language equivalents like "create task Fix the login bug" or "добавь задачу" (Russian) also work.

The planner extracts typed intents from the message content — these intents are then executed by the service layer against the project's task list.

### Interactive Q&A

You can ask Visor questions about the current state of the system. Visor answers using the latest bulletin, the current worker and channel snapshot, and its own memory. Responses are grounded in actual runtime data — Visor won't invent information it doesn't have.

This is available via API and the Dashboard.

## When Visor runs

Visor starts automatically when the Sloppy runtime starts. It runs two parallel loops:

**Supervision tick** — runs every 30 seconds by default. Each tick checks worker health, branch health, and channel degradation signals. Once per hour it also runs memory maintenance.

**Bulletin scheduler** — runs every 5 minutes by default, with a random jitter of up to 1 minute to avoid thundering-herd effects when multiple instances are running. If bulletin generation is already in progress, the scheduler skips the cycle rather than overlapping.

On startup, Visor can optionally generate an initial bulletin immediately (`bootstrapBulletin: true` by default) so that agents have context from the very first message.

## Viewing Visor data in the Dashboard

Inside any project, open the **Visor** tab to see:

**Decisions** — for each channel linked to the project, the latest routing decision is shown: what action was taken, why, and with what confidence. This reflects how the system last classified an incoming message in that channel.

**Bulletins** — the most recent bulletins generated for the runtime. Each bulletin has a headline and a full digest. Up to 8 bulletins are displayed.

## Events Visor emits

| Event | When it fires |
|---|---|
| `visor.bulletin.generated` | A new bulletin was built and saved |
| `visor.branch.timeout` | A branch was force-concluded due to timeout |
| `visor.memory.maintained` | A decay and prune pass completed |
| `visor.memory.merged` | A memory merge pass completed |
| `visor.signal.channel_degraded` | Too many worker failures in a channel within the window |
| `visor.signal.idle` | No messages received for longer than the idle threshold |

All events are published on the internal event bus and forwarded to any configured webhook URLs.
