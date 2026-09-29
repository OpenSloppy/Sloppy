---
layout: doc
title: Model Providers
---

# Model Providers

Sloppy supports multiple LLM providers. Each provider is configured as an entry in the `models` array inside `sloppy.json` (or via the Dashboard UI). At runtime, models are resolved by prefix (`openai-api:`, `openai-oauth:`, `gemini:`, `anthropic:`, `ollama:`) and routed to the corresponding provider implementation.

## Supported providers

| Provider | Prefix | Default API URL | Env variable | Auth |
| --- | --- | --- | --- | --- |
| OpenAI API | `openai-api:` | `https://api.openai.com/v1` | `OPENAI_API_KEY` | API key |
| OpenAI Codex (OAuth) | `openai-oauth:` | `https://chatgpt.com/backend-api` | — | OAuth device code |
| Google Gemini | `gemini:` | `https://generativelanguage.googleapis.com` | `GEMINI_API_KEY` | API key or Antigravity CLI OAuth |
| Anthropic | `anthropic:` | `https://api.anthropic.com` | `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | OAuth / setup token (see below) |
| Ollama | `ollama:` | `http://127.0.0.1:11434` | — | None |
| OpenCode import | `opencode:` | From OpenCode provider config | From OpenCode resolved config/auth | OpenAI-compatible providers |

## Semantic decision providers: Jev and Laya

Automatic executor selection has a separate provider in `semanticDecisions`. Choose **TypeSafe direct (Jev)**, **Vercel AI Gateway (Jev)**, or **Laya** in Settings → Semantic Decisions in the Dashboard or native client. The decision provider selects an executor profile; the executor still uses one of your configured LLM models.

