---
layout: doc
title: CLI Reference
---

# CLI Reference

The `sloppy` binary is both a server and a command-line client. When the server is running, any `sloppy` subcommand acts as a thin HTTP client that calls the running Core API. This lets you manage agents, projects, channels, providers, and the rest of the runtime directly from your terminal — no Dashboard required.

## When to use the CLI

| Situation | Recommended tool |
| --- | --- |
| Quick inspection, scripting, CI/CD | CLI |
| Fast local project chat from a terminal | Terminal UI |
| Day-to-day chat and visual management | Dashboard |
| Custom integrations and automation | HTTP API directly |

## Verify the CLI is available

```bash
sloppy --version
```

Check that the server is reachable:

```bash
sloppy status
```

## Global options

All commands accept these flags:

| Flag | Default | Description |
| --- | --- | --- |
| `--url <url>` | from config or `SLOPPY_URL` | Sloppy server URL |
| `--token <token>` | from config or `SLOPPY_TOKEN` | Auth token |
| `--format <fmt>` | `json` | Output format: `json` or `table` |
| `--verbose` | off | Print HTTP method, URL, status, and timing for every request |
| `--version` | — | Print the sloppy version |
| `--help` | — | Show help for any command |

### Connection resolution

The CLI resolves the server URL and token in this order:

1. `--url` / `--token` flags
2. `SLOPPY_URL` / `SLOPPY_TOKEN` environment variables
3. `sloppy.json` in the current workspace

## Starting the server

```bash
sloppy run
```

Options for `run`:

| Flag | Description |
| --- | --- |
| `--config-path <path>` | Load config from a custom path |
| `--generate-openapi <path>` | Write OpenAPI spec to file and exit |

### Server auth via environment

You can start the server without committing an auth token into `sloppy.json`:

```bash
export SLOPPY_TOKEN="replace-me"
sloppy run
```

When the server starts, `SLOPPY_TOKEN` is used as:

1. the runtime value for legacy `auth.token` when `core.auth.token` is not set explicitly via environment
2. the runtime value for `ui.dashboardAuth.token` when dashboard auth is enabled but no dashboard token is configured

This is useful for local runs, launch agents, CI, or container deployments where secrets should come from the environment instead of the checked-in config file.

### Experimental tool flags

Add this top-level section to `sloppy.json` to disable both the Tool Budget and Tool Loop Guard for agent and channel tool calls:

```json
{
  "experimentalFlags": {
    "disableToolBudgetAndLoopGuard": true,
    "toolBudgetEnabled": false
  }
}
```

`toolBudgetEnabled` also lives in `experimentalFlags`; an older top-level value is read for compatibility and moved into this section on the next save. When omitted, `toolBudgetEnabled` defaults to `false` and `disableToolBudgetAndLoopGuard` defaults to `true`. The disable flag bypasses the tool-round budget and repeated-call detection, including the block after repeated `runtime.exec` timeouts. Individual commands still obey their execution timeouts and the normal tool authorization policy. Restart Sloppy after editing `sloppy.json` directly; changes saved through the Dashboard apply to the running service.

## Terminal UI

The default interactive terminal experience is the Sloppy TUI:

```bash
sloppy
sloppy tui
sloppy tui --config-path /path/to/sloppy.json
sloppy -s <sessionId>
sloppy tui -s <sessionId>
sloppy models
```

`sloppy` with no subcommand opens the TUI. It bootstraps the runtime in-process for the current directory, restores the last agent/session for that project, and shares the same `sloppy.json` and workspace as the server and Dashboard. Use `sloppy models` to open only the model picker for the current TUI agent.

See [Terminal UI](/tui/overview) for keys, slash commands, model/provider setup, file attachments, and [multi-session workflows](/tui/multi-session).

## Background service

Install and manage Sloppy as a persistent background service (starts on login, restarts on crash).

On Linux, `sloppy service install` also checks `systemd` lingering so the user service can stay up after logout. If that step requires `sudo`, the command prints the exact one-time `loginctl enable-linger` fix.

