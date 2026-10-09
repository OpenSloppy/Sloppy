import { MigrationWizard } from "../migrations/MigrationWizard";
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  completeAnthropicOAuth,
  completeGeminiOAuth,
  disconnectAnthropicOAuth,
  disconnectGeminiOAuth,
  disconnectOpenAIOAuth,
  fetchAnthropicProviderStatus,
  fetchGeminiProviderStatus,
  fetchOpenAIModels,
  fetchOpenAIProviderStatus,
  fetchImageGenerationStatus,
  fetchRuntimeConfig,
  fetchMeshNodes,
  fetchConsoleModelInstances,
  fetchVoiceCapabilities,
  fetchAvailableModels,
  fetchChannelPlugins,
  fetchSearchProviderStatus,
  importAnthropicClaudeCredentials,
  probeProvider,
  startAnthropicOAuth,
  startGeminiOAuth,
  startOpenAIDeviceCode,
  pollOpenAIDeviceCode,
  updateRuntimeConfig,
  fetchGitHubAuthStatus,
  connectGitHub,
  disconnectGitHub,
  runWorkspaceGitSync,
  selectDirectory,
  installPlugin
} from "../../api";
import { collectAggregatedProviderModels, mergeModelOptions } from "../agents/utils/aggregateProviderModels";
import { NodeHostEditor } from "./components/NodeHostEditor";
import { MemoryProviderEditor } from "./components/MemoryProviderEditor";
import { MCPEditor } from "./components/MCPEditor";
import { PluginEditor } from "./components/PluginEditor";
import { ProviderEditor } from "./components/ProviderEditor";
import { buildOAuthRedirectURI } from "./oauthRedirect";
import { SearchToolsEditor } from "./components/SearchToolsEditor";
import { ImageGenerationEditor } from "./components/ImageGenerationEditor";
import { SettingsMainHeader } from "./components/SettingsMainHeader";
import { SettingsPlaceholder } from "./components/SettingsPlaceholder";
import { SettingsSidebar } from "./components/SettingsSidebar";
import { ApprovalsView } from "./components/ApprovalsView";
import { ConfigRawView } from "./components/ConfigRawView";
import { ProxyEditor } from "./components/ProxyEditor";
import { BrowserEditor } from "./components/BrowserEditor";
import { VoiceModeEditor } from "./components/VoiceModeEditor";
import { ACPEditor } from "./components/ACPEditor";
import { UIEditor } from "./components/UIEditor";
import { AuthUsersEditor } from "./components/AuthUsersEditor";
import { VisorEditor } from "./components/VisorEditor";
import { CompactorEditor } from "./components/CompactorEditor";
import { ClientConnectView } from "./components/ClientConnectView";
import { ChannelsEditor } from "./components/ChannelsEditor";
import { GitHubAccessCard } from "./components/GitHubAccessCard";
import { GitSyncEditor } from "./components/GitSyncEditor";
import { ModelRoutingEditor } from "./components/ModelRoutingEditor";
import { SemanticDecisionsEditor } from "./components/SemanticDecisionsEditor";
import { UpdatesView } from "../updates/UpdatesView";
import { useUpdateCheck } from "../updates/useUpdateCheck";
import {
  DRAFT_CONFIG_KEY,
  EMPTY_CONFIG,
  PROVIDER_CATALOG,
  PROVIDER_CATALOG_UI,
  SETTINGS_ITEMS,
  clone,
  emptyMCPServer,
  emptyPlugin,
  findProviderModelIndex,
  getProviderDefinition,
  getProviderEntry,
  inferCatalogIdForEntry,
  isSettingsSection,
  isSloppyRelayConnection,
  mergeChannelPluginsIntoConfig,
  normalizeConfig,
  normalizeGitSyncConflictStrategy,
  normalizeGitSyncFrequency,
  normalizeTimeValue,
  parseConfigList,
  parseInteger,
  parseLines,
  providerIsConfigured,
  stableConfigStringify
} from "./configModel";

