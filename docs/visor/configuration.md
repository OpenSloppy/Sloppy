# Visor Configuration

All Visor settings live under the `visor` key in your `sloppy.json` configuration file. Every setting has a sensible default, so you only need to add fields you want to change.

```json
{
  "visor": {
    "scheduler": {
      "enabled": true,
      "intervalSeconds": 300,
      "jitterSeconds": 60
    },
    "bootstrapBulletin": true,
    "bulletinMaxWords": 300,
    "model": null,
    "tickIntervalSeconds": 30,
    "branchTimeoutSeconds": 60,
    "maintenanceIntervalSeconds": 3600,
    "decayRatePerDay": 0.05,
    "pruneImportanceThreshold": 0.1,
    "pruneMinAgeDays": 30,
    "channelDegradedFailureCount": 3,
    "channelDegradedWindowSeconds": 600,
    "idleThresholdSeconds": 1800,
    "webhookURLs": [],
    "mergeEnabled": false,
    "mergeSimilarityThreshold": 0.80,
    "mergeMaxPerRun": 10
  }
}
```

## Bulletin scheduler

These settings control how often Visor generates periodic bulletins.

| Setting | Default | Description |
|---|---|---|
| `visor.scheduler.enabled` | `true` | Whether the periodic bulletin scheduler runs at all. Set to `false` to disable automatic bulletin generation; bulletins can still be generated on-demand. |
| `visor.scheduler.intervalSeconds` | `300` | How often (in seconds) the scheduler generates a new bulletin. Default is every 5 minutes. |
| `visor.scheduler.jitterSeconds` | `60` | A random amount of time (0 to this value) added to each interval. Prevents multiple instances from generating bulletins simultaneously. |

## Bulletin content

These settings control what goes into each bulletin and which model synthesizes it.

| Setting | Default | Description |
|---|---|---|
| `visor.bootstrapBulletin` | `true` | Whether to generate an initial bulletin when Sloppy starts. Ensures agents have context from the very first message. |
| `visor.bulletinMaxWords` | `300` | Target word count for the LLM-synthesized bulletin digest. The model is instructed to stay near this limit. |
| `visor.model` | `null` | The model to use for bulletin synthesis, in the format `"provider:model-id"` (for example `"openai-api:gpt-4o-mini"`). When `null`, the default system model is used. If no model is available at all, Visor falls back to a plain-text summary. |

## Autodream session memory

Autodream periodically reviews recent agent sessions through the same hidden memory checkpoint path used after compaction or session rollover. Reviewed sessions are marked in SQLite by agent id, session id, and the session `updatedAt` timestamp so unchanged sessions are not processed twice.

| Setting | Default | Description |
|---|---|---|
| `visor.autodream.enabled` | `true` | Whether the periodic session review runner starts with the core service. |
| `visor.autodream.intervalSeconds` | `21600` | How often (in seconds) autodream scans recent sessions. Default is every 6 hours. |
| `visor.autodream.jitterSeconds` | `1800` | Random delay added to each interval. Default is up to 30 minutes. |
| `visor.autodream.sessionLimitPerRun` | `10` | Maximum number of changed chat sessions to checkpoint in one pass. |
| `visor.autodream.model` | `null` | Optional small model for autodream checkpoints. When `null`, autodream falls back to `visor.model`, then normal agent/default model selection. |

## Supervision tick

The supervision tick loop is the heartbeat of Visor's health monitoring. It runs continuously in the background.

| Setting | Default | Description |
|---|---|---|
| `visor.tickIntervalSeconds` | `30` | How often (in seconds) the supervision loop runs. Each tick checks branch health and channel signals. |
| `visor.workerTimeoutSeconds` | `600` | Legacy compatibility field, ignored. Workers are not cancelled based on elapsed runtime, including in autopilot. |
| `visor.branchTimeoutSeconds` | `60` | How long (in seconds) a branch may stay active before Visor force-concludes it. Branches are short-lived by design; keep this low. |

## Memory maintenance

Visor runs memory maintenance (decay, pruning, and optional merge) on a schedule separate from the supervision tick.

| Setting | Default | Description |
|---|---|---|
| `visor.maintenanceIntervalSeconds` | `3600` | How often (in seconds) the maintenance pass runs. Default is once per hour. |
| `visor.decayRatePerDay` | `0.05` | The fraction of importance lost each day for non-identity memories. At 0.05, a memory at importance 1.0 will be at roughly 0.6 after 10 days. Set to `0` to disable decay. |
| `visor.pruneImportanceThreshold` | `0.1` | Memories with importance below this value become candidates for pruning. Only memories that also meet the minimum age requirement are actually removed. |
| `visor.pruneMinAgeDays` | `30` | A memory must be at least this many days old to be pruned, even if its importance is below the threshold. Protects recently created memories from early removal. |

## Channel health signals

These settings control when Visor decides that a channel is experiencing problems.

| Setting | Default | Description |
|---|---|---|
| `visor.channelDegradedFailureCount` | `3` | The number of worker failures that must occur in one channel within the time window to trigger a "channel degraded" signal. |
| `visor.channelDegradedWindowSeconds` | `600` | The sliding time window (in seconds) used to count worker failures. Default is 10 minutes. Failures older than this window do not count. |

## Idle detection

| Setting | Default | Description |
|---|---|---|
| `visor.idleThresholdSeconds` | `1800` | How many seconds of inactivity (no incoming messages) must pass before Visor emits an idle signal. Default is 30 minutes. |

## Webhooks

Visor can notify external systems when signals fire. Each URL receives an HTTP POST with the event payload in JSON.

| Setting | Default | Description |
|---|---|---|
| `visor.webhookURLs` | `[]` | A list of URLs to call when any `visor.signal.*` event fires (`visor.signal.channel_degraded` or `visor.signal.idle`). |

Example:

```json
{
  "visor": {
    "webhookURLs": [
      "https://hooks.example.com/sloppy-alerts"
    ]
  }
}
```

## Memory merge

Memory merge is an optional feature that consolidates similar memories over time. It is disabled by default because it requires a capable embedding or recall backend to work well.

| Setting | Default | Description |
|---|---|---|
| `visor.mergeEnabled` | `false` | Whether the merge pass runs during maintenance. |
| `visor.mergeSimilarityThreshold` | `0.80` | The minimum recall similarity score (0 to 1) required to consider two memories as candidates for merging. Higher values mean only very close matches are merged. |
| `visor.mergeMaxPerRun` | `10` | The maximum number of merge operations performed in a single maintenance pass. Caps the amount of work done at once. |

Only memories that are at least 1 day old are considered for merging. Bulletins and identity records are never merged.