```bash
sloppy service install                              # register + start (macOS LaunchAgent / Linux systemd)
sloppy service install --config-path /path/to/sloppy.json
sloppy service uninstall                            # stop + remove
sloppy service start                                # start now
sloppy service stop                                 # stop now (stays registered)
sloppy service restart                              # stop then start
sloppy service status                               # show launchctl / systemctl output
sloppy service logs                                 # tail -f log (macOS) or journalctl (Linux)
sloppy service logs --lines 100                     # show last 100 lines before following
```

See [Install — Run as a background service](/install#run-as-a-background-service) for a full walkthrough.

## System commands

```bash
sloppy status                     # GET /health — connectivity check
sloppy update                     # POST /v1/updates/check
sloppy update --install           # Pull and reinstall source checkout from its current branch
sloppy logs                       # GET /v1/logs
sloppy workers                    # GET /v1/workers
sloppy bulletins                  # GET /v1/bulletins
sloppy token-usage                # GET /v1/token-usage
sloppy token-usage --channel-id main --from 2025-01-01
```

## Agent commands

```bash
# List / inspect
sloppy agent list
sloppy agent get <agentId>

# Create / delete
sloppy agent create --name "Reviewer" --role "Code review agent"
sloppy agent create --id "custom-id" --name "Worker" --model "openai-api:gpt-5.4-mini"
sloppy agent delete <agentId>

# Config
sloppy agent config get <agentId>
sloppy agent config set <agentId> --model "openai-api:gpt-5.4"
sloppy agent config set <agentId> --name "New Name" --role "Updated role"

# Tool policy
sloppy agent tools list <agentId>
sloppy agent tools catalog <agentId>
sloppy agent tools set <agentId> --file policy.json

# Sessions
sloppy agent session list <agentId>
sloppy agent session get <agentId> <sessionId>
sloppy agent session create <agentId> --title "Debug session"
sloppy agent session delete <agentId> <sessionId>
sloppy agent session message <agentId> <sessionId> --content "Hello agent"

# Memory
sloppy agent memory list <agentId>
sloppy agent memory list <agentId> --search "deployment" --filter episodic
sloppy agent memory update <agentId> <memoryId> --importance 0.9
sloppy agent memory delete <agentId> <memoryId>

# Cron
sloppy agent cron list <agentId>
sloppy agent cron create <agentId> --schedule "0 9 * * 1-5" --command "Send daily standup"
sloppy agent cron update <agentId> <cronId> --enabled false
sloppy agent cron delete <agentId> <cronId>

# Skills
sloppy agent skill list <agentId>
sloppy agent skill install <agentId> --owner TeamSloppy --repo my-skill
sloppy agent skill uninstall <agentId> <skillId>

# Token usage
sloppy agent token-usage <agentId>
```

## Project commands

```bash
# List / inspect
sloppy project list
sloppy project get <projectId>

# Create / update / delete
sloppy project create --name "API Refactor"
sloppy project create --name "Mobile" --description "iOS and Android work"
sloppy project create --name "Arcadia Service" --repo-path /arcadia/service --source-control-provider arcadia-mount
sloppy project update <projectId> --name "New Name"
sloppy project update <projectId> --source-control-provider git-cli
sloppy project delete <projectId>

# Tasks
sloppy project task list <projectId>
sloppy project task get <projectId> <taskId>
sloppy project task create <projectId> --title "Fix login bug"
sloppy project task create <projectId> --title "Add OAuth" --priority high --channel-id main
sloppy project task update <projectId> <taskId> --status in_progress
sloppy project task delete <projectId> <taskId>
sloppy project task approve <projectId> <taskId>
sloppy project task reject <projectId> <taskId> --reason "Missing tests"
sloppy project task diff <projectId> <taskId>

# Channels attached to project
sloppy project channel create <projectId> --channel-id main
sloppy project channel delete <projectId> <channelId>

# Memory
sloppy project memory list <projectId>
sloppy project memory list <projectId> --search "api contract" --limit 50
```

## Channel commands

```bash
sloppy channel state <channelId>
sloppy channel events <channelId> --limit 100
sloppy channel message <channelId> --content "Trigger a reply" --user-id operator
sloppy channel model get <channelId>
sloppy channel model set <channelId> --model "openai-api:o4-mini"
sloppy channel model clear <channelId>
sloppy channel control <channelId> --action abort
```

## Config commands

```bash
sloppy config get
sloppy config set --file my-config.json
sloppy config set --json '{"listen":{"port":25102}}'
```

## Provider commands

```bash
sloppy providers list
sloppy providers add --title "openai-api" --api-url "https://api.openai.com/v1" \
  --api-key "$OPENAI_API_KEY" --model "openai-api:gpt-5.4"
sloppy providers remove "openai-api"
sloppy providers probe --provider-id openai --api-key "$OPENAI_API_KEY"
sloppy providers models --api-url "https://api.openai.com/v1" --api-key "$OPENAI_API_KEY"

# OpenAI OAuth
sloppy providers openai status
sloppy providers openai disconnect

# Search provider
sloppy providers search status
```

## Actor commands

```bash
sloppy actor board
sloppy actor node create --id "reviewer" --name "Code Reviewer" --role "Reviews PRs"
sloppy actor node update <actorId> --name "Senior Reviewer"
sloppy actor node delete <actorId>
sloppy actor link create --from "planner" --to "reviewer"
sloppy actor link delete <linkId>
sloppy actor team create --name "Backend" --members "agent-a,agent-b,agent-c"
sloppy actor team update <teamId> --members "agent-a,agent-b"
sloppy actor team delete <teamId>
sloppy actor route --message "Who should review this PR?"
```

## Plugin commands

```bash
sloppy plugin list
sloppy plugin get <pluginId>
sloppy plugin create --file plugin.json
sloppy plugin install <local-plugin-dir>
sloppy plugin install owner@repo
sloppy plugin install https://github.com/example/my-platform-plugin.git --ref v1.0.0 --force
sloppy plugin update <pluginId> --file updated.json
sloppy plugin delete <pluginId>
```

## Source-control commands

```bash
sloppy source-control list
```

## MCP commands

```bash
sloppy mcp server                 # list MCP servers from config
sloppy mcp tool <agentId>         # list tools in agent catalog
sloppy mcp call <agentId> <tool> --args '{"path":"/tmp/file.txt"}'
```

## Visor commands

```bash
sloppy visor ready
sloppy visor chat --question "What did the team work on today?"
```

## Skills commands

```bash
sloppy skills search
sloppy skills search --query "code review"
```

## Practical examples

### Inspect a running instance

```bash
sloppy status
sloppy config get | jq '.listen'
sloppy agent list --format table
sloppy workers
```

### Automate project setup in CI

```bash
PROJECT=$(sloppy project create --name "Release v2" | jq -r '.id')
sloppy project task create "$PROJECT" --title "Update changelog" --priority high
sloppy project task create "$PROJECT" --title "Tag release" --priority high
sloppy project task list "$PROJECT"
```

### Give an agent a cron task

```bash
sloppy agent cron create "my-agent" \
  --schedule "0 9 * * 1-5" \
  --command "Send the daily standup summary to #general"
```

Cron expressions use five fields (minute, hour, day, month, weekday) in the Core
machine's local time zone. Wildcards, lists, ranges such as `1-5`, and steps such
as `*/15` are supported. The Core must be running at the scheduled time; missed
occurrences while it is stopped are not replayed.

Without `--channel-id`, each run creates a new chat for the selected agent. To
continue an existing chat, pass `--channel-id "session-…"` or its full
`agent:AGENT:session:SESSION` channel ID. Cron jobs created by the agent's `cron`
tool default to the current chat. Explicit external channel IDs use channel
delivery instead.

### Override a channel model temporarily

```bash
sloppy channel model set main --model "openai-api:o4"
# ... run your test ...
sloppy channel model clear main
```
