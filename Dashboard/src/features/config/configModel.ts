const GIT_SYNC_FREQUENCIES = new Set(["manual", "daily", "weekdays"]);
const GIT_SYNC_CONFLICT_STRATEGIES = new Set(["remote_wins", "local_wins", "manual"]);
const PROXY_TYPES = new Set(["socks5", "http", "https"]);

export const SETTINGS_ITEMS = [
  { id: "migrations", title: "Data Migration", icon: "move_to_inbox", searchTerms: ["import", "migration", "codex", "claude", "openclaw", "hermes"] },
  {
    id: "providers",
    title: "Providers",
    icon: "hub",
    searchTerms: ["models", "api key", "api url", "openai", "codex", "openrouter", "anthropic", "claude", "gemini", "ollama"]
  },
  {
    id: "users",
    title: "Users",
    icon: "manage_accounts",
    searchTerms: ["auth", "authentication", "login", "password", "accounts", "roles", "admin", "user", "invites", "recovery", "reset"]
  },
  {
    id: "search-tools",
    title: "Search Tools",
    icon: "travel_explore",
    searchTerms: ["web search", "brave", "perplexity", "api key", "active provider"]
  },
  {
    id: "image-generation",
    title: "Image Generation",
    icon: "image",
    searchTerms: ["images", "fal", "flux", "generation", "editing", "api key"]
  },
  {
    id: "model-routing",
    title: "Model routing",
    icon: "linear_scale",
    searchTerms: ["routing", "routes", "model aliases", "default model", "agent models", "task model", "available models"]
  },
  {
    id: "semantic-decisions",
    title: "Semantic Decisions",
    icon: "route",
    searchTerms: ["jev", "laya", "typesafe", "vercel", "decision", "model routing", "executor", "api key", "shadow"]
  },
  {
    id: "channels",
    title: "Channels",
    icon: "forum",
    searchTerms: ["telegram", "discord", "bot token", "chat map", "topic map", "allowed users", "allowed chats", "inactivity"]
  },
  {
    id: "sessions",
    title: "Sessions",
    icon: "history",
    searchTerms: ["retention", "history", "days", "cleanup", "session retention"]
  },
  {
    id: "approvals",
    title: "Approvals",
    icon: "fact_check",
    searchTerms: ["pending", "approve", "approval", "requests", "permissions"]
  },
  {
    id: "plugins",
    title: "Plugins",
    icon: "extension",
    searchTerms: ["plugin", "install", "drop", "delivery mode", "enabled", "api url", "api key"]
  },
  {
    id: "mcp",
    title: "MCP",
    icon: "account_tree",
    searchTerms: ["servers", "stdio", "http", "command", "arguments", "cwd", "endpoint", "headers", "tools", "resources", "prompts", "timeout"]
  },
  {
    id: "browser",
    title: "Browser",
    icon: "open_in_browser",
    searchTerms: ["chromium", "cdp", "headless", "profile", "executable", "startup timeout", "arguments"]
  },
  {
    id: "voice-mode",
    title: "Voice Mode",
    icon: "mic",
    searchTerms: ["voice", "speech", "transcription", "tts", "openai", "microphone", "audio"]
  },
  { id: "tui", title: "TUI", icon: "terminal", searchTerms: ["terminal", "editor", "default editor", "cli"] },
  { id: "ui", title: "UI", icon: "palette", searchTerms: ["dashboard", "auth", "token", "terminal", "local only"] },
  {
    id: "nodehost",
    title: "NodeHost",
    icon: "dns",
    searchTerms: ["nodes", "remote", "local", "url", "token", "token env", "gateway", "host"]
  },
  // { id: "bindings", title: "Bindings", icon: "cable" },
  // { id: "broadcast", title: "Broadcast", icon: "cell_tower" },
  // { id: "audio", title: "Audio", icon: "volume_up" },
  // { id: "media", title: "Media", icon: "perm_media" },
  // { id: "session", title: "Session", icon: "manage_accounts" },
  {
    id: "visor",
    title: "Visor",
    icon: "visibility",
    searchTerms: ["scheduler", "bulletin", "model", "tick interval", "worker timeout", "branch timeout", "maintenance", "decay", "prune", "webhook", "merge"]
  },
  {
    id: "compactor",
    title: "Compactor",
    icon: "compress",
    searchTerms: ["context", "compaction", "compact", "tokens", "threshold", "reduction", "summarize", "context window"]
  },
  { id: "acp", title: "ACP", icon: "smart_toy", searchTerms: ["targets", "server", "agent id", "cwd", "enabled"] },
  { id: "proxy", title: "Proxy", icon: "vpn_key", searchTerms: ["socks5", "http", "https", "host", "port", "username", "password"] },
  {
    id: "git-sync",
    title: "Git Sync",
    icon: "sync",
    searchTerms: ["repository", "branch", "schedule", "frequency", "time", "conflict", "strategy", "auth token", "sync now"]
  },
  { id: "connect-client", title: "Connect Client", icon: "qr_code", searchTerms: ["client", "qr", "connect", "mobile", "token"] },
  { id: "config", title: "Config", icon: "edit_document", searchTerms: ["raw", "json", "runtime", "advanced", "edit config"] },
  { id: "updates", title: "Updates", icon: "system_update", searchTerms: ["version", "check", "update", "release", "upgrade"] },
  // { id: "logging", title: "Logging", icon: "description" }
];

