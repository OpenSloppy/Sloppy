# Proactive attention

Sloppy can watch tasks and pull requests without starting their execution. A periodic collector sends compact source snapshots to the configured semantic decision provider (Jev or another compatible provider). Sources needing investigation are reviewed by an explicitly selected model, which reports structured findings.

## Set up an agent

1. Configure the semantic decision provider in **Settings → Semantic Decisions**. Proactive screening uses this connection independently of automatic executor routing.
2. In Dashboard, open **Agents → Config → Heartbeat**. In ClientNative, open **Settings → Proactivity** and choose an agent.
3. Select **Proactive attention**, a deep review model and the projects or review providers to watch. Set the interval and edit `HEARTBEAT.md` for personal attention criteria.
4. Enable the heartbeat and save. The initial proactive interval is 30 minutes. The checklist heartbeat remains available with its original behavior.

Tasks include those already imported through task sync. PRs include authored open requests and requests for the connected user's review. Sources use their existing connections; the attention service does not create new credentials or subscriptions.

## Findings and notifications

Dashboard's **Attention** tab and ClientNative's **Proactivity** screen show what happened, why it matters and a proposed next step. You can open the source, discuss the finding in its background session, mark it read, snooze it for 24 hours or dismiss its current revision. A changed source may produce a new finding; source outages do not resolve existing findings.

Notification hours default to **09:00–21:00 in Europe/Moscow**. Checks continue outside those hours, but live notifications wait and are grouped when the window opens. History is stored in SQLite and recovered silently after client reconnection. Snoozing also postpones delivery until its expiry and the next allowed notification window.

The Core must be running for checks and delivery. The Apple client can receive live findings while connected; this feature does not provide APNs delivery to a terminated mobile app.

## Costs and failures

Unchanged snapshots skip screening, except deferred decisions and daily reassessments. Task events can accelerate collection, with a minimum five-minute spacing. Each agent gets at most four deep review runs per rolling hour; no more than two can be fallbacks for failed or uncertain screening. Remaining items stay queued across restart. Source failures and analysis failures appear separately in the inbox.

Deep review has only the `heartbeat.report` tool. It cannot modify tasks, execute commands, delegate work or publish comments. Free-text model replies are never interpreted as completion or attention signals.

## API

- `GET /v1/agents/:agentId/proactivity`: durable findings and health.
- `GET /v1/agents/:agentId/proactivity/settings`: heartbeat settings, instructions and available models.
- `PUT /v1/agents/:agentId/proactivity/settings`: update heartbeat settings and optional `heartbeatMarkdown`, preserving the rest of the agent configuration.
- `POST /v1/agents/:agentId/proactivity/findings/:findingId/action`: `{ "action": "read" | "snooze" | "dismiss" }`.
