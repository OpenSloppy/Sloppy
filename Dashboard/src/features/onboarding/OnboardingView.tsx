import { MigrationLaunchNotice } from "../migrations/MigrationWizard";
import React, { useEffect, useMemo, useRef, useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import type { CoreApi } from "../../shared/api/coreApi";
import { setDashboardAuthToken } from "../../shared/api/dashboardAuth";
import { AgentGeneratePreview, type GeneratedAgentFiles } from "../agents/components/AgentGeneratePreview";
import orchestratorImage from "../../assets/orchestrator.png";
import sloppyAgentsMd from "./agents/sloppy/AGENTS.md?raw";
import sloppyBootstrapMd from "./agents/sloppy/BOOTSTRAP.md?raw";
import ceoAgentsMd from "./agents/ceo/AGENTS.md?raw";
import ceoBootstrapMd from "./agents/ceo/BOOTSTRAP.md?raw";

type AnyRecord = Record<string, unknown>;

interface OnboardingViewProps {
  coreApi: CoreApi;
  initialConfig: AnyRecord;
  onCompleted: (config: AnyRecord) => void;
  onAuthenticated?: () => void;
}

interface ProviderDefinition {
  id: string;
  title: string;
  description: string;
  requiresApiKey: boolean;
  authHint: string;
  defaultEntry: {
    title: string;
    apiKey: string;
    apiUrl: string;
    model: string;
  };
}

const PROVIDERS: ProviderDefinition[] = [
  {
    id: "openai-api",
    title: "OpenAI API",
    description: "Hosted OpenAI models via API key auth.",
    requiresApiKey: true,
    authHint: "Uses payload key, saved config key, or OPENAI_API_KEY.",
    defaultEntry: {
      title: "openai-api",
      apiKey: "",
      apiUrl: "https://api.openai.com/v1",
      model: "gpt-5.4-mini"
    }
  },
  {
    id: "openrouter",
    title: "OpenRouter",
    description: "Many models through one OpenAI-compatible API.",
    requiresApiKey: true,
    authHint: "Uses payload key, saved config key, or OPENROUTER_API_KEY.",
    defaultEntry: {
      title: "openrouter",
      apiKey: "",
      apiUrl: "https://openrouter.ai/api/v1",
      model: "openai/gpt-5.4-mini"
    }
  },
  {
    id: "gemini",
    title: "Google Gemini",
    description: "Google Gemini models via API key auth.",
    requiresApiKey: true,
    authHint: "Uses payload key, saved config key, or GEMINI_API_KEY.",
    defaultEntry: {
      title: "gemini",
      apiKey: "",
      apiUrl: "https://generativelanguage.googleapis.com",
      model: "gemini-2.5-flash"
    }
  },
  {
    id: "anthropic-oauth",
    title: "Anthropic",
    description: "Claude via Anthropic OAuth or Claude Code token.",
    requiresApiKey: true,
    authHint: "Paste an OAuth or setup token (not sk-ant-api Console keys).",
    defaultEntry: {
      title: "anthropic-oauth",
      apiKey: "",
      apiUrl: "https://api.anthropic.com",
      model: "claude-sonnet-4-6"
    }
  },
  {
    id: "openai-oauth",
    title: "OpenAI Codex",
    description: "ChatGPT/Codex login via OpenAI OAuth.",
    requiresApiKey: false,
    authHint: "Uses OAuth tokens stored by Sloppy. Connection test loads Codex models from the ChatGPT backend.",
    defaultEntry: {
      title: "openai-oauth",
      apiKey: "",
      apiUrl: "https://chatgpt.com/backend-api",
      model: "gpt-5.4"
    }
  },
  {
    id: "ollama",
    title: "Ollama",
    description: "Local models served from an Ollama endpoint.",
    requiresApiKey: false,
    authHint: "Connects to /api/tags and lists local models.",
    defaultEntry: {
      title: "ollama-local",
      apiKey: "",
      apiUrl: "http://127.0.0.1:11434",
      model: "qwen3"
    }
  }
];

const STEP_TITLES = [
  "Dashboard auth",
  "LLM provider",
  "First agent",
  "Launch prompt"
];

interface AgentPresetDefinition {
  id: string;
  title: string;
  description: string;
  icon: string;
  defaultName: string;
  defaultRole: string;
  agentsMarkdown: string;
  bootstrapPrompt: string;
}

const AGENT_PRESETS: AgentPresetDefinition[] = [
  {
    id: "sloppy",
    title: "Sloppy",
    description: "Default Sloppy AI agent — universal helper and operator.",
    icon: "smart_toy",
    defaultName: "SLOPPY",
    defaultRole: "SLOPPY",
    agentsMarkdown: sloppyAgentsMd,
    bootstrapPrompt: sloppyBootstrapMd
  },
  {
    id: "ceo",
    title: "CEO",
    description: "Strategic CEO agent — sets direction, delegates, and reviews.",
    icon: "business_center",
    defaultName: "CEO",
    defaultRole: "CEO",
    agentsMarkdown: ceoAgentsMd,
    bootstrapPrompt: ceoBootstrapMd
  },
  {
    id: "custom",
    title: "Custom",
    description: "Write your own agent instructions from scratch.",
    icon: "edit_note",
    defaultName: "",
    defaultRole: "",
    agentsMarkdown: "",
    bootstrapPrompt: ""
  },
  {
    id: "generate",
    title: "AI Generate",
    description: "Let AI generate full agent configuration files.",
    icon: "auto_awesome",
    defaultName: "",
    defaultRole: "",
    agentsMarkdown: "",
    bootstrapPrompt: sloppyBootstrapMd
  }
];

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function buildOnboardingGeneratePrompt(agentId: string, agentName: string, agentRole: string, description: string) {
  return `Generate 4 markdown configuration files for a Sloppy AI agent.

Agent ID: ${agentId}
Display Name: ${agentName}
Role: ${agentRole}
Agent responsibility: ${description}

Output exactly 4 files using the markers below. Include only the file content between markers — no extra text outside the markers.

--- AGENTS.md ---
(Write main behavior instructions, responsibilities, operating rules, and capabilities for this agent)
--- IDENTITY.md ---
(Write personality, communication style, tone, and character traits)
--- SOUL.md ---
(Write core values, principles, and decision-making framework)
--- USER.md ---
(Write how to interact with users, preferred response format, and user interaction guidelines)`;
}

function parseOnboardingGeneratedFiles(text: string): GeneratedAgentFiles {
  const markers: Record<keyof GeneratedAgentFiles, string> = {
    agentsMarkdown: "--- AGENTS.md ---",
    identityMarkdown: "--- IDENTITY.md ---",
    soulMarkdown: "--- SOUL.md ---",
    userMarkdown: "--- USER.md ---"
  };

  const markerKeys = Object.keys(markers) as (keyof GeneratedAgentFiles)[];
  const result: GeneratedAgentFiles = { agentsMarkdown: "", identityMarkdown: "", soulMarkdown: "", userMarkdown: "" };

  for (let i = 0; i < markerKeys.length; i++) {
    const key = markerKeys[i];
    const marker = markers[key];
    const startIdx = text.indexOf(marker);
    if (startIdx === -1) continue;

    const contentStart = startIdx + marker.length;
    const nextMarker = i + 1 < markerKeys.length ? markers[markerKeys[i + 1]] : null;
    const endIdx = nextMarker ? text.indexOf(nextMarker, contentStart) : text.length;
    result[key] = (endIdx === -1 ? text.slice(contentStart) : text.slice(contentStart, endIdx)).trim();
  }

  return result;
}

function toSlug(value: string) {
  const slug = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");

  return slug || "id-" + Math.random().toString(36).substring(2, 7);
}

function inferProviderId(config: AnyRecord) {
  const models = Array.isArray(config.models) ? config.models : [];
  const first = models.find((item) => item && typeof item === "object") as AnyRecord | undefined;
  const catalogId = String(first?.providerCatalogId || "").trim();
  if (catalogId === "anthropic-oauth") {
    return "anthropic-oauth";
  }
  if (catalogId === "openai-oauth") {
    return "openai-oauth";
  }
  const title = String(first?.title || "").toLowerCase();
  const apiUrl = String(first?.apiUrl || "").toLowerCase();

  if (title.includes("anthropic-oauth")) {
    return "anthropic-oauth";
  }
  if (title.includes("oauth") && !title.includes("anthropic") && !apiUrl.includes("anthropic")) {
    return "openai-oauth";
  }
  if (title.includes("ollama") || apiUrl.includes("11434") || apiUrl.includes("ollama")) {
    return "ollama";
  }
  if (title.includes("gemini") || apiUrl.includes("generativelanguage.googleapis.com")) {
    return "gemini";
  }
  if (title.includes("anthropic") || apiUrl.includes("anthropic")) {
    return "anthropic";
  }
  if (title.includes("openrouter") || apiUrl.includes("openrouter")) {
    return "openrouter";
  }
  return "openai-api";
}

function initialProviderState(config: AnyRecord) {
  const providerId = inferProviderId(config);
  const definition = PROVIDERS.find((provider) => provider.id === providerId) || PROVIDERS[0];
  const models = Array.isArray(config.models) ? config.models : [];
  const entry = (models.find((item) => item && typeof item === "object") as AnyRecord | undefined) || {};

  return {
    providerId,
    apiKey: String(entry.apiKey || definition.defaultEntry.apiKey || ""),
    apiUrl: String(entry.apiUrl || definition.defaultEntry.apiUrl || ""),
    selectedModel: String(entry.model || "")
  };
}

function runtimeModelId(providerId: string, modelId: string) {
  if (providerId === "openai-oauth") {
    return `openai-oauth:${modelId}`;
  }
  if (providerId === "openai-api") {
    return `openai-api:${modelId}`;
  }
  if (providerId === "openrouter") {
    return `openrouter:${modelId}`;
  }
  if (providerId === "ollama") {
    return `ollama:${modelId}`;
  }
  if (providerId === "gemini") {
    return `gemini:${modelId}`;
  }
  if (providerId === "anthropic" || providerId === "anthropic-oauth") {
    return `anthropic:${modelId}`;
  }
  return modelId;
}

function createConfigWithProvider(
  config: AnyRecord,
  provider: ProviderDefinition,
  apiKey: string,
  apiUrl: string,
  modelId: string,
  onboardingCompleted: boolean
) {
  const next = clone(config);
  next.workspace = {
    ...(typeof next.workspace === "object" && next.workspace ? (next.workspace as AnyRecord) : {}),
    name: ".sloppy",
    basePath: String((next.workspace as AnyRecord | undefined)?.basePath || "~")
  };
  next.onboarding = { completed: onboardingCompleted };
  next.models = [
    {
      title: provider.defaultEntry.title,
      apiKey: provider.requiresApiKey ? apiKey.trim() : "",
      apiUrl: apiUrl.trim() || provider.defaultEntry.apiUrl,
      model: modelId.trim() || provider.defaultEntry.model,
      providerCatalogId: provider.id
    }
  ];
  return next;
}

function createConfigWithoutProvider(config: AnyRecord, onboardingCompleted: boolean) {
  const next = clone(config);
  next.workspace = {
    ...(typeof next.workspace === "object" && next.workspace ? (next.workspace as AnyRecord) : {}),
    name: ".sloppy",
    basePath: String((next.workspace as AnyRecord | undefined)?.basePath || "~")
  };
  next.onboarding = { completed: onboardingCompleted };
  return next;
}

function providerCardIcon(providerId: string) {
  if (providerId === "openai-api") {
    return "auto_awesome";
  }
  if (providerId === "openai-oauth") {
    return "login";
  }
  if (providerId === "openrouter") {
    return "hub";
  }
  if (providerId === "gemini") {
    return "diamond";
  }
  if (providerId === "anthropic" || providerId === "anthropic-oauth") {
    return "psychology";
  }
  return "deployed_code";
}

const ASCII_RAMPS = [
  "  .`',;:-~+=!|xXYH$&#@",
  "   .^\":;!iIlYVWHM#&@",
  "  ._-~:;+=*xX#%$@"
];

function clampValue(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), max);
}