export const PROVIDER_CATALOG = [
  {
    id: "openai-api",
    brandProviderKey: "openai",
    title: "OpenAI API",
    description: "OpenAI via API key authentication.",
    modelHint: "gpt-5.4-mini",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-api",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-5.4-mini",
      disabled: false,
      providerCatalogId: "openai-api"
    }
  },
  {
    id: "openai-oauth",
    brandProviderKey: "openai",
    title: "OpenAI Codex",
    description: "Sign in to Codex with your ChatGPT account using a device code.",
    modelHint: "gpt-5.4",
    authMethod: "deeplink",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openai-oauth",
      apiKey: "",
      apiUrl: "https://chatgpt.com/backend-api",
      model: "gpt-5.4",
      disabled: false,
      providerCatalogId: "openai-oauth"
    }
  },
  {
    id: "sloppy",
    brandProviderKey: null,
    title: "Sloppy server",
    description: "Use models from another Sloppy server. Enter its URL and access token.",
    modelHint: "Choose a model from the remote server",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "Sloppy server",
      apiKey: "",
      apiUrl: "",
      model: "",
      disabled: false,
      providerCatalogId: "sloppy"
    }
  },
  {
    id: "openrouter",
    brandProviderKey: null,
    title: "OpenRouter",
    description: "Unified API for many models (OpenAI-compatible Chat Completions).",
    modelHint: "openai/gpt-5.4-mini",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "openrouter",
      apiKey: "",
      apiUrl: "https://openrouter.ai/api/v1",
      model: "openai/gpt-5.4-mini",
      disabled: false,
      providerCatalogId: "openrouter"
    }
  },
  {
    id: "anthropic",
    brandProviderKey: "anthropic",
    title: "Anthropic",
    description: "Claude models via Anthropic API key.",
    modelHint: "claude-sonnet-4-6",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "anthropic",
      apiKey: "",
      apiUrl: "https://api.anthropic.com",
      model: "claude-sonnet-4-6",
      disabled: false,
      providerCatalogId: "anthropic"
    }
  },
  {
    id: "anthropic-oauth",
    brandProviderKey: "anthropic",
    title: "Anthropic",
    description: "Claude via Anthropic OAuth, Claude Code credentials, or API token.",
    modelHint: "claude-sonnet-4-6",
    authMethod: "api_key",
    requiresApiKey: true,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "anthropic-oauth",
      apiKey: "",
      apiUrl: "https://api.anthropic.com",
      model: "claude-sonnet-4-6",
      disabled: false,
      providerCatalogId: "anthropic-oauth"
    }
  },
  {
    id: "gemini",
    brandProviderKey: "gemini",
    title: "Google Gemini",
    description: "Google Gemini via API key or Antigravity CLI OAuth.",
    modelHint: "gemini-2.5-flash",
    authMethod: "cli_or_api_key",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "gemini",
      apiKey: "",
      apiUrl: "https://generativelanguage.googleapis.com",
      model: "gemini-2.5-flash",
      disabled: false,
      providerCatalogId: "gemini"
    }
  },
  {
    id: "ollama",
    brandProviderKey: "ollama",
    title: "Ollama",
    description: "Local provider using Ollama's HTTP API (/api/tags). LM Studio and similar tools speak OpenAI-compatible /v1 — use OpenAI API with base URL http://host:port/v1 instead.",
    modelHint: "qwen3",
    authMethod: "none",
    requiresApiKey: false,
    supportsModelCatalog: true,
    defaultEntry: {
      title: "ollama-local",
      apiKey: "",
      apiUrl: "http://127.0.0.1:11434",
      model: "qwen3",
      disabled: false,
      providerCatalogId: "ollama"
    }
  }
];

/** UI presets only: hide Anthropic Console API key; OAuth preset remains. Full `PROVIDER_CATALOG` is still used for metadata and existing `anthropic` rows. */
export const PROVIDER_CATALOG_UI = PROVIDER_CATALOG.filter((p) => p.id !== "anthropic");

export function emptyModel() {
  return {
    title: "openai-api",
    apiKey: "",
    apiUrl: "https://api.openai.com/v1",
    model: "gpt-5.4-mini",
    disabled: false,
    providerCatalogId: "openai-api"
  };
}

export function emptyPlugin() {
  return {
    title: "new-plugin",
    apiKey: "",
    apiUrl: "",
    plugin: ""
  };
}

export function emptyMCPServer() {
  return {
    id: "new-mcp-server",
    transport: "stdio",
    command: "npx",
    arguments: [],
    cwd: "",
    endpoint: "",
    headers: {},
    timeoutMs: 15000,
    enabled: true,
    exposeTools: true,
    exposeResources: true,
    exposePrompts: true,
    toolPrefix: ""
  };
}

export function emptyNode(index = 1) {
  return {
    id: `remote-${index}`,
    title: "",
    url: "",
    token: "",
    tokenEnv: "",
    enabled: true,
    kind: "sloppy_instance"
  };
}

export function normalizeNode(node, index = 0) {
  if (typeof node === "string") {
    const id = String(node || "").trim() || `node-${index + 1}`;
    return {
      id,
      title: id === "local" ? "Local" : id,
      url: "",
      token: "",
      tokenEnv: "",
      enabled: true,
      kind: id === "local" ? "local" : "legacy"
    };
  }
  const id = String(node?.id || node?.title || `node-${index + 1}`).trim();
  return {
    id,
    title: String(node?.title || "").trim(),
    url: String(node?.url || "").trim(),
    token: String(node?.token || ""),
    tokenEnv: String(node?.tokenEnv || "").trim(),
    enabled: node?.enabled == null ? true : Boolean(node.enabled),
    kind: String(node?.kind || "sloppy_instance").trim() || "sloppy_instance"
  };
}

function normalizeVoiceProvider(value) {
  const provider = String(value || "auto").trim().toLowerCase();
  return provider === "openai" || provider === "local" ? provider : "auto";
}

function normalizeVoiceInputMode(value) {
  const mode = String(value || "push_to_talk").trim().toLowerCase();
  return mode === "auto_submit" ? "auto_submit" : "push_to_talk";
}

function normalizeNumberRange(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.min(Math.max(parsed, min), max);
}

export function normalizeVoiceMode(value) {
  return {
    enabled: Boolean(value?.enabled),
    provider: normalizeVoiceProvider(value?.provider),
    input: {
      mode: normalizeVoiceInputMode(value?.input?.mode),
      language: String(value?.input?.language || "auto").trim() || "auto",
      previewBeforeSend: value?.input?.previewBeforeSend !== false
    },
    openAI: {
      enabled: Boolean(value?.openAI?.enabled),
      transcriptionModel: String(value?.openAI?.transcriptionModel || "gpt-4o-mini-transcribe").trim() || "gpt-4o-mini-transcribe",
      ttsModel: String(value?.openAI?.ttsModel || "gpt-4o-mini-tts").trim() || "gpt-4o-mini-tts",
      voice: String(value?.openAI?.voice || "coral").trim() || "coral",
      instructions: String(value?.openAI?.instructions || "")
    },
    local: {
      enabled: value?.local?.enabled !== false,
      voiceName: String(value?.local?.voiceName || ""),
      rate: normalizeNumberRange(value?.local?.rate, 1, 0.5, 2),
      pitch: normalizeNumberRange(value?.local?.pitch, 1, 0, 2)
    }
  };
}

