import React, { useState } from "react";
import { AggregatedModelPicker } from "./AggregatedModelPicker";
import { changeSemanticProvider, semanticProviderDefaults, SEMANTIC_PROVIDERS } from "../semanticDecisions";

const ROUTING_MODES = [
  { value: "disabled", label: "Disabled", description: "Keep the current Sloppy model-selection flow." },
  { value: "shadow", label: "Shadow", description: "Evaluate and meter decisions, but do not apply the choice." },
  { value: "active", label: "Active", description: "Apply confident choices for automatic turns." }
];

function ChoicePicker({ label, value, options, onChange }) {
  const [open, setOpen] = useState(false);
  const active = options.find((option) => option.value === value) || options[0];
  return (
    <label>
      {label}
      <div className="actor-team-search-wrap">
        <input
          className="actor-team-search"
          value={active.label}
          readOnly
          onFocus={() => setOpen(true)}
          onClick={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
        />
        {open ? (
          <ul className="actor-team-dropdown">
            {options.map((option) => (
              <li
                key={option.value}
                className={`actor-team-dropdown-item ${option.value === value ? "selected" : ""}`}
                onMouseDown={(event) => {
                  event.preventDefault();
                  onChange(option.value);
                  setOpen(false);
                }}
              >
                <span className="actor-team-dropdown-name">{option.label}</span>
                <span className="actor-team-dropdown-id">{option.description}</span>
                {option.value === value ? <span className="actor-team-dropdown-check">✓</span> : null}
              </li>
            ))}
          </ul>
        ) : null}
      </div>
    </label>
  );
}

function ProfileEditor({ profileId, profile, models, mutateDraft }) {
  const [draftId, setDraftId] = useState(profileId);

  function commitProfileId() {
    const nextId = draftId.trim();
    if (!nextId || nextId === profileId) {
      setDraftId(profileId);
      return;
    }
    mutateDraft((draft) => {
      if (draft.semanticDecisions.modelProfiles[nextId]) return;
      draft.semanticDecisions.modelProfiles[nextId] = draft.semanticDecisions.modelProfiles[profileId];
      delete draft.semanticDecisions.modelProfiles[profileId];
    });
  }

  return (
    <section className="entry-editor-card" style={{ marginTop: 12 }}>
      <div className="entry-list-head">
        <h4>Execution profile</h4>
        <button
          type="button"
          className="config-integration-add-button"
          onClick={() => mutateDraft((draft) => {
            delete draft.semanticDecisions.modelProfiles[profileId];
          })}
        >
          <span className="material-symbols-rounded" aria-hidden>delete</span>
          <span>Remove</span>
        </button>
      </div>
      <div className="entry-form-grid">
        <label>
          Profile ID
          <input value={draftId} onChange={(event) => setDraftId(event.target.value)} onBlur={commitProfileId} />
          <span className="entry-form-hint">Stable choice returned by the provider, for example fast, balanced, or senior.</span>
        </label>
        <AggregatedModelPicker
          label="Executor model"
          value={profile.model || ""}
          onChange={(model) => mutateDraft((draft) => {
            draft.semanticDecisions.modelProfiles[profileId].model = String(model || "");
          })}
          aggregatedModels={models}
        />
        <label style={{ gridColumn: "1 / -1" }}>
          Description for the decision provider
          <textarea
            rows={3}
            value={profile.description || ""}
            onChange={(event) => mutateDraft((draft) => {
              draft.semanticDecisions.modelProfiles[profileId].description = event.target.value;
            })}
          />
        </label>
      </div>
    </section>
  );
}

export function SemanticDecisionsEditor({
  draftConfig,
  mutateDraft,
  modelCatalog,
  modelCatalogStatus
}) {
  const config = draftConfig.semanticDecisions;
  const provider = config.provider || "typesafe";
  const defaults = semanticProviderDefaults(provider);
  const isLaya = provider === "laya";
  const profiles = Object.entries(config.modelProfiles || {});

  return (
    <div>
      <section className="entry-editor-card">
        <h3>Semantic decisions</h3>
        <p className="placeholder-text">
          Choose Jev or Laya for automatic executor selection. Sloppy uses the configured executor model whenever the provider is unavailable, confidence is low, or routing is disabled.
        </p>
        <div className="entry-form-grid">
          <ChoicePicker
            label="Provider"
            value={provider}
            options={SEMANTIC_PROVIDERS}
            onChange={(value) => mutateDraft((draft) => {
              draft.semanticDecisions = changeSemanticProvider(draft.semanticDecisions, value);
            })}
          />
          <ChoicePicker
            label="Executor routing"
            value={config.executorModelRouting || "disabled"}
            options={ROUTING_MODES}
            onChange={(value) => mutateDraft((draft) => {
              draft.semanticDecisions.executorModelRouting = value;
            })}
          />
          <label>
            Minimum confidence
            <input
              type="number"
              min="0"
              max="1"
              step="0.01"
              value={String(config.minimumConfidence ?? 0.75)}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.minimumConfidence = Math.min(1, Math.max(0, Number(event.target.value) || 0));
              })}
            />
            {isLaya ? <span className="entry-form-hint">Uses answer_confidence or the selected answer probability. Validate the threshold on your routing tasks.</span> : null}
          </label>
          <label>
            Request timeout (ms)
            <input
              type="number"
              min="100"
              value={String(config.timeoutMs ?? 2000)}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.timeoutMs = Math.max(100, Number.parseInt(event.target.value, 10) || 2000);
              })}
            />
          </label>
          {!isLaya ? <label>
            Input price per 1M tokens (USD)
            <input
              type="number"
              min="0"
              step="0.001"
              value={String(config.inputCostPerMillionTokensUSD ?? 0.042)}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.inputCostPerMillionTokensUSD = Math.max(0, Number(event.target.value) || 0);
              })}
            />
            <span className="entry-form-hint">Used only when the provider response does not report exact cost.</span>
          </label> : null}
          <label>
            API key environment variable
            <input
              value={config.apiKeyEnvironmentVariable || ""}
              placeholder={defaults.environmentVariable}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.apiKeyEnvironmentVariable = event.target.value;
              })}
            />
          </label>
          <label>
            Custom endpoint (optional)
            <input
              value={config.baseURL || ""}
              placeholder={defaults.endpoint}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.baseURL = event.target.value;
              })}
            />
          </label>
          <label>
            Decision model override (optional)
            <input
              value={config.model || ""}
              placeholder={defaults.model}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.model = event.target.value;
              })}
            />
          </label>
          {isLaya ? <label>
            Input token limit (optional)
            <input
              type="number"
              min="1"
              max="8192"
              value={config.maxInputTokens ?? ""}
              placeholder="Server default"
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.maxInputTokens = event.target.value === ""
                  ? null
                  : Math.min(8192, Math.max(1, Number.parseInt(event.target.value, 10) || 1024));
              })}
            />
            <span className="entry-form-hint">Multilingual supports up to 8192 tokens. Match this limit to the checkpoint and server; long inputs increase latency.</span>
          </label> : null}
        </div>
      </section>

      <section className="entry-editor-card" style={{ marginTop: 12 }}>
        <h3>API credential</h3>
        <p className="placeholder-text">
          The configured key is stored in the local <code>sloppy.json</code>. Leave it empty to use the environment-variable fallback instead.
          {isLaya ? " Laya also works without a key when the server does not require authentication. API calls are recorded at $0; hosting costs are not included." : ""}
        </p>
        <div className="entry-form-grid">
          <label>
            API key
            <input
              type="password"
              autoComplete="new-password"
              value={config.apiKey || ""}
              placeholder={isLaya ? "Optional Laya API key" : "Paste Jev API key"}
              onChange={(event) => mutateDraft((draft) => {
                draft.semanticDecisions.apiKey = event.target.value;
              })}
            />
            <span className="entry-form-hint">Config value has priority over the environment variable.</span>
          </label>
        </div>
      </section>

      <section className="entry-editor-card" style={{ marginTop: 12 }}>
        <div className="entry-list-head">
          <div>
            <h3>Executor profiles</h3>
            <p className="placeholder-text">The provider sees only profiles whose models are currently available to the agent. At least two are required.</p>
          </div>
          <button
            type="button"
            className="config-integration-add-button"
            onClick={() => mutateDraft((draft) => {
              const existing = draft.semanticDecisions.modelProfiles || {};
              let index = Object.keys(existing).length + 1;
              let id = `profile-${index}`;
              while (existing[id]) {
                index += 1;
                id = `profile-${index}`;
              }
              existing[id] = { model: "", description: "" };
              draft.semanticDecisions.modelProfiles = existing;
            })}
          >
            <span className="material-symbols-rounded" aria-hidden>add</span>
            <span>Add profile</span>
          </button>
        </div>
        {modelCatalogStatus ? <p className="placeholder-text">{modelCatalogStatus}</p> : null}
        {profiles.length === 0 ? <p className="entry-editor-empty">No executor profiles configured.</p> : null}
      </section>
      {profiles.map(([profileId, profile]) => (
        <ProfileEditor
          key={profileId}
          profileId={profileId}
          profile={profile}
          models={modelCatalog}
          mutateDraft={mutateDraft}
        />
      ))}
    </div>
  );
}
