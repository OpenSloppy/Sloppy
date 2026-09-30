import React from "react";
import { AgentPetSprite } from "./AgentPetSprite";

export const SYSTEM_ROLES = [
  { value: "manager", label: "Manager" },
  { value: "developer", label: "Developer" },
  { value: "qa", label: "QA" },
  { value: "reviewer", label: "Reviewer" }
];

const SYSTEM_ROLE_VALUES = new Set(SYSTEM_ROLES.map((r) => r.value));

export function resolveSystemRole(role: string): string {
  const normalized = role.trim().toLowerCase();
  return SYSTEM_ROLE_VALUES.has(normalized) ? normalized : (role.trim() ? "custom" : "");
}

export interface AgentFormValues {
  id: string;
  displayName: string;
  role: string;
  systemRole: string;
  generateEnabled: boolean;
  generateDescription: string;
  generateModel: string;
}

export function emptyAgentFormValues(): AgentFormValues {
  return {
    id: "",
    displayName: "",
    role: "",
    systemRole: "",
    generateEnabled: false,
    generateDescription: "",
    generateModel: ""
  };
}

interface AgentCreateFormProps {
  form: AgentFormValues;
  error: string;
  onFormChange: (field: keyof AgentFormValues, value: string | boolean) => void;
  onSubmit: (event: React.FormEvent) => void;
  onCancel: () => void;
  submitLabel?: string;
  cancelLabel?: string;
  availableModels?: { id: string; title: string }[];
  providerConfigured?: boolean;
  isGenerating?: boolean;

}

export function AgentCreateForm({
  form,
  error,
  onFormChange,
  onSubmit,
  onCancel,
  submitLabel = "Create",
  cancelLabel = "Cancel",
  availableModels = [],
  providerConfigured = false,
  isGenerating = false
}: AgentCreateFormProps) {
  const [roleDropdownOpen, setRoleDropdownOpen] = React.useState(false);
  const [modelDropdownOpen, setModelDropdownOpen] = React.useState(false);

  const filteredRoles = SYSTEM_ROLES.filter((r) =>
    r.label.toLowerCase().includes(form.role.toLowerCase())
  );

  const selectedModelLabel = availableModels.find((m) => m.id === form.generateModel)?.title || form.generateModel || "Select a model…";

  return (
    <form className="agent-form" onSubmit={onSubmit}>
      <label>
        Agent ID
        <input
          value={form.id}
          onChange={(event) => onFormChange("id", event.target.value)}
          placeholder="e.g. research_support_dev"
          autoFocus
        />
        <span className="agent-field-note">Lowercase letters, numbers, hyphens, and underscores only.</span>
      </label>
      <label>
        Display Name <span className="agent-field-optional">optional</span>
        <input
          value={form.displayName}
          onChange={(event) => onFormChange("displayName", event.target.value)}
          placeholder="e.g. Research Agent"
        />
      </label>
      <label>
        Role <span className="agent-field-optional">optional</span>
        <div className="actor-team-search-wrap">
          <input
            className="actor-team-search"
            value={form.role}
            onChange={(event) => {
              onFormChange("role", event.target.value);
              onFormChange("systemRole", resolveSystemRole(event.target.value));
              setRoleDropdownOpen(true);
            }}
            onFocus={() => setRoleDropdownOpen(true)}
            onBlur={() => setTimeout(() => setRoleDropdownOpen(false), 150)}
            placeholder="Select or type a role…"
            autoComplete="off"
          />
          {roleDropdownOpen && (
            <ul className="actor-team-dropdown">
              {filteredRoles.map((r) => {
                const isSelected = resolveSystemRole(form.role) === r.value;
                return (
                  <li
                    key={r.value}
                    className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                    onMouseDown={(event) => {
                      event.preventDefault();
                      onFormChange("role", r.label);
                      onFormChange("systemRole", r.value);
                      setRoleDropdownOpen(false);
                    }}
                  >
                    <span className="actor-team-dropdown-name">{r.label}</span>
                    {isSelected && <span className="actor-team-dropdown-check material-symbols-rounded">check</span>}
                  </li>
                );
              })}
              {filteredRoles.length === 0 && (
                <li className="actor-team-dropdown-empty">Custom role</li>
              )}
            </ul>
          )}
        </div>
      </label>

      <div className="agent-generate-section">
        <label className="agent-generate-toggle cron-form-toggle">
          <div className="agent-generate-toggle-copy">
            <span className="agent-generate-toggle-label">Generate Agent</span>
            <span className="agent-generate-toggle-hint">
              Uses an LLM to generate AGENTS.md, IDENTITY.md, SOUL.md, USER.md files for this agent.
            </span>
          </div>
          <span className="agent-tools-switch">
            <input
              type="checkbox"
              checked={form.generateEnabled}
              disabled={!providerConfigured}
              onChange={(event) => onFormChange("generateEnabled", event.target.checked)}
            />
            <span className="agent-tools-switch-track" />
          </span>
        </label>
        {!providerConfigured && (
          <p className="agent-field-note agent-generate-no-provider">Configure a provider to enable agent generation.</p>
        )}
        {form.generateEnabled && providerConfigured && (
          <div className="agent-generate-fields">
            <label>
              Model
              <div className="actor-team-search-wrap">
                <input
                  className="actor-team-search"
                  value={selectedModelLabel}
                  readOnly
                  onClick={() => setModelDropdownOpen((prev) => !prev)}
                  onBlur={() => setTimeout(() => setModelDropdownOpen(false), 150)}
                  placeholder="Select a model…"
                  autoComplete="off"
                />
                {modelDropdownOpen && availableModels.length > 0 && (
                  <ul className="actor-team-dropdown">
                    {availableModels.map((m) => {
                      const isSelected = form.generateModel === m.id;
                      return (
                        <li
                          key={m.id}
                          className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                          onMouseDown={(event) => {
                            event.preventDefault();
                            onFormChange("generateModel", m.id);
                            setModelDropdownOpen(false);
                          }}
                        >
                          <span className="actor-team-dropdown-name">{m.title}</span>
                          {isSelected && <span className="actor-team-dropdown-check material-symbols-rounded">check</span>}
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>
            </label>
            <label>
              Agent responsibility <span className="agent-field-note">(required for generation)</span>
              <textarea
                value={form.generateDescription}
                onChange={(event) => onFormChange("generateDescription", event.target.value)}
                placeholder="Describe what this agent is responsible for, its main goals, and how it should behave…"
                rows={4}
              />
            </label>
          </div>
        )}
      </div>

      <div className="agent-bot-preview">
        <AgentPetSprite agentId={form.id.trim().replace(/\s+/g, "-") || "sloppy"} animated={false} />
        <span>Your agent’s companion. A color is picked when you create the agent.</span>
      </div>

      {error ? <p className="agent-create-error">{error}</p> : null}
      <div className="agent-modal-actions">
        <button type="button" onClick={onCancel} disabled={isGenerating}>
          {cancelLabel}
        </button>
        <button type="submit" className="agent-create-confirm hover-levitate" disabled={isGenerating}>
          {isGenerating ? "Generating…" : submitLabel}
        </button>
      </div>
    </form>
  );
}