export const EMPTY_CONFIG = {
  listen: { host: "0.0.0.0", port: 25101 },
  workspace: { name: ".sloppy", basePath: "~" },
  auth: { token: "dev-token" },
  onboarding: { completed: false },
  sessionRetention: { enabled: true, days: 30 },
  models: [emptyModel()],
  semanticDecisions: {
    provider: null,
    apiKey: "",
    apiKeyEnvironmentVariable: "",
    baseURL: "",
    model: "",
    timeoutMs: 2000,
    maxInputTokens: null as number | null,
    executorModelRouting: "disabled",
    minimumConfidence: 0.75,
    inputCostPerMillionTokensUSD: 0.042,
    modelProfiles: {}
  },
  opencode: {
    enabled: false,
    useResolvedConfigCommand: true,
    command: "opencode",
    configPaths: [],
    authPath: "",
    includeProviders: [],
    excludeProviders: [],
    timeoutMs: 5000
  },
  memory: {
    backend: "sqlite-local-vectors",
    provider: {
      mode: "local",
      endpoint: "",
      mcpServer: "",
      mcpTools: {
        upsert: "memory_upsert",
        query: "memory_query",
        delete: "memory_delete",
        health: "memory_health"
      },
      timeoutMs: 2500,
      apiKeyEnv: ""
    },
    retrieval: {
      topK: 8,
      semanticWeight: 0.55,
      keywordWeight: 0.35,
      graphWeight: 0.1
    },
    retention: {
      episodicDays: 90,
      todoCompletedDays: 30,
      bulletinDays: 180
    },
    embedding: {
      enabled: false,
      model: "text-embedding-3-small",
      dimensions: 1536,
      endpoint: "",
      apiKeyEnv: ""
    }
  },
  nodes: [normalizeNode("local")],
  gateways: [],
  mcp: {
    servers: []
  },
  plugins: [],
  channels: { telegram: null, discord: null, channelInactivityDays: 2 },
  searchTools: {
    activeProvider: "perplexity",
    providers: {
      brave: {
        apiKey: ""
      },
      perplexity: {
        apiKey: ""
      }
    }
  },
  imageGeneration: {
    enabled: false,
    provider: "fal",
    model: "fal-ai/flux-2",
    fal: {
      apiKey: ""
    },
    timeoutMs: 180000
  },
  gitSync: {
    enabled: false,
    authToken: "",
    repository: "",
    branch: "main",
    schedule: {
      frequency: "daily",
      time: "18:00"
    },
    conflictStrategy: "remote_wins",
    status: {
      lastAttemptAt: "",
      lastSuccessAt: "",
      lastFailureAt: "",
      lastError: "",
      lastCommit: "",
      lastFilesChanged: 0,
      failedAttempts: 0
    }
  },
  acp: {
    enabled: false,
    targets: [],
    server: {
      enabled: false,
      agentId: "",
      cwd: ""
    }
  },
  proxy: {
    enabled: false,
    type: "socks5",
    host: "",
    port: 1080,
    username: "",
    password: ""
  },
  browser: {
    enabled: false,
    executablePath: "",
    cdpEndpoint: "",
    profileName: "default",
    profilePath: "",
    headless: false,
    startupTimeoutMs: 10000,
    additionalArguments: []
  },
  voiceMode: {
    enabled: false,
    provider: "auto",
    input: {
      mode: "push_to_talk",
      language: "auto",
      previewBeforeSend: true
    },
    openAI: {
      enabled: false,
      transcriptionModel: "gpt-4o-mini-transcribe",
      ttsModel: "gpt-4o-mini-tts",
      voice: "coral",
      instructions: ""
    },
    local: {
      enabled: true,
      voiceName: "",
      rate: 1,
      pitch: 1
    }
  },
  visor: {
    scheduler: {
      enabled: true,
      intervalSeconds: 300,
      jitterSeconds: 60
    },
    bootstrapBulletin: true,
    model: null,
    bulletinMaxWords: 300,
    tickIntervalSeconds: 30,
    workerTimeoutSeconds: 600,
    branchTimeoutSeconds: 60,
    maintenanceIntervalSeconds: 3600,
    decayRatePerDay: 0.05,
    pruneImportanceThreshold: 0.1,
    pruneMinAgeDays: 30,
    channelDegradedFailureCount: 3,
    channelDegradedWindowSeconds: 600,
    idleThresholdSeconds: 1800,
    webhookURLs: [],
    mergeEnabled: false,
    mergeSimilarityThreshold: 0.80,
    mergeMaxPerRun: 10,
    autodream: {
      enabled: true,
      intervalSeconds: 21600,
      jitterSeconds: 1800,
      sessionLimitPerRun: 10,
      model: null
    }
  },
  compactor: {
    enabled: true,
    contextWindowTokens: 32000,
    levels: [
      {
        level: "soft",
        utilizationThreshold: 0.8,
        targetReductionPercent: 30,
        preserveRecentMessages: 8,
        preserveRecentTokens: 2000
      },
      {
        level: "aggressive",
        utilizationThreshold: 0.85,
        targetReductionPercent: 50,
        preserveRecentMessages: 8,
        preserveRecentTokens: 2000
      },
      {
        level: "emergency",
        utilizationThreshold: 0.95,
        targetReductionPercent: 70,
        preserveRecentMessages: 8,
        preserveRecentTokens: 2000
      }
    ],
    retry: {
      maxAttempts: 3,
      initialBackoffMs: 250,
      multiplier: 2.0,
      maxBackoffMs: 2000
    }
  },
  ui: {
    dashboardAuth: {
      enabled: false,
      token: ""
    },
    dashboardTerminal: {
      enabled: false,
      localOnly: true
    }
  },
  tui: {
    defaultEditor: ""
  },
  toolHooks: {
    preTools: {
      enabled: false,
      command: "",
      arguments: [],
      timeoutMs: 2000,
      maxOutputBytes: 65536,
      failurePolicy: "block"
    }
  },
  experimentalFlags: {
    disableToolBudgetAndLoopGuard: true,
    toolBudgetEnabled: false
  },
  toolBudgetExhausted: 60,
  modelRouting: {},
  sqlitePath: "core.sqlite"
};

export const DRAFT_CONFIG_KEY = "sloppy_draft_config";

export function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