export function ConfigView({
  embedded = false,
  sectionId = "providers",
  onSectionChange = null,
  onRuntimeConfigUpdated = null
}: {
  embedded?: boolean;
  sectionId?: string;
  onSectionChange?: ((nextSectionId: string) => void) | null;
  onRuntimeConfigUpdated?: ((nextConfig: Record<string, unknown>) => void) | null;
}) {
  const initialSectionId = isSettingsSection(sectionId) ? sectionId : "providers";
  const [query, setQuery] = useState("");
  const [selectedSettings, setSelectedSettings] = useState(initialSectionId);
  const { status: updateStatus, isChecking: isUpdateChecking, forceCheck: forceUpdateCheck } = useUpdateCheck();
  const [draftConfig, setDraftConfig] = useState(clone(EMPTY_CONFIG));
  const [savedConfig, setSavedConfig] = useState(clone(EMPTY_CONFIG));
  const [rawConfig, setRawConfig] = useState(JSON.stringify(EMPTY_CONFIG, null, 2));
  const [statusText, setStatusText] = useState("Loading config...");
  const [configLoaded, setConfigLoaded] = useState(false);
  const [selectedPluginIndex, setSelectedPluginIndex] = useState(0);
  const [selectedMCPServerIndex, setSelectedMCPServerIndex] = useState(0);
  const [providerModalId, setProviderModalId] = useState(null);
  const [providerModalIndex, setProviderModalIndex] = useState(null);
  const [providerForm, setProviderForm] = useState(null);
  const [configDeviceCode, setConfigDeviceCode] = useState(null);
  const [configDeviceCodePolling, setConfigDeviceCodePolling] = useState(false);
  const [configDeviceCodeCopied, setConfigDeviceCodeCopied] = useState(false);
  const configDeviceCodeGenerationRef = useRef(0);
  const configDeviceCodePollingRef = useRef(false);
  const [pendingOAuthDisconnect, setPendingOAuthDisconnect] = useState(false);
  const [pendingAnthropicOAuthDisconnect, setPendingAnthropicOAuthDisconnect] = useState(false);
  const [providerModelOptions, setProviderModelOptions] = useState({});
  const [modelRelayNodes, setModelRelayNodes] = useState<any[]>([]);
  const [modelConsoleInstances, setModelConsoleInstances] = useState<any[]>([]);
  const [modelConsoleStatus, setModelConsoleStatus] = useState("");

  async function reloadConsoleInstances() {
    setModelConsoleStatus("Loading Console instances…");
    try {
      const instances = await fetchConsoleModelInstances();
      setModelConsoleInstances(instances);
      setModelConsoleStatus(instances.length ? "" : "No other active instances. Bind both Core computers to Sloppy Console.");
    } catch (error) {
      setModelConsoleInstances([]);
      setModelConsoleStatus(error instanceof Error ? error.message : "Console instances could not be loaded.");
    }
  }

  useEffect(() => {
    if (providerModalId !== "sloppy") return;
    let active = true;
    fetchMeshNodes().then((nodes) => { if (active) setModelRelayNodes(nodes); }).catch(() => { if (active) setModelRelayNodes([]); });
    setModelConsoleStatus("Loading Console instances…");
    fetchConsoleModelInstances().then((instances) => {
      if (active) { setModelConsoleInstances(instances); setModelConsoleStatus(instances.length ? "" : "No other active instances. Bind both Core computers to Sloppy Console."); }
    }).catch((error) => {
      if (active) { setModelConsoleInstances([]); setModelConsoleStatus(error instanceof Error ? error.message : "Console instances could not be loaded."); }
    });
    return () => { active = false; };
  }, [providerModalId]);
  const [providerModelStatus, setProviderModelStatus] = useState({});
  const [providerProbeTesting, setProviderProbeTesting] = useState({});
  const [openAIProviderStatus, setOpenAIProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    hasOAuthCredentials: false,
    oauthAccountId: "",
    oauthPlanType: "",
    oauthExpiresAt: ""
  });
  const [anthropicProviderStatus, setAnthropicProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    hasOAuthCredentials: false,
    oauthSource: "",
    oauthExpiresAt: "",
    oauthRefreshable: false
  });
  const [geminiProviderStatus, setGeminiProviderStatus] = useState({
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    hasOAuthCredentials: false,
    oauthEmail: "",
    oauthExpiresAt: ""
  });
  const [gitHubAuthStatus, setGitHubAuthStatus] = useState({ connected: false, username: null, connectedAt: null });
  const [gitHubToken, setGitHubToken] = useState("");
  const [gitHubStatusText, setGitHubStatusText] = useState("");
  const [gitHubConnecting, setGitHubConnecting] = useState(false);
  const [gitSyncRunning, setGitSyncRunning] = useState(false);
  const [gitSyncStatusText, setGitSyncStatusText] = useState("");
  const [modelRoutingCatalog, setModelRoutingCatalog] = useState([]);
  const [modelRoutingCatalogStatus, setModelRoutingCatalogStatus] = useState("");

  const [searchProviderStatus, setSearchProviderStatus] = useState({
    activeProvider: "perplexity",
    brave: { hasEnvironmentKey: false, hasConfiguredKey: false, hasAnyKey: false },
    perplexity: { hasEnvironmentKey: false, hasConfiguredKey: false, hasAnyKey: false }
  });
  const [imageGenerationStatus, setImageGenerationStatus] = useState({
    enabled: false,
    provider: "fal",
    model: "fal-ai/flux-2",
    hasEnvironmentKey: false,
    hasConfiguredKey: false,
    hasAnyKey: false,
    models: []
  });
  const providerModelLoadTimerRef = useRef(null);
  const providerModelLoadTokenRef = useRef(0);
  const providerAutoSaveTimerRef = useRef(null);
  const providerAutoSaveTokenRef = useRef(0);
  const anthropicOAuthPopupRef = useRef(null);
  const geminiOAuthPopupRef = useRef(null);
  const [anthropicOAuthAuthorizationURL, setAnthropicOAuthAuthorizationURL] = useState("");
  const [geminiOAuthAuthorizationURL, setGeminiOAuthAuthorizationURL] = useState("");
  const [geminiOAuthManualCallback, setGeminiOAuthManualCallback] = useState("");
  const [geminiOAuthManualCode, setGeminiOAuthManualCode] = useState("");
  const [geminiOAuthState, setGeminiOAuthState] = useState("");

  useEffect(() => {
    loadConfig().catch(() => {
      setStatusText("Failed to load config");
    });
  }, []);

  const providerModelsProbeKey = useMemo(
    () => JSON.stringify(draftConfig?.models ?? []),
    [draftConfig.models]
  );

  useEffect(() => {
    if (!["model-routing", "semantic-decisions", "visor", "memory", "memory-dreams"].includes(selectedSettings)) {
      return;
    }
    let cancelled = false;
    (async () => {
      setModelRoutingCatalogStatus("Loading model catalog...");
      try {
        const [availableModelsResponse, catalog] = await Promise.all([
          fetchAvailableModels(),
          collectAggregatedProviderModels(draftConfig)
        ]);
        if (cancelled) {
          return;
        }
        const models = mergeModelOptions(
          Array.isArray(availableModelsResponse) ? availableModelsResponse : [],
          catalog.models
        );
        setModelRoutingCatalog(models);
        if (models.length === 0) {
          const hasModelEntries = Array.isArray(draftConfig.models) && draftConfig.models.length > 0;
          setModelRoutingCatalogStatus(
            hasModelEntries
              ? "No models returned from providers. Check API keys and probe status under Providers."
              : "Add at least one provider under Providers to list models."
          );
        } else {
          setModelRoutingCatalogStatus("");
        }
      } catch {
        if (!cancelled) {
          setModelRoutingCatalog([]);
          setModelRoutingCatalogStatus("Failed to load provider model catalogs.");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedSettings, providerModelsProbeKey]);

  useEffect(() => {
    if (selectedPluginIndex >= draftConfig.plugins.length) {
      setSelectedPluginIndex(Math.max(0, draftConfig.plugins.length - 1));
    }
  }, [draftConfig.plugins.length, selectedPluginIndex]);

  useEffect(() => {
    const serverCount = Array.isArray(draftConfig.mcp?.servers) ? draftConfig.mcp.servers.length : 0;
    if (selectedMCPServerIndex >= serverCount) {
      setSelectedMCPServerIndex(Math.max(0, serverCount - 1));
    }
  }, [draftConfig.mcp?.servers?.length, selectedMCPServerIndex]);

  useEffect(() => {
    if (!isSettingsSection(sectionId)) {
      return;
    }
    setSelectedSettings((current) => (current === sectionId ? current : sectionId));
  }, [sectionId]);

  function selectSettings(nextSectionId) {
    if (!isSettingsSection(nextSectionId)) {
      return;
    }
    setSelectedSettings(nextSectionId);
    if (typeof onSectionChange === "function" && nextSectionId !== sectionId) {
      onSectionChange(nextSectionId);
    }
  }

  const filteredSettings = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) {
      return SETTINGS_ITEMS;
    }
    return SETTINGS_ITEMS.filter((item) => {
      const searchableText = [
        item.id,
        item.title,
        ...(Array.isArray(item.searchTerms) ? item.searchTerms : [])
      ]
        .join(" ")
        .toLowerCase();
      return searchableText.includes(needle);
    });
  }, [query]);

  const isRawMode = selectedSettings === "config";

  const hasChanges = useMemo(() => {
    if (isRawMode) {
      return rawConfig !== JSON.stringify(savedConfig, null, 2);
    }
    const draftNorm = normalizeConfig(draftConfig);
    const savedNorm = normalizeConfig(savedConfig);
    return stableConfigStringify(draftNorm) !== stableConfigStringify(savedNorm);
  }, [isRawMode, rawConfig, draftConfig, savedConfig]);

  const hasManualChanges = useMemo(() => {
    if (selectedSettings !== "providers" || isRawMode) {
      return hasChanges;
    }
    const draftNorm = normalizeConfig(draftConfig);
    const savedNorm = normalizeConfig(savedConfig);
    draftNorm.models = savedNorm.models;
    return stableConfigStringify(draftNorm) !== stableConfigStringify(savedNorm);
  }, [selectedSettings, isRawMode, hasChanges, draftConfig, savedConfig]);

  const rawValid = useMemo(() => {
    try {
      JSON.parse(rawConfig);
      return true;
    } catch {
      return false;
    }
  }, [rawConfig]);

  const providerModalMeta = useMemo(() => {
    if (!providerModalId) {
      return null;
    }
    return getProviderDefinition(providerModalId);
  }, [providerModalId]);

  const customModelsCount = useMemo(
    () => draftConfig.models.filter((entry) => !inferCatalogIdForEntry(entry)).length,
    [draftConfig.models]
  );

  const configuredProviderRows = useMemo(
    () =>
      draftConfig.models.map((entry, index) => {
        const catalogId = inferCatalogIdForEntry(entry);
        return {
          index,
          entry,
          catalogId,
          meta: catalogId ? getProviderDefinition(catalogId) : null
        };
      }),
    [draftConfig.models]
  );

  async function loadConfig() {
    const config = await fetchRuntimeConfig();
    if (!config) {
      setStatusText("Failed to load config");
      return;
    }

    const channelPlugins = await fetchChannelPlugins().catch(() => null);
    const normalized = mergeChannelPluginsIntoConfig(normalizeConfig(config), channelPlugins);
    setSavedConfig(normalized);
    setConfigLoaded(true);

    const savedDraft = localStorage.getItem(DRAFT_CONFIG_KEY);
    if (savedDraft) {
      try {
        const parsedDraft = mergeChannelPluginsIntoConfig(normalizeConfig(JSON.parse(savedDraft)), channelPlugins);
        setDraftConfig(parsedDraft);
        setRawConfig(JSON.stringify(parsedDraft, null, 2));
        setStatusText("Config loaded (with local draft)");
      } catch {
        setDraftConfig(normalized);
        setRawConfig(JSON.stringify(normalized, null, 2));
        setStatusText("Config loaded (draft corrupted)");
      }
    } else {
      setDraftConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      setStatusText("Config loaded");
    }

    setProviderModalId(null);
    setProviderModalIndex(null);
    setProviderForm(null);
    setProviderModelOptions({});
    setProviderModelStatus({});
    await loadOpenAIProviderStatus();
    await loadAnthropicProviderStatus();
    await loadGeminiProviderStatus();
    await loadSearchProviderStatus();
    await loadImageGenerationStatus();
    await loadGitHubAuthStatus();
  }

  async function cancelChanges() {
    localStorage.removeItem(DRAFT_CONFIG_KEY);
    const normalized = clone(savedConfig);
    setDraftConfig(normalized);
    setRawConfig(JSON.stringify(normalized, null, 2));
    setPendingOAuthDisconnect(false);
    setPendingAnthropicOAuthDisconnect(false);
    setStatusText("Changes cancelled");
  }

  async function persistConfig(payload) {
    try {
      const response = await updateRuntimeConfig(payload);

      if (pendingOAuthDisconnect) {
        await disconnectOpenAIOAuth();
        setPendingOAuthDisconnect(false);
      }
      if (pendingAnthropicOAuthDisconnect) {
        await disconnectAnthropicOAuth();
        setPendingAnthropicOAuthDisconnect(false);
      }

      localStorage.removeItem(DRAFT_CONFIG_KEY);
      const channelPlugins = await fetchChannelPlugins().catch(() => null);
      const normalized = mergeChannelPluginsIntoConfig(normalizeConfig(response), channelPlugins);

      setDraftConfig(normalized);
      setSavedConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      if (typeof onRuntimeConfigUpdated === "function") {
        onRuntimeConfigUpdated(response as Record<string, unknown>);
      }
      await loadOpenAIProviderStatus();
      await loadAnthropicProviderStatus();
      await loadGeminiProviderStatus();
      await loadSearchProviderStatus();
      await loadImageGenerationStatus();
      await loadGitHubAuthStatus();
      setStatusText("Config saved");
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to save config";
      setStatusText(message);
      return false;
    }
  }

  async function saveConfig() {
    try {
      const payload = isRawMode ? normalizeConfig(JSON.parse(rawConfig)) : draftConfig;
      return await persistConfig(payload);
    } catch {
      setStatusText("Invalid raw JSON");
      return false;
    }
  }

  async function runGitSyncNow() {
    if (gitSyncRunning) return;
    setGitSyncRunning(true);
    setGitSyncStatusText("Syncing workspace...");
    try {
      if (hasChanges) {
        const payload = isRawMode ? normalizeConfig(JSON.parse(rawConfig)) : draftConfig;
        const saved = await persistConfig(payload);
        if (!saved) {
          setGitSyncStatusText("Save config before syncing.");
          return;
        }
      }
      const response = await runWorkspaceGitSync();
      const ok = Boolean(response?.ok);
      const message = String(response?.message || (ok ? "Workspace synced." : "Workspace sync failed."));
      await loadConfig();
      setGitSyncStatusText(message);
      setStatusText(message);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Workspace sync failed.";
      await loadConfig().catch(() => {});
      setGitSyncStatusText(message);
      setStatusText(message);
    } finally {
      setGitSyncRunning(false);
    }
  }

  async function loadOpenAIProviderStatus() {
    const response = await fetchOpenAIProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setOpenAIProviderStatus({
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      hasOAuthCredentials: Boolean(payload.hasOAuthCredentials),
      oauthAccountId: String(payload.oauthAccountId || ""),
      oauthPlanType: String(payload.oauthPlanType || ""),
      oauthExpiresAt: String(payload.oauthExpiresAt || "")
    });
  }

  async function loadAnthropicProviderStatus() {
    const response = await fetchAnthropicProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setAnthropicProviderStatus({
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      hasOAuthCredentials: Boolean(payload.hasOAuthCredentials),
      oauthSource: String(payload.oauthSource || ""),
      oauthExpiresAt: String(payload.oauthExpiresAt || ""),
      oauthRefreshable: Boolean(payload.oauthRefreshable)
    });
  }

  async function loadGeminiProviderStatus() {
    const response = await fetchGeminiProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setGeminiProviderStatus({
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      hasOAuthCredentials: Boolean(payload.hasOAuthCredentials),
      oauthEmail: String(payload.oauthEmail || ""),
      oauthExpiresAt: String(payload.oauthExpiresAt || "")
    });
  }

  async function loadGitHubAuthStatus() {
    const response = await fetchGitHubAuthStatus();
    if (!response) return;
    const payload = response as any;
    setGitHubAuthStatus({
      connected: Boolean(payload.connected),
      username: payload.username || null,
      connectedAt: payload.connectedAt || null
    });
  }

  async function handleGitHubConnect() {
    const token = gitHubToken.trim();
    if (!token) return;
    setGitHubConnecting(true);
    setGitHubStatusText("Validating token...");
    const response = await connectGitHub({ token }) as any;
    setGitHubConnecting(false);
    if (response?.ok) {
      setGitHubStatusText(response.message || "Connected.");
      setGitHubToken("");
      await loadGitHubAuthStatus();
    } else {
      setGitHubStatusText(response?.message || "Failed to connect GitHub.");
    }
  }

  async function handleGitHubDisconnect() {
    await disconnectGitHub();
    setGitHubStatusText("Disconnected.");
    await loadGitHubAuthStatus();
  }

  async function loadSearchProviderStatus() {
    const response = await fetchSearchProviderStatus();
    if (!response) {
      return;
    }

    const payload = response as any;
    setSearchProviderStatus({
      activeProvider: String(payload.activeProvider || "perplexity"),
      brave: {
        hasEnvironmentKey: Boolean(payload.brave?.hasEnvironmentKey),
        hasConfiguredKey: Boolean(payload.brave?.hasConfiguredKey),
        hasAnyKey: Boolean(payload.brave?.hasAnyKey)
      },
      perplexity: {
        hasEnvironmentKey: Boolean(payload.perplexity?.hasEnvironmentKey),
        hasConfiguredKey: Boolean(payload.perplexity?.hasConfiguredKey),
        hasAnyKey: Boolean(payload.perplexity?.hasAnyKey)
      }
    });
  }

  async function loadImageGenerationStatus() {
    const response = await fetchImageGenerationStatus();
    if (!response) {
      return;
    }
    const payload = response as any;
    setImageGenerationStatus({
      enabled: Boolean(payload.enabled),
      provider: String(payload.provider || "fal"),
      model: String(payload.model || "fal-ai/flux-2"),
      hasEnvironmentKey: Boolean(payload.hasEnvironmentKey),
      hasConfiguredKey: Boolean(payload.hasConfiguredKey),
      hasAnyKey: Boolean(payload.hasAnyKey),
      models: Array.isArray(payload.models) ? payload.models : []
    });
  }

  function mutateDraft(mutator) {
    setDraftConfig((previous) => {
      const next = clone(previous);
      mutator(next);
      const json = JSON.stringify(next, null, 2);
      setRawConfig(json);
      localStorage.setItem(DRAFT_CONFIG_KEY, json);
      return next;
    });
  }

  function writeProviderDraft(nextConfig) {
    const json = JSON.stringify(nextConfig, null, 2);
    setDraftConfig(nextConfig);
    setRawConfig(json);
  }

  async function runProviderConfigSave(payload, token, successMessage) {
    setStatusText("Saving provider changes...");
    try {
      const response = await updateRuntimeConfig(payload);
      if (providerAutoSaveTokenRef.current !== token) {
        return true;
      }

      localStorage.removeItem(DRAFT_CONFIG_KEY);
      const normalized = normalizeConfig(response);
      setDraftConfig(normalized);
      setSavedConfig(normalized);
      setRawConfig(JSON.stringify(normalized, null, 2));
      if (typeof onRuntimeConfigUpdated === "function") {
        onRuntimeConfigUpdated(response as Record<string, unknown>);
      }
      await loadOpenAIProviderStatus();
      await loadAnthropicProviderStatus();
      await loadGeminiProviderStatus();
      await loadSearchProviderStatus();
      await loadImageGenerationStatus();
      await loadGitHubAuthStatus();
      setStatusText(successMessage);
      return true;
    } catch (err) {
      if (providerAutoSaveTokenRef.current === token) {
        const message = err instanceof Error ? err.message : "Failed to save provider changes";
        setStatusText(message);
      }
      return false;
    }
  }

  function scheduleProviderConfigSave(nextConfig, options: { debounce?: boolean; successMessage?: string } = {}) {
    const debounce = options.debounce !== false;
    const successMessage = options.successMessage || "Provider changes saved";
    const payload = normalizeConfig(nextConfig);
    const token = providerAutoSaveTokenRef.current + 1;
    providerAutoSaveTokenRef.current = token;

    if (providerAutoSaveTimerRef.current) {
      clearTimeout(providerAutoSaveTimerRef.current);
      providerAutoSaveTimerRef.current = null;
    }

    if (!debounce) {
      return runProviderConfigSave(payload, token, successMessage);
    }

    setStatusText("Provider changes save automatically...");
    providerAutoSaveTimerRef.current = setTimeout(() => {
      providerAutoSaveTimerRef.current = null;
      runProviderConfigSave(payload, token, successMessage).catch(() => {
        // runProviderConfigSave reports errors in the header.
      });
    }, 650);
    return Promise.resolve(true);
  }

  async function openOpenAIPlatform() {
    const generation = ++configDeviceCodeGenerationRef.current;
    // Open during the click event so the browser does not block the sign-in window.
    const popup = window.open("about:blank", "sloppy-codex-device-code", "popup=yes,width=640,height=860");
    setProviderStatus("openai-oauth", "Requesting a Codex device code...");
    setConfigDeviceCode(null);
    setConfigDeviceCodeCopied(false);
    configDeviceCodePollingRef.current = true;
    setConfigDeviceCodePolling(true);
    try {
      const response = await startOpenAIDeviceCode();
      if (generation !== configDeviceCodeGenerationRef.current || !configDeviceCodePollingRef.current) return;
      if (!response || typeof response.deviceAuthId !== "string") {
        popup?.close();
        setProviderStatus("openai-oauth", "Failed to start Codex device sign-in. Try again.");
        return;
      }
      const info = {
        deviceAuthId: String(response.deviceAuthId),
        userCode: String(response.userCode),
        verificationURL: String(response.verificationURL || "https://auth.openai.com/codex/device")
      };
      setConfigDeviceCode(info);
      if (popup) popup.location.href = info.verificationURL;
      setProviderStatus("openai-oauth", popup
        ? "Enter the device code in the Codex sign-in window."
        : "Allow popups or use Open login page, then enter the device code.");
      let interval = Math.max(1000, Number(response.interval || 5) * 1000);
      const deadline = Date.now() + Math.max(1, Number(response.expiresIn || 600)) * 1000;
      while (Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, interval));
        if (generation !== configDeviceCodeGenerationRef.current || !configDeviceCodePollingRef.current) return;
        const result = await pollOpenAIDeviceCode({ deviceAuthId: info.deviceAuthId, userCode: info.userCode });
        if (generation !== configDeviceCodeGenerationRef.current || !configDeviceCodePollingRef.current) return;
        if (!result) {
          setProviderStatus("openai-oauth", "Polling failed. Try again.");
          return;
        }
        if (result.status === "approved" && result.ok) {
          setConfigDeviceCode(null);
          setProviderStatus("openai-oauth", String(result.message || "Codex connected."));
          setStatusText("Codex connected");
          await loadOpenAIProviderStatus();
          await loadProviderModels("openai-oauth", providerForm || getProviderDefinition("openai-oauth").defaultEntry);
          return;
        }
        if (result.status === "slow_down") interval += 5000;
        else if (result.status !== "pending") {
          setProviderStatus("openai-oauth", String(result.message || "Device sign-in failed."));
          return;
        }
      }
      setConfigDeviceCode(null);
      setProviderStatus("openai-oauth", "The device code expired. Sign in again to get a new code.");
    } finally {
      if (generation === configDeviceCodeGenerationRef.current) {
        configDeviceCodePollingRef.current = false;
        setConfigDeviceCodePolling(false);
      }
    }
  }

  function copyConfigDeviceCode() {
    if (!configDeviceCode) return;
    navigator.clipboard.writeText(configDeviceCode.userCode).then(() => {
      setConfigDeviceCodeCopied(true);
    }).catch(() => {
      setConfigDeviceCodeCopied(true);
    });
  }

  function openConfigDeviceCodeLoginPage() {
    if (!configDeviceCode) return;
    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      configDeviceCode.verificationURL,
      "sloppy-openai-device-code",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    if (!popup) {
      setProviderStatus("openai-oauth", "Login window was blocked. Allow popups or open the login page in a new tab.");
      return;
    }
    setConfigDeviceCodeCopied(true);
  }

  function cancelConfigDeviceCodePolling() {
    configDeviceCodePollingRef.current = false;
    setConfigDeviceCodePolling(false);
    setConfigDeviceCode(null);
    setConfigDeviceCodeCopied(false);
    setProviderStatus("openai-oauth", "Device code authorization cancelled.");
  }

  function waitForOAuthCallback(popup, redirectURI, providerLabel) {
    return new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const interval = window.setInterval(() => {
        if (!popup || popup.closed) {
          window.clearInterval(interval);
          reject(new Error(`${providerLabel} OAuth window was closed.`));
          return;
        }

        if (Date.now() - startedAt > 5 * 60 * 1000) {
          window.clearInterval(interval);
          try {
            popup.close();
          } catch {
            // ignore
          }
          reject(new Error(`${providerLabel} OAuth timed out. Try again.`));
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

  async function openAnthropicOAuthPopup() {
    const redirectURI = `${window.location.origin}${window.location.pathname}`;
    setProviderStatus("anthropic-oauth", "Checking for local Claude Code credentials...");
    setAnthropicOAuthAuthorizationURL("");

    const imported = await importAnthropicClaudeCredentials();
    if (imported?.ok) {
      setProviderStatus("anthropic-oauth", String(imported.message || "Claude Code credentials imported."));
      setStatusText("Anthropic OAuth imported");
      await loadAnthropicProviderStatus();
      await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
      return;
    }

    setProviderStatus("anthropic-oauth", "Claude Code credentials were not found locally. Requesting Anthropic OAuth URL...");

    const response = await startAnthropicOAuth({ redirectURI });
    if (!response || typeof response.authorizationURL !== "string") {
      const message = imported?.message
        ? `Failed to start Anthropic OAuth. ${String(imported.message)}`
        : "Failed to start Anthropic OAuth.";
      setProviderStatus("anthropic-oauth", message);
      return;
    }
    setAnthropicOAuthAuthorizationURL(String(response.authorizationURL));

    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      String(response.authorizationURL),
      "sloppy-anthropic-oauth",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    anthropicOAuthPopupRef.current = popup;
    if (!popup) {
      setProviderStatus("anthropic-oauth", "Popup was blocked. Allow popups, use the QR code, or open the browser login again.");
      return;
    }

    setProviderStatus("anthropic-oauth", "Waiting for Anthropic sign-in confirmation...");

    try {
      const callbackURL = await waitForOAuthCallback(popup, redirectURI, "Anthropic");
      const completion = await completeAnthropicOAuth({ callbackURL });
      if (!completion?.ok) {
        setProviderStatus("anthropic-oauth", String(completion?.message || "Anthropic OAuth failed."));
        return;
      }

      setProviderStatus("anthropic-oauth", String(completion.message || "Anthropic OAuth connected."));
      setStatusText("Anthropic OAuth connected");
      setAnthropicOAuthAuthorizationURL("");
      await loadAnthropicProviderStatus();
      await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Anthropic OAuth failed.";
      setProviderStatus("anthropic-oauth", message);
    } finally {
      anthropicOAuthPopupRef.current = null;
    }
  }

  async function importClaudeCredentialsForAnthropic() {
    setProviderStatus("anthropic-oauth", "Importing Claude Code credentials...");
    setAnthropicOAuthAuthorizationURL("");
    const response = await importAnthropicClaudeCredentials();
    if (!response?.ok) {
      setProviderStatus("anthropic-oauth", String(response?.message || "Failed to import Claude Code credentials."));
      return;
    }

    setProviderStatus("anthropic-oauth", String(response.message || "Claude Code credentials imported."));
    setStatusText("Anthropic OAuth imported");
    await loadAnthropicProviderStatus();
    await loadProviderModels("anthropic-oauth", providerForm || getProviderDefinition("anthropic-oauth").defaultEntry);
  }

  async function handleAnthropicOAuthDisconnect() {
    const ok = await disconnectAnthropicOAuth();
    if (!ok) {
      setProviderStatus("anthropic-oauth", "Failed to disconnect Anthropic OAuth.");
      return;
    }

    setProviderStatus("anthropic-oauth", "Anthropic OAuth disconnected.");
    setAnthropicOAuthAuthorizationURL("");
    setStatusText("Anthropic OAuth disconnected");
    setProviderModelOptions((previous) => ({
      ...previous,
      ["anthropic-oauth"]: []
    }));
    await loadAnthropicProviderStatus();
  }

  async function openGeminiOAuthPopup() {
    const redirectURI = buildOAuthRedirectURI(window.location.href);
    setProviderStatus("gemini", "Requesting Google OAuth URL...");
    setGeminiOAuthAuthorizationURL("");
    setGeminiOAuthManualCallback("");
    setGeminiOAuthManualCode("");
    setGeminiOAuthState("");

    const response = await startGeminiOAuth({ redirectURI });
    if (!response || typeof response.authorizationURL !== "string") {
      setProviderStatus("gemini", "Failed to start Gemini OAuth.");
      return;
    }

    const authorizationURL = String(response.authorizationURL);
    setGeminiOAuthAuthorizationURL(authorizationURL);
    setGeminiOAuthState(String(response.state || ""));

    const width = 640;
    const height = 860;
    const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2));
    const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2));
    const popup = window.open(
      authorizationURL,
      "sloppy-gemini-oauth",
      `popup=yes,width=${width},height=${height},left=${left},top=${top}`
    );
    geminiOAuthPopupRef.current = popup;
    if (!popup) {
      setProviderStatus("gemini", "Popup was blocked. Allow popups, scan the QR code, or open the login page manually.");
      return;
    }

    setProviderStatus("gemini", "Waiting for Google sign-in confirmation...");

    try {
      const callbackURL = await waitForOAuthCallback(popup, redirectURI, "Gemini");
      await completeGeminiOAuthFromPayload({ callbackURL });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Gemini OAuth failed.";
      setProviderStatus("gemini", message);
    } finally {
      geminiOAuthPopupRef.current = null;
    }
  }

  async function completeGeminiOAuthFromPayload(payload) {
    const completion = await completeGeminiOAuth(payload);
    if (!completion?.ok) {
      setProviderStatus("gemini", String(completion?.message || "Gemini OAuth failed."));
      return false;
    }

    setProviderStatus("gemini", String(completion.message || "Gemini OAuth connected."));
    setStatusText("Gemini OAuth connected");
    setGeminiOAuthAuthorizationURL("");
    setGeminiOAuthManualCallback("");
    setGeminiOAuthManualCode("");
    setGeminiOAuthState("");
    await loadGeminiProviderStatus();
    await loadProviderModels("gemini", providerForm || getProviderDefinition("gemini").defaultEntry);
    return true;
  }

  async function completeGeminiOAuthManually() {
    const callbackURL = geminiOAuthManualCallback.trim();
    const code = geminiOAuthManualCode.trim();
    if (!callbackURL && !code) {
      setProviderStatus("gemini", "Paste the Google callback URL or authorization code first.");
      return;
    }

    const payload = callbackURL
      ? { callbackURL }
      : { code, state: geminiOAuthState };
    setProviderStatus("gemini", "Completing Gemini OAuth...");
    await completeGeminiOAuthFromPayload(payload);
  }

  async function handleGeminiOAuthDisconnect() {
    const ok = await disconnectGeminiOAuth();
    if (!ok) {
      setProviderStatus("gemini", "Failed to disconnect Gemini OAuth.");
      return;
    }

    setProviderStatus("gemini", "Gemini OAuth disconnected.");
    setGeminiOAuthAuthorizationURL("");
    setGeminiOAuthManualCallback("");
    setGeminiOAuthManualCode("");
    setGeminiOAuthState("");
    setStatusText("Gemini OAuth disconnected");
    await loadGeminiProviderStatus();
  }

  function setProviderStatus(providerId, message) {
    setProviderModelStatus((previous) => ({
      ...previous,
      [providerId]: message
    }));
  }

  function openProviderModalAtIndex(index) {
    const entry = draftConfig.models[index];
    if (!entry) {
      return;
    }
    const catalogId = inferCatalogIdForEntry(entry) || "openai-api";
    const provider = getProviderDefinition(catalogId);
    setProviderModalIndex(index);
    setProviderModalId(catalogId);
    setProviderForm({
      apiKey: entry.apiKey ?? "",
      apiUrl: entry.apiUrl ?? "",
      model: entry.model ?? "",
      title: entry.title || provider.defaultEntry.title,
      disabled: Boolean(entry.disabled)
    });
  }

  function appendProviderAndOpenModal(catalogId) {
    const provider = getProviderDefinition(catalogId);
    const base = clone(provider.defaultEntry);
    const next = clone(draftConfig);
    next.models.push({
      ...base,
      title: base.title,
      disabled: false,
      providerCatalogId: catalogId
    });
    const idx = next.models.length - 1;
    const entry = next.models[idx];
    writeProviderDraft(next);
    setProviderModalIndex(idx);
    setProviderModalId(catalogId);
    setProviderForm({
      apiKey: entry.apiKey ?? "",
      apiUrl: entry.apiUrl ?? "",
      model: entry.model ?? "",
      title: entry.title || provider.defaultEntry.title,
      disabled: false
    });
    scheduleProviderConfigSave(next, {
      debounce: false,
      successMessage: "Provider added"
    });
  }

  /** @deprecated prefer appendProviderAndOpenModal / openProviderModalAtIndex */
  function openProviderModal(catalogId) {
    const idx = findProviderModelIndex(draftConfig.models, catalogId);
    if (idx >= 0) {
      openProviderModalAtIndex(idx);
    } else {
      appendProviderAndOpenModal(catalogId);
    }
  }

  function closeProviderModal() {
    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }
    setProviderModalId(null);
    setProviderModalIndex(null);
    setProviderForm(null);
  }

  function providerEntryFromForm(provider, form) {
    const isAnthropic = provider.id === "anthropic" || provider.id === "anthropic-oauth";
    const allowsApiKey = provider.requiresApiKey || provider.id === "gemini";
    const isRelay = provider.id === "sloppy" && isSloppyRelayConnection(form.apiUrl);
    return {
      title: String(form.title || "").trim() || provider.defaultEntry.title,
      apiKey: allowsApiKey && !isRelay ? String(form.apiKey || "").trim() : "",
      apiUrl: isAnthropic
        ? String(form.apiUrl || "").trim()
        : String(form.apiUrl || "").trim() || provider.defaultEntry.apiUrl,
      model: String(form.model || "").trim() || provider.defaultEntry.model,
      disabled: Boolean(form.disabled),
      providerCatalogId: provider.id
    };
  }

  function configWithProviderForm(provider, form) {
    const nextConfig = clone(draftConfig);
    const nextEntry = providerEntryFromForm(provider, form);
    const index =
      providerModalIndex != null ? providerModalIndex : findProviderModelIndex(nextConfig.models, provider.id);
    if (index >= 0) {
      nextConfig.models[index] = nextEntry;
    } else {
      nextConfig.models.push(nextEntry);
      setProviderModalIndex(nextConfig.models.length - 1);
    }
    return nextConfig;
  }

  function updateProviderForm(field, value) {
    if (!providerModalMeta || !providerForm) {
      return;
    }

    const nextForm = {
      ...providerForm,
      [field]: value
    };
    if (field === "apiUrl" && providerModalMeta.id === "sloppy" &&
        (isSloppyRelayConnection(value) || isSloppyRelayConnection(providerForm.apiUrl))) {
      nextForm.apiKey = "";
    }
    setProviderForm(nextForm);

    const nextConfig = configWithProviderForm(providerModalMeta, nextForm);
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      successMessage: "Provider changes saved"
    });

  }

  function selectAnthropicAuthMode(mode) {
    if (!providerForm) {
      return;
    }
    const nextProviderId = mode === "api-token" ? "anthropic" : "anthropic-oauth";
    if (providerModalId === nextProviderId) {
      return;
    }

    const provider = getProviderDefinition(nextProviderId);
    const currentTitle = String(providerForm.title || "").trim();
    const nextTitle =
      currentTitle === "anthropic" || currentTitle === "anthropic-oauth" || !currentTitle
        ? provider.defaultEntry.title
        : currentTitle;
    const nextForm = {
      ...providerForm,
      title: nextTitle,
      apiUrl: providerForm.apiUrl ?? provider.defaultEntry.apiUrl,
      model: providerForm.model || provider.defaultEntry.model
    };

    setProviderModalId(nextProviderId);
    setProviderForm(nextForm);
    setProviderStatus(nextProviderId, "");

    const nextConfig = configWithProviderForm(provider, nextForm);
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      successMessage: "Provider changes saved"
    });
  }

  async function loadProviderModels(providerId, entryOverride = null) {
    const provider = getProviderDefinition(providerId);
    if (!provider.supportsModelCatalog) {
      return;
    }

    const entryFromConfig =
      providerModalIndex != null
        ? draftConfig.models[providerModalIndex]
        : getProviderEntry(draftConfig.models, provider.id)?.entry || provider.defaultEntry;
    const entry = entryOverride || entryFromConfig;
    setProviderStatus(provider.id, "Loading provider models...");

    let payload;
    if (
      provider.id === "sloppy" ||
      provider.id === "openrouter" ||
      provider.id === "ollama" ||
      provider.id === "gemini" ||
      provider.id === "anthropic" ||
      provider.id === "claude-code" ||
      provider.id === "anthropic-oauth"
    ) {
      const probe = await probeProvider({
        providerId: provider.id,
        apiKey: String(entry.apiKey || "").trim() || undefined,
        apiUrl: entry.apiUrl || (provider.id === "anthropic" || provider.id === "anthropic-oauth" ? "" : provider.defaultEntry.apiUrl)
      });
      if (!probe) {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
        return;
      }
      payload = {
        models: Array.isArray(probe.models) ? probe.models : [],
        warning: probe.ok ? undefined : String(probe.message || ""),
        source: probe.ok ? "remote" : "fallback",
        usedEnvironmentKey: Boolean(probe.usedEnvironmentKey)
      };
    } else {
      const response = await fetchOpenAIModels({
        authMethod: provider.authMethod,
        apiKey: provider.authMethod === "api_key" ? entry.apiKey : undefined,
        apiUrl: entry.apiUrl || provider.defaultEntry.apiUrl
      });

      if (!response) {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
        return;
      }
      payload = response;
    }

    payload = payload as any;
    const models = Array.isArray(payload.models) ? payload.models : [];

    setProviderModelOptions((previous) => ({
      ...previous,
      [provider.id]: models
    }));

    if (payload.warning) {
      setProviderStatus(provider.id, payload.warning);
    } else if (payload.source === "remote") {
      const label =
        provider.id === "claude-code" ? "Claude Code CLI aliases" : provider.id === "sloppy" ? "Sloppy" : provider.id === "openrouter"
          ? "OpenRouter"
          : provider.id === "ollama"
            ? "Ollama"
            : provider.id === "gemini"
              ? "Gemini"
              : provider.id === "anthropic-oauth" || provider.id === "anthropic"
                ? "Anthropic"
                : "OpenAI";
      setProviderStatus(provider.id, `Loaded ${models.length} models from ${label}`);
    } else {
      setProviderStatus(provider.id, `Loaded fallback catalog (${models.length} models)`);
    }

    if (provider.id === "openai-api" || provider.id === "openai-oauth") {
      setOpenAIProviderStatus((previous) => (
        provider.id === "openai-api"
          ? {
            ...previous,
            hasEnvironmentKey: Boolean(payload.usedEnvironmentKey),
            hasAnyKey: previous.hasConfiguredKey || Boolean(payload.usedEnvironmentKey)
          }
          : previous
      ));
    }
    if (provider.id === "anthropic-oauth") {
      await loadAnthropicProviderStatus();
    }
    if (provider.id === "gemini") {
      await loadGeminiProviderStatus();
    }
  }

  async function testProviderConnection(providerId) {
    const provider = getProviderDefinition(providerId);
    if (!provider) {
      return;
    }

    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }
    providerModelLoadTokenRef.current += 1;

    setProviderProbeTesting((previous) => ({ ...previous, [provider.id]: true }));
    try {
      if (provider.supportsModelCatalog) {
        await loadProviderModels(provider.id, providerForm);
      } else {
        setProviderStatus(provider.id, "This provider does not support a connection test.");
      }
    } catch {
      setProviderStatus(provider.id, "Failed to reach provider.");
    } finally {
      setProviderProbeTesting((previous) => ({ ...previous, [provider.id]: false }));
    }
  }

  useEffect(() => {
    if (!providerModalMeta || !providerForm || !providerModalMeta.supportsModelCatalog) {
      return;
    }

    const provider = providerModalMeta;
    const hasEnvironmentKeyForOpenAI = provider.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey;
    const hasOAuthCredentialsForOpenAI = provider.id === "openai-oauth" && openAIProviderStatus.hasOAuthCredentials;
    const hasOAuthCredentialsForAnthropic = provider.id === "anthropic-oauth" && anthropicProviderStatus.hasOAuthCredentials;
    const requiresApiKey = provider.authMethod === "api_key" && !(provider.id === "sloppy" && isSloppyRelayConnection(providerForm.apiUrl));
    const hasKey = Boolean(String(providerForm.apiKey || "").trim())
      || hasEnvironmentKeyForOpenAI
      || (provider.id === "anthropic-oauth" && anthropicProviderStatus.hasEnvironmentKey);

    if (requiresApiKey && !hasKey) {
      setProviderStatus(provider.id, provider.id === "sloppy" ? "Set the Sloppy access token to load models." : "Set API Key to load models.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (
      provider.id === "anthropic-oauth" &&
      !hasOAuthCredentialsForAnthropic &&
      !anthropicProviderStatus.hasEnvironmentKey &&
      !String(providerForm.apiKey || "").trim()
    ) {
      setProviderStatus(provider.id, "Connect Anthropic OAuth, import Claude Code credentials, or set ANTHROPIC_AUTH_TOKEN.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (provider.id === "openai-oauth" && !hasOAuthCredentialsForOpenAI) {
      setProviderStatus(provider.id, "Connect OpenAI OAuth to load Codex models.");
      setProviderModelOptions((previous) => ({
        ...previous,
        [provider.id]: []
      }));
      return;
    }

    if (providerModelLoadTimerRef.current) {
      clearTimeout(providerModelLoadTimerRef.current);
      providerModelLoadTimerRef.current = null;
    }

    const token = providerModelLoadTokenRef.current + 1;
    providerModelLoadTokenRef.current = token;
    providerModelLoadTimerRef.current = setTimeout(() => {
      if (providerModelLoadTokenRef.current !== token) {
        return;
      }
      loadProviderModels(provider.id, providerForm).catch(() => {
        setProviderStatus(provider.id, "Failed to load models from sloppy");
      });
    }, 450);

    return () => {
      if (providerModelLoadTimerRef.current) {
        clearTimeout(providerModelLoadTimerRef.current);
        providerModelLoadTimerRef.current = null;
      }
    };
  }, [
    providerModalMeta,
    providerModalIndex,
    providerForm?.apiKey,
    providerForm?.apiUrl,
    openAIProviderStatus.hasEnvironmentKey,
    openAIProviderStatus.hasOAuthCredentials,
    anthropicProviderStatus.hasEnvironmentKey,
    anthropicProviderStatus.hasOAuthCredentials
  ]);

  useEffect(() => {
    return () => {
      configDeviceCodePollingRef.current = false;
      if (providerAutoSaveTimerRef.current) {
        clearTimeout(providerAutoSaveTimerRef.current);
        providerAutoSaveTimerRef.current = null;
      }
    };
  }, []);

  async function saveProviderFromModal() {
    if (!providerModalMeta || !providerForm) {
      return;
    }

    const nextConfig = configWithProviderForm(providerModalMeta, providerForm);
    writeProviderDraft(nextConfig);
    closeProviderModal();
    await scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider changes saved"
    });
  }

  async function closeProviderModalWithAutosave() {
    if (!providerModalMeta || !providerForm) {
      closeProviderModal();
      return;
    }
    await saveProviderFromModal();
  }

  async function removeProviderFromModal() {
    if (!providerModalMeta) {
      return;
    }

    const provider = providerModalMeta;
    const disconnectOpenAI = provider.id === "openai-oauth";
    const disconnectAnthropic = provider.id === "anthropic-oauth";
    const disconnectGemini = provider.id === "gemini";

    const nextConfig = clone(draftConfig);
    const index =
      providerModalIndex != null ? providerModalIndex : findProviderModelIndex(nextConfig.models, provider.id);
    if (index >= 0) {
      nextConfig.models.splice(index, 1);
    }

    writeProviderDraft(nextConfig);
    closeProviderModal();
    const saved = await scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider removed"
    });
    if (saved && disconnectOpenAI) {
      await disconnectOpenAIOAuth();
      await loadOpenAIProviderStatus();
    }
    if (saved && disconnectAnthropic) {
      await disconnectAnthropicOAuth();
      await loadAnthropicProviderStatus();
    }
    if (saved && disconnectGemini) {
      await disconnectGeminiOAuth();
      await loadGeminiProviderStatus();
    }
  }

  function setProviderRowDisabled(index, disabled) {
    const nextConfig = clone(draftConfig);
    if (!nextConfig.models[index]) {
      return;
    }
    nextConfig.models[index].disabled = disabled;
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      debounce: false,
      successMessage: "Provider changes saved"
    });
  }

  function updateOpenCodeConfig(patch) {
    const nextConfig = clone(draftConfig);
    nextConfig.opencode = {
      ...clone(EMPTY_CONFIG.opencode),
      ...(nextConfig.opencode || {}),
      ...patch
    };
    nextConfig.opencode.command = String(nextConfig.opencode.command || "").trim() || "opencode";
    nextConfig.opencode.authPath = String(nextConfig.opencode.authPath || "");
    nextConfig.opencode.configPaths = Array.isArray(nextConfig.opencode.configPaths)
      ? nextConfig.opencode.configPaths.map((item) => String(item || "").trim()).filter(Boolean)
      : [];
    nextConfig.opencode.includeProviders = Array.isArray(nextConfig.opencode.includeProviders)
      ? nextConfig.opencode.includeProviders.map((item) => String(item || "").trim()).filter(Boolean)
      : [];
    nextConfig.opencode.excludeProviders = Array.isArray(nextConfig.opencode.excludeProviders)
      ? nextConfig.opencode.excludeProviders.map((item) => String(item || "").trim()).filter(Boolean)
      : [];
    nextConfig.opencode.timeoutMs = parseInteger(nextConfig.opencode.timeoutMs ?? 5000, 5000);
    writeProviderDraft(nextConfig);
    scheduleProviderConfigSave(nextConfig, {
      successMessage: "OpenCode import settings saved"
    });
  }

  function renderSessionRetentionSettings() {
    const retention = draftConfig.sessionRetention || { enabled: true, days: 30 };
    const retentionEnabled = retention.enabled !== false;
    const retentionDays = Math.min(90, Math.max(1, parseInteger(retention.days ?? 30, 30)));

    const setRetentionDays = (value) => {
      const nextDays = Math.min(90, Math.max(1, parseInteger(value, 30)));
      mutateDraft((draft) => {
        if (!draft.sessionRetention) {
          draft.sessionRetention = { enabled: true, days: 30 };
        }
        draft.sessionRetention.days = nextDays;
      });
    };

    return (
      <div className="tg-settings-shell sessions-settings-shell">
        <section className="entry-editor-card providers-intro-card">
          <h3>Sessions</h3>
          <p className="placeholder-text">
            Keep session files bounded by automatically deleting old agent and channel sessions.
          </p>
        </section>

        <section className="entry-editor-card">
          <h3>Retention</h3>
          <div className="entry-form-grid">
            <div className="settings-toggle-row" style={{ gridColumn: "1 / -1" }}>
              <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
                <span className="agent-tools-guardrail-copy">
                  <span className="agent-tools-guardrail-title">Delete old sessions automatically</span>
                </span>
                <span className="agent-tools-switch">
                  <input
                    type="checkbox"
                    checked={retentionEnabled}
                    onChange={(event) => {
                      const checked = event.target.checked;
                      mutateDraft((draft) => {
                        if (!draft.sessionRetention) {
                          draft.sessionRetention = { enabled: true, days: 30 };
                        }
                        draft.sessionRetention.enabled = checked;
                      });
                    }}
                  />
                  <span className="agent-tools-switch-track" />
                </span>
              </label>
            </div>

            <label style={{ gridColumn: "1 / -1" }}>
              Delete sessions after (days)
              <input
                type="number"
                min="1"
                max="90"
                step="1"
                disabled={!retentionEnabled}
                value={retentionDays}
                onChange={(event) => setRetentionDays(event.target.value)}
              />
              <span className="entry-form-hint">
                Allowed range is 1-90 days. Default is 30 days.
              </span>
            </label>
          </div>
        </section>
      </div>
    );
  }

  function renderTUISettings() {
    const defaultEditor = String(draftConfig?.tui?.defaultEditor || "");

    return (
      <div className="tg-settings-shell sessions-settings-shell">
        <section className="entry-editor-card providers-intro-card">
          <h3>TUI</h3>
          <p className="placeholder-text">
            Configure terminal interface defaults.
          </p>
        </section>

        <section className="entry-editor-card">
          <h3>Editor</h3>
          <div className="entry-form-grid">
            <label style={{ gridColumn: "1 / -1" }}>
              Default editor command
              <input
                type="text"
                value={defaultEditor}
                placeholder="code --reuse-window"
                onChange={(event) => {
                  mutateDraft((draft) => {
                    if (!draft.tui) {
                      draft.tui = { defaultEditor: "" };
                    }
                    draft.tui.defaultEditor = event.target.value;
                  });
                }}
                spellCheck={false}
              />
              <span className="entry-form-hint">
                Used by `/editor` when no editor argument is passed. `/editor zed` overrides this value for that launch.
              </span>
            </label>
          </div>
        </section>
      </div>
    );
  }

  function renderSettingsContent() {
    if (selectedSettings === "migrations") return <MigrationWizard />;
    if (selectedSettings === "providers") {
      return (
        <>
          <ProviderEditor
            providerCatalog={PROVIDER_CATALOG_UI}
            configuredProviderRows={configuredProviderRows}
            customModelsCount={customModelsCount}
            openAIProviderStatus={openAIProviderStatus}
            anthropicProviderStatus={anthropicProviderStatus}
            geminiProviderStatus={geminiProviderStatus}
            providerModalMeta={providerModalMeta}
            providerForm={providerForm}
            modelRelayNodes={modelRelayNodes}
            modelConsoleInstances={modelConsoleInstances}
            modelConsoleStatus={modelConsoleStatus}
            onReloadConsoleInstances={reloadConsoleInstances}
            providerModelStatus={providerModelStatus}
            providerModelOptions={providerModelOptions}
            modalActiveEntry={providerModalIndex != null ? draftConfig.models[providerModalIndex] : null}
            onOpenProviderAtIndex={openProviderModalAtIndex}
            onAppendProvider={appendProviderAndOpenModal}
            onSetProviderRowDisabled={setProviderRowDisabled}
            onCloseProviderModal={closeProviderModalWithAutosave}
            onUpdateProviderForm={updateProviderForm}
            onSelectAnthropicAuthMode={selectAnthropicAuthMode}
            onOpenOAuth={openOpenAIPlatform}
            onOpenAnthropicOAuth={openAnthropicOAuthPopup}
            onImportAnthropicClaudeCredentials={importClaudeCredentialsForAnthropic}
            onDisconnectAnthropicOAuth={handleAnthropicOAuthDisconnect}
            anthropicOAuthAuthorizationURL={anthropicOAuthAuthorizationURL}
            onOpenGeminiOAuth={openGeminiOAuthPopup}
            onCompleteGeminiOAuthManually={completeGeminiOAuthManually}
            onDisconnectGeminiOAuth={handleGeminiOAuthDisconnect}
            geminiOAuthAuthorizationURL={geminiOAuthAuthorizationURL}
            geminiOAuthManualCallback={geminiOAuthManualCallback}
            geminiOAuthManualCode={geminiOAuthManualCode}
            onSetGeminiOAuthManualCallback={setGeminiOAuthManualCallback}
            onSetGeminiOAuthManualCode={setGeminiOAuthManualCode}
            onCancelDeviceCode={cancelConfigDeviceCodePolling}
            onCopyDeviceCode={copyConfigDeviceCode}
            onOpenDeviceCodeLoginPage={openConfigDeviceCodeLoginPage}
            deviceCode={configDeviceCode}
            deviceCodeCopied={configDeviceCodeCopied}
            isDeviceCodePolling={configDeviceCodePolling}
            onRemoveProvider={removeProviderFromModal}
            onSaveProvider={saveProviderFromModal}
            onTestProviderConnection={testProviderConnection}
            providerProbeTesting={providerProbeTesting}
            openCodeConfig={draftConfig.opencode}
            onUpdateOpenCodeConfig={updateOpenCodeConfig}
            parseConfigList={parseConfigList}
            providerIsConfigured={providerIsConfigured}
          />
          <GitHubAccessCard
            gitHubAuthStatus={gitHubAuthStatus}
            gitHubToken={gitHubToken}
            gitHubStatusText={gitHubStatusText}
            gitHubConnecting={gitHubConnecting}
            onGitHubTokenChange={setGitHubToken}
            onConnect={handleGitHubConnect}
            onDisconnect={handleGitHubDisconnect}
          />
        </>
      );
    }
    if (selectedSettings === "plugins") {
      return (
        <PluginEditor
          draftConfig={draftConfig}
          selectedPluginIndex={selectedPluginIndex}
          onSelectPluginIndex={setSelectedPluginIndex}
          mutateDraft={mutateDraft}
          emptyPlugin={emptyPlugin}
          selectDirectory={selectDirectory}
          installPlugin={installPlugin}
        />
      );
    }
    if (selectedSettings === "mcp") {
      return (
        <MCPEditor
          draftConfig={draftConfig}
          selectedMCPServerIndex={selectedMCPServerIndex}
          onSelectMCPServerIndex={setSelectedMCPServerIndex}
          mutateDraft={mutateDraft}
          emptyMCPServer={emptyMCPServer}
          parseLines={parseLines}
        />
      );
    }
    if (selectedSettings === "nodehost") {
      return <NodeHostEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }
    if (selectedSettings === "channels") {
      return (
        <ChannelsEditor
          draftConfig={draftConfig}
          mutateDraft={mutateDraft}
          parseInteger={parseInteger}
        />
      );
    }
    if (selectedSettings === "sessions") {
      return renderSessionRetentionSettings();
    }
    if (selectedSettings === "search-tools") {
      return (
        <SearchToolsEditor
          draftConfig={draftConfig}
          searchProviderStatus={searchProviderStatus}
          mutateDraft={mutateDraft}
        />
      );
    }
    if (selectedSettings === "image-generation") {
      return (
        <ImageGenerationEditor
          draftConfig={draftConfig}
          status={imageGenerationStatus}
          mutateDraft={mutateDraft}
        />
      );
    }
    if (selectedSettings === "git-sync") {
      return (
        <GitSyncEditor
          draftConfig={draftConfig}
          mutateDraft={mutateDraft}
          normalizeGitSyncFrequency={normalizeGitSyncFrequency}
          normalizeGitSyncConflictStrategy={normalizeGitSyncConflictStrategy}
          normalizeTimeValue={normalizeTimeValue}
          gitSyncRunning={gitSyncRunning}
          gitSyncStatusText={gitSyncStatusText}
          onRunGitSyncNow={runGitSyncNow}
        />
      );
    }

    if (selectedSettings === "acp") {
      return <ACPEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "ui") {
      return <UIEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "tui") {
      return renderTUISettings();
    }

    if (selectedSettings === "proxy") {
      return <ProxyEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "browser") {
      return <BrowserEditor draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} />;
    }

    if (selectedSettings === "voice-mode") {
      return (
        <VoiceModeEditor
          voiceMode={draftConfig.voiceMode}
          fetchVoiceCapabilities={fetchVoiceCapabilities}
          onUpdate={(nextVoiceMode) => mutateDraft((next) => {
            next.voiceMode = nextVoiceMode;
          })}
        />
      );
    }

    if (selectedSettings === "memory" || selectedSettings === "memory-dreams") {
      return <>
        {selectedSettings === "memory" && <MemoryProviderEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />}
        <VisorEditor section={selectedSettings === "memory" ? "memory" : "dreams"} draftConfig={draftConfig} mutateDraft={mutateDraft} parseLines={parseLines} modelRoutingCatalog={modelRoutingCatalog} modelRoutingCatalogStatus={modelRoutingCatalogStatus} />
      </>;
    }

    if (selectedSettings === "visor") {
      return (
        <VisorEditor
          draftConfig={draftConfig}
          mutateDraft={mutateDraft}
          parseLines={parseLines}
          modelRoutingCatalog={modelRoutingCatalog}
          modelRoutingCatalogStatus={modelRoutingCatalogStatus}
        />
      );
    }

    if (selectedSettings === "compactor") {
      return <CompactorEditor draftConfig={draftConfig} mutateDraft={mutateDraft} />;
    }

    if (selectedSettings === "model-routing") {
      return (
        <ModelRoutingEditor
          draftConfig={draftConfig}
          mutateDraft={mutateDraft}
          modelRoutingCatalog={modelRoutingCatalog}
          modelRoutingCatalogStatus={modelRoutingCatalogStatus}
        />
      );
    }

    if (selectedSettings === "semantic-decisions") {
      return (
        <SemanticDecisionsEditor
          draftConfig={draftConfig}
          mutateDraft={mutateDraft}
          modelCatalog={modelRoutingCatalog}
          modelCatalogStatus={modelRoutingCatalogStatus}
        />
      );
    }

    if (selectedSettings === "approvals") {
      return <ApprovalsView />;
    }

    if (selectedSettings === "users") {
      return <AuthUsersEditor />;
    }

    if (selectedSettings === "updates") {
      return (
        <UpdatesView
          status={updateStatus}
          isChecking={isUpdateChecking}
          onForceCheck={forceUpdateCheck}
        />
      );
    }

    if (selectedSettings === "connect-client") {
      return (
        <ClientConnectView
          listenPort={draftConfig.listen.port}
          clientPublicURL={String(draftConfig.clientPublicURL || "")}
          clientAlternateURLs={Array.isArray(draftConfig.clientAlternateURLs) ? draftConfig.clientAlternateURLs : []}
          clientTLSFingerprint={String(draftConfig.clientTLSFingerprint || "")}
          onConfigChange={(patch) => mutateDraft((draft) => {
            draft.clientPublicURL = patch.clientPublicURL || null;
            draft.clientAlternateURLs = patch.clientAlternateURLs;
            draft.clientTLSFingerprint = patch.clientTLSFingerprint || null;
          })}
          onSave={saveConfig}
          onFingerprintDetected={async (fingerprint) => {
            const next = clone(draftConfig);
            next.clientTLSFingerprint = fingerprint;
            return await persistConfig(next);
          }}
        />
      );
    }

    if (selectedSettings === "config") {
      return (
        <ConfigRawView
          rawConfig={rawConfig}
          savedConfig={savedConfig}
          onChange={(val) => {
            setRawConfig(val);
            try {
              const parsed = JSON.parse(val);
              const normalized = normalizeConfig(parsed);
              setDraftConfig(normalized);
              localStorage.setItem(DRAFT_CONFIG_KEY, JSON.stringify(normalized, null, 2));
            } catch {
              // keep rawConfig state even if JSON invalid
            }
          }}
        />
      );
    }

    const section = SETTINGS_ITEMS.find((item) => item.id === selectedSettings);
    return <SettingsPlaceholder title={section?.title} />;
  }

  const selectedSectionTitle = selectedSettings === "memory"
    ? "Memory"
    : selectedSettings === "memory-dreams"
      ? "Dreams"
      : SETTINGS_ITEMS.find((item) => item.id === selectedSettings)?.title || "Configuration";

  return (
    <main className={embedded ? "memory-settings-editor" : "settings-shell"}>
      {!embedded && <SettingsSidebar
        rawValid={isRawMode ? rawValid : true}
        query={query}
        onQueryChange={setQuery}
        filteredSettings={filteredSettings}
        selectedSettings={selectedSettings}
        onSelectSettings={selectSettings}
      />}

      <section className="settings-main">
        <SettingsMainHeader
          title={selectedSectionTitle}
          hasChanges={(!embedded || configLoaded) && hasManualChanges}
          statusText={statusText}
          onReload={cancelChanges}
          onSave={saveConfig}
        />

        {embedded && !configLoaded
          ? <button type="button" onClick={() => loadConfig().catch(() => setStatusText("Failed to load config"))}>Retry loading settings</button>
          : renderSettingsContent()}
      </section>
    </main>
  );
}
