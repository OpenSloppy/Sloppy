import React, { useEffect, useMemo, useState } from "react";
import { LoadingSkeleton } from "../../components/LoadingSkeleton";
import {
  createAgent as createAgentRequest,
  deleteAgent as deleteAgentRequest,
  fetchAgent,
  fetchAgents,
  fetchAvailableModels,
  fetchRuntimeConfig,
  generateText,
  updateAgentConfig,
  fetchAgentConfig,
} from "../../api";
import { collectAggregatedProviderModels, mergeModelOptions } from "./utils/aggregateProviderModels";
import { AgentOverviewTab } from "./components/AgentOverviewTab";
import { AgentTasksTab } from "./components/AgentTasksTab";
import { AgentChatTab } from "./components/AgentChatTab";
import { AgentChannelsTab } from "./components/AgentChannelsTab";
import { AgentConfigTab } from "./components/AgentConfigTab";
import { AgentToolsTab } from "./components/AgentToolsTab";
import { AgentSkillsTab } from "./components/AgentSkillsTab";
import { AgentCronTab } from "./components/AgentCronTab";
import { Breadcrumbs } from "../../components/Breadcrumbs/Breadcrumbs";
import { AgentCreateForm, emptyAgentFormValues } from "./components/AgentCreateForm";
import { AgentGeneratePreview, type GeneratedAgentFiles } from "./components/AgentGeneratePreview";
import { AgentPetIcon } from "./components/AgentPetSprite";
import { AgentWorkersTab } from "./components/AgentWorkersTab";
import { ProactivityInbox } from "./components/ProactivityInbox";
import { useAgentChatBackground } from "./model/useAgentChatBackground";

const AGENT_TABS = [
  { id: "overview", title: "Overview" },
  { id: "attention", title: "Attention" },
  { id: "chat", title: "Chat" },
  { id: "workers", title: "Workers" },
  { id: "tasks", title: "Tasks" },
  { id: "skills", title: "Skills" },
  { id: "tools", title: "Tools" },
  { id: "channels", title: "Channels" },
  { id: "cron", title: "Automations" },
  { id: "config", title: "Config" }
];

const AGENT_TAB_SET = new Set(AGENT_TABS.map((tab) => tab.id));


const EMPTY_GENERATED_FILES: GeneratedAgentFiles = {
  agentsMarkdown: "",
  identityMarkdown: "",
  soulMarkdown: "",
  userMarkdown: ""
};
const USER_MARKDOWN_MAX_CHARS = 2000;

function normalizeAgent(item, index = 0) {
  const id = String(item?.id || `agent-${index + 1}`).trim();
  return {
    ...item,
    id,
    displayName: String(item?.displayName || id).trim() || id,
    role: String(item?.role || "").trim(),
    createdAt: item?.createdAt || new Date().toISOString()
  };
}

function mergeAgent(previousAgents, incomingAgent) {
  const normalized = normalizeAgent(incomingAgent);
  const withoutOld = previousAgents.filter((item) => item.id !== normalized.id);
  return [...withoutOld, normalized].sort((left, right) =>
    left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" })
  );
}

function tabTitle(tabId) {
  return AGENT_TABS.find((tab) => tab.id === tabId)?.title || "Overview";
}

function buildGeneratePrompt(form: { id: string; displayName: string; role: string; generateDescription: string }) {
  return `Generate 4 markdown configuration files for a Sloppy AI agent.

Agent ID: ${form.id || "agent"}
Display Name: ${form.displayName || form.id || "Agent"}
Role: ${form.role || "General-purpose assistant"}
Agent responsibility: ${form.generateDescription}

Hard requirements:
- Output exactly 4 files using the markers below.
- Include only file content between markers (no extra text before/after markers).
- Keep files concise and practical. Avoid long essays and repetition.
- USER.md MUST be at most 2000 characters.
- Preferred targets for readability:
  - AGENTS.md: 800-1800 chars
  - IDENTITY.md: 400-900 chars
  - SOUL.md: 400-900 chars
  - USER.md: 600-1600 chars (hard max 2000)

--- AGENTS.md ---
(Write main behavior instructions, responsibilities, operating rules, and capabilities for this agent)
--- IDENTITY.md ---
(Write personality, communication style, tone, and character traits)
--- SOUL.md ---
(Write core values, principles, and decision-making framework)
--- USER.md ---
(Write how to interact with users, preferred response format, and user interaction guidelines)`;
}