export function normalizeModel(item, index) {
  if (typeof item === "string") {
    const [provider, name] = item.includes(":") ? item.split(":", 2) : ["", item];
    const apiUrlMap = {
      "openai-api": "https://api.openai.com/v1",
      "openai-oauth": "https://chatgpt.com/backend-api",
      openrouter: "https://openrouter.ai/api/v1",
      ollama: "http://127.0.0.1:11434",
      gemini: "https://generativelanguage.googleapis.com",
      anthropic: "https://api.anthropic.com"
    };
    return {
      title: provider ? `${provider}-${name}` : name || `model-${index + 1}`,
      apiKey: "",
      apiUrl: apiUrlMap[provider] || "",
      model: name || item,
      disabled: false,
      providerCatalogId: null
    };
  }

  const catalogRaw = item?.providerCatalogId;
  const providerCatalogId =
    typeof catalogRaw === "string" && catalogRaw.trim() ? catalogRaw.trim() : null;

  return {
    title: item?.title || `model-${index + 1}`,
    apiKey: item?.apiKey || "",
    apiUrl: item?.apiUrl || "",
    model: item?.model || "",
    disabled: Boolean(item?.disabled),
    providerCatalogId
  };
}

export function inferModelProvider(model) {
  if (model?.providerCatalogId === "sloppy" || String(model?.model || "").startsWith("sloppy:")) return "sloppy";
  const apiUrl = String(model?.apiUrl || "").toLowerCase();
  const title = String(model?.title || "").toLowerCase();
  const modelName = String(model?.model || "").toLowerCase();

  if (
    apiUrl.includes("openai") ||
    title.includes("openai") ||
    modelName.startsWith("gpt-") ||
    /^o\d/.test(modelName)
  ) {
    return "openai";
  }

  if (apiUrl.includes("openrouter") || title.includes("openrouter")) {
    return "openrouter";
  }

  if (/:1234(\/|$)/i.test(apiUrl)) {
    return "openai";
  }

  if (apiUrl.includes("ollama") || apiUrl.includes("11434") || title.includes("ollama")) {
    return "ollama";
  }

  if (apiUrl.includes("generativelanguage.googleapis.com") || title.includes("gemini") || modelName.startsWith("gemini")) {
    return "gemini";
  }

  if (apiUrl.includes("anthropic") || title.includes("anthropic") || modelName.startsWith("claude")) {
    return "anthropic";
  }

  return "custom";
}

export function inferCatalogIdForEntry(entry) {
  const raw = entry?.providerCatalogId;
  if (typeof raw === "string" && raw.trim()) {
    const id = raw.trim();
    if (PROVIDER_CATALOG.some((p) => p.id === id)) {
      return id;
    }
  }
  const p = inferModelProvider(entry);
  if (p === "openai") {
    return isOpenAIOAuthEntry(entry) ? "openai-oauth" : "openai-api";
  }
  if (p === "anthropic") {
    return isAnthropicOAuthCatalogEntry(entry) ? "anthropic-oauth" : "anthropic";
  }
  const map = {
    sloppy: "sloppy",
    openrouter: "openrouter",
    ollama: "ollama",
    gemini: "gemini"
  };
  return map[p] || null;
}

export function isOpenAIOAuthEntry(model) {
  if (model?.providerCatalogId) return model.providerCatalogId === "openai-oauth";
  if (String(model?.model || "").startsWith("openai-oauth:")) return true;
  if (String(model?.apiUrl || "").includes("chatgpt.com")) return true;
  const title = String(model?.title || "").toLowerCase();
  return title.includes("oauth") || title.includes("deeplink");
}

export function isAnthropicOAuthCatalogEntry(entry) {
  const id = String(entry?.providerCatalogId || "").trim();
  if (id === "anthropic-oauth") {
    return true;
  }
  const title = String(entry?.title || "").toLowerCase();
  return title.includes("anthropic-oauth");
}

export function findProviderModelIndex(models, providerId) {
  const direct = models.findIndex((m) => m.providerCatalogId === providerId);
  if (direct >= 0) {
    return direct;
  }
  return models.findIndex((item) => {
    if (item.providerCatalogId) {
      return false;
    }
    if (providerId === "openai-api") {
      return inferModelProvider(item) === "openai" && !isOpenAIOAuthEntry(item);
    }
    if (providerId === "openai-oauth") {
      return inferModelProvider(item) === "openai" && isOpenAIOAuthEntry(item);
    }
    if (providerId === "ollama") {
      return inferModelProvider(item) === "ollama";
    }
    if (providerId === "gemini") {
      return inferModelProvider(item) === "gemini";
    }
    if (providerId === "anthropic") {
      return inferModelProvider(item) === "anthropic" && !isAnthropicOAuthCatalogEntry(item);
    }
    if (providerId === "anthropic-oauth") {
      return inferModelProvider(item) === "anthropic" && isAnthropicOAuthCatalogEntry(item);
    }
    if (providerId === "openrouter") {
      return inferModelProvider(item) === "openrouter";
    }
    return false;
  });
}

export function getProviderDefinition(providerId) {
  return PROVIDER_CATALOG.find((provider) => provider.id === providerId) || PROVIDER_CATALOG[0];
}

export function getProviderEntry(models, providerId) {
  const index = findProviderModelIndex(models, providerId);
  if (index < 0) {
    return null;
  }
  return { index, entry: models[index] };
}

export function providerIsConfigured(provider, entry) {
  if (!entry) {
    return false;
  }
  const hasModel = Boolean(String(entry.model || "").trim());
  const hasURL = Boolean(String(entry.apiUrl || "").trim());
  if (provider.id === "gemini") {
    return hasModel && hasURL;
  }
  if (provider.id === "anthropic") {
    return hasModel && Boolean(String(entry.apiKey || "").trim());
  }
  if (provider.requiresApiKey) {
    return hasModel && hasURL && Boolean(String(entry.apiKey || "").trim());
  }
  return hasModel && hasURL;
}

export function normalizePlugin(item, index) {
  if (typeof item === "string") {
    return {
      title: item || `plugin-${index + 1}`,
      apiKey: "",
      apiUrl: "",
      plugin: item || ""
    };
  }

  return {
    title: item?.title || `plugin-${index + 1}`,
    apiKey: item?.apiKey || "",
    apiUrl: item?.apiUrl || "",
    plugin: item?.plugin || "",
    ...(item?.deliveryMode != null ? { deliveryMode: item.deliveryMode } : {}),
    ...(item?.enabled != null ? { enabled: item.enabled } : {})
  };
}

export function channelPluginToConfigEntry(item, index) {
  const pluginId = String(item?.id || item?.type || "").trim();
  return {
    title: String(item?.type || pluginId || `plugin-${index + 1}`),
    apiKey: "",
    apiUrl: String(item?.baseUrl || ""),
    plugin: pluginId,
    deliveryMode: String(item?.deliveryMode || ""),
    enabled: item?.enabled == null ? true : Boolean(item.enabled)
  };
}

