# Bring your assistant data to Sloppy

Open **Settings → Data Migration** in the Dashboard or macOS client. Sloppy also offers migration during onboarding or after finding a new assistant installation.

The Dashboard reads data **on the Core machine**. The macOS client reads data **on your Mac** and shows the selected destination before sending anything. A sandboxed client asks you to choose a source folder; selecting your home folder also permits reading Claude's sibling `.claude.json` and Codex's shared `.agents/skills`. Folder access is retained using read-only security-scoped bookmarks.

Choose sources, individual objects, destination agents and project folders, then review and start. By default each source profile becomes a separate native Sloppy agent. Leave project folder mappings blank to import history and instructions without transferring repository files. Existing projects with the same confirmed destination folder are reused.

## Supported data

- Codex: TOML MCP configuration, active/archived JSONL rollouts, Markdown memory, `.codex/skills` and `.agents/skills`.
- Claude: global/project MCP, Markdown skills and commands, project JSONL transcripts and memory.
- OpenClaw: JSON5 config, agent workspaces, SQLite sessions/transcripts including Zstandard event blobs, legacy JSONL and compressed transcript files.
- Hermes: YAML MCP configuration, skills, profiles, Markdown memory, read-only SQLite sessions/messages including committed WAL data, legacy file sessions.

Skills are copied with their resources and executable bits. Imported source-specific settings that Sloppy cannot represent are reported for review. Provider logins, hooks and scheduled runs are not activated. MCP configurations include their configured environment/headers, stay disabled, and can be explicitly checked and enabled on Core. Local programs, paths and authorization may need configuration on a remote Core.

Imported conversations can be continued by a native Sloppy agent. Historical tool calls are displayed and included as historical context; they are never replayed as executable tool requests. System prompts from the old runtime are not imported as conversation instructions. Instructions and memory are separate selected objects.

Memory source documents are retained in the migration journal and processed with the existing verified memory importer. A configured native model is required; if it is unavailable the other categories remain usable and memory can be resumed after setup. Project memory uses project scope; other memory uses the selected agent's scope.

## Recovery and progress

Transfers show acknowledged bytes, imported/already-present/error counts, and verified memory parts. Closing the wizard does not stop Core. Reopen previous migrations to resume after interruption. Cancelling stops remaining work and retains completed imports. The Mac retains the pending upload snapshot in its Application Support directory, restricted to the user.

A repeated identical import skips confirmed objects. Changed source conversations create separate revisions, preserving any work already continued in Sloppy. Source files are never modified. Unsupported, oversized or unreadable source records produce diagnostics rather than silently successful results. Individual source files are bounded to 32 MB; memory documents to 1 MB; the selected transfer manifest to 256 MB. Split larger imports into smaller selections.

## Core API

All `/v1/migrations` routes use existing authentication and require Admin in identity mode.

- `GET /sources`: shallow discovery on Core.
- `POST /scan`: analyze explicitly selected source roots.
- `POST /preview`: validate normalized selection and report duplicates/conflicts.
- `POST /import`: start a selected Core-source import.
- `POST /`: create an upload with destination, size, checksum and item count.
- `POST /:jobId/chunks`: append/retry a base64 chunk at its acknowledged offset, at most 1 MB.
- `GET /`, `GET /:jobId`: history and progress.
- `POST /:jobId/start`, `/resume`, `/cancel`: lifecycle controls.
- `POST /:jobId/enable-mcp`: explicitly enable and probe selected imported server IDs.

The shared `Packages/SloppyMigration` module supplies adapters and Codable contracts. Durable journals and the deduplication ledger live in the Core workspace's `migrations` directory. Uploads are checksum-verified before decoding and applying data. Session and file writes use deterministic identities so recovering an interrupted acknowledgement does not duplicate objects.
