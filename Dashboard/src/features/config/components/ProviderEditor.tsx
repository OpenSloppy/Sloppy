import React, { useEffect, useRef, useState } from "react";
import { Gemini, ProviderIcon } from "@lobehub/icons";
import { QRCodeSVG } from "qrcode.react";
import { AggregatedModelPicker } from "./AggregatedModelPicker";

/** ProviderIcon resolves providers via keyword map; "gemini" is not registered (only "google"). */
function ProviderBrandMark({ brandProviderKey, size }) {
  if (!brandProviderKey) {
    return (
      <span className="material-symbols-rounded" aria-hidden="true" style={{ fontSize: size, lineHeight: 1 }}>
        hub
      </span>
    );
  }
  if (brandProviderKey === "gemini") {
    return <Gemini.Color size={size} />;
  }
  return <ProviderIcon provider={brandProviderKey} size={size} type="color" />;
}

const CLI_AUTH_TOOLS = [
  {
    providerId: "openai-oauth",
    title: "OpenAI Codex",
    command: "codex login",
    source: "Sign in with a Codex device code"
  },
  {
    providerId: "claude-code",
    title: "Claude Code",
    command: "claude auth login",
    source: "Official CLI on the Sloppy server"
  },
  {
    providerId: "gemini",
    title: "Google Gemini",
    command: "Google OAuth",
    source: "Sloppy-owned OAuth credentials"
  }
];