export function mergeChannelPluginsIntoConfig(config, channelPlugins) {
  if (!Array.isArray(channelPlugins) || channelPlugins.length === 0) {
    return config;
  }

  const merged = clone(config);
  if (!Array.isArray(merged.plugins)) {
    merged.plugins = [];
  }

  for (const [index, channelPlugin] of channelPlugins.entries()) {
    const entry = channelPluginToConfigEntry(channelPlugin, index);
    if (!entry.plugin) {
      continue;
    }

    const existingIndex = merged.plugins.findIndex((item) =>
      String(item?.plugin || "").trim() === entry.plugin
    );
    if (existingIndex >= 0) {
      merged.plugins[existingIndex] = {
        ...entry,
        ...merged.plugins[existingIndex],
        title: merged.plugins[existingIndex].title || entry.title,
        apiUrl: merged.plugins[existingIndex].apiUrl || entry.apiUrl,
        deliveryMode: entry.deliveryMode,
        enabled: entry.enabled
      };
    } else {
      merged.plugins.push(entry);
    }
  }

  return merged;
}

export function normalizeMCPServer(item, index) {
  const base = emptyMCPServer();
  const transport = String(item?.transport || base.transport).trim().toLowerCase();
  const headers = item?.headers && typeof item.headers === "object" && !Array.isArray(item.headers)
    ? Object.fromEntries(
      Object.entries(item.headers).map(([key, value]) => [String(key), String(value)])
    )
    : {};

  return {
    ...base,
    id: String(item?.id || `mcp-server-${index + 1}`),
    transport: transport === "http" ? "http" : "stdio",
    command: String(item?.command || ""),
    arguments: Array.isArray(item?.arguments) ? item.arguments.map((arg) => String(arg)) : [],
    cwd: String(item?.cwd || ""),
    endpoint: String(item?.endpoint || ""),
    headers,
    timeoutMs: parseInteger(item?.timeoutMs ?? base.timeoutMs, base.timeoutMs),
    enabled: item?.enabled == null ? true : Boolean(item.enabled),
    exposeTools: item?.exposeTools == null ? true : Boolean(item.exposeTools),
    exposeResources: item?.exposeResources == null ? true : Boolean(item.exposeResources),
    exposePrompts: item?.exposePrompts == null ? true : Boolean(item.exposePrompts),
    toolPrefix: String(item?.toolPrefix || "")
  };
}