function buildAsciiGrid(source: HTMLImageElement, columns: number) {
  const rows = Math.max(22, Math.round(columns * (source.height / source.width) * 0.54));
  const offscreen = document.createElement("canvas");
  offscreen.width = columns;
  offscreen.height = rows;

  const ctx = offscreen.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;

  ctx.drawImage(source, 0, 0, columns, rows);
  const pixels = ctx.getImageData(0, 0, columns, rows).data;
  const grid: number[][] = [];

  for (let r = 0; r < rows; r++) {
    const row: number[] = [];
    for (let c = 0; c < columns; c++) {
      const offset = (r * columns + c) * 4;
      const brightness = pixels[offset] * 0.299 + pixels[offset + 1] * 0.587 + pixels[offset + 2] * 0.114;
      row.push(brightness);
    }
    grid.push(row);
  }
  return grid;
}

function OnboardingAsciiCanvas({
  stepIndex,
  agentName,
  providerTitle
}: {
  stepIndex: number;
  agentName: string;
  providerTitle: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const gridRef = useRef<number[][] | null>(null);
  const imageLoadedRef = useRef(false);

  useEffect(() => {
    if (imageLoadedRef.current) return;

    const img = new Image();
    img.onload = () => {
      imageLoadedRef.current = true;
      gridRef.current = buildAsciiGrid(img, 96);
    };
    img.src = orchestratorImage;
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const context = canvas.getContext("2d");
    if (!context) return;

    let frame = 0;
    let animationFrame = 0;

    function draw() {
      const parent = canvas!.parentElement;
      const width = parent?.clientWidth || 640;
      const height = parent?.clientHeight || 720;
      const scale = window.devicePixelRatio || 1;
      canvas!.width = Math.floor(width * scale);
      canvas!.height = Math.floor(height * scale);
      canvas!.style.width = `${width}px`;
      canvas!.style.height = `${height}px`;
      context!.setTransform(scale, 0, 0, scale, 0, 0);

      context!.fillStyle = "#020403";
      context!.fillRect(0, 0, width, height);

      context!.font = "9px 'Fira Code', monospace";
      context!.textBaseline = "top";

      const charW = 5.4;
      const charH = 10;
      const grid = gridRef.current;

      if (grid && grid.length > 0) {
        const gridRows = grid.length;
        const gridCols = grid[0].length;
        const artWidth = gridCols * charW;
        const artHeight = gridRows * charH;
        const offsetX = Math.max(0, (width - artWidth) / 2);
        const offsetY = Math.max(40, (height - artHeight) / 2 - 40);

        const ramp = ASCII_RAMPS[frame % ASCII_RAMPS.length];
        const phase = frame * 0.06;

        for (let r = 0; r < gridRows; r++) {
          for (let c = 0; c < gridCols; c++) {
            const brightness = grid[r][c];
            const pulse = brightness > 18
              ? Math.sin(c * 0.22 + r * 0.14 + phase) * 12
              : 0;
            const adjusted = clampValue(brightness + pulse, 0, 255);
            const rampIndex = Math.round((adjusted / 255) * (ramp.length - 1));
            const ch = ramp[rampIndex];

            if (ch === " ") continue;

            const alpha = 0.25 + (adjusted / 255) * 0.75;
            context!.fillStyle = `rgba(204,255,0,${alpha.toFixed(2)})`;
            context!.fillText(ch, offsetX + c * charW, offsetY + r * charH);
          }
        }
      } else {
        const cols = Math.floor(width / 14);
        const rows = Math.floor(height / 16);
        const glyphs = [".", ":", "+", "=", "/", "\\", "[", "]", "0", "1"];

        for (let row = 0; row < rows; row++) {
          for (let col = 0; col < cols; col++) {
            const seed = (row * 17 + col * 31 + frame) % 19;
            if ((row + col + frame) % 7 !== 0 && seed % 5 !== 0) continue;
            const glyph = glyphs[(seed + stepIndex) % glyphs.length];
            context!.fillStyle = seed % 3 === 0 ? "rgba(204,255,0,0.78)" : "rgba(204,255,0,0.22)";
            context!.fillText(glyph, col * 14, row * 16);
          }
        }
      }

      const logo = [
        "╔════════════════════╗",
        "║      SLOPPY        ║",
        "║   INIT / BOOT      ║",
        "╚════════════════════╝"
      ];
      context!.fillStyle = "#d9ff57";
      context!.font = "13px 'Fira Code', monospace";
      logo.forEach((line, index) => {
        context!.fillText(line, 56, 72 + index * 18);
      });

      const meta = [
        `STEP 0${stepIndex + 1} // ${STEP_TITLES[stepIndex].toUpperCase()}`,
        `AGENT: ${(agentName || "pending").slice(0, 28).toUpperCase()}`,
        `LINK: ${(providerTitle || "No uplink").toUpperCase()}`
      ];
      context!.fillStyle = "rgba(240,255,214,0.88)";
      meta.forEach((line, index) => {
        context!.fillText(line, 67, height - 137 + index * 20);
      });

      context!.strokeStyle = "rgba(204,255,0,0.65)";
      context!.lineWidth = 1;
      context!.strokeRect(34, 42, width - 68, height - 84);
      context!.strokeRect(48, 56, width - 96, height - 112);

      frame += 1;
      animationFrame = window.requestAnimationFrame(draw);
    }

    draw();
    return () => window.cancelAnimationFrame(animationFrame);
  }, [agentName, providerTitle, stepIndex]);

  return <canvas ref={canvasRef} className="onboarding-ascii-canvas" aria-hidden="true" />;
}

export function OnboardingView({ coreApi, initialConfig, onCompleted, onAuthenticated }: OnboardingViewProps) {
  const initialProvider = useMemo(() => initialProviderState(initialConfig), [initialConfig]);
  const [stepIndex, setStepIndex] = useState(0);
  const [authChallenge, setAuthChallenge] = useState<AnyRecord | null>(null);
  const [authMode, setAuthMode] = useState<"token" | "login_password">("token");
  const [authWarningAccepted, setAuthWarningAccepted] = useState(false);
  const [authAdminName, setAuthAdminName] = useState("Admin");
  const [authAdminLogin, setAuthAdminLogin] = useState("admin");
  const [authAdminPassword, setAuthAdminPassword] = useState("");
  const [authStatus, setAuthStatus] = useState("Choose how this Sloppy instance should authenticate operators.");
  const [providerId, setProviderId] = useState(initialProvider.providerId);
  const [providerApiKey, setProviderApiKey] = useState(initialProvider.apiKey);
  const [providerApiUrl, setProviderApiUrl] = useState(initialProvider.apiUrl);
  const [selectedModel, setSelectedModel] = useState(initialProvider.selectedModel);
  const [modelSearchQuery, setModelSearchQuery] = useState("");
  const [probeStatus, setProbeStatus] = useState("Pick a provider and test the connection.");
  const [probeOk, setProbeOk] = useState(false);
  const [probeModels, setProbeModels] = useState<AnyRecord[]>([]);
  const [agentPreset, setAgentPreset] = useState("sloppy");
  const [agentName, setAgentName] = useState("SLOPPY");
  const [agentRole, setAgentRole] = useState("SLOPPY");
  const [customAgentsMarkdown, setCustomAgentsMarkdown] = useState("");
  const [generateDescription, setGenerateDescription] = useState("");
  const [generationPhase, setGenerationPhase] = useState<"form" | "generating" | "preview">("form");
  const [generatedFiles, setGeneratedFiles] = useState<GeneratedAgentFiles>({ agentsMarkdown: "", identityMarkdown: "", soulMarkdown: "", userMarkdown: "" });
  const [launchPrompt, setLaunchPrompt] = useState(sloppyBootstrapMd);
  const [statusText, setStatusText] = useState("Preparing first-run setup.");
  const [isProbing, setIsProbing] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [deviceCode, setDeviceCode] = useState<{ deviceAuthId: string; userCode: string; verificationURL: string } | null>(null);
  const [isDeviceCodePolling, setIsDeviceCodePolling] = useState(false);
  const [deviceCodeCopied, setDeviceCodeCopied] = useState(false);
  const [anthropicOAuthAuthorizationURL, setAnthropicOAuthAuthorizationURL] = useState("");
  const deviceCodePollingRef = useRef(false);
  const anthropicOAuthPopupRef = useRef<Window | null>(null);

  useEffect(() => {
    let cancelled = false;
    coreApi.fetchAuthChallenge().then((challenge) => {
      if (cancelled || !challenge) {
        return;
      }
      setAuthChallenge(challenge);
      if (challenge.mode === "login_password") {
        setAuthMode("login_password");
        setAuthWarningAccepted(true);
        setAuthStatus(
          Boolean(challenge.bootstrapRequired)
            ? "Login/password auth is enabled. Create the first Admin account."
            : "Login/password auth is already enabled."
        );
      }
    });
    return () => {
      cancelled = true;
    };
  }, [coreApi]);

  const activeProvider = useMemo(
    () => PROVIDERS.find((provider) => provider.id === providerId) || PROVIDERS[0],
    [providerId]
  );
  const agentId = useMemo(() => toSlug(agentName), [agentName]);
  const selectedRuntimeModel = useMemo(
    () => runtimeModelId(providerId, selectedModel),
    [providerId, selectedModel]
  );
  const filteredProbeModels = useMemo(() => {
    const needle = modelSearchQuery.trim().toLowerCase();
    if (!needle) return probeModels;
    return probeModels.filter(m => {
      const id = String(m.id || "").toLowerCase();
      const title = String(m.title || "").toLowerCase();
      return id.includes(needle) || title.includes(needle);
    });
  }, [probeModels, modelSearchQuery]);

  useEffect(() => {
    setProbeOk(false);
    setProbeModels([]);
    setSelectedModel("");
    setProbeStatus("Connection parameters changed. Test the provider again.");
  }, [providerId, providerApiKey, providerApiUrl]);

  async function runProviderProbe(nextProviderId = activeProvider.id, nextApiKey = providerApiKey, nextApiUrl = providerApiUrl) {
    setIsProbing(true);
    setProbeStatus(`Testing ${nextProviderId === "openai-oauth" ? "OpenAI Codex" : activeProvider.title}...`);
    const requiresKey =
      nextProviderId === "openai-api" ||
      nextProviderId === "openrouter" ||
      nextProviderId === "gemini" ||
      nextProviderId === "anthropic" ||
      nextProviderId === "anthropic-oauth";
    const probeProviderId = nextProviderId === "anthropic-oauth" ? "anthropic" : nextProviderId;
    const response = await coreApi.probeProvider({
      providerId: probeProviderId,
      apiKey: requiresKey ? nextApiKey : undefined,
      apiUrl: nextApiUrl
    });
    setIsProbing(false);

    if (!response) {
      setProbeOk(false);
      setProbeModels([]);
      setProbeStatus("Probe failed. Sloppy did not return a provider response.");
      return;
    }

    const ok = Boolean(response.ok);
    const models = Array.isArray(response.models) ? response.models : [];
    setProbeOk(ok);
    setProbeModels(models);
    setProbeStatus(String(response.message || (ok ? "Provider is ready." : "Provider probe failed.")));
    if (ok && models.length > 0) {
      setSelectedModel(String(models[0]?.id || ""));
    }
  }

  async function startDeviceCodeFlow() {
    setProbeStatus("Checking for local Codex credentials...");
    setDeviceCode(null);
    setDeviceCodeCopied(false);
    deviceCodePollingRef.current = false;

    const imported = await coreApi.importOpenAICodexCredentials();
    if (imported?.ok) {
      setProviderId("openai-oauth");
      const oauthApiUrl = PROVIDERS.find((p) => p.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl;
      setProviderApiUrl(oauthApiUrl);
      setProbeStatus(String(imported.message || "Codex credentials imported."));
      await runProviderProbe("openai-oauth", "", oauthApiUrl);
      return;
    }

    setProbeStatus("Codex credentials were not found locally. Requesting device code from OpenAI...");
    const response = await coreApi.startOpenAIDeviceCode();
    if (!response || typeof response.deviceAuthId !== "string") {
      const message = imported?.message
        ? `Failed to start device code flow. ${String(imported.message)}`
        : "Failed to start device code flow.";
      setProbeStatus(message);
      return;
    }

    const info = {
      deviceAuthId: String(response.deviceAuthId),
      userCode: String(response.userCode),
      verificationURL: String(response.verificationURL || "https://auth.openai.com/codex/device")
    };
    setDeviceCode(info);
    setProbeStatus("Copy the code below, then open the login page to authorize.");

    pollDeviceCode(info);
  }

  function copyDeviceCode() {
    if (!deviceCode) return;
    navigator.clipboard.writeText(deviceCode.userCode).then(() => {
      setDeviceCodeCopied(true);
    }).catch(() => {
      setDeviceCodeCopied(true);
    });
  }

  function openDeviceCodeLoginPage() {
    if (!deviceCode) return;
    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      deviceCode.verificationURL,
      "sloppy-openai-device-code",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    if (!popup) {
      setProbeStatus("Login window was blocked. Allow popups or open the login page in a new tab.");
      return;
    }
    setDeviceCodeCopied(true);
  }

  function waitForAnthropicOAuthCallback(popup: Window | null, redirectURI: string) {
    return new Promise<string>((resolve, reject) => {
      const startedAt = Date.now();
      const interval = window.setInterval(() => {
        if (!popup || popup.closed) {
          window.clearInterval(interval);
          reject(new Error("Anthropic OAuth window was closed."));
          return;
        }

        if (Date.now() - startedAt > 5 * 60 * 1000) {
          window.clearInterval(interval);
          try {
            popup.close();
          } catch {
            // ignore
          }
          reject(new Error("Anthropic OAuth timed out. Try again."));
          return;
        }

        try {
          const href = popup.location.href;
          if (href && href.startsWith(redirectURI)) {
            window.clearInterval(interval);
            try {
              popup.close();
            } catch {
              // ignore
            }
            resolve(href);
          }
        } catch {
          // Cross-origin until the popup returns to our redirect URI.
        }
      }, 500);
    });
  }

  async function connectAnthropicOAuth() {
    setProbeStatus("Checking for local Claude Code credentials...");
    setAnthropicOAuthAuthorizationURL("");

    const imported = await coreApi.importAnthropicClaudeCredentials();
    const oauthApiUrl = PROVIDERS.find((p) => p.id === "anthropic-oauth")?.defaultEntry.apiUrl || providerApiUrl;
    if (imported?.ok) {
      setProviderId("anthropic-oauth");
      setProviderApiUrl(oauthApiUrl);
      setProviderApiKey("");
      setProbeStatus(String(imported.message || "Claude Code credentials imported."));
      await runProviderProbe("anthropic-oauth", "", oauthApiUrl);
      return;
    }

    setProbeStatus("Claude Code credentials were not found locally. Requesting Anthropic OAuth URL...");
    const redirectURI = `${window.location.origin}${window.location.pathname}`;
    const response = await coreApi.startAnthropicOAuth({ redirectURI });
    if (!response || typeof response.authorizationURL !== "string") {
      const message = imported?.message
        ? `Failed to start Anthropic OAuth. ${String(imported.message)}`
        : "Failed to start Anthropic OAuth.";
      setProbeStatus(message);
      return;
    }

    const authorizationURL = String(response.authorizationURL);
    setAnthropicOAuthAuthorizationURL(authorizationURL);
    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      authorizationURL,
      "sloppy-anthropic-oauth",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    anthropicOAuthPopupRef.current = popup;
    if (!popup) {
      setProbeStatus("Popup was blocked. Allow popups, use the QR code, or open the login page.");
      return;
    }

    setProbeStatus("Waiting for Anthropic sign-in confirmation...");
    try {
      const callbackURL = await waitForAnthropicOAuthCallback(popup, redirectURI);
      const completion = await coreApi.completeAnthropicOAuth({ callbackURL });
      if (!completion?.ok) {
        setProbeStatus(String(completion?.message || "Anthropic OAuth failed."));
        return;
      }
      setAnthropicOAuthAuthorizationURL("");
      setProviderId("anthropic-oauth");
      setProviderApiUrl(oauthApiUrl);
      setProviderApiKey("");
      setProbeStatus(String(completion.message || "Anthropic OAuth connected."));
      await runProviderProbe("anthropic-oauth", "", oauthApiUrl);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Anthropic OAuth failed.";
      setProbeStatus(message);
    } finally {
      anthropicOAuthPopupRef.current = null;
    }
  }

  async function pollDeviceCode(info: { deviceAuthId: string; userCode: string; verificationURL: string }) {
    if (deviceCodePollingRef.current) return;
    deviceCodePollingRef.current = true;
    setIsDeviceCodePolling(true);

    const maxAttempts = 120;
    let interval = 5000;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (!deviceCodePollingRef.current) break;
      await new Promise((r) => setTimeout(r, interval));
      if (!deviceCodePollingRef.current) break;

      const result = await coreApi.pollOpenAIDeviceCode({
        deviceAuthId: info.deviceAuthId,
        userCode: info.userCode
      });

      if (!result) {
        setProbeStatus("Polling failed. Try again.");
        break;
      }

      const status = String(result.status || "");
      if (status === "approved" && result.ok) {
        setDeviceCode(null);
        setProviderId("openai-oauth");
        const oauthApiUrl = PROVIDERS.find((p) => p.id === "openai-oauth")?.defaultEntry.apiUrl || providerApiUrl;
        setProviderApiUrl(oauthApiUrl);
        setProbeStatus(String(result.message || "Connected via device code."));
        await runProviderProbe("openai-oauth", "", oauthApiUrl);
        break;
      }

      if (status === "slow_down") {
        interval = Math.min(interval + 2000, 15000);
      }

      if (status === "error") {
        setProbeStatus(String(result.message || "Device code authorization failed."));
        break;
      }
    }

    deviceCodePollingRef.current = false;
    setIsDeviceCodePolling(false);
  }

  function cancelDeviceCodePolling() {
    deviceCodePollingRef.current = false;
    setIsDeviceCodePolling(false);
    setDeviceCode(null);
    setDeviceCodeCopied(false);
    setProbeStatus("Device code authorization cancelled.");
  }

  async function testProviderConnection() {
    if (isProbing) {
      return;
    }
    await runProviderProbe();
  }

  function selectPreset(presetId: string) {
    const preset = AGENT_PRESETS.find((p) => p.id === presetId);
    if (!preset) return;
    setAgentPreset(presetId);
    if (preset.defaultName) setAgentName(preset.defaultName);
    if (preset.defaultRole) setAgentRole(preset.defaultRole);
    if (preset.bootstrapPrompt) setLaunchPrompt(preset.bootstrapPrompt);
    setGenerationPhase("form");
  }

  function canAdvance() {
    if (stepIndex === 0) {
      if (authMode === "token") return true;
      if (!authWarningAccepted) return false;
      if (authChallenge?.mode === "login_password" && !Boolean(authChallenge?.bootstrapRequired)) return true;
      return authAdminLogin.trim().length > 0 && authAdminPassword.length > 0;
    }
    if (stepIndex === 1) {
      return probeOk && selectedModel.trim().length > 0;
    }
    if (stepIndex === 2) {
      if (agentName.trim().length === 0 || agentRole.trim().length === 0 || agentId.length === 0) return false;
      if (agentPreset === "generate" && generateDescription.trim().length === 0) return false;
      if (agentPreset === "custom" && customAgentsMarkdown.trim().length === 0) return false;
      return true;
    }
    return launchPrompt.trim().length > 0;
  }

  async function ensureAgent() {
    const existing = await coreApi.fetchAgent(agentId);
    if (existing) {
      return existing;
    }

    const created = await coreApi.createAgent({
      id: agentId,
      displayName: agentName.trim(),
      role: agentRole.trim(),
      isSystem: false
    });
    if (created) {
      return created;
    }

    const retried = await coreApi.fetchAgent(agentId);
    if (retried) {
      return retried;
    }

    throw new Error("Failed to create or reuse the first agent.");
  }

  async function completeOnboarding() {
    if (isSubmitting || !canAdvance()) {
      return;
    }

    setIsSubmitting(true);

    try {
      setStatusText("Saving provider configuration...");
      const draftConfig = createConfigWithProvider(
        initialConfig,
        activeProvider,
        providerApiKey,
        providerApiUrl,
        selectedModel,
        false
      );
      const savedConfig = await coreApi.updateRuntimeConfig(draftConfig);

      setStatusText("Creating the first agent...");
      await ensureAgent();

      setStatusText("Applying agent model...");
      const agentConfig = await coreApi.fetchAgentConfig(agentId);
      if (!agentConfig) {
        throw new Error("Failed to load agent config.");
      }

      const currentDocuments =
        agentConfig.documents && typeof agentConfig.documents === "object"
          ? (agentConfig.documents as AnyRecord)
          : {};

      const activePresetDef = AGENT_PRESETS.find((p) => p.id === agentPreset);

      let nextDocuments: AnyRecord;
      if (agentPreset === "generate" && (generatedFiles.agentsMarkdown || generatedFiles.identityMarkdown || generatedFiles.soulMarkdown || generatedFiles.userMarkdown)) {
        nextDocuments = {
          ...currentDocuments,
          agentsMarkdown: generatedFiles.agentsMarkdown,
          identityMarkdown: generatedFiles.identityMarkdown,
          soulMarkdown: generatedFiles.soulMarkdown,
          userMarkdown: generatedFiles.userMarkdown
        };
      } else if (agentPreset === "custom") {
        nextDocuments = { ...currentDocuments, agentsMarkdown: customAgentsMarkdown.trim() };
      } else if (activePresetDef && activePresetDef.agentsMarkdown) {
        nextDocuments = { ...currentDocuments, agentsMarkdown: activePresetDef.agentsMarkdown.trim() };
      } else {
        nextDocuments = currentDocuments;
      }

      await coreApi.updateAgentConfig(agentId, {
        selectedModel: selectedRuntimeModel,
        documents: nextDocuments,
        heartbeat: agentConfig.heartbeat,
        channelSessions: agentConfig.channelSessions
      });

      setStatusText("Opening the first session...");
      const session = await coreApi.createAgentSession(agentId, {
        title: "Onboarding bootstrap"
      });
      if (!session || typeof session.id !== "string") {
        throw new Error("Failed to create onboarding session.");
      }

      setStatusText("Finalizing workspace...");
      const completedConfig = createConfigWithProvider(
        savedConfig,
        activeProvider,
        providerApiKey,
        providerApiUrl,
        selectedModel,
        true
      );
      const finalized = await coreApi.updateRuntimeConfig(completedConfig);

      window.history.pushState({}, "", `/agents/${encodeURIComponent(agentId)}/chat`);
      onCompleted(finalized);

      void coreApi.postAgentSessionMessage(agentId, session.id, {
        userId: "onboarding",
        content: launchPrompt.trim(),
        attachments: [],
        spawnSubSession: false
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to finish onboarding.";
      setStatusText(message);
      setIsSubmitting(false);
      return;
    }

    setIsSubmitting(false);
  }

  async function skipProviderSetup() {
    if (isSubmitting || stepIndex !== 1) {
      return;
    }

    setIsSubmitting(true);

    try {
      setStatusText("Skipping provider setup. You can configure it later in Settings.");
      const completedConfig = createConfigWithoutProvider(initialConfig, true);
      const finalized = await coreApi.updateRuntimeConfig(completedConfig);

      onCompleted(finalized);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to skip provider setup.";
      setStatusText(message);
      setIsSubmitting(false);
      return;
    }

    setIsSubmitting(false);
  }

  async function runAgentGeneration() {
    setGenerationPhase("generating");
    setStatusText("Generating agent files…");

    const prompt = buildOnboardingGeneratePrompt(agentId, agentName.trim(), agentRole.trim(), generateDescription);
    const result = await coreApi.generateText({ model: selectedModel, prompt });

    if (!result || typeof result.text !== "string") {
      setGenerationPhase("form");
      setStatusText("Generation failed. Please try again or disable generate.");
      return;
    }

    const parsed = parseOnboardingGeneratedFiles(result.text as string);
    setGeneratedFiles(parsed);
    setGenerationPhase("preview");
    setStatusText("Review and edit the generated files.");
  }

  async function completeAuthStep() {
    if (authMode === "token") {
      setStatusText(`Step 2 of ${STEP_TITLES.length}.`);
      setStepIndex(1);
      return;
    }

    setIsSubmitting(true);
    try {
      let challenge = authChallenge;
      if (challenge?.mode !== "login_password") {
        setAuthStatus("Enabling login/password auth...");
        challenge = await coreApi.enableIdentityAuthMode();
        if (!challenge) {
          throw new Error("Failed to enable login/password auth.");
        }
        setAuthChallenge(challenge);
      }

      if (Boolean(challenge?.bootstrapRequired)) {
        setAuthStatus("Creating the first Admin account...");
        const session = await coreApi.bootstrapIdentityAdmin({
          login: authAdminLogin.trim(),
          name: authAdminName.trim() || authAdminLogin.trim(),
          password: authAdminPassword
        });
        const accessToken = typeof session?.accessToken === "string" ? session.accessToken.trim() : "";
        if (!accessToken) {
          throw new Error("Failed to create the first Admin account.");
        }
        setDashboardAuthToken(accessToken, { persist: true });
        onAuthenticated?.();
        const nextChallenge = await coreApi.fetchAuthChallenge();
        if (nextChallenge) {
          setAuthChallenge(nextChallenge);
        }
        setAuthAdminPassword("");
      }

      setAuthStatus("Dashboard auth is ready.");
      setStatusText(`Step 2 of ${STEP_TITLES.length}.`);
      setStepIndex(1);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to configure dashboard auth.";
      setAuthStatus(message);
    } finally {
      setIsSubmitting(false);
    }
  }

  function nextStep() {
    if (!canAdvance()) {
      return;
    }
    if (stepIndex === 0) {
      void completeAuthStep();
      return;
    }
    if (stepIndex === 2 && agentPreset === "generate" && generationPhase === "form") {
      void runAgentGeneration();
      return;
    }
    if (stepIndex === STEP_TITLES.length - 1) {
      void completeOnboarding();
      return;
    }
    setStepIndex((value) => Math.min(STEP_TITLES.length - 1, value + 1));
    setStatusText(`Step ${stepIndex + 2} of ${STEP_TITLES.length}.`);
  }

  function previousStep() {
    setStepIndex((value) => Math.max(0, value - 1));
  }

  return (
    <div className="onboarding-shell">
      <section className="onboarding-panel">
        {stepIndex > 0 && <MigrationLaunchNotice onboarding />}
        <div className="onboarding-chrome">
          <span className="onboarding-kicker">First start bootstrap</span>
          <div className="onboarding-progress">
            {STEP_TITLES.map((title, index) => (
              <span
                key={title}
                className={`onboarding-progress-segment ${index === stepIndex ? "active" : index < stepIndex ? "done" : ""}`}
              />
            ))}
          </div>
        </div>

        <div key={stepIndex} className="onboarding-stage">
          <div className="onboarding-stage-head">
            <span className="material-symbols-rounded" aria-hidden="true">
              {stepIndex === 0 ? "admin_panel_settings" : stepIndex === 1 ? "hub" : stepIndex === 2 ? "support_agent" : "terminal"}
            </span>
            <div>
              <p className="onboarding-stage-overline">Step {stepIndex + 1} of {STEP_TITLES.length}</p>
              <h1>{STEP_TITLES[stepIndex]}</h1>
              <p>{statusText}</p>
            </div>
          </div>

          {stepIndex === 0 ? (
            <div className="onboarding-form-block">
              <div className="onboarding-provider-grid">
                <button
                  type="button"
                  className={`onboarding-provider-card ${authMode === "token" ? "active" : ""}`}
                  onClick={() => {
                    setAuthMode("token");
                    setAuthStatus("Token auth keeps the current local operator-token flow.");
                  }}
                >
                  <span className="material-symbols-rounded" aria-hidden="true">
                    key
                  </span>
                  <strong>Token</strong>
                  <span>Use the existing dashboard operator token flow.</span>
                </button>
                <button
                  type="button"
                  className={`onboarding-provider-card ${authMode === "login_password" ? "active" : ""}`}
                  onClick={() => {
                    setAuthMode("login_password");
                    setAuthStatus("Login/password auth creates named users and roles.");
                  }}
                >
                  <span className="material-symbols-rounded" aria-hidden="true">
                    badge
                  </span>
                  <strong>Login/password</strong>
                  <span>Create accounts, invites, roles, recovery codes, and sessions.</span>
                </button>
              </div>

              {authMode === "login_password" ? (
                <>
                  <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
                    <span className="agent-tools-guardrail-copy">
                      <span className="agent-tools-guardrail-title">I understand this switch cannot be reverted to token auth</span>
                      <span className="agent-tools-guardrail-note">The first account created here becomes Admin.</span>
                    </span>
                    <span className="agent-tools-switch">
                      <input
                        type="checkbox"
                        checked={authWarningAccepted}
                        disabled={authChallenge?.mode === "login_password"}
                        onChange={(event) => setAuthWarningAccepted(event.target.checked)}
                      />
                      <span className="agent-tools-switch-track" />
                    </span>
                  </label>

                  {authChallenge?.mode === "login_password" && !Boolean(authChallenge?.bootstrapRequired) ? (
                    <div className="onboarding-inline-note">
                      Login/password authentication is already enabled.
                    </div>
                  ) : (
                    <>
                      <label>
                        Admin name
                        <input
                          value={authAdminName}
                          onChange={(event) => setAuthAdminName(event.target.value)}
                          placeholder="Admin"
                        />
                      </label>
                      <label>
                        Admin login
                        <input
                          value={authAdminLogin}
                          autoCapitalize="off"
                          autoCorrect="off"
                          spellCheck={false}
                          onChange={(event) => setAuthAdminLogin(event.target.value)}
                          placeholder="admin"
                        />
                      </label>
                      <label>
                        Admin password
                        <input
                          type="password"
                          value={authAdminPassword}
                          onChange={(event) => setAuthAdminPassword(event.target.value)}
                        />
                      </label>
                    </>
                  )}
                </>
              ) : null}

              <div className={`onboarding-provider-status ${authMode === "token" || authWarningAccepted ? "ok" : "warn"}`}>
                <strong>{authMode === "token" ? "Token mode" : "Login/password mode"}</strong>
                <span>{authStatus}</span>
                <small>{authChallenge?.passkeySupported ? "PassKey support is advertised by this Core." : "PassKey can be enabled when browser and Core support it."}</small>
              </div>
            </div>
          ) : null}

          {stepIndex === 1 ? (
            <div className="onboarding-form-block">
              <div className="onboarding-provider-grid">
                {PROVIDERS.map((provider) => (
                  <button
                    key={provider.id}
                    type="button"
                    className={`onboarding-provider-card ${provider.id === providerId ? "active" : ""}`}
                    onClick={() => {
                      setProviderId(provider.id);
                      setProviderApiKey(provider.defaultEntry.apiKey);
                      setProviderApiUrl(provider.defaultEntry.apiUrl);
                    }}
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">
                      {providerCardIcon(provider.id)}
                    </span>
                    <strong>{provider.title}</strong>
                    <span>{provider.description}</span>
                  </button>
                ))}
              </div>

              {activeProvider.requiresApiKey ? (
                <label>
                  API key
                  <input
                    type="password"
                    value={providerApiKey}
                    onChange={(event) => setProviderApiKey(event.target.value)}
                    placeholder="sk-..."
                  />
                </label>
              ) : null}

              <label>
                API URL
                <input
                  value={providerApiUrl}
                  onChange={(event) => setProviderApiUrl(event.target.value)}
                  placeholder={activeProvider.defaultEntry.apiUrl}
                />
              </label>

              {activeProvider.id === "openai-oauth" ? (
                deviceCode ? (
                  <div className="onboarding-device-code-card">
                    <div className="onboarding-device-code-step">
                      <span className="onboarding-device-code-step-number">1</span>
                      <span>Copy this device code</span>
                    </div>
                    <div className="onboarding-device-code-row">
                      <code className="onboarding-device-code-value">{deviceCode.userCode}</code>
                      <button type="button" className="onboarding-ghost-button" onClick={copyDeviceCode}>
                        {deviceCodeCopied ? "Copied" : "Copy"}
                      </button>
                    </div>

                    <div className="onboarding-device-code-qr">
                      <QRCodeSVG
                        value={deviceCode.verificationURL}
                        size={132}
                        bgColor="#ffffff"
                        fgColor="#000000"
                        level="M"
                      />
                    </div>

                    <div className="onboarding-device-code-step">
                      <span className="onboarding-device-code-step-number">2</span>
                      <span>Open OpenAI in this browser or scan the QR code</span>
                    </div>
                    <button
                      type="button"
                      className="onboarding-ghost-button hover-levitate"
                      onClick={openDeviceCodeLoginPage}
                    >
                      Open login page
                    </button>

                    {isDeviceCodePolling ? (
                      <div className="onboarding-device-code-waiting">
                        <span className="onboarding-device-code-dot" />
                        <span>Waiting for sign-in confirmation...</span>
                      </div>
                    ) : null}

                    <div className="onboarding-provider-actions">
                      <button type="button" className="onboarding-ghost-button" onClick={cancelDeviceCodePolling}>
                        Cancel
                      </button>
                      <button type="button" className="onboarding-ghost-button hover-levitate" onClick={() => void startDeviceCodeFlow()}>
                        Get new code
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className="onboarding-provider-actions">
                    <button type="button" className="onboarding-ghost-button hover-levitate" onClick={() => void startDeviceCodeFlow()}>
                      Connect OpenAI
                    </button>
                  </div>
                )
              ) : null}

              {activeProvider.id === "anthropic-oauth" ? (
                <div className="onboarding-device-code-card">
                  <div className="onboarding-provider-actions">
                    <button type="button" className="onboarding-ghost-button hover-levitate" onClick={() => void connectAnthropicOAuth()}>
                      Connect Anthropic
                    </button>
                  </div>
                  {anthropicOAuthAuthorizationURL ? (
                    <>
                      <div className="onboarding-device-code-step">
                        <span className="onboarding-device-code-step-number">1</span>
                        <span>Open Anthropic in this browser or scan the QR code</span>
                      </div>
                      <div className="onboarding-device-code-qr">
                        <QRCodeSVG
                          value={anthropicOAuthAuthorizationURL}
                          size={132}
                          bgColor="#ffffff"
                          fgColor="#000000"
                          level="M"
                        />
                      </div>
                      <a
                        className="onboarding-device-code-link"
                        href={anthropicOAuthAuthorizationURL}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        Open login page
                      </a>
                    </>
                  ) : null}
                </div>
              ) : null}

              {activeProvider.id === "openai-oauth" ? (
                <div className="onboarding-inline-note">
                  You must first <a href="https://chatgpt.com/security-settings" target="_blank" rel="noopener noreferrer">enable device code login</a> in your ChatGPT security settings.
                </div>
              ) : null}

              <div className="onboarding-provider-actions">
                <button type="button" className="onboarding-primary-button hover-levitate" onClick={() => void testProviderConnection()} disabled={isProbing}>
                  {isProbing ? "Testing..." : "Test connection"}
                </button>
              </div>

              <div className="onboarding-inline-note">
                No proxy or VPN yet? Skip provider setup for now and configure it later in Settings.
              </div>

              <div className={`onboarding-provider-status ${probeOk ? "ok" : "warn"}`}>
                <strong>{probeOk ? "Ready" : "Pending"}</strong>
                <span>{probeStatus}</span>
                <small>{activeProvider.authHint}</small>
              </div>

              {probeOk && probeModels.length > 0 ? (
                <div className="onboarding-model-picker-container">
                  <label>
                    Model
                    <input
                      className="onboarding-model-search"
                      value={modelSearchQuery}
                      onChange={(event) => setModelSearchQuery(event.target.value)}
                      placeholder="Search for a model..."
                    />
                  </label>
                  <div className="onboarding-model-list">
                    {filteredProbeModels.length > 0 ? (
                      filteredProbeModels.map((model) => {
                        const id = String(model.id || "");
                        const title = String(model.title || id);
                        const isActive = selectedModel === id;
                        return (
                          <button
                            key={id}
                            type="button"
                            className={`onboarding-model-item ${isActive ? "active" : ""}`}
                            onClick={() => setSelectedModel(id)}
                          >
                            <div className="onboarding-model-item-main">
                              <strong>{title}</strong>
                              <small>{id}</small>
                            </div>
                            {isActive && <span className="material-symbols-rounded">check</span>}
                          </button>
                        );
                      })
                    ) : (
                      <div className="onboarding-model-empty">No models match your search.</div>
                    )}
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}

          {stepIndex === 2 ? (
            <div className="onboarding-form-block">
              <div className="onboarding-preset-grid">
                {AGENT_PRESETS.map((preset) => (
                  <button
                    key={preset.id}
                    type="button"
                    className={`onboarding-preset-card ${preset.id === agentPreset ? "active" : ""}`}
                    onClick={() => selectPreset(preset.id)}
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">
                      {preset.icon}
                    </span>
                    <strong>{preset.title}</strong>
                    <span>{preset.description}</span>
                  </button>
                ))}
              </div>

              <label>
                Agent name
                <input
                  value={agentName}
                  onChange={(event) => setAgentName(event.target.value)}
                  placeholder="SLOPPY"
                  autoFocus
                />
              </label>
              <label>
                Role
                <input
                  value={agentRole}
                  onChange={(event) => setAgentRole(event.target.value)}
                  placeholder="Founding operator"
                />
              </label>
              <div className="onboarding-inline-note">
                Agent id preview: <strong>{agentId || "agent"}</strong>
              </div>

              {agentPreset === "custom" && (
                <label>
                  Agent instructions (AGENTS.md)
                  <textarea
                    value={customAgentsMarkdown}
                    onChange={(event) => setCustomAgentsMarkdown(event.target.value)}
                    placeholder="Write the agent's behavior instructions, responsibilities, operating rules…"
                    rows={8}
                  />
                </label>
              )}

              {agentPreset === "generate" && (
                <div className="agent-generate-fields">
                  <label>
                    Agent responsibility <span className="agent-field-note">(required for generation)</span>
                    <textarea
                      value={generateDescription}
                      onChange={(event) => setGenerateDescription(event.target.value)}
                      placeholder="Describe what this agent is responsible for, its main goals, and how it should behave…"
                      rows={4}
                    />
                  </label>
                </div>
              )}
            </div>
          ) : null}

          {stepIndex === 3 ? (
            <div className="onboarding-form-block">
              <label>
                Launch prompt
                <textarea
                  value={launchPrompt}
                  onChange={(event) => setLaunchPrompt(event.target.value)}
                  rows={14}
                  autoFocus
                />
              </label>
              <div className="onboarding-inline-note">
                Session title: <strong>Onboarding bootstrap</strong>
              </div>
            </div>
          ) : null}
        </div>

        <div className="onboarding-footer">
          <button
            type="button"
            className="onboarding-ghost-button hover-levitate"
            onClick={stepIndex === 1 ? () => void skipProviderSetup() : previousStep}
            disabled={isSubmitting}
          >
            {stepIndex === 1 ? "Skip for now" : "Back"}
          </button>
          <button
            type="button"
            className="onboarding-primary-button hover-levitate"
            onClick={nextStep}
            disabled={!canAdvance() || isSubmitting || generationPhase === "generating"}
          >
            {stepIndex === STEP_TITLES.length - 1
              ? (isSubmitting ? "Booting..." : "Finish setup")
              : stepIndex === 2 && agentPreset === "generate" && generationPhase === "form"
                ? "Generate & Continue"
                : "Next"}
          </button>
        </div>
      </section>

      <section className="onboarding-visual">
        <div className="onboarding-visual-hud">
          <span>[ uplink // {activeProvider.title.toLowerCase()} ]</span>
          <span>[ session // preboot ]</span>
        </div>
        <div className="onboarding-micrograph onboarding-micrograph-top" />
        <div className="onboarding-micrograph onboarding-micrograph-middle" />
        <div className="onboarding-micrograph onboarding-micrograph-bottom" />
        <OnboardingAsciiCanvas
          stepIndex={stepIndex}
          agentName={agentName}
          providerTitle={activeProvider.title}
        />
      </section>

      {generationPhase === "preview" && (
        <AgentGeneratePreview
          files={generatedFiles}
          onFilesChange={setGeneratedFiles}
          onBack={() => {
            setGenerationPhase("form");
            setStatusText(`Step 3 of ${STEP_TITLES.length}.`);
          }}
          onDone={() => {
            setGenerationPhase("form");
            setStepIndex((value) => Math.min(STEP_TITLES.length - 1, value + 1));
            setStatusText(`Step 4 of ${STEP_TITLES.length}.`);
          }}
          isSubmitting={false}
          submitLabel="Done"
        />
      )}
    </div>
  );
}