export function ProviderEditor({
  providerCatalog,
  configuredProviderRows,
  customModelsCount,
  openAIProviderStatus,
  anthropicProviderStatus,
  geminiProviderStatus,
  providerModalMeta,
  providerForm,
  providerModelStatus,
  providerModelOptions,
  modalActiveEntry,
  onOpenProviderAtIndex,
  onAppendProvider,
  onSetProviderRowDisabled,
  onCloseProviderModal,
  onUpdateProviderForm,
  onSelectAnthropicAuthMode,
  onOpenOAuth,
  onOpenAnthropicOAuth,
  onImportAnthropicClaudeCredentials,
  onDisconnectAnthropicOAuth,
  anthropicOAuthAuthorizationURL,
  onOpenGeminiOAuth,
  onCompleteGeminiOAuthManually,
  onDisconnectGeminiOAuth,
  geminiOAuthAuthorizationURL,
  geminiOAuthManualCallback,
  geminiOAuthManualCode,
  onSetGeminiOAuthManualCallback,
  onSetGeminiOAuthManualCode,
  onCancelDeviceCode,
  onCopyDeviceCode,
  onOpenDeviceCodeLoginPage,
  deviceCode,
  deviceCodeCopied,
  isDeviceCodePolling,
  onRemoveProvider,
  onSaveProvider,
  onTestProviderConnection,
  providerProbeTesting,
  openCodeConfig,
  onUpdateOpenCodeConfig,
  parseConfigList,
  providerIsConfigured,
  modelRelayNodes = [],
  modelConsoleInstances = [],
  modelConsoleStatus = "",
  onReloadConsoleInstances = null
}) {
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  const [openCodeExpanded, setOpenCodeExpanded] = useState(false);
  const [relayPickerOpen, setRelayPickerOpen] = useState(false);
  const [relaySearch, setRelaySearch] = useState("");
  const addMenuRef = useRef(null);

  useEffect(() => {
    if (!addMenuOpen) {
      return undefined;
    }
    function handlePointerDown(event) {
      if (addMenuRef.current && !addMenuRef.current.contains(event.target)) {
        setAddMenuOpen(false);
      }
    }
    window.addEventListener("pointerdown", handlePointerDown);
    return () => window.removeEventListener("pointerdown", handlePointerDown);
  }, [addMenuOpen]);

  const activeProviderStatus = providerModalMeta ? providerModelStatus[providerModalMeta.id] : "";
  const activeProviderModels = providerModalMeta ? providerModelOptions[providerModalMeta.id] || [] : [];
  const isTestingActiveProvider = providerModalMeta
    ? Boolean(providerProbeTesting?.[providerModalMeta.id])
    : false;
  const isAnthropicModal = providerModalMeta?.id === "anthropic" || providerModalMeta?.id === "anthropic-oauth";
  const isGeminiModal = providerModalMeta?.id === "gemini";
  const isSloppyRelay = providerModalMeta?.id === "sloppy" && /^sloppy-(?:console|relay):/.test(String(providerForm?.apiUrl || ""));
  const isConsoleRelay = isSloppyRelay && String(providerForm.apiUrl).startsWith("sloppy-console:");
  const relayNodeID = isSloppyRelay ? String(providerForm.apiUrl).replace(/^sloppy-(?:console|relay):\/\//, "") : "";
  const relayChoices = isConsoleRelay ? modelConsoleInstances : modelRelayNodes;
  const selectedRelayChoice = relayChoices.find((node) => String(node.id).toLowerCase() === relayNodeID.toLowerCase());
  const anthropicAuthMode = providerModalMeta?.id === "anthropic" ? "api-token" : "oauth";
  const canTestActiveProvider = Boolean(
    providerModalMeta &&
      providerModalMeta.id !== "openai-oauth" &&
      providerModalMeta.supportsModelCatalog &&
      onTestProviderConnection
  );
  const providerRowByCatalog = new Map<string, any>(
    configuredProviderRows
      .filter((row) => row.catalogId)
      .map((row) => [row.catalogId, row])
  );
  const openCodeEnabled = Boolean(openCodeConfig?.enabled);
  const openCodeUseCommand = openCodeConfig?.useResolvedConfigCommand !== false;
  const openCodeCommand = String(openCodeConfig?.command || "opencode");
  const openCodeTimeoutMs = Number.parseInt(String(openCodeConfig?.timeoutMs ?? 5000), 10) || 5000;
  const openCodeConfigPaths = Array.isArray(openCodeConfig?.configPaths) ? openCodeConfig.configPaths : [];
  const openCodeIncludeProviders = Array.isArray(openCodeConfig?.includeProviders) ? openCodeConfig.includeProviders : [];
  const openCodeExcludeProviders = Array.isArray(openCodeConfig?.excludeProviders) ? openCodeConfig.excludeProviders : [];
  const openCodeAuthPath = String(openCodeConfig?.authPath || "");

  function openOrAppendProvider(providerId) {
    const row = providerRowByCatalog.get(providerId);
    if (row) {
      onOpenProviderAtIndex(row.index);
      return;
    }
    onAppendProvider(providerId);
  }

  return (
    <div className="providers-shell">
      <section className="entry-editor-card providers-intro-card">
        <h3>LLM Providers</h3>
        <p className="placeholder-text">
          Configure credentials and endpoints for providers. At least one enabled provider is required for agents.
          Disabled providers stay in config but are ignored at runtime.
        </p>
        <div className="providers-note">
          Provider changes save automatically. Add credentials, choose a model, and run a connection test when needed.
        </div>
        {customModelsCount > 0 ? (
          <p className="placeholder-text">
            Config has {customModelsCount} custom model entries. They are preserved and available in raw mode.
          </p>
        ) : null}
      </section>

      <section className="providers-cli-auth-block">
        <div className="providers-cli-auth-head">
          <span className="material-symbols-rounded providers-presets-icon" aria-hidden>
            terminal
          </span>
          <h4>CLI auth sources</h4>
        </div>
        <div className="providers-cli-grid">
          {CLI_AUTH_TOOLS.map((tool) => {
            const row = providerRowByCatalog.get(tool.providerId);
            const isConnected =
              tool.providerId === "openai-oauth"
                ? openAIProviderStatus.hasOAuthCredentials
                : tool.providerId === "claude-code"
                  ? (providerModelOptions["claude-code"] || []).length > 0
                  : tool.providerId === "gemini"
                    ? geminiProviderStatus.hasOAuthCredentials
                    : false;
            const status = isConnected
              ? "connected"
              : row
                ? "configured"
                : "available";
            return (
              <button
                key={tool.providerId}
                type="button"
                className="providers-cli-card"
                onClick={() => openOrAppendProvider(tool.providerId)}
              >
                <span className="providers-cli-card-icon material-symbols-rounded" aria-hidden>
                  terminal
                </span>
                <span className="providers-cli-card-main">
                  <span className="providers-cli-card-title">
                    {tool.title}
                    <span className={`provider-state ${isConnected || row ? "on" : "off"}`}>{status}</span>
                  </span>
                  <code>{tool.command}</code>
                  <span>{tool.source}</span>
                </span>
              </button>
            );
          })}
        </div>
      </section>

      <section className={`providers-opencode-card ${openCodeEnabled ? "enabled" : ""}`}>
        <div className="providers-opencode-head">
          <button
            type="button"
            className="providers-opencode-summary"
            onClick={() => setOpenCodeExpanded((expanded) => !expanded)}
            aria-expanded={openCodeExpanded}
          >
            <span className="providers-cli-card-icon material-symbols-rounded" aria-hidden>
              inventory_2
            </span>
            <span className="providers-opencode-title">
              <span className="providers-opencode-heading">OpenCode catalog import</span>
              <span className={`provider-state ${openCodeEnabled ? "on" : "off"}`}>
                {openCodeEnabled ? "enabled" : "disabled"}
              </span>
            </span>
            <span className="providers-opencode-subtitle">
              {openCodeEnabled
                ? `${openCodeCommand || "opencode"} · ${openCodeUseCommand ? "resolved config" : "local config files"}`
                : "Import OpenAI-compatible providers from OpenCode"}
            </span>
            <span className={`material-symbols-rounded providers-opencode-chevron ${openCodeExpanded ? "open" : ""}`} aria-hidden>
              expand_more
            </span>
          </button>
          <label className="provider-instance-toggle providers-opencode-toggle">
            <span className="agent-tools-switch">
              <input
                type="checkbox"
                aria-label="OpenCode catalog import enabled"
                checked={openCodeEnabled}
                onChange={(event) => onUpdateOpenCodeConfig?.({ enabled: event.target.checked })}
              />
              <span className="agent-tools-switch-track" />
            </span>
          </label>
        </div>
        {openCodeExpanded ? (
          <div className="providers-opencode-body">
            <p className="placeholder-text">
              Import OpenAI-compatible providers from your OpenCode setup. Models appear as{" "}
              <code>opencode:&lt;provider-id&gt;/&lt;model-id&gt;</code> in agent model pickers after Sloppy reloads config.
            </p>
            <div className="providers-opencode-grid">
              <label className="providers-opencode-field providers-opencode-field--toggle">
                <span>Resolved config command</span>
                <span className="agent-tools-switch">
                  <input
                    type="checkbox"
                    checked={openCodeUseCommand}
                    onChange={(event) => onUpdateOpenCodeConfig?.({ useResolvedConfigCommand: event.target.checked })}
                  />
                  <span className="agent-tools-switch-track" />
                </span>
              </label>
              <label className="providers-opencode-field">
                Command
                <input
                  value={openCodeCommand}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ command: event.target.value })}
                  placeholder="opencode"
                />
              </label>
              <label className="providers-opencode-field">
                Timeout
                <input
                  type="number"
                  min="500"
                  step="500"
                  value={openCodeTimeoutMs}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ timeoutMs: Number.parseInt(event.target.value, 10) || 5000 })}
                />
              </label>
              <label className="providers-opencode-field providers-opencode-wide">
                Auth path
                <input
                  value={openCodeAuthPath}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ authPath: event.target.value })}
                  placeholder="~/.local/share/opencode/auth.json"
                />
              </label>
              <label className="providers-opencode-field providers-opencode-wide">
                Extra config paths
                <textarea
                  rows={2}
                  value={openCodeConfigPaths.join("\n")}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ configPaths: parseConfigList(event.target.value) })}
                  placeholder="One path per line"
                />
              </label>
              <label className="providers-opencode-field">
                Include providers
                <textarea
                  rows={3}
                  value={openCodeIncludeProviders.join("\n")}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ includeProviders: parseConfigList(event.target.value) })}
                  placeholder="Optional provider IDs"
                />
              </label>
              <label className="providers-opencode-field">
                Exclude providers
                <textarea
                  rows={3}
                  value={openCodeExcludeProviders.join("\n")}
                  onChange={(event) => onUpdateOpenCodeConfig?.({ excludeProviders: parseConfigList(event.target.value) })}
                  placeholder="Optional provider IDs"
                />
              </label>
            </div>
            <div className="providers-opencode-note">
              Sloppy tries <code>opencode debug config</code> first, then local OpenCode config files. Imported credentials stay in memory and are not written as provider rows.
            </div>
          </div>
        ) : null}
      </section>

      <div className="providers-section-toolbar">
        <div className="providers-section-toolbar-spacer" />
        <div className="providers-toolbar-actions" ref={addMenuRef}>
          <button
            type="button"
            className="provider-card-action providers-toolbar-btn"
            onClick={() => setAddMenuOpen((o) => !o)}
            aria-expanded={addMenuOpen}
            aria-haspopup="listbox"
          >
            Add provider
            <span className="material-symbols-rounded" style={{ fontSize: "1.1rem", marginLeft: 4 }} aria-hidden>
              expand_more
            </span>
          </button>
          {addMenuOpen ? (
            <div className="providers-dropdown" role="listbox">
              {providerCatalog.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  role="option"
                  className="providers-dropdown-item"
                  onClick={() => {
                    onAppendProvider(p.id);
                    setAddMenuOpen(false);
                  }}
                >
                  <span className="providers-dropdown-item-title">{p.title}</span>
                  <span className="providers-dropdown-item-desc">{p.description}</span>
                </button>
              ))}
            </div>
          ) : null}
        </div>
      </div>

      <details className="providers-presets-details">
        <summary className="providers-presets-summary">
          <span className="material-symbols-rounded providers-presets-icon" aria-hidden>
            apps
          </span>
          Standard provider presets
        </summary>
        <p className="placeholder-text providers-presets-hint">
          Quick reference — use <strong>Add provider</strong> above to create a new row. Click a preset to add that type.
        </p>
        <section className="providers-list providers-presets-grid">
          {providerCatalog.map((provider) => (
            <div key={provider.id} className="provider-card provider-preset-card">
              <span className="provider-list-icon" aria-hidden="true">
                <ProviderBrandMark brandProviderKey={provider.brandProviderKey} size={30} />
              </span>
              <div className="provider-list-main">
                <div className="provider-card-head">
                  <h4>{provider.title}</h4>
                </div>
                <p>{provider.description}</p>
                <span className="provider-model-line">Default: {provider.modelHint}</span>
              </div>
              <button
                type="button"
                className="provider-card-action"
                onClick={() => onAppendProvider(provider.id)}
              >
                Add
              </button>
            </div>
          ))}
        </section>
      </details>

      <section className="providers-configured-block">
        <h4 className="providers-configured-heading">Configured providers</h4>
        <div className="providers-list">
          {configuredProviderRows.length === 0 ? (
            <p className="placeholder-text">No provider rows yet. Use Add provider or a preset.</p>
          ) : (
            configuredProviderRows.map((row) => {
              const { index, entry, catalogId, meta } = row;
              const label = meta?.title || catalogId || "Custom";
              const configuredViaEnvironment =
                catalogId === "openai-api" &&
                openAIProviderStatus.hasEnvironmentKey &&
                !Boolean(String(entry?.apiKey || "").trim()) &&
                Boolean(String(entry?.model || "").trim()) &&
                Boolean(String(entry?.apiUrl || "").trim());
              const configuredViaOAuth =
                catalogId === "openai-oauth" &&
                openAIProviderStatus.hasOAuthCredentials &&
                Boolean(String(entry?.model || "").trim()) &&
                Boolean(String(entry?.apiUrl || "").trim());
              const configuredViaAnthropicOAuth =
                catalogId === "anthropic-oauth" &&
                (anthropicProviderStatus.hasOAuthCredentials || Boolean(String(entry?.apiKey || "").trim())) &&
                Boolean(String(entry?.model || "").trim());
              const configuredViaAnthropicAPI =
                catalogId === "anthropic" &&
                Boolean(String(entry?.apiKey || "").trim()) &&
                Boolean(String(entry?.model || "").trim());
              const configuredViaGeminiOAuth =
                catalogId === "gemini" &&
                geminiProviderStatus.hasOAuthCredentials &&
                Boolean(String(entry?.model || "").trim());
              const configuredViaGeminiAPI =
                catalogId === "gemini" &&
                (geminiProviderStatus.hasEnvironmentKey || Boolean(String(entry?.apiKey || "").trim())) &&
                Boolean(String(entry?.model || "").trim());
              let configured = false;
              if (
                configuredViaEnvironment ||
                configuredViaOAuth ||
                configuredViaAnthropicOAuth ||
                configuredViaAnthropicAPI ||
                configuredViaGeminiOAuth ||
                configuredViaGeminiAPI
              ) {
                configured = true;
              } else if (meta && catalogId !== "openai-oauth" && catalogId !== "gemini") {
                configured = providerIsConfigured(meta, entry);
              }
              const configuredBadgeText =
                configuredViaEnvironment
                  ? "env"
                  : configuredViaOAuth || configuredViaAnthropicOAuth || configuredViaGeminiOAuth
                    ? "oauth"
                    : configured
                      ? "configured"
                      : "not set";

              return (
                <div
                  key={`${index}-${catalogId || "custom"}`}
                  className={`provider-instance-row ${entry.disabled ? "provider-instance-row--disabled" : ""}`}
                >
                  <div className="provider-instance-row-main">
                    <span className="provider-list-icon" aria-hidden="true">
                      {meta?.brandProviderKey ? (
                        <ProviderBrandMark brandProviderKey={meta.brandProviderKey} size={28} />
                      ) : (
                        <span className="material-symbols-rounded" style={{ fontSize: 28 }}>
                          hub
                        </span>
                      )}
                    </span>
                    <div className="provider-list-main">
                      <div className="provider-card-head">
                        <h4>{entry.title || label}</h4>
                        <span className={`provider-state ${configured ? "on" : "off"}`}>{configuredBadgeText}</span>
                        {entry.disabled ? (
                          <span className="provider-disabled-badge">disabled</span>
                        ) : null}
                      </div>
                      <span className="provider-model-line">
                        {label}
                        {catalogId ? ` · ${catalogId}` : ""}
                      </span>
                      <span className="provider-model-line">
                        Model: {entry.model || "—"} · {String(entry.apiUrl || "").slice(0, 56)}
                        {String(entry.apiUrl || "").length > 56 ? "…" : ""}
                      </span>
                    </div>
                  </div>
                  <label className="provider-instance-toggle">
                    <span className="agent-tools-switch">
                      <input
                        type="checkbox"
                        aria-label="Provider enabled"
                        checked={!entry.disabled}
                        onChange={(e) => onSetProviderRowDisabled(index, !e.target.checked)}
                      />
                      <span className="agent-tools-switch-track" />
                    </span>
                  </label>
                  <button
                    type="button"
                    className="provider-card-action"
                    onClick={() => onOpenProviderAtIndex(index)}
                  >
                    Manage
                  </button>
                </div>
              );
            })
          )}
        </div>
      </section>

      {providerModalMeta && providerForm ? (
        <div className="provider-modal-overlay" onClick={onCloseProviderModal}>
          <section className="provider-modal-card" onClick={(event) => event.stopPropagation()}>
            <div className="provider-modal-head">
              <div className="provider-modal-title-row">
                {providerModalMeta.brandProviderKey ? (
                  <span className="provider-modal-brand" aria-hidden="true">
                    <ProviderBrandMark brandProviderKey={providerModalMeta.brandProviderKey} size={28} />
                  </span>
                ) : null}
                <h3>{providerModalMeta.title}</h3>
              </div>
              <button type="button" className="provider-close-button" onClick={onCloseProviderModal}>
                x
              </button>
            </div>
            <p className="placeholder-text">{providerModalMeta.description}</p>

            <div className="provider-modal-form">
              <label>
                Label
                <input
                  value={providerForm.title ?? ""}
                  onChange={(event) => onUpdateProviderForm("title", event.target.value)}
                  placeholder="Display name in list"
                />
              </label>
              <label className="provider-modal-disabled-row">
                <span className="agent-tools-switch">
                  <input
                    type="checkbox"
                    checked={!providerForm.disabled}
                    onChange={(e) => onUpdateProviderForm("disabled", !e.target.checked)}
                  />
                  <span className="agent-tools-switch-track" />
                </span>
                <span>Enabled (runtime)</span>
              </label>
              {isAnthropicModal ? (
                <div className="provider-auth-mode-field">
                  <span>Auth</span>
                  <div className="provider-auth-mode-segmented" role="tablist" aria-label="Anthropic auth mode">
                    <button
                      type="button"
                      role="tab"
                      aria-selected={anthropicAuthMode === "oauth"}
                      className={anthropicAuthMode === "oauth" ? "active" : ""}
                      onClick={() => onSelectAnthropicAuthMode?.("oauth")}
                    >
                      OAuth
                    </button>
                    <button
                      type="button"
                      role="tab"
                      aria-selected={anthropicAuthMode === "api-token"}
                      className={anthropicAuthMode === "api-token" ? "active" : ""}
                      onClick={() => onSelectAnthropicAuthMode?.("api-token")}
                    >
                      API token
                    </button>
                  </div>
                </div>
              ) : null}
              {providerModalMeta.id === "sloppy" ? (
                <div>
                  <span>Connection</span>
                  <div className="provider-auth-mode-segmented" role="group" aria-label="Sloppy connection">
                    <button type="button" aria-pressed={!isSloppyRelay} onClick={() => {
                      onUpdateProviderForm("apiUrl", "http://127.0.0.1:25101");
                    }}>Direct / localhost</button>
                    <button type="button" aria-pressed={isSloppyRelay} onClick={() => {
                      onUpdateProviderForm("apiUrl", "sloppy-console://");
                    }}>Relay</button>
                  </div>
                </div>
              ) : null}
              {(providerModalMeta.requiresApiKey && !isSloppyRelay) || isGeminiModal ? (
                <label>
                  {isGeminiModal
                    ? "API Key (optional)"
                    : isAnthropicModal
                    ? anthropicAuthMode === "oauth"
                      ? "OAuth token"
                      : "API token"
                    : providerModalMeta.id === "sloppy" ? "Sloppy access token" : "API Key"}
                  <input
                    type="password"
                    value={providerForm.apiKey}
                    onChange={(event) => onUpdateProviderForm("apiKey", event.target.value)}
                    placeholder={
                      isGeminiModal
                        ? "Leave empty for Sloppy OAuth or GEMINI_API_KEY"
                        : providerModalMeta.id === "anthropic-oauth"
                        ? "Paste token or leave empty for ANTHROPIC_AUTH_TOKEN"
                        : providerModalMeta.id === "anthropic"
                          ? "Console API key (sk-ant-api...)"
                          : providerModalMeta.id === "sloppy" ? "Access token from the Sloppy server" : "sk-..."
                    }
                  />
                  {providerModalMeta.id === "openai-api" && openAIProviderStatus.hasEnvironmentKey ? (
                    <span className="placeholder-text">Using OPENAI_API_KEY from Sloppy environment.</span>
                  ) : null}
                  {providerModalMeta.id === "anthropic-oauth" ? (
                    <span className="placeholder-text">
                      Sloppy also checks ANTHROPIC_AUTH_TOKEN in the environment and .claude/settings.json.
                    </span>
                  ) : null}
                  {isGeminiModal ? (
                    <span className="placeholder-text">
                      Sloppy checks this key first, then GEMINI_API_KEY or GOOGLE_API_KEY, then Sloppy-owned Google OAuth.
                    </span>
                  ) : null}
                </label>
              ) : null}

              {providerModalMeta.id === "claude-code" ? (
                <p className="placeholder-text">
                  Install Claude Code and run <code>claude auth login</code> on the machine running Sloppy.
                  Requests use that CLI account and its subscription or enabled usage credits.
                </p>
              ) : null}
              {isSloppyRelay ? (
                <div className={`actor-team-search-wrap${isConsoleRelay ? " provider-console-relay-picker" : ""}`}>
                  <label>{isConsoleRelay ? "Console instance" : "Manual Mesh computer"}</label>
                  <input className="actor-team-search" aria-label={isConsoleRelay ? "Console instance" : "Manual Mesh computer"} aria-haspopup="listbox" aria-expanded={relayPickerOpen}
                    value={relayPickerOpen ? relaySearch : relayChoices.find((node) => node.id.toLowerCase() === relayNodeID.toLowerCase())?.name || relayNodeID}
                    placeholder={isConsoleRelay ? "Choose a Console instance" : "Choose a Mesh computer"} autoComplete="off"
                    onFocus={() => { setRelaySearch(""); setRelayPickerOpen(true); }}
                    onChange={(event) => { setRelaySearch(event.target.value); setRelayPickerOpen(true); }}
                    onBlur={() => setTimeout(() => setRelayPickerOpen(false), 150)} />
                  {relayPickerOpen ? <ul className="actor-team-dropdown" role="listbox" aria-label="Relay computers">
                    {relayChoices.filter((node) => `${node.name || ""} ${node.id}`.toLowerCase().includes(relaySearch.toLowerCase())).map((node) => <li key={node.id}><button type="button" role="option" aria-selected={node.id.toLowerCase() === relayNodeID.toLowerCase()} onClick={() => {
                      onUpdateProviderForm("apiUrl", `${isConsoleRelay ? "sloppy-console" : "sloppy-relay"}://${node.id}`);
                      setRelayPickerOpen(false);
                    }}>{node.name || node.id} · {isConsoleRelay && !node.canInfer ? "approval needed" : node.status || "unknown"}</button></li>)}
                    {relayChoices.length === 0 ? <li>{isConsoleRelay ? modelConsoleStatus || "No Console instances available." : "Join both computers in Nodes → Join Remote Mesh."}</li> : null}
                  </ul> : null}
                  <span className="placeholder-text">{isConsoleRelay ? "Claude stays on the selected instance. Connection, device access, and encryption are managed by Sloppy Console." : "This connection uses the manually configured Nodes / Mesh relay."}</span>
                  {isConsoleRelay && selectedRelayChoice?.message ? <span className="placeholder-text" role="status">{selectedRelayChoice.message}</span> : null}
                  {isConsoleRelay ? <button type="button" className="provider-test-button" onClick={() => void onReloadConsoleInstances?.()}>Reload instances</button> : null}
                  {isConsoleRelay && modelConsoleStatus ? <span className="placeholder-text" role="status">{modelConsoleStatus}</span> : null}
                </div>
              ) : providerModalMeta.id !== "claude-code" ? <label>
                {providerModalMeta.id === "sloppy" ? "Sloppy server URL" : "API URL"}
                <input
                  value={providerForm.apiUrl}
                  onChange={(event) => onUpdateProviderForm("apiUrl", event.target.value)}
                  placeholder={isAnthropicModal ? "Leave empty to read ANTHROPIC_BASE_URL" : undefined}
                />
              </label> : null}

              <AggregatedModelPicker
                label="Model"
                value={String(providerForm.model || "")}
                onChange={(id) => onUpdateProviderForm("model", id)}
                aggregatedModels={activeProviderModels}
                includeEmptyOption={false}
                groupTitle={providerModalMeta.title}
              />
            </div>

            {providerModalMeta.supportsModelCatalog || providerModalMeta.id === "anthropic-oauth" ? (
              <div className="provider-modal-catalog">
                {canTestActiveProvider ? (
                  <div className="provider-modal-probe-row">
                    <button
                      type="button"
                      className="hover-levitate"
                      disabled={isTestingActiveProvider}
                      onClick={() => onTestProviderConnection(providerModalMeta.id)}
                    >
                      {isTestingActiveProvider ? "Testing..." : "Test connection"}
                    </button>
                    <span
                      className={`provider-modal-probe-status ${activeProviderModels.length > 0 ? "ok" : ""}`}
                    >
                      {activeProviderStatus || "Press Test connection to probe the provider."}
                    </span>
                  </div>
                ) : (
                  <p className="placeholder-text">{activeProviderStatus || "Model catalog is loading automatically."}</p>
                )}
                {providerModalMeta.id === "openai-oauth" && deviceCode ? (
                  <div className="provider-device-code-card">
                    <div className="provider-device-code-step">
                      <span className="provider-device-code-step-number">1</span>
                      <span>Copy this device code</span>
                    </div>
                    <div className="provider-device-code-row">
                      <code className="provider-device-code-value">{deviceCode.userCode}</code>
                      <button type="button" onClick={onCopyDeviceCode}>
                        {deviceCodeCopied ? "Copied" : "Copy"}
                      </button>
                    </div>

                    <div className="provider-device-code-qr">
                      <QRCodeSVG
                        value={deviceCode.verificationURL}
                        size={132}
                        bgColor="#ffffff"
                        fgColor="#000000"
                        level="M"
                      />
                    </div>

                    <div className="provider-device-code-step">
                      <span className="provider-device-code-step-number">2</span>
                      <span>Open Codex sign-in in this browser or scan the QR code</span>
                    </div>
                    <button type="button" onClick={onOpenDeviceCodeLoginPage}>
                      Open login page
                    </button>

                    {isDeviceCodePolling ? (
                      <div className="provider-device-code-waiting">
                        <span className="onboarding-device-code-dot" />
                        <span>Waiting for sign-in confirmation...</span>
                      </div>
                    ) : null}

                    <div className="provider-modal-actions">
                      <button type="button" onClick={onCancelDeviceCode}>Cancel</button>
                      <button type="button" onClick={onOpenOAuth}>Get new code</button>
                    </div>
                  </div>
                ) : providerModalMeta.id === "openai-oauth" ? (
                  <div className="provider-modal-actions">
                    <button type="button" onClick={onOpenOAuth}>
                      {openAIProviderStatus.hasOAuthCredentials ? "Reconnect Codex" : "Sign in to Codex"}
                    </button>
                  </div>
                ) : null}
                {providerModalMeta.id === "openai-oauth" && !openAIProviderStatus.hasOAuthCredentials ? (
                  <p className="placeholder-text">
                    You must first <a href="https://chatgpt.com/security-settings" target="_blank" rel="noopener noreferrer">enable device code login</a> in your ChatGPT security settings.
                  </p>
                ) : null}
                {providerModalMeta.id === "openai-oauth" && openAIProviderStatus.hasOAuthCredentials ? (
                  <p className="placeholder-text">
                    Connected
                    {openAIProviderStatus.oauthPlanType ? ` as ${openAIProviderStatus.oauthPlanType}` : ""}
                    {openAIProviderStatus.oauthAccountId ? ` (${openAIProviderStatus.oauthAccountId})` : ""}.
                  </p>
                ) : null}
                {providerModalMeta.id === "anthropic-oauth" ? (
                  <>
                    <div className="provider-modal-actions">
                      <button type="button" onClick={onOpenAnthropicOAuth}>
                        {anthropicProviderStatus.hasOAuthCredentials ? "Reconnect Anthropic" : "Connect Anthropic"}
                      </button>
                      <button type="button" onClick={onImportAnthropicClaudeCredentials}>
                        Import Claude Code credentials
                      </button>
                      {anthropicProviderStatus.hasOAuthCredentials ? (
                        <button type="button" onClick={onDisconnectAnthropicOAuth}>
                          Disconnect
                        </button>
                      ) : null}
                    </div>
                    {anthropicOAuthAuthorizationURL ? (
                      <div className="provider-device-code-card">
                        <div className="provider-device-code-step">
                          <span className="provider-device-code-step-number">1</span>
                          <span>Open Anthropic in this browser or scan the QR code</span>
                        </div>
                        <div className="provider-device-code-qr">
                          <QRCodeSVG
                            value={anthropicOAuthAuthorizationURL}
                            size={132}
                            bgColor="#ffffff"
                            fgColor="#000000"
                            level="M"
                          />
                        </div>
                        <a
                          className="provider-device-code-link"
                          href={anthropicOAuthAuthorizationURL}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          Open login page
                        </a>
                      </div>
                    ) : null}
                    <p className="placeholder-text">
                      {anthropicProviderStatus.hasOAuthCredentials
                        ? `Connected via ${anthropicProviderStatus.oauthSource || "anthropic_oauth"}${anthropicProviderStatus.oauthRefreshable ? " (refreshable)" : ""}${anthropicProviderStatus.oauthExpiresAt ? `, expires ${anthropicProviderStatus.oauthExpiresAt}` : ""}.`
                        : "Connect Anthropic OAuth or import Claude Code credentials. You can still paste a setup token manually if needed."}
                    </p>
                  </>
                ) : null}
                {isGeminiModal ? (
                  <div className="provider-cli-auth-panel">
                    <div className="provider-cli-auth-panel-head">
                      <span className="material-symbols-rounded" aria-hidden>
                        account_circle
                      </span>
                      <strong>Google OAuth</strong>
                    </div>
                    <p className="placeholder-text">
                      Sign in with Google here and Sloppy will save refreshable Gemini credentials in{" "}
                      <code>.sloppy/auth/gemini-oauth-auth.json</code>. OAuth tokens must include the Cloud Platform scope.
                    </p>
                    <div className="provider-modal-actions">
                      <button type="button" onClick={onOpenGeminiOAuth}>
                        {geminiProviderStatus.hasOAuthCredentials ? "Reconnect Gemini" : "Connect Gemini"}
                      </button>
                      {geminiProviderStatus.hasOAuthCredentials ? (
                        <button type="button" onClick={onDisconnectGeminiOAuth}>
                          Disconnect
                        </button>
                      ) : null}
                    </div>
                    {geminiOAuthAuthorizationURL ? (
                      <div className="provider-device-code-card">
                        <div className="provider-device-code-step">
                          <span className="provider-device-code-step-number">1</span>
                          <span>Open Google in this browser or scan the QR code</span>
                        </div>
                        <div className="provider-device-code-qr">
                          <QRCodeSVG
                            value={geminiOAuthAuthorizationURL}
                            size={132}
                            bgColor="#ffffff"
                            fgColor="#000000"
                            level="M"
                          />
                        </div>
                        <a
                          className="provider-device-code-link"
                          href={geminiOAuthAuthorizationURL}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          Open login page
                        </a>
                        <div className="provider-device-code-step">
                          <span className="provider-device-code-step-number">2</span>
                          <span>Paste the callback URL or authorization code if the popup cannot return automatically</span>
                        </div>
                        <label>
                          Callback URL
                          <textarea
                            rows={2}
                            value={geminiOAuthManualCallback}
                            onChange={(event) => onSetGeminiOAuthManualCallback?.(event.target.value)}
                            placeholder="http://localhost:25102/oauth2callback?code=...&state=..."
                          />
                        </label>
                        <label>
                          Authorization code
                          <input
                            value={geminiOAuthManualCode}
                            onChange={(event) => onSetGeminiOAuthManualCode?.(event.target.value)}
                            placeholder="Paste code instead of callback URL"
                          />
                        </label>
                        <button type="button" onClick={onCompleteGeminiOAuthManually}>
                          Complete sign-in
                        </button>
                      </div>
                    ) : null}
                    <p className="placeholder-text">
                      {geminiProviderStatus.hasOAuthCredentials
                        ? `Connected${geminiProviderStatus.oauthEmail ? ` as ${geminiProviderStatus.oauthEmail}` : ""}${geminiProviderStatus.oauthExpiresAt ? `, expires ${geminiProviderStatus.oauthExpiresAt}` : ""}.`
                        : "Connect Google OAuth or use a Gemini API key."}
                    </p>
                  </div>
                ) : null}
              </div>
            ) : null}
            <div className="provider-modal-footer">
              {modalActiveEntry ? (
                <button type="button" className="danger" onClick={onRemoveProvider}>
                  Remove Provider
                </button>
              ) : (
                <span />
              )}
              <div className="provider-modal-footer-actions">
                <button type="button" onClick={onCloseProviderModal}>
                  Close
                </button>
                <button type="button" onClick={onSaveProvider}>
                  Done
                </button>
              </div>
            </div>
          </section>
        </div>
      ) : null}
    </div>
  );
}