export function normalizeConfig(config) {
  const normalized = clone(EMPTY_CONFIG);

  normalized.listen.host = config?.listen?.host || normalized.listen.host;
  normalized.listen.port = parseInteger(config?.listen?.port ?? normalized.listen.port, normalized.listen.port);
  normalized.workspace.name = config?.workspace?.name || normalized.workspace.name;
  normalized.workspace.basePath = config?.workspace?.basePath || normalized.workspace.basePath;
  normalized.auth.token = config?.auth?.token || normalized.auth.token;
  normalized.onboarding.completed = Boolean(config?.onboarding?.completed);
  normalized.sessionRetention.enabled = config?.sessionRetention?.enabled !== false;
  normalized.sessionRetention.days = Math.min(
    90,
    Math.max(1, parseInteger(
      config?.sessionRetention?.days ?? config?.sessionRetention?.retentionDays ?? 30,
      30
    ))
  );
  normalized.opencode.enabled = Boolean(config?.opencode?.enabled);
  normalized.opencode.useResolvedConfigCommand = config?.opencode?.useResolvedConfigCommand !== false;
  normalized.opencode.command = String(config?.opencode?.command || normalized.opencode.command).trim() || "opencode";
  normalized.opencode.configPaths = Array.isArray(config?.opencode?.configPaths)
    ? config.opencode.configPaths.map((item) => String(item || "").trim()).filter(Boolean)
    : [];
  normalized.opencode.authPath = String(config?.opencode?.authPath || "");
  normalized.opencode.includeProviders = Array.isArray(config?.opencode?.includeProviders)
    ? config.opencode.includeProviders.map((item) => String(item || "").trim()).filter(Boolean)
    : [];
  normalized.opencode.excludeProviders = Array.isArray(config?.opencode?.excludeProviders)
    ? config.opencode.excludeProviders.map((item) => String(item || "").trim()).filter(Boolean)
    : [];
  normalized.opencode.timeoutMs = parseInteger(config?.opencode?.timeoutMs ?? 5000, 5000);
  normalized.memory.backend = config?.memory?.backend || normalized.memory.backend;
  normalized.memory.provider.mode = String(config?.memory?.provider?.mode || normalized.memory.provider.mode);
  normalized.memory.provider.endpoint = String(config?.memory?.provider?.endpoint || "");
  normalized.memory.provider.mcpServer = String(config?.memory?.provider?.mcpServer || "");
  normalized.memory.provider.mcpTools.upsert = String(config?.memory?.provider?.mcpTools?.upsert || normalized.memory.provider.mcpTools.upsert);
  normalized.memory.provider.mcpTools.query = String(config?.memory?.provider?.mcpTools?.query || normalized.memory.provider.mcpTools.query);
  normalized.memory.provider.mcpTools.delete = String(config?.memory?.provider?.mcpTools?.delete || normalized.memory.provider.mcpTools.delete);
  normalized.memory.provider.mcpTools.health = String(config?.memory?.provider?.mcpTools?.health || normalized.memory.provider.mcpTools.health);
  normalized.memory.provider.timeoutMs = parseInteger(
    config?.memory?.provider?.timeoutMs ?? normalized.memory.provider.timeoutMs,
    normalized.memory.provider.timeoutMs
  );
  normalized.memory.provider.apiKeyEnv = String(config?.memory?.provider?.apiKeyEnv || "");

  normalized.memory.retrieval.topK = parseInteger(
    config?.memory?.retrieval?.topK ?? normalized.memory.retrieval.topK,
    normalized.memory.retrieval.topK
  );
  normalized.memory.retrieval.semanticWeight = parseNumber(
    config?.memory?.retrieval?.semanticWeight ?? normalized.memory.retrieval.semanticWeight,
    normalized.memory.retrieval.semanticWeight
  );
  normalized.memory.retrieval.keywordWeight = parseNumber(
    config?.memory?.retrieval?.keywordWeight ?? normalized.memory.retrieval.keywordWeight,
    normalized.memory.retrieval.keywordWeight
  );
  normalized.memory.retrieval.graphWeight = parseNumber(
    config?.memory?.retrieval?.graphWeight ?? normalized.memory.retrieval.graphWeight,
    normalized.memory.retrieval.graphWeight
  );

  normalized.memory.retention.episodicDays = parseInteger(
    config?.memory?.retention?.episodicDays ?? normalized.memory.retention.episodicDays,
    normalized.memory.retention.episodicDays
  );
  normalized.memory.retention.todoCompletedDays = parseInteger(
    config?.memory?.retention?.todoCompletedDays ?? normalized.memory.retention.todoCompletedDays,
    normalized.memory.retention.todoCompletedDays
  );
  normalized.memory.retention.bulletinDays = parseInteger(
    config?.memory?.retention?.bulletinDays ?? normalized.memory.retention.bulletinDays,
    normalized.memory.retention.bulletinDays
  );
  normalized.memory.embedding.enabled = Boolean(config?.memory?.embedding?.enabled);
  normalized.memory.embedding.model = String(config?.memory?.embedding?.model || normalized.memory.embedding.model);
  normalized.memory.embedding.dimensions = parseInteger(
    config?.memory?.embedding?.dimensions ?? normalized.memory.embedding.dimensions,
    normalized.memory.embedding.dimensions
  );
  normalized.memory.embedding.endpoint = String(config?.memory?.embedding?.endpoint || "");
  normalized.memory.embedding.apiKeyEnv = String(config?.memory?.embedding?.apiKeyEnv || "");
  normalized.sqlitePath = config?.sqlitePath || normalized.sqlitePath;
  normalized.ui.dashboardAuth.enabled = Boolean(config?.ui?.dashboardAuth?.enabled);
  normalized.ui.dashboardAuth.token = String(config?.ui?.dashboardAuth?.token || "");
  normalized.ui.dashboardTerminal.enabled = Boolean(config?.ui?.dashboardTerminal?.enabled);
  normalized.ui.dashboardTerminal.localOnly =
    config?.ui?.dashboardTerminal?.localOnly == null ? true : Boolean(config?.ui?.dashboardTerminal?.localOnly);
  normalized.tui.defaultEditor = String(config?.tui?.defaultEditor || "");
  normalized.toolHooks.preTools.enabled = Boolean(config?.toolHooks?.preTools?.enabled);
  normalized.toolHooks.preTools.command = String(config?.toolHooks?.preTools?.command || "");
  normalized.toolHooks.preTools.arguments = Array.isArray(config?.toolHooks?.preTools?.arguments)
    ? config.toolHooks.preTools.arguments.map((item) => String(item || ""))
    : [];
  normalized.toolHooks.preTools.timeoutMs = parseInteger(
    config?.toolHooks?.preTools?.timeoutMs ?? normalized.toolHooks.preTools.timeoutMs,
    normalized.toolHooks.preTools.timeoutMs
  );
  normalized.toolHooks.preTools.maxOutputBytes = parseInteger(
    config?.toolHooks?.preTools?.maxOutputBytes ?? normalized.toolHooks.preTools.maxOutputBytes,
    normalized.toolHooks.preTools.maxOutputBytes
  );
  normalized.toolHooks.preTools.failurePolicy =
    String(config?.toolHooks?.preTools?.failurePolicy || "block") === "allow" ? "allow" : "block";
  normalized.experimentalFlags.disableToolBudgetAndLoopGuard =
    config?.experimentalFlags?.disableToolBudgetAndLoopGuard !== false;
  normalized.experimentalFlags.toolBudgetEnabled =
    (config?.experimentalFlags?.toolBudgetEnabled ?? config?.toolBudgetEnabled) === true;
  normalized.toolBudgetExhausted = Math.max(
    0,
    parseInteger(config?.toolBudgetExhausted ?? normalized.toolBudgetExhausted, normalized.toolBudgetExhausted)
  );

  const semantic = config?.semanticDecisions;
  const semanticProvider = String(semantic?.provider || "").trim().toLowerCase();
  normalized.semanticDecisions.provider = ["typesafe", "vercel", "laya"].includes(semanticProvider)
    ? semanticProvider
    : null;
  normalized.semanticDecisions.apiKey = String(semantic?.apiKey || "");
  normalized.semanticDecisions.apiKeyEnvironmentVariable = String(semantic?.apiKeyEnvironmentVariable || "").trim();
  normalized.semanticDecisions.baseURL = String(semantic?.baseURL || "").trim();
  normalized.semanticDecisions.model = String(semantic?.model || "").trim();
  normalized.semanticDecisions.maxInputTokens = semantic?.maxInputTokens == null
    ? null
    : Math.min(8192, Math.max(1, parseInteger(semantic.maxInputTokens, 1024)));
  normalized.semanticDecisions.timeoutMs = Math.max(100, parseInteger(semantic?.timeoutMs ?? 2000, 2000));
  const semanticMode = String(semantic?.executorModelRouting || "disabled").trim().toLowerCase();
  normalized.semanticDecisions.executorModelRouting = ["disabled", "shadow", "active"].includes(semanticMode)
    ? semanticMode
    : "disabled";
  normalized.semanticDecisions.minimumConfidence = normalizeNumberRange(
    semantic?.minimumConfidence,
    0.75,
    0,
    1
  );
  normalized.semanticDecisions.inputCostPerMillionTokensUSD = Math.max(
    0,
    Number(semantic?.inputCostPerMillionTokensUSD ?? (semanticProvider === "laya" ? 0 : 0.042)) || 0
  );
  normalized.semanticDecisions.modelProfiles = {};
  if (semantic?.modelProfiles && typeof semantic.modelProfiles === "object" && !Array.isArray(semantic.modelProfiles)) {
    for (const [profileId, rawProfile] of Object.entries(semantic.modelProfiles)) {
      const id = String(profileId || "").trim();
      const profile = rawProfile && typeof rawProfile === "object"
        ? rawProfile as Record<string, unknown>
        : {};
      const model = String(profile.model || "").trim();
      if (!id || !model) continue;
      normalized.semanticDecisions.modelProfiles[id] = {
        model,
        description: String(profile.description || "").trim()
      };
    }
  }

  const mr = config?.modelRouting;
  normalized.modelRouting = {};
  if (mr && typeof mr === "object" && !Array.isArray(mr)) {
    for (const [k, v] of Object.entries(mr)) {
      const key = String(k).trim();
      const val = String(v ?? "").trim();
      if (key && val) {
        normalized.modelRouting[key] = val;
      }
    }
  }

  normalized.gitSync.enabled = Boolean(config?.gitSync?.enabled);
  normalized.gitSync.authToken = String(config?.gitSync?.authToken || "");
  normalized.gitSync.repository = String(config?.gitSync?.repository || "");
  normalized.gitSync.branch = String(config?.gitSync?.branch || normalized.gitSync.branch);
  normalized.gitSync.schedule.frequency = normalizeGitSyncFrequency(
    config?.gitSync?.schedule?.frequency,
    normalized.gitSync.schedule.frequency
  );
  normalized.gitSync.schedule.time = normalizeTimeValue(
    config?.gitSync?.schedule?.time,
    normalized.gitSync.schedule.time
  );
  normalized.gitSync.conflictStrategy = normalizeGitSyncConflictStrategy(
    config?.gitSync?.conflictStrategy,
    normalized.gitSync.conflictStrategy
  );
  normalized.gitSync.status = normalizeGitSyncStatus(config?.gitSync?.status);

  normalized.nodes = Array.isArray(config?.nodes)
    ? config.nodes.filter(Boolean).map((node, index) => normalizeNode(node, index))
    : [];
  normalized.gateways = Array.isArray(config?.gateways) ? config.gateways.filter(Boolean) : [];
  normalized.mcp.servers = Array.isArray(config?.mcp?.servers)
    ? config.mcp.servers.map((server, index) => normalizeMCPServer(server, index))
    : [];

  const models = Array.isArray(config?.models) ? config.models : [];
  normalized.models = models.map(normalizeModel);
  if (normalized.models.length === 0) {
    normalized.models.push(clone(PROVIDER_CATALOG[0].defaultEntry));
  }

  const plugins = Array.isArray(config?.plugins) ? config.plugins : [];
  normalized.plugins = plugins.map(normalizePlugin);

  const tg = config?.channels?.telegram;
  const dc = config?.channels?.discord;

  normalized.channels = {
    telegram: tg && typeof tg === "object"
      ? {
        botToken: String(tg.botToken || ""),
        channelChatMap: tg.channelChatMap && typeof tg.channelChatMap === "object" ? tg.channelChatMap : {},
        topicChannelMap: tg.topicChannelMap && typeof tg.topicChannelMap === "object" ? tg.topicChannelMap : {},
        allowedUserIds: Array.isArray(tg.allowedUserIds) ? tg.allowedUserIds : [],
        allowedChatIds: Array.isArray(tg.allowedChatIds) ? tg.allowedChatIds : []
      }
      : null,
    discord: dc && typeof dc === "object"
      ? {
        botToken: String(dc.botToken || ""),
        guildId: String(dc.guildId || ""),
        channelAgentMap: dc.channelAgentMap && typeof dc.channelAgentMap === "object" ? dc.channelAgentMap : {}
      }
      : null,
    channelInactivityDays: parseInteger(config?.channels?.channelInactivityDays ?? 2, 2)
  };

  normalized.searchTools.activeProvider =
    String(config?.searchTools?.activeProvider || normalized.searchTools.activeProvider).trim().toLowerCase() === "brave"
      ? "brave"
      : "perplexity";
  normalized.searchTools.providers.brave.apiKey = String(config?.searchTools?.providers?.brave?.apiKey || "");
  normalized.searchTools.providers.perplexity.apiKey = String(config?.searchTools?.providers?.perplexity?.apiKey || "");
  normalized.imageGeneration.enabled = Boolean(config?.imageGeneration?.enabled);
  normalized.imageGeneration.provider = String(config?.imageGeneration?.provider || "fal").trim().toLowerCase() === "openai"
    ? "openai"
    : "fal";
  const defaultImageModel = normalized.imageGeneration.provider === "openai" ? "gpt-image-2" : "fal-ai/flux-2";
  normalized.imageGeneration.model = String(config?.imageGeneration?.model || defaultImageModel).trim() || defaultImageModel;
  normalized.imageGeneration.fal.apiKey = String(config?.imageGeneration?.fal?.apiKey || "");
  normalized.imageGeneration.timeoutMs = Math.min(
    600000,
    Math.max(10000, parseInteger(config?.imageGeneration?.timeoutMs ?? 180000, 180000))
  );

  normalized.acp.enabled = Boolean(config?.acp?.enabled);
  normalized.acp.targets = Array.isArray(config?.acp?.targets) ? config.acp.targets : [];
  normalized.acp.server = {
    enabled: Boolean(config?.acp?.server?.enabled),
    agentId: String(config?.acp?.server?.agentId || ""),
    cwd: String(config?.acp?.server?.cwd || "")
  };

  normalized.proxy.enabled = Boolean(config?.proxy?.enabled);
  normalized.proxy.type = normalizeProxyType(config?.proxy?.type);
  normalized.proxy.host = String(config?.proxy?.host || "");
  normalized.proxy.port = parseInteger(config?.proxy?.port ?? 1080, 1080);
  normalized.proxy.username = String(config?.proxy?.username || "");
  normalized.proxy.password = String(config?.proxy?.password || "");

  normalized.browser.enabled = Boolean(config?.browser?.enabled);
  normalized.browser.executablePath = String(config?.browser?.executablePath || "");
  normalized.browser.cdpEndpoint = String(config?.browser?.cdpEndpoint || "");
  normalized.browser.profileName = String(config?.browser?.profileName || "default").trim() || "default";
  normalized.browser.profilePath = String(config?.browser?.profilePath || "");
  normalized.browser.headless = Boolean(config?.browser?.headless);
  normalized.browser.startupTimeoutMs = parseInteger(config?.browser?.startupTimeoutMs ?? 10000, 10000);
  normalized.browser.additionalArguments = Array.isArray(config?.browser?.additionalArguments)
    ? config.browser.additionalArguments.map((arg) => String(arg)).filter(Boolean)
    : [];
  normalized.voiceMode = normalizeVoiceMode(config?.voiceMode);

  const cc = config?.compactor;
  normalized.compactor.enabled = cc?.enabled !== false;
  normalized.compactor.contextWindowTokens = Math.max(1, parseInteger(
    cc?.contextWindowTokens ?? normalized.compactor.contextWindowTokens,
    normalized.compactor.contextWindowTokens
  ));
  normalized.compactor.levels = Array.isArray(cc?.levels) && cc.levels.length > 0
    ? cc.levels.map((level) => {
      const rawThreshold = level?.utilizationThreshold ?? (level?.thresholdPercent != null ? Number(level.thresholdPercent) / 100 : 0.8);
      const thresholdRatio = Number(rawThreshold) > 1 ? Number(rawThreshold) / 100 : Number(rawThreshold);
      return {
        level: ["soft", "aggressive", "emergency"].includes(String(level?.level)) ? String(level.level) : "soft",
        utilizationThreshold: Math.min(1, Math.max(0, Number.isFinite(thresholdRatio) ? thresholdRatio : 0.8)),
        targetReductionPercent: Math.min(100, Math.max(1, parseInteger(level?.targetReductionPercent ?? 50, 50))),
        preserveRecentMessages: Math.max(0, parseInteger(level?.preserveRecentMessages ?? 8, 8)),
        preserveRecentTokens: Math.max(0, parseInteger(level?.preserveRecentTokens ?? 2000, 2000))
      };
    })
    : normalized.compactor.levels;
  normalized.compactor.retry = {
    maxAttempts: Math.max(1, parseInteger(cc?.retry?.maxAttempts ?? normalized.compactor.retry.maxAttempts, normalized.compactor.retry.maxAttempts)),
    initialBackoffMs: Math.max(0, parseInteger(cc?.retry?.initialBackoffMs ?? normalized.compactor.retry.initialBackoffMs, normalized.compactor.retry.initialBackoffMs)),
    multiplier: Math.max(1, parseNumber(cc?.retry?.multiplier ?? normalized.compactor.retry.multiplier, normalized.compactor.retry.multiplier)),
    maxBackoffMs: Math.max(0, parseInteger(cc?.retry?.maxBackoffMs ?? normalized.compactor.retry.maxBackoffMs, normalized.compactor.retry.maxBackoffMs))
  };

  const vc = config?.visor;
  normalized.visor.scheduler.enabled = vc?.scheduler?.enabled !== false;
  normalized.visor.scheduler.intervalSeconds = parseInteger(vc?.scheduler?.intervalSeconds ?? 300, 300);
  normalized.visor.scheduler.jitterSeconds = parseInteger(vc?.scheduler?.jitterSeconds ?? 60, 60);
  normalized.visor.bootstrapBulletin = vc?.bootstrapBulletin !== false;
  normalized.visor.model = vc?.model ? String(vc.model) : null;
  normalized.visor.bulletinMaxWords = parseInteger(vc?.bulletinMaxWords ?? 300, 300);
  normalized.visor.tickIntervalSeconds = parseInteger(vc?.tickIntervalSeconds ?? 30, 30);
  normalized.visor.workerTimeoutSeconds = parseInteger(vc?.workerTimeoutSeconds ?? 600, 600);
  normalized.visor.branchTimeoutSeconds = parseInteger(vc?.branchTimeoutSeconds ?? 60, 60);
  normalized.visor.maintenanceIntervalSeconds = parseInteger(vc?.maintenanceIntervalSeconds ?? 3600, 3600);
  normalized.visor.decayRatePerDay = parseNumber(vc?.decayRatePerDay ?? 0.05, 0.05);
  normalized.visor.pruneImportanceThreshold = parseNumber(vc?.pruneImportanceThreshold ?? 0.1, 0.1);
  normalized.visor.pruneMinAgeDays = parseInteger(vc?.pruneMinAgeDays ?? 30, 30);
  normalized.visor.channelDegradedFailureCount = parseInteger(vc?.channelDegradedFailureCount ?? 3, 3);
  normalized.visor.channelDegradedWindowSeconds = parseInteger(vc?.channelDegradedWindowSeconds ?? 600, 600);
  normalized.visor.idleThresholdSeconds = parseInteger(vc?.idleThresholdSeconds ?? 1800, 1800);
  normalized.visor.webhookURLs = Array.isArray(vc?.webhookURLs) ? vc.webhookURLs.filter(Boolean) : [];
  normalized.visor.mergeEnabled = Boolean(vc?.mergeEnabled);
  normalized.visor.mergeSimilarityThreshold = parseNumber(vc?.mergeSimilarityThreshold ?? 0.80, 0.80);
  normalized.visor.mergeMaxPerRun = parseInteger(vc?.mergeMaxPerRun ?? 10, 10);
  normalized.visor.autodream = {
    enabled: vc?.autodream?.enabled !== false,
    intervalSeconds: parseInteger(vc?.autodream?.intervalSeconds ?? 21600, 21600),
    jitterSeconds: parseInteger(vc?.autodream?.jitterSeconds ?? 1800, 1800),
    sessionLimitPerRun: parseInteger(vc?.autodream?.sessionLimitPerRun ?? 10, 10),
    model: vc?.autodream?.model ? String(vc.autodream.model) : null
  };

  return normalized;
}

