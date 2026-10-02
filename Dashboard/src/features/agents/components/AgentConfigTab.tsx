import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  fetchActorsBoard,
  fetchAgentConfig,
  fetchAgentFileContent,
  fetchAgentFiles,
  fetchAvailableModels,
  fetchRuntimeConfig,
  updateAgentConfig,
  deleteAgent
} from "../../../api";
import {
  coerceLegacySloppyModelId,
  collectAggregatedProviderModels,
  mergeModelOptions
} from "../utils/aggregateProviderModels";
import { AggregatedModelPicker } from "../../config/components/AggregatedModelPicker";
import { ChannelModelSelector } from "./ChannelModelSelector";
import { resolveSystemRole, SYSTEM_ROLES } from "./AgentCreateForm";
import { ProactivitySettingsFields } from "./ProactivitySettingsFields";
import { defaultProactiveSettings } from "../../../shared/api/proactivity";

const AGENT_CONFIG_SECTIONS = [
  { id: "runtime", title: "Runtime", icon: "smart_toy" },
  { id: "models", title: "Models", icon: "hub" },
  { id: "files", title: "Agent Files", icon: "description" },
  { id: "channel", title: "Channel", icon: "forum" },
  { id: "heartbeat", title: "Heartbeat", icon: "monitor_heart" },
  { id: "danger", title: "Danger Zone", icon: "warning", danger: true }
];

const REASONING_EFFORT_OPTIONS = [
  { value: "", label: "Default" },
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" }
];

function emptyAgentConfigDraft(agentId) {
  return {
    agentId,
    role: "",
    selectedModel: "",
    plannerModel: "",
    reasoningEffort: "",
    automaticModelRouting: true,
    autoApproveInput: true,
    availableModels: [],
    documents: {
      userMarkdown: "",
      agentsMarkdown: "",
      soulMarkdown: "",
      identityMarkdown: "",
      heartbeatMarkdown: "",
      friendReminderMarkdown: "",
      memoryMarkdown: ""
    },
    heartbeat: {
      enabled: false,
      intervalMinutes: 5,
      mode: "checklist" as "checklist" | "proactive",
      proactive: defaultProactiveSettings()
    },
    channelSessions: {
      autoCloseEnabled: false,
      autoCloseAfterMinutes: 30,
      inboundActivation: "all",
      allowedChannelIds: [],
      excludedChannelIds: []
    },
    heartbeatStatus: {
      lastRunAt: null,
      lastSuccessAt: null,
      lastFailureAt: null,
      lastResult: "",
      lastErrorMessage: "",
      lastSessionId: ""
    },
    runtime: {
      type: "native",
      acp: null,
      sharedMemoryEnabled: true
    }
  };
}