For Laya, run its [System One HTTP server](https://github.com/NandhaKishorM/laya#self-hosting-http-server-jev-compatible) on the same host as Sloppy or another reachable machine. For example, in a Python virtual environment:

```sh
python -m pip install "laya[serve]"
LAYA_HOST=127.0.0.1 LAYA_MODELS=multilingual LAYA_PRELOAD=1 laya-serve
```

Wait for the checkpoint download and startup to finish before sending requests. Configure the Sloppy server with:

```json
{
  "semanticDecisions": {
    "provider": "laya",
    "baseURL": "http://127.0.0.1:8000/v1/systemone",
    "model": "multilingual",
    "apiKey": "",
    "apiKeyEnvironmentVariable": "LAYA_API_KEY",
    "maxInputTokens": 8192,
    "timeoutMs": 5000,
    "executorModelRouting": "shadow",
    "minimumConfidence": 0.85,
    "modelProfiles": {
      "fast": { "model": "openai-api:gpt-5.4-mini", "description": "Simple questions and routine edits" },
      "senior": { "model": "openai-api:gpt-5.4", "description": "Complex debugging, architecture and broad changes" }
    }
  }
}
```

Use actual model IDs available to the agent. At least two eligible profiles are required. The endpoint above is the default when `baseURL` is empty; `127.0.0.1` refers to the machine running Sloppy, including its container when using Docker. The default Laya checkpoint is `multilingual`. You can override it with `english`, `typed-decisions`, or another alias accepted by your Laya server.

`maxInputTokens` is optional and maps to Laya's `max_len`; omitting it uses the server's default token budget. Match it to the checkpoint and server limits: multilingual supports up to 8192 tokens, while the English and typed-decisions checkpoints have smaller default windows. Longer inputs require more time. Laya can truncate inputs to its token budget, so validate your routing prompts and profile descriptions for the checkpoint you deploy.

Laya accepts requests without a key when server authentication is disabled. If the server requires one, set Sloppy's `apiKey` or export `LAYA_API_KEY` in Sloppy's environment. A config key takes priority. Switching providers in the UI clears the previous provider's key, endpoint and model overrides; executor profiles and routing mode remain configured.

Laya routing uses `answer_confidence`, falling back to the selected answer's probability for older responses. Its entropy-based `confidence` is not used. Thresholds and checkpoint quality need evaluation on your tasks; start with `shadow`, which records decisions without applying them, and then choose `active`. Errors, timeouts, invalid answers and confidence below the threshold use the agent's configured model. An explicit per-turn model wins over automatic routing.

Laya calls are recorded at zero API cost; hardware and hosting costs are outside this meter. The usage and cost views aggregate semantic decisions across providers. Existing Jev configuration, pricing and the persisted `auto:jev` automatic-selection identifier remain compatible.

## Environment variables

Environment variables provide a way to configure API keys without writing them into `sloppy.json`. When both an environment variable and a config key are set, the config key takes precedence.

| Variable | Provider | Description |
| --- | --- | --- |
| `OPENAI_API_KEY` | OpenAI | API key for OpenAI models |
| `GEMINI_API_KEY` | Gemini | API key for Google Gemini models |
| `ANTHROPIC_API_KEY` | Anthropic | Console API key or OAuth/setup token for Claude (direct `api.anthropic.com` only) |
| `ANTHROPIC_AUTH_TOKEN` | Anthropic | Auth token for Claude/Anthropic-compatible auth; can also be read from `.claude/settings.json` under `env` |
| `ANTHROPIC_BASE_URL` | Anthropic | Base URL for Anthropic-compatible auth when set in `.claude/settings.json` under `env` |
| `SLOPPY_CA_CERTS` | TLS | Path to a PEM bundle with additional Certificate Authority certificates for Sloppy-owned outbound HTTPS sessions |
| `BRAVE_API_KEY` | Search | API key for Brave web search tool |
| `PERPLEXITY_API_KEY` | Search | API key for Perplexity web search tool |

## Config file format

Each model entry in `sloppy.json` has four fields:

```json
{
  "models": [
    {
      "title": "openai-api",
      "apiKey": "",
      "apiUrl": "https://api.openai.com/v1",
      "model": "gpt-5.4-mini"
    }
  ]
}
```

| Field | Description |
| --- | --- |
| `title` | Identifier used to infer the provider when the model string has no prefix. Must contain the provider name (e.g. `openai-api`, `gemini`, `anthropic`, `ollama-local`). |
| `apiKey` | API key for authenticated providers. Leave empty to use the environment variable. |
| `apiUrl` | Base URL for the provider API. Override for proxied or self-hosted endpoints. |
| `model` | Model identifier passed to the provider. Can include a prefix (`openai-api:gpt-5.4-mini`) or be plain (`gpt-5.4-mini`). |

## Provider examples

### OpenAI

```json
{
  "title": "openai-api",
  "apiKey": "",
  "apiUrl": "https://api.openai.com/v1",
  "model": "gpt-5.4-mini"
}
```

With `OPENAI_API_KEY` set in the environment, `apiKey` can stay empty. Supports Chat Completions and Responses API variants with automatic fallback.

### Google Gemini

```json
{
  "title": "gemini",
  "apiKey": "",
  "apiUrl": "https://generativelanguage.googleapis.com",
  "model": "gemini-2.5-flash"
}
```

Get an API key from [Google AI Studio](https://aistudio.google.com/apikey). The probe endpoint fetches the full model list from the Gemini API.

When no API key is configured, Sloppy can also use local Google OAuth credentials from Antigravity CLI style auth. In that mode requests are routed through Google's Cloud Code Assist endpoint (`https://cloudcode-pa.googleapis.com/v1internal:*`) and wrapped in the Antigravity request envelope.

### Anthropic

Sloppy supports two ways to authenticate against the **direct** Anthropic API (`https://api.anthropic.com`): a **Console API key** or an **OAuth / setup / subscription-style token**. The model prefix is always `anthropic:`; only the credential type changes.

#### Console API key

Use a key from [Anthropic Console](https://console.anthropic.com/). Console keys typically start with `sk-ant-api`.

```json
{
  "title": "anthropic",
  "apiKey": "",
  "apiUrl": "https://api.anthropic.com",
  "model": "claude-sonnet-4-6"
}
```

With `ANTHROPIC_API_KEY` set in the environment, `apiKey` can stay empty. Available models include Claude Sonnet 4.6, Claude Opus 4.7, Claude 3.7 Sonnet, Claude 3.5 Sonnet, Claude 3.5 Haiku, and Claude 3 Opus.

#### OAuth, setup tokens, and Claude Code

If you use **Anthropic OAuth**, **setup tokens**, or tokens aligned with **Claude Code** (not the Console `sk-ant-api` keys), put that value in `apiKey`, set `ANTHROPIC_AUTH_TOKEN`, or set `ANTHROPIC_API_KEY` to the same value. Sloppy also reads `.claude/settings.json` and uses `env.ANTHROPIC_AUTH_TOKEN` plus `env.ANTHROPIC_BASE_URL` when local Claude credentials are empty or absent. Sloppy sends the right headers for direct `api.anthropic.com` requests based on the key shape.

Example entry (same fields as above; the difference is the token you paste):

```json
{
  "title": "anthropic-oauth",
  "apiKey": "",
  "apiUrl": "https://api.anthropic.com",
  "model": "claude-sonnet-4-6",
  "providerCatalogId": "anthropic-oauth"
}
```

The optional `providerCatalogId` field is set automatically when you use the Dashboard preset; you can omit it if you edit JSON by hand.

**Dashboard:** open **Settings → Providers**, then add the **Anthropic** preset (or paste an OAuth/setup token into the API key field for an Anthropic row). The OAuth preset uses placeholder text that matches setup-style tokens.

**Third-party proxies** (Bedrock bridges, self-hosted gateways, etc.): point `apiUrl` at your proxy and use the **proxy’s** API key. Do not rely on OAuth-style heuristics for non-Anthropic hosts—Sloppy treats those endpoints as third-party and uses `x-api-key` with whatever secret you configure.

**Probe:** connection tests use `providerId` `anthropic` for both Console keys and OAuth tokens; the probe sends the same auth rules as runtime.

### Ollama

```json
{
  "title": "ollama-local",
  "apiKey": "",
  "apiUrl": "http://127.0.0.1:11434",
  "model": "qwen3"
}
```

No API key needed. Point `apiUrl` at any running Ollama instance. The probe endpoint queries `/api/tags` to list locally available models.

### Multiple providers

The `models` array supports multiple entries. `sloppy` builds a composite model provider that routes requests based on the model prefix:

```json
{
  "models": [
    {
      "title": "openai-api",
      "apiKey": "",
      "apiUrl": "https://api.openai.com/v1",
      "model": "gpt-5.4-mini"
    },
    {
      "title": "gemini",
      "apiKey": "",
      "apiUrl": "https://generativelanguage.googleapis.com",
      "model": "gemini-2.5-flash"
    },
    {
      "title": "anthropic",
      "apiKey": "",
      "apiUrl": "https://api.anthropic.com",
      "model": "claude-sonnet-4-6"
    }
  ]
}
```

## Importing providers from OpenCode

Sloppy can import OpenAI-compatible providers and models from your OpenCode setup. This is useful when an organization already publishes a large OpenCode provider catalog.

Enable it in `sloppy.json`:

```json
{
  "opencode": {
    "enabled": true
  }
}
```

When enabled, Sloppy first runs `opencode debug config` and reads the resolved OpenCode config. That includes global/project config plus remote or plugin-provided providers. If the command is unavailable or times out, Sloppy falls back to local OpenCode config files (`~/.config/opencode/opencode.json`, `OPENCODE_CONFIG`, and the nearest project `opencode.json`).

Imported model IDs use this shape:

```text
opencode:<provider-id>/<model-id>
```

For example, an OpenCode provider `company` with a model `fast-code` becomes `opencode:company/fast-code` in Sloppy's model picker.

Supported OpenCode providers are those configured with `npm` equal to `@ai-sdk/openai-compatible` or `@ai-sdk/openai`. Sloppy uses `provider.options.baseURL` and `provider.models`; API keys can come from `provider.options.apiKey`, `{env:NAME}` references, or OpenCode's auth file (`~/.local/share/opencode/auth.json`). Imported keys are used in memory and are not written into `sloppy.json`.

Optional filters:

```json
{
  "opencode": {
    "enabled": true,
    "includeProviders": ["company"],
    "excludeProviders": ["slow-lab"],
    "timeoutMs": 5000
  }
}
```

## Model selection for agents

Each agent has a `selectedModel` field in its config that determines which model it uses. The value includes the provider prefix:

| Provider | Example `selectedModel` |
| --- | --- |
| OpenAI | `openai-api:gpt-5.4-mini` |
| Gemini | `gemini:gemini-2.5-flash` |
| Anthropic | `anthropic:claude-sonnet-4-6` |
| Ollama | `ollama:qwen3` |
| OpenCode import | `opencode:company/fast-code` |

Set this via:

- **Dashboard** — Agent settings page, model dropdown
- **API** — `PUT /v1/agents/:id/config` with `{ "selectedModel": "gemini:gemini-2.5-flash" }`
- **Onboarding** — model selection step during first-run setup

## Model resolution flow

1. `sloppy` reads the `models` array from config at startup.
2. Each entry is resolved to a prefixed identifier (e.g. `openai-api:gpt-5.4-mini`) using either an explicit prefix in the `model` field or by inferring the provider from `title` and `apiUrl`.
3. Factory classes build provider instances for each recognized prefix.
4. A `CompositeModelProvider` combines all active providers.
5. When an agent runs, its `selectedModel` is matched against supported models and routed to the correct provider.

## Adding providers via CLI

You can also manage providers directly from the terminal without opening the Dashboard:

```bash
# List currently configured providers
sloppy providers list

# Add a new provider
sloppy providers add \
  --title "openai-api" \
  --api-url "https://api.openai.com/v1" \
  --api-key "$OPENAI_API_KEY" \
  --model "openai-api:gpt-5.4"

# Test connectivity
sloppy providers probe --provider-id openai --api-key "$OPENAI_API_KEY"

# List models from an OpenAI-compatible endpoint
sloppy providers models \
  --api-url "https://api.openai.com/v1" \
  --api-key "$OPENAI_API_KEY"

# Remove a provider
sloppy providers remove "openai-api"
```

See the [CLI Reference](/guides/cli#provider-commands) for all provider commands.

## Adding providers via Dashboard

### Onboarding

The first-run onboarding wizard (step 2) shows all providers as cards. Select a provider, enter the API key, click **Test connection** to probe, then select a model from the returned list.

### Settings

Open **Settings → Providers** in the Dashboard. Use **Add provider** or a preset card. For Anthropic, choose **Anthropic** (Console API key) or **Anthropic** (OAuth / Claude Code–style token). Click **Manage** on a row to open the configuration modal. Enter the API key and API URL, select a model, and click **Save Provider**. The config is saved to `sloppy.json` immediately.

## Provider probe API

The `/v1/providers/probe` endpoint tests connectivity for any provider:

```bash
curl -X POST http://localhost:25101/v1/providers/probe \
  -H "Content-Type: application/json" \
  -d '{"providerId": "gemini", "apiKey": "YOUR_KEY"}'
```

Supported `providerId` values: `openai-api`, `openai-oauth`, `gemini`, `anthropic`, `ollama`.

The response includes `ok`, `message`, and a `models` array with available model options.