/** JSON.stringify ignores key order; server round-trips and UI mutations can reorder keys while staying semantically equal. */
export function stableConfigStringify(value) {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableConfigStringify(item)).join(",")}]`;
  }
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableConfigStringify(value[k])}`).join(",")}}`;
}

export function parseLines(value) {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

export function parseConfigList(value) {
  return String(value || "")
    .split(/[\n,]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

export function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function parseNumber(value, fallback) {
  const parsed = Number.parseFloat(String(value));
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function normalizeGitSyncFrequency(value, fallback = "daily") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  return GIT_SYNC_FREQUENCIES.has(normalized) ? normalized : fallback;
}

export function normalizeGitSyncConflictStrategy(value, fallback = "remote_wins") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  return GIT_SYNC_CONFLICT_STRATEGIES.has(normalized) ? normalized : fallback;
}

export function normalizeGitSyncStatus(value) {
  const status = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  return {
    lastAttemptAt: String(status.lastAttemptAt || ""),
    lastSuccessAt: String(status.lastSuccessAt || ""),
    lastFailureAt: String(status.lastFailureAt || ""),
    lastError: String(status.lastError || ""),
    lastCommit: String(status.lastCommit || ""),
    lastFilesChanged: parseInteger(status.lastFilesChanged ?? 0, 0),
    failedAttempts: parseInteger(status.failedAttempts ?? 0, 0)
  };
}

export function normalizeTimeValue(value, fallback = "18:00") {
  const normalized = String(value || "").trim();
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(normalized) ? normalized : fallback;
}

export function normalizeProxyType(value, fallback = "socks5") {
  const normalized = String(value || "").trim().toLowerCase();
  return PROXY_TYPES.has(normalized) ? normalized : fallback;
}

export function isSettingsSection(id) {
  return id === "memory" || id === "memory-dreams" || SETTINGS_ITEMS.some((item) => item.id === id);
}