function normalizeConfigDraft(agentId, config) {
  return {
    agentId: config.agentId || agentId,
    role: String(config.role || ""),
    selectedModel: coerceLegacySloppyModelId(String(config.selectedModel || "")),
    plannerModel: coerceLegacySloppyModelId(String(config.plannerModel || "")),
    reasoningEffort: REASONING_EFFORT_OPTIONS.some((option) => option.value === config.reasoningEffort)
      ? String(config.reasoningEffort || "")
      : "",
    automaticModelRouting: config.automaticModelRouting !== false,
    autoApproveInput: config.autoApproveInput !== false,
    availableModels: Array.isArray(config.availableModels) ? config.availableModels : [],
    documents: {
      userMarkdown: String(config.documents?.userMarkdown || ""),
      agentsMarkdown: String(config.documents?.agentsMarkdown || ""),
      soulMarkdown: String(config.documents?.soulMarkdown || ""),
      identityMarkdown: String(config.documents?.identityMarkdown || ""),
      heartbeatMarkdown: String(config.documents?.heartbeatMarkdown || ""),
      friendReminderMarkdown: String(config.documents?.friendReminderMarkdown || ""),
      memoryMarkdown: String(config.documents?.memoryMarkdown || "")
    },
    heartbeat: {
      enabled: Boolean(config.heartbeat?.enabled),
      intervalMinutes: Number.parseInt(String(config.heartbeat?.intervalMinutes ?? 5), 10) || 5,
      mode: config.heartbeat?.mode === "proactive" ? "proactive" as const : "checklist" as const,
      proactive: { ...defaultProactiveSettings(), ...config.heartbeat?.proactive }
    },
    channelSessions: {
      autoCloseEnabled: Boolean(config.channelSessions?.autoCloseEnabled),
      autoCloseAfterMinutes: Number.parseInt(String(config.channelSessions?.autoCloseAfterMinutes ?? 30), 10) || 30,
      inboundActivation:
        config.channelSessions?.inboundActivation === "mention_or_reply" ? "mention_or_reply" : "all",
      allowedChannelIds: Array.isArray(config.channelSessions?.allowedChannelIds)
        ? config.channelSessions.allowedChannelIds
        : [],
      excludedChannelIds: Array.isArray(config.channelSessions?.excludedChannelIds)
        ? config.channelSessions.excludedChannelIds
        : []
    },
    heartbeatStatus: {
      lastRunAt: config.heartbeatStatus?.lastRunAt || null,
      lastSuccessAt: config.heartbeatStatus?.lastSuccessAt || null,
      lastFailureAt: config.heartbeatStatus?.lastFailureAt || null,
      lastResult: String(config.heartbeatStatus?.lastResult || ""),
      lastErrorMessage: String(config.heartbeatStatus?.lastErrorMessage || ""),
      lastSessionId: String(config.heartbeatStatus?.lastSessionId || "")
    },
    runtime: {
      type: String(config.runtime?.type || "native"),
      sharedMemoryEnabled: config.runtime?.sharedMemoryEnabled !== false,
      acp: config.runtime?.acp
        ? {
            targetId: String(config.runtime.acp.targetId || ""),
            cwd: config.runtime.acp.cwd || null
          }
        : null
    }
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function formatDateTime(value) {
  if (!value) {
    return "Never";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Never";
  }

  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function statusValue(value, fallback = "None") {
  const normalized = String(value || "").trim();
  return normalized || fallback;
}

const AGENT_DOC_FILES: Array<{ id: string; name: string; icon: string; readOnly?: boolean }> = [
  { id: "userMarkdown", name: "USER.md", icon: "person" },
  { id: "agentsMarkdown", name: "AGENTS.md", icon: "smart_toy" },
  { id: "soulMarkdown", name: "SOUL.md", icon: "psychology" },
  { id: "identityMarkdown", name: "IDENTITY.md", icon: "badge" },
  { id: "heartbeatMarkdown", name: "HEARTBEAT.md", icon: "monitor_heart" },
  { id: "friendReminderMarkdown", name: "FRIEND_REMINDER.md", icon: "favorite" }
];

const MOBILE_AGENT_FILES_BREAKPOINT_PX = 1000;

function useNarrowAgentFilesLayout() {
  const [narrow, setNarrow] = useState(
    () => typeof window !== "undefined" && window.innerWidth <= MOBILE_AGENT_FILES_BREAKPOINT_PX
  );

  useEffect(() => {
    const mq = window.matchMedia(`(max-width: ${MOBILE_AGENT_FILES_BREAKPOINT_PX}px)`);
    const sync = () => setNarrow(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  return narrow;
}

function docIdForFilePath(path) {
  const normalizedPath = String(path || "").trim();
  const match = AGENT_DOC_FILES.find((file) => file.name === normalizedPath);
  return match?.id || null;
}

function AgentFileTreeNode({ agentId, name, type, path, depth, selectedPath, onSelectFile, narrowLayout }) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [children, setChildren] = useState(null);
  const [isLoading, setIsLoading] = useState(false);

  const isSelected = type === "file" && path === selectedPath;
  const rowPadLeft = narrowLayout ? 12 + depth * 22 : 8 + depth * 16;

  async function handleExpand() {
    if (type !== "directory") return;
    const next = !isExpanded;
    setIsExpanded(next);
    if (next && children === null) {
      setIsLoading(true);
      const entries = await fetchAgentFiles(agentId, path);
      setChildren(entries || []);
      setIsLoading(false);
    }
  }

  function handleClick() {
    if (type === "directory") {
      handleExpand();
    } else {
      onSelectFile(path);
    }
  }

  const icon = type === "directory"
    ? (isExpanded ? "folder_open" : "folder")
    : "description";

  return (
    <div className="pft-node">
      <button
        type="button"
        className={`pft-node-row ${isSelected ? "selected" : ""} ${narrowLayout ? "pft-node-row--touch" : ""}`}
        style={{ paddingLeft: `${rowPadLeft}px` }}
        onClick={handleClick}
        title={name}
      >
        <span className={`material-symbols-rounded pft-node-icon ${type === "directory" ? "pft-icon-dir" : "pft-icon-file"}`}>
          {icon}
        </span>
        <span className="pft-node-name">{name}</span>
        {isLoading && <span className="pft-node-spinner" />}
        {narrowLayout && (
          <span
            className={`pft-node-chevron ${type === "directory" && isExpanded ? "pft-node-chevron--expanded" : ""}`}
            aria-hidden
          >
            <span className="material-symbols-rounded">chevron_right</span>
          </span>
        )}
      </button>
      {isExpanded && children !== null && (
        <div className="pft-children">
          {children.length === 0 ? (
            <div
              className="pft-empty-dir"
              style={{ paddingLeft: `${(narrowLayout ? 12 : 8) + (depth + 1) * (narrowLayout ? 22 : 16)}px` }}
            >
              Empty
            </div>
          ) : (
            children.map((child) => (
              <AgentFileTreeNode
                key={child.name}
                agentId={agentId}
                name={child.name}
                type={child.type}
                path={path ? `${path}/${child.name}` : child.name}
                depth={depth + 1}
                selectedPath={selectedPath}
                onSelectFile={onSelectFile}
                narrowLayout={narrowLayout}
              />
            ))
          )}
        </div>
      )}
    </div>
  );
}

export function AgentConfigTab({ agentId, agentDisplayName = "", onDeleteAgent = null }) {
  const [draft, setDraft] = useState(() => emptyAgentConfigDraft(agentId));
  const [savedDraft, setSavedDraft] = useState(() => emptyAgentConfigDraft(agentId));
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [statusText, setStatusText] = useState("Loading agent config...");
  const [channelNodes, setChannelNodes] = useState([]);
  const [selectedSection, setSelectedSection] = useState("runtime");
  const [acpTargets, setAcpTargets] = useState([]);
  const [selectedFilePath, setSelectedFilePath] = useState("");
  const [agentRootEntries, setAgentRootEntries] = useState(null);
  const [agentFilesLoading, setAgentFilesLoading] = useState(true);
  const [agentFileContent, setAgentFileContent] = useState(null);
  const [agentFileLoading, setAgentFileLoading] = useState(false);
  const [agentFileError, setAgentFileError] = useState("");
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
  const [deleteConfirmText, setDeleteConfirmText] = useState("");
  const [isDeleting, setIsDeleting] = useState(false);
  const [aggregatedModels, setAggregatedModels] = useState([]);
  const [modelCatalogStatus, setModelCatalogStatus] = useState("");
  const [semanticRoutingMode, setSemanticRoutingMode] = useState("disabled");
  const [roleDropdownOpen, setRoleDropdownOpen] = useState(false);
  const agentFileRequestRef = useRef(null);
  const narrowAgentFilesLayout = useNarrowAgentFilesLayout();

  useEffect(() => {
    let isCancelled = false;

    async function load() {
      setIsLoading(true);
      setStatusText("Loading agent config...");
      setAggregatedModels([]);
      setModelCatalogStatus("Loading model catalog...");
      const [response, board, runtimeCfg, availableModelsResponse] = await Promise.all([
        fetchAgentConfig(agentId),
        fetchActorsBoard(),
        fetchRuntimeConfig(),
        fetchAvailableModels()
      ]);
      if (isCancelled) {
        return;
      }

      if (board && Array.isArray(board.nodes)) {
        setChannelNodes(board.nodes.filter((n) => n.linkedAgentId === agentId));
      }

      if (runtimeCfg && Array.isArray((runtimeCfg as any).acp?.targets)) {
        setAcpTargets((runtimeCfg as any).acp.targets.filter((t) => t.enabled !== false));
      }
      setSemanticRoutingMode(String((runtimeCfg as any)?.semanticDecisions?.executorModelRouting || "disabled"));

      let catalog: { models: any[]; probes: any[] } = { models: [], probes: [] };
      let catalogLoadError = false;
      if (runtimeCfg) {
        try {
          catalog = await collectAggregatedProviderModels(runtimeCfg as Record<string, unknown>);
        } catch {
          catalogLoadError = true;
        }
      }
      if (isCancelled) {
        return;
      }

      if (!response) {
        const empty = emptyAgentConfigDraft(agentId);
        setDraft(empty);
        setSavedDraft(clone(empty));
        setStatusText("Failed to load config.");
        setIsLoading(false);
        return;
      }

      const normalized = normalizeConfigDraft(agentId, response);
      const mergedModels = mergeModelOptions(
        normalized.availableModels,
        Array.isArray(availableModelsResponse) ? availableModelsResponse : [],
        catalog.models
      );
      setAggregatedModels(mergedModels);
      if (catalogLoadError) {
        setModelCatalogStatus("Failed to load provider model catalogs.");
      } else {
        const failed = (catalog.probes || []).filter((p) => !p.ok);
        const modelsField = runtimeCfg ? (runtimeCfg as Record<string, unknown>).models : undefined;
        const hasModelEntries =
          runtimeCfg && Array.isArray(modelsField) && modelsField.length > 0;

        if (mergedModels.length === 0 && !hasModelEntries) {
          setModelCatalogStatus("No models found. Configure providers in Settings.");
        } else if (failed.length > 0) {
          const summary = failed
            .map((p) => {
              const reason = p.message ? ` — ${p.message}` : "";
              return `${p.title || p.providerId}${reason}`;
            })
            .join("; ");
          setModelCatalogStatus(
            mergedModels.length === 0
              ? `Providers failed probe: ${summary}. Check Settings > Providers.`
              : `Some providers failed probe: ${summary}.`
          );
        } else {
          setModelCatalogStatus("");
        }
      }
      setDraft(normalized);
      setSavedDraft(clone(normalized));
      setStatusText("Config loaded.");
      setIsLoading(false);
    }

    load().catch(() => {
      if (!isCancelled) {
        setStatusText("Failed to load config.");
        setModelCatalogStatus("Failed to load provider model catalogs.");
        setIsLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [agentId]);

  const hasChanges = useMemo(() => {
    return JSON.stringify(draft) !== JSON.stringify(savedDraft);
  }, [draft, savedDraft]);

  const activeDocFileId = useMemo(() => docIdForFilePath(selectedFilePath), [selectedFilePath]);
  const activeDocFile = useMemo(
    () => AGENT_DOC_FILES.find((file) => file.id === activeDocFileId) || null,
    [activeDocFileId]
  );

  function updateField(field, value) {
    setDraft((previous) => ({
      ...previous,
      [field]: value
    }));
  }

  function updateDocumentField(field, value) {
    setDraft((previous) => ({
      ...previous,
      documents: {
        ...previous.documents,
        [field]: value
      }
    }));
  }

  function updateHeartbeatField(field, value) {
    setDraft((previous) => ({
      ...previous,
      heartbeat: {
        ...previous.heartbeat,
        [field]: value
      }
    }));
  }

  function updateChannelSessionField(field, value) {
    setDraft((previous) => ({
      ...previous,
      channelSessions: {
        ...previous.channelSessions,
        [field]: value
      }
    }));
  }

  function updateRuntimeType(type) {
    setDraft((previous) => ({
      ...previous,
      runtime: {
        ...previous.runtime,
        type,
        acp: type === "acp" ? (previous.runtime.acp || { targetId: "", cwd: null }) : null
      }
    }));
  }

  function updateRuntimeACPField(field, value) {
    setDraft((previous) => ({
      ...previous,
      runtime: {
        ...previous.runtime,
        sharedMemoryEnabled: previous.runtime.sharedMemoryEnabled !== false,
        acp: {
          ...(previous.runtime.acp || { targetId: "", cwd: null }),
          [field]: value
        }
      }
    }));
  }

  function cancelChanges() {
    setDraft(clone(savedDraft));
    setStatusText("Changes cancelled.");
  }

  async function saveConfig() {
    if (isSaving) {
      return;
    }

    const runtimeType = draft.runtime?.type || "native";
    const selectedModel = coerceLegacySloppyModelId(String(draft.selectedModel || "").trim());
    const plannerModel = coerceLegacySloppyModelId(String(draft.plannerModel || "").trim());
    if (runtimeType === "native" && !selectedModel) {
      setStatusText("Executor model is required for native runtime.");
      return;
    }
    if (runtimeType === "acp" && !draft.runtime?.acp?.targetId?.trim()) {
      setStatusText("ACP target is required.");
      return;
    }

    const intervalMinutes = Number.parseInt(String(draft.heartbeat.intervalMinutes || 0), 10);
    if (draft.heartbeat.enabled && draft.heartbeat.mode === "proactive" &&
      (intervalMinutes < 5 || !draft.heartbeat.proactive.analysisModel ||
        (!draft.heartbeat.proactive.projectIds.length && !draft.heartbeat.proactive.reviewProviderIds.length))) {
      setStatusText("Choose a deep review model, at least one source and an interval of 5 minutes or more.");
      return;
    }
    if (draft.heartbeat.enabled && (!Number.isFinite(intervalMinutes) || intervalMinutes < 1)) {
      setStatusText("Heartbeat interval must be at least 1 minute.");
      return;
    }
    const autoCloseAfterMinutes = Number.parseInt(String(draft.channelSessions.autoCloseAfterMinutes || 0), 10);
    if (draft.channelSessions.autoCloseEnabled && (!Number.isFinite(autoCloseAfterMinutes) || autoCloseAfterMinutes < 1)) {
      setStatusText("Channel session timeout must be at least 1 minute.");
      return;
    }

    const runtime = {
      type: runtimeType,
      sharedMemoryEnabled: draft.runtime?.sharedMemoryEnabled !== false
    };
    if (runtimeType === "acp" && draft.runtime?.acp) {
      (runtime as any).acp = {
        targetId: draft.runtime.acp.targetId,
        cwd: draft.runtime.acp.cwd || undefined
      };
    }

    const payload = {
      role: String(draft.role || "").trim(),
      selectedModel: runtimeType === "native" ? selectedModel : null,
      plannerModel: runtimeType === "native" ? plannerModel || null : null,
      reasoningEffort: runtimeType === "native" && draft.reasoningEffort ? draft.reasoningEffort : null,
      automaticModelRouting: draft.automaticModelRouting !== false,
      autoApproveInput: draft.autoApproveInput,
      documents: {
        userMarkdown: String(draft.documents.userMarkdown || ""),
        agentsMarkdown: String(draft.documents.agentsMarkdown || ""),
        soulMarkdown: String(draft.documents.soulMarkdown || ""),
        identityMarkdown: String(draft.documents.identityMarkdown || ""),
        heartbeatMarkdown: String(draft.documents.heartbeatMarkdown || ""),
        friendReminderMarkdown: String(draft.documents.friendReminderMarkdown || ""),
        memoryMarkdown: String(draft.documents.memoryMarkdown || "")
      },
      heartbeat: {
        enabled: Boolean(draft.heartbeat.enabled),
        intervalMinutes: intervalMinutes || 5,
        mode: draft.heartbeat.mode,
        proactive: draft.heartbeat.proactive
      },
      channelSessions: {
        autoCloseEnabled: Boolean(draft.channelSessions.autoCloseEnabled),
        autoCloseAfterMinutes: autoCloseAfterMinutes || 30,
        inboundActivation: draft.channelSessions.inboundActivation === "mention_or_reply" ? "mention_or_reply" : "all",
        allowedChannelIds: Array.isArray(draft.channelSessions.allowedChannelIds)
          ? draft.channelSessions.allowedChannelIds
          : [],
        excludedChannelIds: Array.isArray(draft.channelSessions.excludedChannelIds)
          ? draft.channelSessions.excludedChannelIds
          : []
      },
      runtime
    };

    setIsSaving(true);
    try {
      const response = await updateAgentConfig(agentId, payload);
      const normalized = normalizeConfigDraft(agentId, response);
      setDraft(normalized);
      setSavedDraft(clone(normalized));
      setStatusText("Config saved.");
    } catch (err) {
      setStatusText(err instanceof Error ? err.message : "Failed to save config.");
    }
    setIsSaving(false);
  }

  const isACP = draft.runtime?.type === "acp";

  const closeMobileAgentFile = useCallback(() => {
    setSelectedFilePath("");
  }, []);

  useEffect(() => {
    if (!narrowAgentFilesLayout || !selectedFilePath) {
      return undefined;
    }

    function onKeyDown(event) {
      if (event.key === "Escape") {
        event.preventDefault();
        closeMobileAgentFile();
      }
    }

    window.addEventListener("keydown", onKeyDown);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      document.body.style.overflow = previousOverflow;
    };
  }, [closeMobileAgentFile, narrowAgentFilesLayout, selectedFilePath]);

  useEffect(() => {
    let isCancelled = false;

    async function loadAgentFilesRoot() {
      setAgentFilesLoading(true);
      const entries = await fetchAgentFiles(agentId, "");
      if (isCancelled) {
        return;
      }
      setAgentRootEntries(entries);
      setAgentFilesLoading(false);
    }

    loadAgentFilesRoot().catch(() => {
      if (!isCancelled) {
        setAgentRootEntries(null);
        setAgentFilesLoading(false);
      }
    });

    return () => {
      isCancelled = true;
    };
  }, [agentId]);

  const handleSelectAgentFile = useCallback(async (path) => {
    const token = { path };
    agentFileRequestRef.current = token;
    setSelectedFilePath(path);
    setAgentFileContent(null);
    setAgentFileError("");

    if (docIdForFilePath(path)) {
      setAgentFileLoading(false);
      return;
    }

    setAgentFileLoading(true);
    const response = await fetchAgentFileContent(agentId, path);
    if (agentFileRequestRef.current !== token) {
      return;
    }
    if (!response) {
      setAgentFileError("Unable to load file. It may be binary or too large.");
      setAgentFileLoading(false);
      return;
    }
    setAgentFileContent(response);
    setAgentFileLoading(false);
  }, [agentId]);

  async function handleDeleteAgent() {
    if (isDeleting) return;
    setIsDeleting(true);
    const ok = await deleteAgent(agentId);
    if (ok) {
      onDeleteAgent?.();
    } else {
      setStatusText("Failed to delete agent.");
      setIsDeleting(false);
      setDeleteConfirmOpen(false);
      setDeleteConfirmText("");
    }
  }

  function renderDangerSection() {
    const confirmName = agentDisplayName || agentId;
    return (
      <section className="entry-editor-card settings-danger-zone">
        <h3 style={{ color: "var(--danger, #ef4444)" }}>Danger Zone</h3>
        <div className="settings-danger-block">
          <div className="settings-danger-info">
            <strong>Delete this agent</strong>
            <p>
              Once you delete an agent, there is no going back. All sessions, memories, and configuration will be permanently removed.
            </p>
          </div>
          {!deleteConfirmOpen ? (
            <button
              type="button"
              className="danger hover-levitate"
              onClick={() => {
                setDeleteConfirmOpen(true);
                setDeleteConfirmText("");
              }}
            >
              Delete Agent
            </button>
          ) : (
            <div className="settings-danger-confirm">
              <p className="settings-danger-warning">
                <span className="material-symbols-rounded" style={{ fontSize: "1rem", verticalAlign: "middle" }}>warning</span>
                {" "}This action is irreversible. All agent data will be permanently deleted.
              </p>
              <label>
                Type <strong>{confirmName}</strong> to confirm
                <input
                  type="text"
                  value={deleteConfirmText}
                  onChange={(e) => setDeleteConfirmText(e.target.value)}
                  placeholder={confirmName}
                  autoFocus
                />
              </label>
              <div className="settings-danger-confirm-actions">
                <button
                  type="button"
                  onClick={() => {
                    setDeleteConfirmOpen(false);
                    setDeleteConfirmText("");
                  }}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="danger hover-levitate"
                  disabled={deleteConfirmText.trim() !== confirmName || isDeleting}
                  onClick={handleDeleteAgent}
                >
                  {isDeleting ? "Deleting..." : "I understand, delete this agent"}
                </button>
              </div>
            </div>
          )}
        </div>
      </section>
    );
  }

  function renderSectionContent() {
    if (selectedSection === "runtime") {
      return (
        <section className="entry-editor-card">
          <h3>Agent Runtime</h3>
          <p className="placeholder-text">
            Choose how this agent processes messages. <strong>Native</strong> uses the built-in Sloppy runtime with a selected model.{" "}
            <strong>ACP</strong> delegates to an external agent (e.g. Claude Code) via the Agent Client Protocol.
          </p>
          <div className="entry-form-grid">
            <label style={{ gridColumn: "1 / -1" }}>
              Agent Role
              <div className="actor-team-search-wrap">
                <input
                  className="actor-team-search"
                  placeholder="e.g. Senior Backend Developer"
                  value={draft.role}
                  onChange={(e) => {
                    updateField("role", e.target.value);
                    setRoleDropdownOpen(true);
                  }}
                  onFocus={() => setRoleDropdownOpen(true)}
                  onBlur={() => setTimeout(() => setRoleDropdownOpen(false), 150)}
                  autoComplete="off"
                />
                {roleDropdownOpen && (
                  <ul className="actor-team-dropdown">
                    {SYSTEM_ROLES.filter((r) =>
                      r.label.toLowerCase().includes(draft.role.toLowerCase())
                    ).map((r) => {
                      const isSelected = resolveSystemRole(draft.role) === r.value;
                      return (
                        <li
                          key={r.value}
                          className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                          onMouseDown={(event) => {
                            event.preventDefault();
                            updateField("role", r.label);
                            setRoleDropdownOpen(false);
                          }}
                        >
                          <span className="actor-team-dropdown-name">{r.label}</span>
                          {isSelected && <span className="actor-team-dropdown-check material-symbols-rounded">check</span>}
                        </li>
                      );
                    })}
                    {SYSTEM_ROLES.filter((r) =>
                      r.label.toLowerCase().includes(draft.role.toLowerCase())
                    ).length === 0 && (
                      <li className="actor-team-dropdown-empty">Custom role</li>
                    )}
                  </ul>
                )}
              </div>
              <span className="entry-form-hint">
                This describes the agent's persona and expertise. It is included in the system prompt.
              </span>
            </label>

            <label style={{ gridColumn: "1 / -1" }}>
              Runtime Type
              <select
                value={draft.runtime?.type || "native"}
                onChange={(e) => updateRuntimeType(e.target.value)}
              >
                <option value="native">Native</option>
                <option value="acp">ACP (Agent Client Protocol)</option>
              </select>
            </label>

            <label className="agent-config-memory-toggle" style={{ gridColumn: "1 / -1" }}>
              <span className="agent-config-memory-copy">
                <strong>Shared memory</strong>
                <small>Allow this agent to read and write the global shared memory scope.</small>
              </span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={draft.runtime?.sharedMemoryEnabled !== false}
                  onChange={(e) => {
                    setDraft((previous) => ({
                      ...previous,
                      runtime: {
                        ...(previous.runtime || { type: "native", acp: null }),
                        sharedMemoryEnabled: e.target.checked
                      }
                    }));
                  }}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>

            <label className="agent-config-memory-toggle" style={{ gridColumn: "1 / -1" }}>
              <span className="agent-config-memory-copy">
                <strong>Auto-approve unanswered questions</strong>
                <small>After 2 minutes without an answer, let the agent decide from the task context and continue.</small>
              </span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={draft.autoApproveInput}
                  onChange={(event) => updateField("autoApproveInput", event.target.checked)}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>

            {isACP && (
              <>
                <label style={{ gridColumn: "1 / -1" }}>
                  ACP Target
                  <select
                    value={draft.runtime?.acp?.targetId || ""}
                    onChange={(e) => updateRuntimeACPField("targetId", e.target.value)}
                  >
                    <option value="">Select a target...</option>
                    {acpTargets.map((t) => (
                      <option key={t.id} value={t.id}>
                        {t.title} ({t.id})
                      </option>
                    ))}
                  </select>
                  {acpTargets.length === 0 && (
                    <span className="entry-form-hint">No ACP targets configured. Add targets in Settings &gt; ACP.</span>
                  )}
                </label>
                <label style={{ gridColumn: "1 / -1" }}>
                  Working Directory Override
                  <input
                    placeholder="(defaults to target cwd or workspace root)"
                    value={draft.runtime?.acp?.cwd || ""}
                    onChange={(e) => updateRuntimeACPField("cwd", e.target.value || null)}
                  />
                </label>
              </>
            )}
          </div>
        </section>
      );
    }

    if (selectedSection === "models") {
      return (
        <section className="entry-editor-card">
          <h3>Models</h3>
          <div className="entry-form-grid">
            <div className="agent-config-reasoning-field" style={{ gridColumn: "1 / -1" }}>
              <span className="agent-config-reasoning-label">Executor selection</span>
              <div className="agent-config-reasoning-options" role="group" aria-label="Executor selection">
                {[{ enabled: true, label: "Automatic" }, { enabled: false, label: "Fixed model" }].map((option) => (
                  <button
                    key={option.label}
                    type="button"
                    className="agent-config-reasoning-option"
                    aria-pressed={Boolean(draft.automaticModelRouting) === option.enabled}
                    onClick={() => updateField("automaticModelRouting", option.enabled)}
                    disabled={isSaving || isACP}
                  >
                    {option.label}
                  </button>
                ))}
              </div>
              <span className="entry-form-hint">
                {!draft.automaticModelRouting
                  ? "This agent uses the executor model below. The decision provider does not evaluate its turns."
                  : semanticRoutingMode === "active"
                  ? "The decision provider chooses among configured profiles for automatic turns. The model below is used if the provider cannot choose. An explicit model selected for a turn takes precedence."
                  : semanticRoutingMode === "shadow"
                    ? "The decision provider is in shadow mode globally: it evaluates choices, but the model below is always used."
                    : "The decision provider is disabled globally. Enable executor routing in Settings > Semantic decisions to use automatic selection."}
              </span>
            </div>
            <AggregatedModelPicker
              label={draft.automaticModelRouting ? "Fallback Executor Model" : "Executor Model"}
              value={String(draft.selectedModel || "")}
              onChange={(id) => updateField("selectedModel", id)}
              aggregatedModels={aggregatedModels}
              disabled={isSaving}
              hint={modelCatalogStatus}
              includeEmptyOption={false}
            />
            <AggregatedModelPicker
              label="Planner Model"
              value={String(draft.plannerModel || "")}
              onChange={(id) => updateField("plannerModel", id)}
              aggregatedModels={aggregatedModels}
              disabled={isSaving || isACP}
              hint="When empty, the planner uses the executor model."
              emptyOptionTitle="Use executor model"
              emptyOptionSubtitle="Clear planner override"
            />
            <div className="agent-config-reasoning-field" style={{ gridColumn: "1 / -1" }}>
              <span className="agent-config-reasoning-label">Reasoning Effort</span>
              <div className="agent-config-reasoning-options" role="group" aria-label="Default reasoning effort">
                {REASONING_EFFORT_OPTIONS.map((option) => {
                  const isActive = String(draft.reasoningEffort || "") === option.value;
                  return (
                    <button
                      key={option.value || "default"}
                      type="button"
                      className="agent-config-reasoning-option"
                      aria-pressed={isActive}
                      onClick={() => updateField("reasoningEffort", option.value)}
                      disabled={isSaving || isACP}
                    >
                      {option.label}
                    </button>
                  );
                })}
              </div>
              <span className="entry-form-hint">
                Used for reasoning-capable native models when a chat turn does not override it.
              </span>
            </div>
          </div>

          {channelNodes.length > 0 && (
            <>
              <div className="agent-config-head" style={{ marginTop: 16 }}>
                <div className="agent-tools-head-copy">
                  <h4>Channel Models</h4>
                  <p className="placeholder-text">
                    Override the model used for specific channels. Channels without an override use the agent selection above.
                  </p>
                </div>
              </div>
              <div className="agent-channels-list">
                {channelNodes.map((node) => {
                  const channelId = node.channelId || node.id;
                  return (
                    <div key={node.id} className="agent-channel-row">
                      <div className="agent-channel-info">
                        <span className="agent-channel-id">
                          <span className="material-symbols-rounded agent-channel-icon">forum</span>
                          {channelId}
                        </span>
                      </div>
                      <div className="agent-channel-actions">
                        <ChannelModelSelector channelId={channelId} />
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </section>
      );
    }

    if (selectedSection === "files") {
      const viewerPath = selectedFilePath ? `${agentDisplayName || agentId}/${selectedFilePath}` : "";
      const hasSelectedContent = activeDocFileId
        ? Boolean(draft.documents[activeDocFileId]?.trim())
        : Boolean(agentFileContent?.content?.trim());
      const showMobileFileOverlay = narrowAgentFilesLayout && Boolean(selectedFilePath);

      const viewerPanel = !selectedFilePath ? (
        <div className="pft-viewer-empty">
          <span className="material-symbols-rounded pft-viewer-empty-icon">description</span>
          <p>Select an agent file to view or edit its contents</p>
        </div>
      ) : activeDocFile && activeDocFileId ? (
        <>
          <div className="pft-viewer-head">
            <span className="material-symbols-rounded pft-viewer-path-icon">description</span>
            <span className="pft-viewer-path">{viewerPath}</span>
          </div>
          <div className="pft-viewer-body agent-doc-files-viewer-body">
            <div className="agent-doc-files-editor-surface">
              <div className="agent-doc-files-editor-meta">
                <span>{activeDocFile.readOnly ? "Read-only" : "Editable"}</span>
                <span>{hasSelectedContent ? "Has content" : "Empty file"}</span>
              </div>
              <label className="agent-doc-files-editor-label">
                <span>
                  {activeDocFile.name}
                  {activeDocFile.readOnly && (
                    <span className="agent-doc-files-readonly-badge"> [Read-Only]</span>
                  )}
                </span>
                <textarea
                  rows={18}
                  value={draft.documents[activeDocFileId]}
                  onChange={(event) => updateDocumentField(activeDocFileId, event.target.value)}
                  readOnly={activeDocFile.readOnly}
                  className={activeDocFile.readOnly ? "readonly-textarea" : ""}
                />
              </label>
            </div>
          </div>
        </>
      ) : (
        <>
          <div className="pft-viewer-head">
            <span className="material-symbols-rounded pft-viewer-path-icon">description</span>
            <span className="pft-viewer-path">{viewerPath}</span>
          </div>
          <div className="pft-viewer-body agent-doc-files-viewer-body">
            <div className="agent-doc-files-editor-surface">
              <div className="agent-doc-files-editor-meta">
                <span>Read-only</span>
                <span>{agentFileContent?.sizeBytes ? `${agentFileContent.sizeBytes} bytes` : "External file"}</span>
              </div>
              <label className="agent-doc-files-editor-label">
                <span>{selectedFilePath.split("/").pop()}</span>
                <textarea
                  rows={18}
                  value={agentFileLoading ? "Loading..." : (agentFileError || agentFileContent?.content || "")}
                  readOnly
                  className="readonly-textarea"
                />
              </label>
            </div>
          </div>
        </>
      );

      return (
        <section className="entry-editor-card agent-doc-files-card">
          <h3>Agent Files</h3>
          <div className={`pft-shell agent-doc-files-shell${narrowAgentFilesLayout ? " pft-shell--narrow" : ""}`}>
            <div className="pft-tree-panel agent-doc-files-tree-panel">
              <div className="pft-tree-head">
                <span className="material-symbols-rounded pft-tree-head-icon">folder</span>
                <span className="pft-tree-head-label">{agentDisplayName || agentId}</span>
              </div>
              <div className="pft-tree-body">
                {agentFilesLoading ? (
                  <div className="pft-status">Loading…</div>
                ) : agentRootEntries === null ? (
                  <div className="pft-status pft-status-error">Failed to load files.</div>
                ) : agentRootEntries.length === 0 ? (
                  <div className="pft-status">No files found.</div>
                ) : (
                  agentRootEntries.map((entry) => (
                    <AgentFileTreeNode
                      key={entry.name}
                      agentId={agentId}
                      name={entry.name}
                      type={entry.type}
                      path={entry.name}
                      depth={0}
                      selectedPath={selectedFilePath}
                      onSelectFile={handleSelectAgentFile}
                      narrowLayout={narrowAgentFilesLayout}
                    />
                  ))
                )}
              </div>
            </div>

            {!narrowAgentFilesLayout && (
              <div className="pft-viewer-panel agent-doc-files-viewer-panel">{viewerPanel}</div>
            )}

            {showMobileFileOverlay && (
              <div
                className="pft-mobile-file-overlay"
                role="dialog"
                aria-modal="true"
                aria-labelledby="agent-files-mobile-file-title"
              >
                <div className="pft-mobile-file-overlay-inner">
                  <div className="pft-viewer-head pft-mobile-file-head">
                    <button
                      type="button"
                      className="pft-mobile-file-back"
                      onClick={closeMobileAgentFile}
                      aria-label="Close agent file"
                    >
                      <span className="material-symbols-rounded">arrow_back</span>
                    </button>
                    <span className="material-symbols-rounded pft-viewer-path-icon">description</span>
                    <span className="pft-viewer-path" id="agent-files-mobile-file-title">
                      {viewerPath}
                    </span>
                  </div>
                  <div className="pft-viewer-body pft-mobile-file-body agent-doc-files-viewer-body">
                    <div className="agent-doc-files-editor-surface">
                      <div className="agent-doc-files-editor-meta">
                        <span>{activeDocFile ? (activeDocFile.readOnly ? "Read-only" : "Editable") : "Read-only"}</span>
                        <span>
                          {activeDocFile
                            ? (hasSelectedContent ? "Has content" : "Empty file")
                            : (agentFileContent?.sizeBytes ? `${agentFileContent.sizeBytes} bytes` : "External file")}
                        </span>
                      </div>
                      <label className="agent-doc-files-editor-label">
                        <span>
                          {activeDocFile?.name || selectedFilePath.split("/").pop()}
                          {activeDocFile?.readOnly && (
                            <span className="agent-doc-files-readonly-badge"> [Read-Only]</span>
                          )}
                        </span>
                        <textarea
                          rows={18}
                          value={activeDocFile && activeDocFileId
                            ? draft.documents[activeDocFileId]
                            : (agentFileLoading ? "Loading..." : (agentFileError || agentFileContent?.content || ""))}
                          onChange={activeDocFile && activeDocFileId
                            ? (event) => updateDocumentField(activeDocFileId, event.target.value)
                            : undefined}
                          readOnly={!activeDocFile || activeDocFile.readOnly}
                          className={!activeDocFile || activeDocFile.readOnly ? "readonly-textarea" : ""}
                        />
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            )}
          </div>
        </section>
      );
    }

    if (selectedSection === "channel") {
      return (
        <section className="entry-editor-card">
          <h3>Channel Sessions</h3>
          <p className="placeholder-text">
            Telegram and Discord: control when this agent reacts in shared chats. Slash commands (e.g. <code>/model</code>) always
            apply when sent as <code>/model@YourBot</code> or without an <code>@</code> suffix. Use <code>/command@bot_username</code> to
            target a specific bot when several agents share a group.
          </p>
          <div className="entry-form-grid">
            <label style={{ gridColumn: "1 / -1" }}>
              Inbound messages (Telegram / Discord)
              <select
                value={draft.channelSessions.inboundActivation || "all"}
                onChange={(event) => updateChannelSessionField("inboundActivation", event.target.value)}
              >
                <option value="all">Respond to every message</option>
                <option value="mention_or_reply">Only @mention or reply to the bot (recommended for busy groups)</option>
              </select>
            </label>
            <label className="cron-form-toggle" style={{ gridColumn: "1 / -1" }}>
              <span>Close session after</span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={draft.channelSessions.autoCloseEnabled}
                  onChange={(event) => updateChannelSessionField("autoCloseEnabled", event.target.checked)}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>
            <label>
              Timeout (minutes)
              <input
                type="number"
                min="1"
                step="1"
                value={draft.channelSessions.autoCloseAfterMinutes}
                onChange={(event) => updateChannelSessionField("autoCloseAfterMinutes", event.target.value)}
              />
            </label>
          </div>
        </section>
      );
    }

    if (selectedSection === "danger") {
      return renderDangerSection();
    }

    if (selectedSection === "heartbeat") {
      return (
        <section className="entry-editor-card">
          <h3>Heartbeat</h3>
          <p className="placeholder-text">
            {draft.heartbeat.mode === "proactive"
              ? "Checks selected tasks and PRs and reports meaningful situations that need your attention. Actions start after your reply."
              : "Runs HEARTBEAT.md on a timer and reports checklist problems."}
          </p>
          <div className="entry-form-grid">
            <label className="cron-form-toggle" style={{ gridColumn: "1 / -1" }}>
              <span>Enabled</span>
              <span className="agent-tools-switch">
                <input
                  type="checkbox"
                  checked={draft.heartbeat.enabled}
                  onChange={(event) => updateHeartbeatField("enabled", event.target.checked)}
                />
                <span className="agent-tools-switch-track" />
              </span>
            </label>
            <label>
              Interval (minutes)
              <input
                type="number"
                min="1"
                step="1"
                value={draft.heartbeat.intervalMinutes}
                onChange={(event) => updateHeartbeatField("intervalMinutes", event.target.value)}
              />
            </label>
            <label style={{ gridColumn: "1 / -1" }}>
              HEARTBEAT.md
              <textarea
                rows={10}
                value={draft.documents.heartbeatMarkdown}
                onChange={(event) => updateDocumentField("heartbeatMarkdown", event.target.value)}
                placeholder="Describe what the automated heartbeat should verify."
              />
            </label>
          </div>

          <ProactivitySettingsFields heartbeat={draft.heartbeat} onChange={updateHeartbeatField} models={aggregatedModels} disabled={isSaving} />
          <div className="agent-config-heartbeat-status proactivity-run-status" style={{ marginTop: 12 }}>
            <h4>Recent activity</h4>
            <div>
              <strong>Last run:</strong> {formatDateTime(draft.heartbeatStatus.lastRunAt)}
            </div>
            <div>
              <strong>Last success:</strong> {formatDateTime(draft.heartbeatStatus.lastSuccessAt)}
            </div>
            <div>
              <strong>Last failure:</strong> {formatDateTime(draft.heartbeatStatus.lastFailureAt)}
            </div>
            <div>
              <strong>Last result:</strong> {statusValue(draft.heartbeatStatus.lastResult)}
            </div>
            <div>
              <strong>Last session:</strong> {statusValue(draft.heartbeatStatus.lastSessionId)}
            </div>
            <div>
              <strong>Last error:</strong> {statusValue(draft.heartbeatStatus.lastErrorMessage)}
            </div>
          </div>
        </section>
      );
    }

    return null;
  }

  return (
    <>
    <main className="settings-shell agent-settings-shell">
      <aside className="settings-side agent-settings-side">
        <div className="settings-title-row">
          <h2>Agent Config</h2>
        </div>

        <nav className="settings-nav agent-settings-nav" aria-label="Agent configuration sections">
          {AGENT_CONFIG_SECTIONS.map((item) => (
            <button
              key={item.id}
              type="button"
              className={`settings-nav-item ${selectedSection === item.id ? "active" : ""}${(item as any).danger ? " settings-nav-item--danger" : ""}`}
              aria-current={selectedSection === item.id ? "page" : undefined}
              onClick={() => setSelectedSection(item.id)}
            >
              <span className="material-symbols-rounded settings-nav-icon">{item.icon}</span>
              <span>{item.title}</span>
            </button>
          ))}
        </nav>
      </aside>

      <section className="settings-main agent-settings-main">
        <header className="settings-main-head agent-settings-main-head">
          <div className="settings-main-status">
            <span>{statusText}</span>
          </div>
        </header>

        <div className={`settings-toast ${hasChanges ? "settings-toast--visible" : ""}`}>
          <span className="settings-toast-label">Unsaved changes</span>
          <div className="settings-toast-actions">
            <button type="button" className="danger hover-levitate" onClick={cancelChanges}>
              Cancel
            </button>
            <button type="button" className="hover-levitate" onClick={saveConfig} disabled={isSaving}>
              {isSaving ? "Saving..." : "Apply"}
            </button>
          </div>
        </div>

        {isLoading ? (
          <p className="placeholder-text">Loading...</p>
        ) : (
          renderSectionContent()
        )}
      </section>
    </main>
    </>
  );
}