function parseGeneratedFiles(text: string): GeneratedAgentFiles {
  const markers = {
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

function validateGeneratedFiles(files: GeneratedAgentFiles): string | null {
  if (!files.agentsMarkdown.trim()) return "Generation is missing AGENTS.md content.";
  if (!files.identityMarkdown.trim()) return "Generation is missing IDENTITY.md content.";
  if (!files.soulMarkdown.trim()) return "Generation is missing SOUL.md content.";
  if (!files.userMarkdown.trim()) return "Generation is missing USER.md content.";
  if (files.userMarkdown.length > USER_MARKDOWN_MAX_CHARS) {
    return `Generated USER.md is too long (${files.userMarkdown.length}/${USER_MARKDOWN_MAX_CHARS}). Try a shorter responsibility description or regenerate.`;
  }
  return null;
}

function AgentCreateModal({
  isOpen,
  form,
  createError,
  onFormChange,
  onClose,
  onSubmit,
  availableModels,
  providerConfigured,
  isGenerating,
}) {
  if (!isOpen) {
    return null;
  }

  return (
    <div className="agent-modal-overlay" onClick={onClose}>
      <section className="agent-modal-card" onClick={(event) => event.stopPropagation()}>
        <div className="agent-modal-head">
          <h3>Create Agent</h3>
          <button type="button" className="provider-close-button" onClick={onClose}>
            ×
          </button>
        </div>
        <AgentCreateForm
          form={form}
          error={createError}
          onFormChange={onFormChange}
          onSubmit={onSubmit}
          onCancel={onClose}
          availableModels={availableModels}
          providerConfigured={providerConfigured}
          isGenerating={isGenerating}
        />
      </section>
    </div>
  );
}

function AgentsIndexSection({
  agents,
  isLoadingAgents,
  statusText,
  onOpenCreateModal,
  onSelectAgent
}) {
  return (
    <section className="agents-index">
      {isLoadingAgents ? (
        <div className="agents-empty-stage">
          <LoadingSkeleton label="Loading agents from Sloppy…" variant="cards" cards={6} />
        </div>
      ) : agents.length === 0 ? (
        <section className="agents-empty-stage project-board-list--empty">
          <article className="project-board-empty">
            <div className="project-board-empty-actions">
              <p className="project-new-action-subtitle">Create your first agent to start work</p>
              <button type="button" className="project-new-action hover-levitate" onClick={onOpenCreateModal}>
                Create Agent
              </button>
            </div>
          </article>
        </section>
      ) : (
        <div className="agent-list-container">
          {agents.map((agent) => (
            <button
              key={agent.id}
              type="button"
              className="agent-list-item-card hover-levitate"
              data-testid={`agent-list-item-${agent.id}`}
              onClick={() => onSelectAgent(agent.id)}
            >
              <div className="agent-list-avatar-wrap" aria-hidden="true">
                <AgentPetIcon agentId={agent.id} paletteId={agent.pet?.visual?.paletteId} />
              </div>
              <div className="agent-list-main">
                <div className="agent-list-head">
                  <h4>{agent.displayName}</h4>
                </div>
                <p>{agent.role || "General-purpose assistant"}</p>
                <span className="agent-list-id">{agent.id}</span>
              </div>
            </button>
          ))}
        </div>
      )}

      {statusText ? (
        <p className="app-status-text">{statusText}</p>
      ) : null}
    </section>
  );
}

export function AgentsView({
  routeAgentId = null,
  routeTab = "overview",
  routeAgentInitialChatSessionId = null,
  onRouteChange = null,
  onNavigateToChannelSession = null
}) {
  const [agents, setAgents] = useState([]);
  const [isLoadingAgents, setIsLoadingAgents] = useState(true);
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [form, setForm] = useState(emptyAgentFormValues);
  const [createError, setCreateError] = useState("");
  const [statusText, setStatusText] = useState("");
  const [availableModels, setAvailableModels] = useState<{ id: string; title: string }[]>([]);
  const [providerConfigured, setProviderConfigured] = useState(false);
  const [generationPhase, setGenerationPhase] = useState<"form" | "generating" | "preview">("form");
  const [generatedFiles, setGeneratedFiles] = useState<GeneratedAgentFiles>(EMPTY_GENERATED_FILES);
  const [isSubmittingAgent, setIsSubmittingAgent] = useState(false);

  const activeAgent = useMemo(
    () => agents.find((agent) => agent.id === routeAgentId) || null,
    [agents, routeAgentId]
  );

  const activeTab = useMemo(() => {
    if (!activeAgent) {
      return "overview";
    }
    if (AGENT_TAB_SET.has(String(routeTab || "").toLowerCase())) {
      return String(routeTab).toLowerCase();
    }
    return "overview";
  }, [activeAgent, routeTab]);

  useAgentChatBackground(routeAgentId ?? "", !!routeAgentId && activeTab !== "chat");

  useEffect(() => {
    refreshAgents().catch(() => {
      setStatusText("Failed to load agents from Sloppy");
      setIsLoadingAgents(false);
    });
    loadRuntimeConfig();
  }, []);

  useEffect(() => {
    if (!routeAgentId) {
      return;
    }
    if (agents.some((agent) => agent.id === routeAgentId)) {
      return;
    }

    fetchAgent(routeAgentId).then((agent) => {
      if (!agent) {
        return;
      }
      setAgents((previous) => mergeAgent(previous, agent));
    });
  }, [routeAgentId, agents]);

  async function loadRuntimeConfig() {
    const [config, availableModelsResponse] = await Promise.all([
      fetchRuntimeConfig(),
      fetchAvailableModels()
    ]);
    if (!config) {
      setProviderConfigured(false);
      return;
    }

    const catalog = Array.isArray(config.models) && (config.models as unknown[]).length > 0
      ? await collectAggregatedProviderModels(config as Record<string, unknown>)
      : { models: [] };
    const models = mergeModelOptions(
      Array.isArray(availableModelsResponse) ? availableModelsResponse : [],
      catalog.models
    );
    setAvailableModels(models);
    setProviderConfigured(models.length > 0);
  }

  async function refreshAgents() {
    setIsLoadingAgents(true);
    const response = await fetchAgents();
    if (!Array.isArray(response)) {
      setStatusText("Failed to load agents from Sloppy");
      setIsLoadingAgents(false);
      return;
    }

    const normalized = response
      .map((item, index) => normalizeAgent(item, index))
      .filter((item) => item.id.length > 0)
      .sort((left, right) => left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" }));

    setAgents(normalized);
    setIsLoadingAgents(false);
    setStatusText("");
  }

  function navigateToAgent(agentId, tab = "overview") {
    if (typeof onRouteChange === "function") {
      onRouteChange(agentId, tab, null);
    }
  }

  function handleOpenWorkerSession(agentId: string, sessionId: string) {
    if (typeof onRouteChange === "function") {
      onRouteChange(agentId, "chat", sessionId);
    }
  }

  function navigateToAgentList() {
    if (typeof onRouteChange === "function") {
      onRouteChange(null, null, null);
    }
  }

  function updateForm(field, value) {
    setForm((previous) => ({
      ...previous,
      [field]: value
    }));

  }

  function openCreateModal() {
    const defaultModel = availableModels[0]?.id ?? "";
    setForm({ ...emptyAgentFormValues(), generateModel: defaultModel });
    setCreateError("");
    setGenerationPhase("form");
    setGeneratedFiles(EMPTY_GENERATED_FILES);
    setIsCreateModalOpen(true);
  }

  function closeCreateModal() {
    setCreateError("");
    setIsCreateModalOpen(false);
    setGenerationPhase("form");
    setGeneratedFiles(EMPTY_GENERATED_FILES);
  }

  async function handleCreateSubmit(event) {
    event.preventDefault();

    const rawId = String(form.id || "").trim();
    const normalizedId = rawId.replace(/\s+/g, "-");

    if (!normalizedId) {
      setCreateError("Agent ID is required.");
      return;
    }

    if (form.generateEnabled && providerConfigured) {
      if (!form.generateDescription.trim()) {
        setCreateError("Agent responsibility description is required for generation.");
        return;
      }
      await runGeneration(normalizedId);
    } else {
      await createAgentDirectly(normalizedId);
    }
  }

  async function runGeneration(normalizedId: string) {
    setGenerationPhase("generating");
    setCreateError("");

    const prompt = buildGeneratePrompt({
      id: normalizedId,
      displayName: String(form.displayName || "").trim(),
      role: String(form.role || "").trim(),
      generateDescription: form.generateDescription
    });

    const result = await generateText({ model: form.generateModel, prompt });
    if (!result || typeof result.text !== "string") {
      setGenerationPhase("form");
      setCreateError("Failed to generate agent files. Please try again.");
      return;
    }

    const parsed = parseGeneratedFiles(result.text);
    const validationError = validateGeneratedFiles(parsed);
    if (validationError) {
      setGenerationPhase("form");
      setCreateError(validationError);
      return;
    }
    setGeneratedFiles(parsed);
    setGenerationPhase("preview");
  }

  async function createAgentDirectly(normalizedId: string) {
    const displayName = String(form.displayName || "").trim();
    const role = String(form.role || "").trim();

    const response = await createAgentRequest({
      id: normalizedId,
      displayName: displayName || normalizedId,
      role: role || "General-purpose assistant",
      isSystem: false,
    });

    if (!response) {
      setCreateError("Failed to create agent in Sloppy. Check ID format and duplicates.");
      return;
    }

    setAgents((previous) => mergeAgent(previous, response));
    setForm(emptyAgentFormValues());
    setStatusText(`Agent ${response.id} created in Sloppy`);
    setIsCreateModalOpen(false);
  }

  async function handlePreviewDone() {
    const normalizedId = String(form.id || "").trim().replace(/\s+/g, "-");
    const displayName = String(form.displayName || "").trim();
    const role = String(form.role || "").trim();

    setIsSubmittingAgent(true);
    setCreateError("");

    const response = await createAgentRequest({
      id: normalizedId,
      displayName: displayName || normalizedId,
      role: role || "General-purpose assistant",
      isSystem: false,
    });

    if (!response) {
      setIsSubmittingAgent(false);
      setCreateError("Failed to create agent in Sloppy. Check ID format and duplicates.");
      setGenerationPhase("form");
      return;
    }

    const agentConfig = await fetchAgentConfig(normalizedId);
    if (agentConfig) {
      try {
        await updateAgentConfig(normalizedId, {
          selectedModel: agentConfig.selectedModel || form.generateModel || "",
          documents: {
            agentsMarkdown: generatedFiles.agentsMarkdown,
            identityMarkdown: generatedFiles.identityMarkdown,
            soulMarkdown: generatedFiles.soulMarkdown,
            userMarkdown: generatedFiles.userMarkdown,
            heartbeatMarkdown: String((agentConfig.documents as Record<string, unknown>)?.heartbeatMarkdown || "")
          },
          heartbeat: agentConfig.heartbeat,
          channelSessions: agentConfig.channelSessions
        });
      } catch (err) {
        await deleteAgentRequest(normalizedId);
        setCreateError(
          `${err instanceof Error ? err.message : "Failed to update agent config after creation."} Agent creation was rolled back.`
        );
        setIsSubmittingAgent(false);
        setGenerationPhase("form");
        return;
      }
    }

    setAgents((previous) => mergeAgent(previous, response));
    setForm(emptyAgentFormValues());
    setStatusText(`Agent ${response.id} created in Sloppy`);
    setIsSubmittingAgent(false);
    setIsCreateModalOpen(false);
    setGenerationPhase("form");
    setGeneratedFiles(EMPTY_GENERATED_FILES);
  }

  function renderAgentTabContent(agent, tab) {
    if (tab === "attention") {
      return <ProactivityInbox agentId={agent.id} onOpenSession={handleOpenWorkerSession} />;
    }
    if (tab === "overview") {
      return <AgentOverviewTab agent={agent} navigateToAgent={navigateToAgent} />;
    }

    if (tab === "chat") {
      return (
        <AgentChatTab agentId={agent.id} initialSessionId={routeAgentInitialChatSessionId} />
      );
    }

    if (tab === "workers") {
      return <AgentWorkersTab agentId={agent.id} onOpenWorkerSession={handleOpenWorkerSession} />;
    }

    if (tab === "tasks") {
      return <AgentTasksTab agentId={agent.id} />;
    }

    if (tab === "skills") {
      return <AgentSkillsTab agentId={agent.id} />;
    }

    if (tab === "cron") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentCronTab agentId={agent.id} />
        </section>
      );
    }

    if (tab === "tools") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentToolsTab agentId={agent.id} />
        </section>
      );
    }

    if (tab === "channels") {
      return (
        <section className="entry-editor-card agent-content-card">
          <AgentChannelsTab agentId={agent.id} agentDisplayName={agent.displayName} onNavigateToChannelSession={onNavigateToChannelSession} />
        </section>
      );
    }

    return (
      <section className="entry-editor-card agent-content-card">
        <AgentConfigTab
          agentId={agent.id}
          agentDisplayName={agent.displayName || agent.id}
          onDeleteAgent={() => {
            setAgents((previous) => previous.filter((a) => a.id !== agent.id));
            navigateToAgentList();
          }}
        />
      </section>
    );
  }

  if (routeAgentId && !activeAgent) {
    return (
      <main className="agents-shell">
        <section className="entry-editor-card">
          <h2>{isLoadingAgents ? "Loading agent..." : "Agent Not Found"}</h2>
          <p className="placeholder-text">
            {isLoadingAgents ? "Synchronizing agent data from Sloppy." : `Agent with id ${routeAgentId} does not exist in Sloppy.`}
          </p>
          <div className="agent-inline-actions">
            <button type="button" onClick={navigateToAgentList}>
              Back To Agents
            </button>
          </div>
        </section>
      </main>
    );
  }

  if (!activeAgent) {
    return (
      <main className="agents-shell">
        <Breadcrumbs
          items={[
            { id: 'agents', label: 'Agents' }
          ]}
          style={{ marginBottom: '20px' }}
          action={
            <button type="button" className="agents-create-inline hover-levitate" onClick={openCreateModal}>
              Create Agent
            </button>
          }
        />

        <AgentsIndexSection
          agents={agents}
          isLoadingAgents={isLoadingAgents}
          statusText={statusText}
          onOpenCreateModal={openCreateModal}
          onSelectAgent={navigateToAgent}
        />

        <AgentCreateModal
          isOpen={isCreateModalOpen && generationPhase !== "preview"}
          form={form}
          createError={createError}
          onFormChange={updateForm}
          onClose={closeCreateModal}
          onSubmit={handleCreateSubmit}
          availableModels={availableModels}
          providerConfigured={providerConfigured}
          isGenerating={generationPhase === "generating"}
        />

        {isCreateModalOpen && generationPhase === "preview" && (
          <AgentGeneratePreview
            files={generatedFiles}
            onFilesChange={setGeneratedFiles}
            onBack={() => setGenerationPhase("form")}
            onDone={handlePreviewDone}
            isSubmitting={isSubmittingAgent}
          />
        )}
      </main>
    );
  }

  const isChatLayout = activeTab === "chat";

  return (
    <main className={`agents-shell ${isChatLayout ? "chat-layout" : ""}`}>
      {isChatLayout ? (
        <button
          type="button"
          className="agent-chat-back-button"
          onClick={() => navigateToAgent(activeAgent.id, "overview")}
          aria-label="Back to agent overview"
        >
          <span className="material-symbols-rounded" aria-hidden="true">arrow_back</span>
          Back
        </button>
      ) : (
        <Breadcrumbs
          items={[
            { id: 'agents', label: 'Agents', onClick: navigateToAgentList },
            { id: activeAgent.id, label: activeAgent.displayName }
          ]}
          style={{ marginBottom: '20px' }}
          action={
            <button type="button" className="agents-create-inline hover-levitate" onClick={openCreateModal}>
              Create Agent
            </button>
          }
        />
      )}

      {!isChatLayout ? <section className="agent-tabs" aria-label="Agent sections">
        {AGENT_TABS.map((tab) => (
          <button
            key={tab.id}
            type="button"
            className={`agent-tab ${activeTab === tab.id ? "active" : ""}`}
            data-testid={`agent-tab-${tab.id}`}
            onClick={() => navigateToAgent(activeAgent.id, tab.id)}
          >
            {tab.title}
          </button>
        ))}
      </section> : null}

      <section className="agent-content-shell">
        {renderAgentTabContent(activeAgent, activeTab)}
      </section>

      <AgentCreateModal
        isOpen={isCreateModalOpen && generationPhase !== "preview"}
        form={form}
        createError={createError}
        onFormChange={updateForm}
        onClose={closeCreateModal}
        onSubmit={handleCreateSubmit}
        availableModels={availableModels}
        providerConfigured={providerConfigured}
        isGenerating={generationPhase === "generating"}
      />

      {isCreateModalOpen && generationPhase === "preview" && (
        <AgentGeneratePreview
          files={generatedFiles}
          onFilesChange={setGeneratedFiles}
          onBack={() => setGenerationPhase("form")}
          onDone={handlePreviewDone}
          isSubmitting={isSubmittingAgent}
        />
      )}
    </main>
  );
}
