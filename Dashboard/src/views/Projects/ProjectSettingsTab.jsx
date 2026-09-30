import React, { useState, useMemo, useEffect, useRef, useCallback } from "react";
import {
    emergencyStopProject,
    attachMeshSharedProjectMember,
    createMeshSharedProject,
    deleteMeshSharedProject,
    fetchMeshState,
    fetchSourceControlProviders,
    fetchTaskSyncProviders,
    fetchProjectTaskSync,
    linkProjectTaskSync,
    unlinkProjectTaskSync,
    syncProjectTasksNow,
    fetchProjectTaskSyncToken,
    setProjectTaskSyncToken,
    clearProjectTaskSyncToken,
    createProjectSourceControlWorktree
} from "../../api";
import { PROJECT_IMAGE_ICON_MAX_BYTES, ProjectIcon, isProjectImageIcon } from "../../components/ProjectIcon";
import { WorkspaceDirectoriesEditor } from "./WorkspaceDirectoriesEditor";
import { TaskPickupRulesEditor } from "./TaskPickupRulesEditor";
import { clonePickupRules, pickupRulesError } from "./taskPickupRules";

const SETTINGS_TABS = [
    { id: "general", title: "General", icon: "settings" },
    { id: "actors", title: "Actors", icon: "group" },
    { id: "loop", title: "Task Loop Mode", icon: "sync" },
    { id: "autopilot", title: "Workers", icon: "robot_2" },
    { id: "review", title: "Git Worktree & Review", icon: "rate_review" },
    { id: "task_sync", title: "Task Sync", icon: "sync_alt" },
    { id: "mesh", title: "Mesh Sharing", icon: "hub" }
];

const APPROVAL_MODES = [
    {
        id: "human",
        label: "Human Approve",
        icon: "person_check",
        description: "Notify the dashboard and task creator. Requires manual approval."
    },
    {
        id: "auto",
        label: "Auto Approve",
        icon: "check_circle",
        description: "Automatically merge and mark as done when the task reaches review."
    },
    {
        id: "agent",
        label: "Agent Approve",
        icon: "smart_toy",
        description: "Delegate review to the actor with the Reviewer system role in the team."
    }
];

const AUTOPILOT_MODES = [
    {
        id: "assistive",
        label: "Assistive",
        icon: "support_agent",
        description: "Plan tagged tasks and run one safe task at a time."
    },
    {
        id: "sequential",
        label: "Sequential",
        icon: "view_agenda",
        description: "Pick and execute one task from backlog at a time."
    },
    {
        id: "parallel",
        label: "Parallel",
        icon: "view_quilt",
        description: "Pick and execute multiple backlog tasks in parallel."
    }
];

const AUTOPILOT_PERMISSIONS = [
    { id: "canUseWeb", label: "Web", icon: "travel_explore" },
    { id: "canEditFiles", label: "Files", icon: "edit_document" },
    { id: "canRunCommands", label: "Commands", icon: "terminal" },
    { id: "canStartLocalhost", label: "Localhost", icon: "dns" },
    { id: "canCommit", label: "Commit", icon: "commit" },
    { id: "canPush", label: "Push", icon: "upload" }
];

const MESH_PERMISSION_OPTIONS = [
    { id: "project.read", label: "Project read" },
    { id: "task.update", label: "Task update" },
    { id: "task.assign", label: "Task assign" },
    { id: "node.rpc", label: "Node RPC" },
    { id: "project.sync", label: "Project sync" }
];

const PROJECT_ICONS = [
    "folder", "rocket_launch", "code", "terminal", "science",
    "deployed_code", "bug_report", "psychology", "smart_toy", "extension",
    "database", "cloud", "language", "brush", "analytics",
    "school", "build", "architecture", "api", "hub",
    "storage", "monitoring", "security", "memory", "web"
];

const PROJECT_ICON_ACCEPT = "image/png,image/jpeg,image/webp,image/gif";

const DEFAULT_SOURCE_CONTROL_PROVIDER = {
    id: "git-cli",
    displayName: "Git CLI",
    capabilities: [
        "branch_diff",
        "inspect_repository",
        "merge",
        "restore",
        "working_tree_diff",
        "working_tree_status",
        "worktrees"
    ]
};

const LOOP_MODE_OPTIONS = [
    {
        id: "human",
        label: "Human in the Loop",
        icon: "person",
        description: "When an agent needs input, the question is routed to the dashboard or source channel for a human to answer."
    },
    {
        id: "agent",
        label: "Agent in the Loop",
        icon: "smart_toy",
        description: "When an agent needs input, the question is routed to the project manager actor or the assigned team for autonomous resolution."
    }
];

const TASK_SYNC_STATUS_FIELDS = [
    { id: "pending_approval", label: "Pending approval", placeholder: "Todo" },
    { id: "backlog", label: "Backlog", placeholder: "Todo" },
    { id: "ready", label: "Ready", placeholder: "Todo" },
    { id: "in_progress", label: "In progress", placeholder: "In Progress" },
    { id: "waiting_input", label: "Waiting input", placeholder: "In Progress" },
    { id: "blocked", label: "Blocked", placeholder: "In Progress" },
    { id: "needs_review", label: "Needs review", placeholder: "In Progress" },
    { id: "done", label: "Done", placeholder: "Done" },
    { id: "cancelled", label: "Cancelled", placeholder: "Done" }
];

function SloppyStatusDropdown({ value, onChange }) {
    const [open, setOpen] = useState(false);
    const ref = useRef(null);
    const selected = TASK_SYNC_STATUS_FIELDS.find((field) => field.id === value);

    useEffect(() => {
        if (!open) return;
        function handleClick(e) {
            if (ref.current && !ref.current.contains(e.target)) {
                setOpen(false);
            }
        }
        document.addEventListener("mousedown", handleClick);
        return () => document.removeEventListener("mousedown", handleClick);
    }, [open]);

    return (
        <div className="actor-team-search-wrap task-sync-status-dropdown" ref={ref}>
            <button
                type="button"
                className="actor-team-search task-sync-status-dropdown-button"
                onClick={() => setOpen((next) => !next)}
            >
                <span>{selected?.label || "Automatic"}</span>
                <span className="material-symbols-rounded" aria-hidden="true">expand_more</span>
            </button>
            {open && (
                <ul className="actor-team-dropdown">
                    <li
                        className={`actor-team-dropdown-item ${!value ? "selected" : ""}`}
                        onMouseDown={(e) => {
                            e.preventDefault();
                            onChange("");
                            setOpen(false);
                        }}
                    >
                        <span className="actor-team-dropdown-name">Automatic</span>
                        <span className="actor-team-dropdown-id">Recommended</span>
                        {!value && <span className="actor-team-dropdown-check">✓</span>}
                    </li>
                    {TASK_SYNC_STATUS_FIELDS.map((field) => (
                        <li
                            key={field.id}
                            className={`actor-team-dropdown-item ${field.id === value ? "selected" : ""}`}
                            onMouseDown={(e) => {
                                e.preventDefault();
                                onChange(field.id);
                                setOpen(false);
                            }}
                        >
                            <span className="actor-team-dropdown-name">{field.label}</span>
                            <span className="actor-team-dropdown-id">{field.id}</span>
                            {field.id === value && <span className="actor-team-dropdown-check">✓</span>}
                        </li>
                    ))}
                </ul>
            )}
        </div>
    );
}

function SourceControlProviderDropdown({ providers, value, onChange }) {
    const [open, setOpen] = useState(false);
    const ref = useRef(null);
    const selected = providers.find((provider) => provider.id === value) || providers[0] || DEFAULT_SOURCE_CONTROL_PROVIDER;

    useEffect(() => {
        if (!open) return;
        function handleClick(e) {
            if (ref.current && !ref.current.contains(e.target)) {
                setOpen(false);
            }
        }
        document.addEventListener("mousedown", handleClick);
        return () => document.removeEventListener("mousedown", handleClick);
    }, [open]);

    return (
        <div className="actor-team-search-wrap source-control-provider-dropdown" ref={ref}>
            <button
                type="button"
                className="actor-team-search source-control-provider-dropdown-button"
                onClick={() => setOpen((next) => !next)}
            >
                <span className="source-control-provider-current">
                    <span>{selected.displayName || selected.id}</span>
                    <small>{selected.id}</small>
                </span>
                <span className="material-symbols-rounded" aria-hidden="true">expand_more</span>
            </button>
            {open && (
                <ul className="actor-team-dropdown source-control-provider-options">
                    {providers.map((provider) => {
                        const active = provider.id === selected.id;
                        return (
                            <li
                                key={provider.id}
                                className={`actor-team-dropdown-item ${active ? "selected" : ""}`}
                                onMouseDown={(e) => {
                                    e.preventDefault();
                                    onChange(provider.id);
                                    setOpen(false);
                                }}
                            >
                                <span className="actor-team-dropdown-name">{provider.displayName || provider.id}</span>
                                <span className="actor-team-dropdown-id">{provider.id}</span>
                                {active && <span className="actor-team-dropdown-check">✓</span>}
                            </li>
                        );
                    })}
                </ul>
            )}
        </div>
    );
}

function AgentPickerDropdown({ agents, value, placeholder, onChange }) {
    const [open, setOpen] = useState(false);
    const ref = useRef(null);
    const selected = agents.find((agent) => agent.id === value);

    useEffect(() => {
        if (!open) return;
        function handleClick(e) {
            if (ref.current && !ref.current.contains(e.target)) {
                setOpen(false);
            }
        }
        document.addEventListener("mousedown", handleClick);
        return () => document.removeEventListener("mousedown", handleClick);
    }, [open]);

    return (
        <div className="actor-team-search-wrap autopilot-agent-dropdown" ref={ref}>
            <button
                type="button"
                className="actor-team-search autopilot-agent-dropdown-button"
                onClick={() => setOpen((next) => !next)}
            >
                <span className="source-control-provider-current">
                    <span>{selected?.label || value || placeholder}</span>
                    <small>{selected?.id || value || "not set"}</small>
                </span>
                <span className="material-symbols-rounded" aria-hidden="true">expand_more</span>
            </button>
            {open && (
                <ul className="actor-team-dropdown autopilot-agent-options">
                    <li
                        className={`actor-team-dropdown-item ${!value ? "selected" : ""}`}
                        onMouseDown={(e) => {
                            e.preventDefault();
                            onChange("");
                            setOpen(false);
                        }}
                    >
                        <span className="actor-team-dropdown-name">{placeholder}</span>
                        <span className="actor-team-dropdown-id">none</span>
                        {!value && <span className="actor-team-dropdown-check">✓</span>}
                    </li>
                    {agents.map((agent) => {
                        const active = agent.id === value;
                        return (
                            <li
                                key={agent.id}
                                className={`actor-team-dropdown-item ${active ? "selected" : ""}`}
                                onMouseDown={(e) => {
                                    e.preventDefault();
                                    onChange(agent.id);
                                    setOpen(false);
                                }}
                            >
                                <span className="actor-team-dropdown-name">{agent.label}</span>
                                <span className="actor-team-dropdown-id">{agent.id}</span>
                                {active && <span className="actor-team-dropdown-check">✓</span>}
                            </li>
                        );
                    })}
                </ul>
            )}
        </div>
    );
}

function parseList(value) {
    return String(value || "")
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);
}

function toggleListValue(values, value) {
    const set = new Set(Array.isArray(values) ? values : []);
    if (set.has(value)) {
        set.delete(value);
    } else {
        set.add(value);
    }
    return Array.from(set);
}

function listText(values) {
    return Array.isArray(values) ? values.join(", ") : "";
}

function cloneAutopilotSettings(project) {
    const settings = project?.autopilotSettings || {};
    return {
        enabled: Boolean(settings.enabled),
        mode: settings.mode || "assistive",
        defaultAgentId: settings.defaultAgentId || "",
        reviewerAgentId: settings.reviewerAgentId || "",
        includedTags: Array.isArray(settings.includedTags) ? [...settings.includedTags] : [],
        ignoredTags: Array.isArray(settings.ignoredTags) ? [...settings.ignoredTags] : [],
        trustedAuthors: Array.isArray(settings.trustedAuthors) ? [...settings.trustedAuthors] : [],
        pickupRules: clonePickupRules(settings.pickupRules),
        maxParallelTasks: Number.isFinite(Number(settings.maxParallelTasks))
            ? Math.max(1, Number(settings.maxParallelTasks))
            : 1,
        canUseWeb: Boolean(settings.canUseWeb),
        canEditFiles: Boolean(settings.canEditFiles),
        canRunCommands: Boolean(settings.canRunCommands),
        canStartLocalhost: Boolean(settings.canStartLocalhost),
        canCommit: Boolean(settings.canCommit),
        canPush: Boolean(settings.canPush)
    };
}

function cloneDraft(project) {
    const directoryPaths = Array.isArray(project?.directoryPaths) && project.directoryPaths.length > 0
        ? [...project.directoryPaths]
        : (project?.repoPath ? [project.repoPath] : []);
    return {
        name: project?.name ?? "",
        icon: project?.icon ?? "",
        models: Array.isArray(project?.models) ? [...project.models] : [],
        agentFiles: Array.isArray(project?.agentFiles) ? [...project.agentFiles] : [],
        heartbeat: {
            enabled: Boolean(project?.heartbeat?.enabled),
            intervalMinutes: Number.isFinite(Number(project?.heartbeat?.intervalMinutes))
                ? Number(project.heartbeat.intervalMinutes)
                : 5
        },
        repoPath: project?.repoPath ?? "",
        kind: project?.kind === "workspace" ? "workspace" : "project",
        directoryPaths,
        sourceControlProviderId: project?.sourceControlProviderId ?? DEFAULT_SOURCE_CONTROL_PROVIDER.id,
        reviewSettings: {
            enabled: Boolean(project?.reviewSettings?.enabled),
            approvalMode: project?.reviewSettings?.approvalMode ?? "human",
            autonomousMode: project?.reviewSettings?.autonomousMode ?? "off"
        },
        automaticTaskPickupEnabled: project?.automaticTaskPickupEnabled !== false,
        autopilotSettings: cloneAutopilotSettings(project),
        taskLoopMode: project?.taskLoopMode ?? "human",
        actors: Array.isArray(project?.actors) ? [...project.actors] : [],
        teams: Array.isArray(project?.teams) ? [...project.teams] : []
    };
}

function cloneTaskSyncDraft(project) {
    const settings = project?.taskSyncSettings || {};
    return {
        enabled: Boolean(settings.enabled),
        providerId: settings.providerId || "github",
        repositoryURL: settings.repositoryURL || "",
        repositorySlug: settings.repositorySlug || "",
        projectURL: settings.projectURL || "",
        projectNodeId: settings.projectNodeId || "",
        defaultRepo: settings.defaultRepo || "",
        source: settings.source || { kind: "query", value: "", displayName: "", url: "" },
        tokenMode: settings.tokenMode || "inherit",
        statusMappings: { ...(settings.statusMappings || {}) },
        inboundStatusMappings: { ...(settings.inboundStatusMappings || settings.statusMappings || {}) },
        linkedProjects: Array.isArray(settings.linkedProjects) ? [...settings.linkedProjects] : [],
        syncSchedule: {
            enabled: Boolean(settings.syncSchedule?.enabled),
            intervalMinutes: Number.isFinite(Number(settings.syncSchedule?.intervalMinutes))
                ? Number(settings.syncSchedule.intervalMinutes)
                : 15,
            lastRunAt: settings.syncSchedule?.lastRunAt || null
        },
        health: settings.health || {},
        webhook: settings.webhook || {}
    };
}

function inferStartrekSourceKind(value) {
    const source = String(value || "").trim();
    if (/^(filter:)?\d+$/i.test(source) || /[?&](filter|filterId)=/i.test(source) || /\/filters\//i.test(source)) {
        return "saved_filter";
    }
    if (/^[A-Z][A-Z0-9_]+$/.test(source) || /^https?:\/\/st\.yandex-team\.ru\/[A-Z][A-Z0-9_]+\/?$/i.test(source)) {
        return "queue";
    }
    return "query";
}

function normalizedExternalStatusKey(value) {
    return String(value || "").trim().replace(/\s+/g, " ").toLowerCase();
}

function preferredExternalStatusLabel(current, candidate) {
    if (!current) return candidate;
    const currentHasCase = current !== current.toLowerCase();
    const candidateHasCase = candidate !== candidate.toLowerCase();
    return candidateHasCase && !currentHasCase ? candidate : current;
}

export function ProjectSettingsTab({
    project,
    onUpdateProject,
    deleteProject,
    onArchiveProject,
    onReplaceProject,
    openAddChannelModal,
    removeProjectChannel,
    availableActors = [],
    availableTeams = []
}) {
    const [emergencyStopBusy, setEmergencyStopBusy] = useState(false);
    const [emergencyStopStatus, setEmergencyStopStatus] = useState("");
    const [selectedSettings, setSelectedSettings] = useState("general");
    const [draft, setDraft] = useState(() => cloneDraft(project));
    const [statusText, setStatusText] = useState("");
    const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
    const [deleteConfirmText, setDeleteConfirmText] = useState("");
    const [actorSearch, setActorSearch] = useState("");
    const [actorDropdownOpen, setActorDropdownOpen] = useState(false);
    const actorSearchRef = useRef(null);
    const [teamSearch, setTeamSearch] = useState("");
    const [teamDropdownOpen, setTeamDropdownOpen] = useState(false);
    const teamSearchRef = useRef(null);
    const iconUploadRef = useRef(null);
    const [iconUploadStatus, setIconUploadStatus] = useState("");
    const [taskSyncDraft, setTaskSyncDraft] = useState(() => cloneTaskSyncDraft(project));
    const [savedTaskSyncDraft, setSavedTaskSyncDraft] = useState(() => cloneTaskSyncDraft(project));
    const [taskSyncToken, setTaskSyncToken] = useState("");
    const [taskSyncTokenStatus, setTaskSyncTokenStatus] = useState(null);
    const [taskSyncBusy, setTaskSyncBusy] = useState(false);
    const [sourceControlProviders, setSourceControlProviders] = useState([DEFAULT_SOURCE_CONTROL_PROVIDER]);
    const [taskSyncProviders, setTaskSyncProviders] = useState([
        { id: "github", displayName: "GitHub Projects", sourceKinds: [], capabilities: [] }
    ]);
    const [debugWorktreeOpen, setDebugWorktreeOpen] = useState(false);
    const [debugWorktreeName, setDebugWorktreeName] = useState("");
    const [debugWorktreeStatus, setDebugWorktreeStatus] = useState("");
    const [debugWorktreeResult, setDebugWorktreeResult] = useState(null);
    const [debugWorktreeBusy, setDebugWorktreeBusy] = useState(false);
    const [meshState, setMeshState] = useState(null);
    const [meshStatus, setMeshStatus] = useState("");
    const [meshBusy, setMeshBusy] = useState("");
    const [meshSelectedNodeId, setMeshSelectedNodeId] = useState("");
    const [meshMemberPath, setMeshMemberPath] = useState("");
    const [meshMemberRole, setMeshMemberRole] = useState("worker");
    const [meshMemberPermissions, setMeshMemberPermissions] = useState(["project.read", "task.update"]);

    useEffect(() => {
        setDraft(cloneDraft(project));
        const nextTaskSyncDraft = cloneTaskSyncDraft(project);
        setTaskSyncDraft(nextTaskSyncDraft);
        setSavedTaskSyncDraft(nextTaskSyncDraft);
        setIconUploadStatus("");
        setDebugWorktreeName("");
        setDebugWorktreeStatus("");
        setDebugWorktreeResult(null);
    }, [project?.id, project?.updatedAt]);

    const loadMeshState = useCallback(async () => {
        const state = await fetchMeshState();
        setMeshState(state);
        const nodes = Array.isArray(state?.nodes) ? state.nodes : [];
        setMeshSelectedNodeId((current) => {
            if (current && nodes.some((node) => String(node?.id || "") === current)) {
                return current;
            }
            return String(nodes[0]?.id || "");
        });
    }, []);

    useEffect(() => {
        let cancelled = false;
        async function load() {
            const state = await fetchMeshState();
            if (cancelled) return;
            setMeshState(state);
            const nodes = Array.isArray(state?.nodes) ? state.nodes : [];
            setMeshSelectedNodeId((current) => current || String(nodes[0]?.id || ""));
        }
        load();
        return () => { cancelled = true; };
    }, [project.id, project.updatedAt]);

    useEffect(() => {
        let cancelled = false;
        async function loadTaskSync() {
            const settings = await fetchProjectTaskSync(project.id);
            const providerId = settings?.providerId || "github";
            const tokenStatus = await fetchProjectTaskSyncToken(project.id, providerId);
            if (cancelled) return;
            if (settings) {
                const nextTaskSyncDraft = cloneTaskSyncDraft({ taskSyncSettings: settings });
                setTaskSyncDraft(nextTaskSyncDraft);
                setSavedTaskSyncDraft(nextTaskSyncDraft);
            }
            if (tokenStatus) setTaskSyncTokenStatus(tokenStatus);
        }
        loadTaskSync();
        return () => { cancelled = true; };
    }, [project.id, project.updatedAt]);

    useEffect(() => {
        let cancelled = false;
        fetchTaskSyncProviders().then((providers) => {
            if (cancelled || !Array.isArray(providers) || providers.length === 0) return;
            setTaskSyncProviders(providers);
        });
        return () => { cancelled = true; };
    }, []);

    useEffect(() => {
        let cancelled = false;
        async function loadSourceControlProviders() {
            const providers = await fetchSourceControlProviders();
            if (cancelled || !Array.isArray(providers)) return;
            const nextProviders = [DEFAULT_SOURCE_CONTROL_PROVIDER];
            const seen = new Set(nextProviders.map((provider) => provider.id));
            providers.forEach((provider) => {
                const id = String(provider?.id || "").trim();
                if (!id) return;
                const normalizedProvider = {
                    id,
                    displayName: String(provider?.displayName || id).trim() || id,
                    capabilities: Array.isArray(provider?.capabilities) ? provider.capabilities : []
                };
                if (seen.has(id)) {
                    const index = nextProviders.findIndex((item) => item.id === id);
                    if (index >= 0) nextProviders[index] = normalizedProvider;
                    return;
                }
                nextProviders.push(normalizedProvider);
                seen.add(id);
            });
            setSourceControlProviders(nextProviders);
        }
        loadSourceControlProviders();
        return () => { cancelled = true; };
    }, []);

    const hasProjectChanges = useMemo(() => {
        const saved = cloneDraft(project);
        return JSON.stringify(draft) !== JSON.stringify(saved);
    }, [draft, project]);
    const hasTaskSyncChanges = useMemo(
        () => JSON.stringify(taskSyncDraft) !== JSON.stringify(savedTaskSyncDraft),
        [taskSyncDraft, savedTaskSyncDraft]
    );
    const hasChanges = hasProjectChanges || hasTaskSyncChanges || Boolean(taskSyncToken.trim());

    const agentOptions = useMemo(() => {
        const options = [];
        const seen = new Set();
        availableActors.forEach((actor) => {
            const agentId = String(actor?.linkedAgentId || actor?.agentId || "").trim();
            if (!agentId || seen.has(agentId)) return;
            seen.add(agentId);
            options.push({
                id: agentId,
                label: String(actor?.displayName || actor?.name || agentId).trim() || agentId
            });
        });
        [draft.autopilotSettings.defaultAgentId, draft.autopilotSettings.reviewerAgentId].forEach((agentId) => {
            const id = String(agentId || "").trim();
            if (!id || seen.has(id)) return;
            seen.add(id);
            options.push({ id, label: id });
        });
        return options;
    }, [availableActors, draft.autopilotSettings.defaultAgentId, draft.autopilotSettings.reviewerAgentId]);
    const meshNodes = useMemo(
        () => Array.isArray(meshState?.nodes) ? meshState.nodes : [],
        [meshState]
    );
    const meshSharedProjects = useMemo(
        () => Array.isArray(meshState?.sharedProjects) ? meshState.sharedProjects : [],
        [meshState]
    );
    const meshProject = useMemo(() => {
        const projectId = String(project?.id || "").trim();
        const projectName = String(project?.name || "").trim();
        return meshSharedProjects.find((item) => (
            String(item?.id || "") === projectId ||
            String(item?.name || "") === projectName
        )) || null;
    }, [meshSharedProjects, project?.id, project?.name]);
    const meshProjectMembers = useMemo(
        () => Array.isArray(meshProject?.members) ? meshProject.members : [],
        [meshProject]
    );

    function mutateDraft(mutator) {
        setDraft((prev) => {
            const next = JSON.parse(JSON.stringify(prev));
            mutator(next);
            return next;
        });
    }

    function mutateTaskSync(mutator) {
        setTaskSyncDraft((prev) => {
            const next = JSON.parse(JSON.stringify(prev));
            mutator(next);
            return next;
        });
    }

    function sanitizedStatusMappings(mappings) {
        return Object.entries(mappings || {}).reduce((acc, [key, value]) => {
            const normalizedKey = String(key || "").trim().toLowerCase();
            const normalizedValue = String(value || "").trim();
            if (normalizedKey && normalizedValue) acc[normalizedKey] = normalizedValue;
            return acc;
        }, {});
    }

    function applyTaskSyncResponse(result) {
        const settings = result?.settings || result?.project?.taskSyncSettings;
        if (settings) {
            const nextTaskSyncDraft = cloneTaskSyncDraft({ taskSyncSettings: settings });
            setTaskSyncDraft(nextTaskSyncDraft);
            setSavedTaskSyncDraft(nextTaskSyncDraft);
        }
        if (result?.project && onReplaceProject) {
            onReplaceProject(result.project);
        }
    }

    function taskSyncLinkPayload(source, tokenMode) {
        const providerId = source.providerId || "github";
        const isStartrek = providerId === "startrek";
        const sourceValue = String(source.source?.value || "").trim();
        return {
            providerId,
            repositoryURL: isStartrek ? null : source.repositoryURL.trim() || source.repositorySlug.trim() || null,
            defaultRepo: isStartrek ? null : source.defaultRepo.trim() || source.repositorySlug.trim() || null,
            source: isStartrek ? {
                kind: inferStartrekSourceKind(sourceValue),
                value: sourceValue
            } : null,
            tokenMode,
            inboundStatusMappings: sanitizedStatusMappings(source.inboundStatusMappings),
            statusMappings: sanitizedStatusMappings(source.statusMappings),
            syncSchedule: {
                enabled: Boolean(source.syncSchedule?.enabled),
                intervalMinutes: Math.max(1, Number(source.syncSchedule?.intervalMinutes) || 15)
            }
        };
    }

    async function saveTaskSync(source) {
        const providerId = source.providerId || "github";
        const isStartrek = providerId === "startrek";
        const sourceValue = String(source.source?.value || "").trim();
        if (isStartrek && !sourceValue) {
            throw new Error("Enter a StartTrack queue, saved filter, board query, or Tracker query.");
        }

        let tokenMode = source.tokenMode || "inherit";
        const token = taskSyncToken.trim();
        if (token) {
            const tokenStatus = await setProjectTaskSyncToken(project.id, { token }, providerId);
            setTaskSyncTokenStatus(tokenStatus);
            setTaskSyncToken("");
            tokenMode = "override";
        }

        setStatusText("Saving and checking the external source...");
        const linked = await linkProjectTaskSync(project.id, taskSyncLinkPayload(source, tokenMode));
        applyTaskSyncResponse(linked);

        setStatusText("Source linked. Running the first sync...");
        const synced = await syncProjectTasksNow(project.id);
        if (synced?.message) {
            throw new Error(String(synced.message));
        }
        return `Settings saved · ${Number(synced?.imported || 0)} imported · ${Number(synced?.updated || 0)} updated`;
    }

    async function saveSettings() {
        const rulesError = pickupRulesError(draft.autopilotSettings.pickupRules);
        if (rulesError) { setStatusText(rulesError); return; }
        if (hasProjectChanges && draft.kind === "workspace" && draft.directoryPaths.length < 2) {
            setStatusText("A workspace requires at least two directories");
            return;
        }
        const projectDraft = cloneDraft({ ...project, ...draft });
        const syncDraft = cloneTaskSyncDraft({ taskSyncSettings: taskSyncDraft });
        let saved = true;
        let successMessage = "Settings saved";
        let failureMessage = "";

        if (hasTaskSyncChanges || taskSyncToken.trim()) {
            setTaskSyncBusy(true);
            try {
                successMessage = await saveTaskSync(syncDraft);
            } catch (error) {
                saved = false;
                failureMessage = error?.message || "Failed to save task sync settings";
            } finally {
                setTaskSyncBusy(false);
            }
        }

        if (hasProjectChanges) {
            const result = await onUpdateProject({
                name: projectDraft.name.trim() || undefined,
                icon: projectDraft.icon.trim(),
                models: projectDraft.models,
                agentFiles: projectDraft.agentFiles,
                heartbeat: projectDraft.heartbeat,
                kind: projectDraft.kind,
                directoryPaths: projectDraft.kind === "workspace"
                    ? projectDraft.directoryPaths
                    : (projectDraft.repoPath.trim() ? [projectDraft.repoPath.trim()] : []),
                sourceControlProviderId: projectDraft.sourceControlProviderId || DEFAULT_SOURCE_CONTROL_PROVIDER.id,
                reviewSettings: projectDraft.reviewSettings,
                automaticTaskPickupEnabled: projectDraft.automaticTaskPickupEnabled,
                autopilotSettings: projectDraft.autopilotSettings,
                taskLoopMode: projectDraft.taskLoopMode,
                actors: projectDraft.actors,
                teams: projectDraft.teams
            });
            if (result) {
                setDraft(cloneDraft(result));
            } else {
                saved = false;
            }
        }

        if (saved) {
            setStatusText(successMessage);
        } else {
            setStatusText(failureMessage || "Failed to save settings");
        }
    }

    function cancelChanges() {
        setDraft(cloneDraft(project));
        setTaskSyncDraft(cloneTaskSyncDraft({ taskSyncSettings: savedTaskSyncDraft }));
        setIconUploadStatus("");
        setStatusText("Changes cancelled");
    }

    function openDebugWorktreeModal() {
        setDebugWorktreeName(`debug-${project.id}`);
        setDebugWorktreeStatus("");
        setDebugWorktreeResult(null);
        setDebugWorktreeOpen(true);
    }

    async function createDebugWorktree(event) {
        event.preventDefault();
        const taskId = debugWorktreeName.trim();
        if (!taskId) {
            setDebugWorktreeStatus("Enter a worktree name.");
            return;
        }
        setDebugWorktreeBusy(true);
        setDebugWorktreeStatus("Creating worktree...");
        setDebugWorktreeResult(null);
        try {
            const result = await createProjectSourceControlWorktree(project.id, { taskId });
            const worktree = result?.worktree;
            if (worktree?.worktreePath && worktree?.branchName) {
                setDebugWorktreeResult(worktree);
                setDebugWorktreeStatus("Worktree created");
                return;
            }
            setDebugWorktreeStatus(result?.message || "Failed to create worktree");
        } catch (error) {
            setDebugWorktreeStatus(error?.message || "Failed to create worktree");
        } finally {
            setDebugWorktreeBusy(false);
        }
    }

    async function enableMeshSharing() {
        const repoTarget = draft.repoPath.trim() || project.repoPath || "";
        if (!repoTarget) {
            setMeshStatus("Set a workspace path before enabling mesh sharing.");
            return;
        }
        setMeshBusy("enable");
        setMeshStatus("Enabling mesh sharing...");
        try {
            const result = await createMeshSharedProject({
                id: project.id,
                name: draft.name.trim() || project.name || project.id,
                repoUrl: repoTarget,
                defaultBranch: "main"
            });
            if (!result) {
                setMeshStatus("Mesh sharing could not be enabled.");
                return;
            }
            setMeshStatus("Mesh sharing enabled.");
            await loadMeshState();
        } catch (error) {
            setMeshStatus(error?.message || "Mesh sharing could not be enabled.");
        } finally {
            setMeshBusy("");
        }
    }

    async function disableMeshSharing() {
        if (!meshProject?.id) {
            return;
        }
        setMeshBusy("disable");
        setMeshStatus("Disabling mesh sharing...");
        try {
            const ok = await deleteMeshSharedProject(meshProject.id);
            if (!ok) {
                setMeshStatus("Mesh sharing could not be disabled.");
                return;
            }
            setMeshStatus("Mesh sharing disabled.");
            await loadMeshState();
        } catch (error) {
            setMeshStatus(error?.message || "Mesh sharing could not be disabled.");
        } finally {
            setMeshBusy("");
        }
    }

    async function attachMeshMember() {
        const nodeId = meshSelectedNodeId.trim();
        const localRepoPath = meshMemberPath.trim();
        if (!meshProject?.id || !nodeId || !localRepoPath) {
            setMeshStatus("Choose a node and local checkout path.");
            return;
        }
        setMeshBusy("attach");
        setMeshStatus("Attaching node...");
        try {
            const result = await attachMeshSharedProjectMember(meshProject.id, {
                nodeId,
                localRepoPath,
                role: meshMemberRole.trim() || "worker",
                permissions: meshMemberPermissions
            });
            if (!result) {
                setMeshStatus("Node could not be attached to this project.");
                return;
            }
            setMeshMemberPath("");
            setMeshStatus("Node attached to mesh project.");
            await loadMeshState();
        } catch (error) {
            setMeshStatus(error?.message || "Node could not be attached to this project.");
        } finally {
            setMeshBusy("");
        }
    }

    function handleIconUpload(event) {
        const file = event.target.files?.[0];
        event.target.value = "";
        if (!file) return;

        if (!PROJECT_ICON_ACCEPT.split(",").includes(file.type)) {
            setIconUploadStatus("Use PNG, JPEG, WebP, or GIF.");
            return;
        }

        if (file.size > PROJECT_IMAGE_ICON_MAX_BYTES) {
            setIconUploadStatus("Image must be 512 KB or smaller.");
            return;
        }

        const reader = new FileReader();
        reader.onload = () => {
            const value = typeof reader.result === "string" ? reader.result : "";
            if (!isProjectImageIcon(value)) {
                setIconUploadStatus("Could not read this image.");
                return;
            }
            mutateDraft((d) => { d.icon = value; });
            setIconUploadStatus(file.name);
        };
        reader.onerror = () => {
            setIconUploadStatus("Could not read this image.");
        };
        reader.readAsDataURL(file);
    }

    function renderGeneral() {
        const workspacePath = draft.kind === "workspace"
            ? String(draft.directoryPaths[0] || "").trim()
            : draft.repoPath.trim();
        return (
            <>
                <section className="entry-editor-card">
                    <h3>Project Identity</h3>
                    <div className="entry-form-grid">
                        <label style={{ gridColumn: "1 / -1" }}>
                            Project Name
                            <input
                                type="text"
                                value={draft.name}
                                onChange={(e) => mutateDraft((d) => { d.name = e.target.value; })}
                                placeholder="My Project"
                            />
                        </label>
                    </div>

                    <div style={{ marginTop: 16 }}>
                        <p className="settings-general-label">Project Icon</p>
                        <div className="settings-icon-grid">
                            {PROJECT_ICONS.map((iconName) => {
                                const active = draft.icon === iconName;
                                return (
                                    <button
                                        key={iconName}
                                        type="button"
                                        className={`settings-icon-option ${active ? "active" : ""}`}
                                        aria-pressed={active}
                                        aria-label={`Project icon: ${iconName}`}
                                        onClick={() => {
                                            mutateDraft((d) => { d.icon = active ? "" : iconName; });
                                            setIconUploadStatus("");
                                        }}
                                        title={iconName}
                                    >
                                        <span className="material-symbols-rounded">{iconName}</span>
                                    </button>
                                );
                            })}
                        </div>
                        <div className="settings-icon-upload-row">
                            <input
                                ref={iconUploadRef}
                                type="file"
                                accept={PROJECT_ICON_ACCEPT}
                                className="settings-icon-upload-input"
                                onChange={handleIconUpload}
                            />
                            <button
                                type="button"
                                className={`settings-icon-upload-button ${isProjectImageIcon(draft.icon) ? "active" : ""}`}
                                onClick={() => iconUploadRef.current?.click()}
                            >
                                <span className="material-symbols-rounded" aria-hidden="true">add_photo_alternate</span>
                                <span>Upload image</span>
                            </button>
                            {isProjectImageIcon(draft.icon) ? (
                                <button
                                    type="button"
                                    className="settings-icon-clear-button"
                                    onClick={() => {
                                        mutateDraft((d) => { d.icon = ""; });
                                        setIconUploadStatus("");
                                    }}
                                >
                                    Clear image
                                </button>
                            ) : null}
                            {iconUploadStatus ? (
                                <span className="settings-icon-upload-status">{iconUploadStatus}</span>
                            ) : null}
                        </div>
                        {draft.icon && (
                            <div className="settings-icon-preview">
                                <ProjectIcon
                                    icon={draft.icon}
                                    className="settings-icon-preview-icon"
                                    imageClassName="settings-icon-preview-image"
                                />
                                <span>{isProjectImageIcon(draft.icon) ? "Custom image" : draft.icon}</span>
                            </div>
                        )}
                    </div>
                </section>

                <section className="entry-editor-card">
                    <h3>Project Directories</h3>
                    <div className="entry-form-grid">
                        <div className="onboarding-provider-grid" style={{ gridColumn: "1 / -1" }}>
                            <button
                                type="button"
                                className={`onboarding-provider-card ${draft.kind === "project" ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => {
                                    d.kind = "project";
                                    const keptRoot = d.directoryPaths[0] || d.repoPath;
                                    d.directoryPaths = keptRoot ? [keptRoot] : [];
                                    d.repoPath = keptRoot || "";
                                })}
                            >
                                <span className="material-symbols-rounded">folder</span>
                                <strong>Project</strong>
                                <span>Zero or one working directory.</span>
                            </button>
                            <button
                                type="button"
                                className={`onboarding-provider-card ${draft.kind === "workspace" ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => {
                                    d.kind = "workspace";
                                    if (d.directoryPaths.length === 0 && d.repoPath) d.directoryPaths = [d.repoPath];
                                })}
                            >
                                <span className="material-symbols-rounded">folder_copy</span>
                                <strong>Workspace</strong>
                                <span>Two or more ordered roots.</span>
                            </button>
                        </div>

                        {draft.kind === "workspace" ? (
                            <div style={{ gridColumn: "1 / -1" }}>
                                <WorkspaceDirectoriesEditor
                                    paths={draft.directoryPaths}
                                    onChange={(paths) => mutateDraft((d) => {
                                        d.directoryPaths = paths;
                                        d.repoPath = paths[0] || "";
                                    })}
                                    minimum={2}
                                />
                            </div>
                        ) : (
                            <label style={{ gridColumn: "1 / -1" }}>
                                Project workspace / repository path
                                <input
                                    type="text"
                                    placeholder="e.g. /Users/me/Developer/my-project"
                                    value={draft.repoPath}
                                    onChange={(e) => mutateDraft((d) => {
                                        d.repoPath = e.target.value;
                                        d.directoryPaths = e.target.value.trim() ? [e.target.value] : [];
                                    })}
                                />
                            </label>
                        )}
                        <span className="entry-form-hint" style={{ gridColumn: "1 / -1" }}>
                            {workspacePath
                                ? <>Terminal and source control use Primary <code>{workspacePath}</code>.</>
                                : "Choose the directory access granted to agents."}
                        </span>
                    </div>
                </section>

                <section className="entry-editor-card">
                    <h3>Archive</h3>
                    <div className="settings-danger-block">
                        <div className="settings-danger-info">
                            {project.isArchived ? (
                                <>
                                    <strong>Unarchive this project</strong>
                                    <p>Restore this project to the active projects list.</p>
                                </>
                            ) : (
                                <>
                                    <strong>Archive this project</strong>
                                    <p>Hide this project from the main list. You can restore it at any time from the Archived view.</p>
                                </>
                            )}
                        </div>
                        <button
                            type="button"
                            className="hover-levitate"
                            onClick={() => onArchiveProject(project.id, !project.isArchived)}
                        >
                            <span className="material-symbols-rounded" style={{ fontSize: "1rem", verticalAlign: "middle", marginRight: 4 }}>
                                {project.isArchived ? "unarchive" : "archive"}
                            </span>
                            {project.isArchived ? "Unarchive Project" : "Archive Project"}
                        </button>
                    </div>
                </section>

                <section className="entry-editor-card settings-danger-zone">
                    <h3 style={{ color: "var(--danger, #ef4444)" }}>Danger Zone</h3>
                    <div className="settings-danger-block">
                        <div className="settings-danger-info">
                            <strong>Delete this project</strong>
                            <p>
                                Once you delete a project, there is no going back. All tasks will be cancelled and all project data will be permanently removed.
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
                                Delete Project
                            </button>
                        ) : (
                            <div className="settings-danger-confirm">
                                <p className="settings-danger-warning">
                                    <span className="material-symbols-rounded" style={{ fontSize: "1rem", verticalAlign: "middle" }}>warning</span>
                                    {" "}This action is irreversible. All jobs for this project will be cancelled.
                                </p>
                                <label>
                                    Type <strong>{project.name}</strong> to confirm
                                    <input
                                        type="text"
                                        value={deleteConfirmText}
                                        onChange={(e) => setDeleteConfirmText(e.target.value)}
                                        placeholder={project.name}
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
                                        disabled={deleteConfirmText.trim() !== project.name}
                                        onClick={() => deleteProject(project.id)}
                                    >
                                        I understand, delete this project
                                    </button>
                                </div>
                            </div>
                        )}
                    </div>
                </section>
            </>
        );
    }

    function renderMeshSharing() {
        const repoTarget = draft.repoPath.trim() || project.repoPath || "";
        const sharingEnabled = Boolean(meshProject);
        return (
            <>
                <section className="entry-editor-card mesh-sharing-card">
                    <div className="mesh-sharing-head">
                        <div>
                            <h3>Project Mesh Sharing</h3>
                            <p>
                                Enable this project only when worker nodes should receive tasks and repository context from the mesh.
                            </p>
                        </div>
                        <span className={`mesh-sharing-state ${sharingEnabled ? "enabled" : "disabled"}`}>
                            {sharingEnabled ? "Enabled" : "Disabled"}
                        </span>
                    </div>

                    <div className="mesh-sharing-summary">
                        <article>
                            <span>Project id</span>
                            <strong>{project.id}</strong>
                        </article>
                        <article>
                            <span>Repository target</span>
                            <strong>{repoTarget || "Set workspace path first"}</strong>
                        </article>
                        <article>
                            <span>Members</span>
                            <strong>{meshProjectMembers.length}</strong>
                        </article>
                    </div>

                    <div className="mesh-sharing-actions">
                        {sharingEnabled ? (
                            <button
                                type="button"
                                className="danger hover-levitate"
                                disabled={!!meshBusy}
                                onClick={() => void disableMeshSharing()}
                            >
                                <span className="material-symbols-rounded" aria-hidden="true">link_off</span>
                                {meshBusy === "disable" ? "Disabling" : "Disable sharing"}
                            </button>
                        ) : (
                            <button
                                type="button"
                                className="hover-levitate"
                                disabled={!repoTarget || !!meshBusy}
                                onClick={() => void enableMeshSharing()}
                            >
                                <span className="material-symbols-rounded" aria-hidden="true">share</span>
                                {meshBusy === "enable" ? "Enabling" : "Enable sharing"}
                            </button>
                        )}
                        <button type="button" className="hover-levitate" disabled={!!meshBusy} onClick={() => void loadMeshState()}>
                            <span className="material-symbols-rounded" aria-hidden="true">refresh</span>
                            Refresh
                        </button>
                    </div>

                    {meshStatus ? <p className="mesh-sharing-status">{meshStatus}</p> : null}
                </section>

                {sharingEnabled ? (
                    <section className="entry-editor-card mesh-sharing-card">
                        <h3>Worker Access</h3>
                        <p className="mesh-sharing-copy">
                            Attach a registered mesh node to this project and define where that node should keep its local checkout.
                        </p>

                        <div className="mesh-node-picker" role="group" aria-label="Mesh nodes">
                            {meshNodes.length === 0 ? (
                                <p className="mesh-sharing-empty">No mesh nodes registered yet. Register a node on the Node Mesh page first.</p>
                            ) : meshNodes.map((node) => {
                                const nodeId = String(node?.id || "");
                                const active = meshSelectedNodeId === nodeId;
                                return (
                                    <button
                                        key={nodeId}
                                        type="button"
                                        className={active ? "active" : ""}
                                        onClick={() => setMeshSelectedNodeId(nodeId)}
                                    >
                                        <span className="material-symbols-rounded" aria-hidden="true">dns</span>
                                        <span>
                                            <strong>{String(node?.name || nodeId)}</strong>
                                            <small>{String(node?.endpoint || node?.status || "offline")}</small>
                                        </span>
                                    </button>
                                );
                            })}
                        </div>

                        <div className="entry-form-grid mesh-sharing-form">
                            <label>
                                Local checkout path on selected node
                                <input
                                    type="text"
                                    value={meshMemberPath}
                                    onChange={(e) => setMeshMemberPath(e.target.value)}
                                    placeholder="/Users/worker/Developer/project"
                                />
                            </label>
                            <label>
                                Role
                                <input
                                    type="text"
                                    value={meshMemberRole}
                                    onChange={(e) => setMeshMemberRole(e.target.value)}
                                />
                            </label>
                        </div>

                        <div className="mesh-permission-grid" role="group" aria-label="Mesh permissions">
                            {MESH_PERMISSION_OPTIONS.map((permission) => {
                                const active = meshMemberPermissions.includes(permission.id);
                                return (
                                    <button
                                        key={permission.id}
                                        type="button"
                                        className={active ? "active" : ""}
                                        onClick={() => setMeshMemberPermissions((current) => toggleListValue(current, permission.id))}
                                    >
                                        {permission.label}
                                    </button>
                                );
                            })}
                        </div>

                        <button
                            type="button"
                            className="hover-levitate"
                            disabled={!meshSelectedNodeId || !meshMemberPath.trim() || !!meshBusy}
                            onClick={() => void attachMeshMember()}
                        >
                            <span className="material-symbols-rounded" aria-hidden="true">lan</span>
                            {meshBusy === "attach" ? "Attaching" : "Attach node"}
                        </button>

                        <div className="mesh-member-list">
                            {meshProjectMembers.length === 0 ? (
                                <p className="mesh-sharing-empty">No worker nodes attached to this project.</p>
                            ) : meshProjectMembers.map((member) => (
                                <article key={String(member?.nodeId || member?.localRepoPath || "")}>
                                    <span className="material-symbols-rounded" aria-hidden="true">badge</span>
                                    <div>
                                        <strong>{String(member?.nodeId || "node")}</strong>
                                        <small>{String(member?.localRepoPath || "no path")} / {listText(member?.permissions) || "no permissions"}</small>
                                    </div>
                                </article>
                            ))}
                        </div>
                    </section>
                ) : null}
            </>
        );
    }

    function renderActors() {
        const projectActors = draft.actors;
        const projectTeams = draft.teams;
        const actorNameById = new Map(availableActors.map((n) => [String(n?.id || ""), String(n?.displayName || "").trim()]));
        const teamNameById = new Map(availableTeams.map((t) => [String(t?.id || ""), String(t?.name || "").trim()]));

        const actorQ = actorSearch.trim().toLowerCase();
        const filteredActors = availableActors.filter(
            (node) =>
                node.displayName.toLowerCase().includes(actorQ) || node.id.toLowerCase().includes(actorQ)
        );
        const actorsToShow = actorQ && filteredActors.length > 0 ? filteredActors : availableActors;

        const teamQ = teamSearch.trim().toLowerCase();
        const filteredTeams = availableTeams.filter(
            (team) =>
                team.name.toLowerCase().includes(teamQ) || team.id.toLowerCase().includes(teamQ)
        );
        const teamsToShow = teamQ && filteredTeams.length > 0 ? filteredTeams : availableTeams;

        function addActor(node) {
            mutateDraft((d) => {
                const actorId = String(node?.id || "").trim();
                if (!actorId) return;
                if (!d.actors.includes(actorId)) {
                    d.actors.push(actorId);
                }
            });
            setActorSearch("");
        }

        function removeActor(actorId) {
            mutateDraft((d) => {
                d.actors = d.actors.filter((a) => a !== actorId);
            });
        }

        function addTeam(team) {
            mutateDraft((d) => {
                const teamId = String(team?.id || "").trim();
                if (!teamId) return;
                if (!d.teams.includes(teamId)) {
                    d.teams.push(teamId);
                }
            });
            setTeamSearch("");
        }

        function removeTeam(teamId) {
            mutateDraft((d) => {
                d.teams = d.teams.filter((t) => t !== teamId);
            });
        }

        return (
            <section className="entry-editor-card">
                <h3>Actors</h3>
                <p style={{ margin: "0 0 12px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Choose which actors can interact with this project. Actors will be able to receive tasks and work within this project scope.
                </p>

                <div className="actor-team-members-picker">
                    <div className="actor-team-search-wrap">
                        <input
                            ref={actorSearchRef}
                            className="actor-team-search"
                            value={actorSearch}
                            onChange={(e) => {
                                setActorSearch(e.target.value);
                                setActorDropdownOpen(true);
                            }}
                            onFocus={() => setActorDropdownOpen(true)}
                            onBlur={() => setTimeout(() => setActorDropdownOpen(false), 150)}
                            placeholder="Search actors…"
                            autoComplete="off"
                        />
                        {actorDropdownOpen && (
                            <ul className="actor-team-dropdown">
                                {actorsToShow.length === 0 ? (
                                    <li className="actor-team-dropdown-empty">No actors available</li>
                                ) : (
                                    actorsToShow.map((node) => {
                                        const isSelected = projectActors.includes(node.id);
                                        return (
                                            <li
                                                key={node.id}
                                                className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                                                onMouseDown={(e) => {
                                                    e.preventDefault();
                                                    if (isSelected) {
                                                        removeActor(node.id);
                                                    } else {
                                                        addActor(node);
                                                    }
                                                }}
                                            >
                                                <span className="actor-team-dropdown-name">{node.displayName}</span>
                                                <span className="actor-team-dropdown-id">{node.id}</span>
                                                {isSelected && (
                                                    <span className="actor-team-dropdown-check">✓</span>
                                                )}
                                            </li>
                                        );
                                    })
                                )}
                            </ul>
                        )}
                    </div>
                </div>

                {projectActors.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {projectActors.map((actorId) => (
                            <article key={actorId} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                                    <span className="material-symbols-rounded" style={{ fontSize: "1.1rem", color: "var(--accent)" }}>person</span>
                                    <strong>{actorNameById.get(actorId) || actorId}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => removeActor(actorId)}
                                >
                                    <span className="material-symbols-rounded">close</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}

                {projectActors.length === 0 && (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No actors assigned to this project.</p>
                )}

                <h3 style={{ marginTop: 24 }}>Teams</h3>
                <p style={{ margin: "0 0 12px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Assign entire teams to this project. All members of the team will be able to work within this project scope.
                </p>

                <div className="actor-team-members-picker">
                    <div className="actor-team-search-wrap">
                        <input
                            ref={teamSearchRef}
                            className="actor-team-search"
                            value={teamSearch}
                            onChange={(e) => {
                                setTeamSearch(e.target.value);
                                setTeamDropdownOpen(true);
                            }}
                            onFocus={() => setTeamDropdownOpen(true)}
                            onBlur={() => setTimeout(() => setTeamDropdownOpen(false), 150)}
                            placeholder="Search teams…"
                            autoComplete="off"
                        />
                        {teamDropdownOpen && (
                            <ul className="actor-team-dropdown">
                                {teamsToShow.length === 0 ? (
                                    <li className="actor-team-dropdown-empty">No teams available</li>
                                ) : (
                                    teamsToShow.map((team) => {
                                        const isSelected = projectTeams.includes(team.id);
                                        return (
                                            <li
                                                key={team.id}
                                                className={`actor-team-dropdown-item ${isSelected ? "selected" : ""}`}
                                                onMouseDown={(e) => {
                                                    e.preventDefault();
                                                    if (isSelected) {
                                                        removeTeam(team.id);
                                                    } else {
                                                        addTeam(team);
                                                    }
                                                }}
                                            >
                                                <span className="actor-team-dropdown-name">{team.name}</span>
                                                <span className="actor-team-dropdown-id">{team.id}</span>
                                                {isSelected && (
                                                    <span className="actor-team-dropdown-check">✓</span>
                                                )}
                                            </li>
                                        );
                                    })
                                )}
                            </ul>
                        )}
                    </div>
                </div>

                {projectTeams.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {projectTeams.map((teamId) => (
                            <article key={teamId} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                                    <span className="material-symbols-rounded" style={{ fontSize: "1.1rem", color: "var(--accent)" }}>groups</span>
                                    <strong>{teamNameById.get(teamId) || teamId}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => removeTeam(teamId)}
                                >
                                    <span className="material-symbols-rounded">close</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}

                {projectTeams.length === 0 && (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No teams assigned to this project.</p>
                )}
            </section>
        );
    }

    function renderModels() {
        return (
            <section className="entry-editor-card">
                <h3>Models</h3>
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        Model identifiers
                        <textarea
                            rows={5}
                            placeholder={"gpt-5.4-mini\nopenai-api:gpt-5.4\nollama:qwen3"}
                            value={draft.models.join("\n")}
                            onChange={(e) => {
                                mutateDraft((d) => {
                                    d.models = e.target.value
                                        .split("\n")
                                        .map((s) => s.trim())
                                        .filter(Boolean);
                                });
                            }}
                        />
                        <span className="entry-form-hint">
                            One model per line. These models will be available for agents in this project.
                        </span>
                    </label>
                </div>

                {draft.models.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {draft.models.map((model, idx) => (
                            <article key={idx} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{model}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => {
                                        mutateDraft((d) => {
                                            d.models.splice(idx, 1);
                                        });
                                    }}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}
            </section>
        );
    }

    function renderAgentFiles() {
        return (
            <section className="entry-editor-card">
                <h3>Agent Files</h3>
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        File paths
                        <textarea
                            rows={5}
                            placeholder={"docs/spec.md\nREADME.md\nsrc/prompts/system.txt"}
                            value={draft.agentFiles.join("\n")}
                            onChange={(e) => {
                                mutateDraft((d) => {
                                    d.agentFiles = e.target.value
                                        .split("\n")
                                        .map((s) => s.trim())
                                        .filter(Boolean);
                                });
                            }}
                        />
                        <span className="entry-form-hint">
                            One file path per line. These files will be included as context for agents working on this project.
                        </span>
                    </label>
                </div>

                {draft.agentFiles.length > 0 && (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {draft.agentFiles.map((file, idx) => (
                            <article key={idx} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{file}</strong>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    onClick={() => {
                                        mutateDraft((d) => {
                                            d.agentFiles.splice(idx, 1);
                                        });
                                    }}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                )}
            </section>
        );
    }

    function renderChannels() {
        return (
            <section className="entry-editor-card">
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <h3>Channels</h3>
                    <button type="button" className="hover-levitate" onClick={openAddChannelModal}>
                        Add Channel
                    </button>
                </div>

                {project.chats.length > 0 ? (
                    <div className="project-created-list" style={{ marginTop: 16 }}>
                        {project.chats.map((chat) => (
                            <article key={chat.id} className="project-created-item" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                                <div>
                                    <strong>{chat.title}</strong>
                                    <p style={{ margin: 0, fontSize: "0.85rem", color: "var(--muted)" }}>{chat.channelId}</p>
                                </div>
                                <button
                                    type="button"
                                    className="agent-channel-remove"
                                    style={{ color: "var(--warn)", border: "none", background: "transparent", cursor: "pointer", padding: "4px" }}
                                    disabled={project.chats.length <= 1}
                                    onClick={() => removeProjectChannel(chat.id)}
                                >
                                    <span className="material-symbols-rounded">delete</span>
                                </button>
                            </article>
                        ))}
                    </div>
                ) : (
                    <p className="placeholder-text" style={{ marginTop: 12 }}>No channels configured.</p>
                )}
            </section>
        );
    }

    function renderHeartbeat() {
        return (
            <section className="entry-editor-card">
                <h3>Heartbeat</h3>
                <div className="entry-form-grid">
                    <div className="task-sync-token-mode-field">
                        <span className="task-sync-field-label">Enable Heartbeat</span>
                        <div className="task-sync-token-options">
                            {[
                                { id: "disabled", title: "Disabled", icon: "heart_minus" },
                                { id: "enabled", title: "Enabled", icon: "favorite" }
                            ].map((option) => {
                                const active = draft.heartbeat.enabled === (option.id === "enabled");
                                return (
                                    <button
                                        key={option.id}
                                        type="button"
                                        className={`task-sync-token-option ${active ? "active" : ""}`}
                                        onClick={() => mutateDraft((d) => {
                                            d.heartbeat.enabled = option.id === "enabled";
                                        })}
                                    >
                                        <span className="material-symbols-rounded">{option.icon}</span>
                                        <strong>{option.title}</strong>
                                    </button>
                                );
                            })}
                        </div>
                    </div>
                    <label>
                        Interval (minutes)
                        <input
                            type="number"
                            min={1}
                            disabled={!draft.heartbeat.enabled}
                            value={draft.heartbeat.intervalMinutes}
                            onChange={(e) =>
                                mutateDraft((d) => {
                                    const val = parseInt(e.target.value, 10);
                                    d.heartbeat.intervalMinutes = Number.isFinite(val) && val > 0 ? val : 5;
                                })
                            }
                        />
                        <span className="entry-form-hint">
                            How often agents in this project will run heartbeat checks.
                        </span>
                    </label>
                </div>
            </section>
        );
    }

    function renderLoop() {
        return (
            <section className="entry-editor-card">
                <h3>Task Loop Mode</h3>
                <p style={{ margin: "0 0 16px", fontSize: "0.85rem", color: "var(--muted)" }}>
                    Choose how clarification questions from agents are handled. Individual tasks can override this default.
                </p>
                <div className="review-approval-options">
                    {LOOP_MODE_OPTIONS.map((mode) => {
                        const active = draft.taskLoopMode === mode.id;
                        return (
                            <button
                                key={mode.id}
                                type="button"
                                className={`review-approval-option ${active ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => { d.taskLoopMode = mode.id; })}
                            >
                                <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                <strong className="review-approval-name">{mode.label}</strong>
                                <span className="review-approval-desc">{mode.description}</span>
                                {active && (
                                    <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                )}
                            </button>
                        );
                    })}
                </div>
            </section>
        );
    }

    function renderAutopilot() {
        const settings = draft.autopilotSettings;
        return (
            <section className="entry-editor-card">
                <h3>Workers</h3>
                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <div>
                            <strong>Emergency stop</strong>
                            <p className="review-toggle-desc">
                                Interrupt running task sessions and their processes, cancel active tasks,
                                and disable automatic pickup. Other projects are unaffected.
                            </p>
                        </div>
                    </div>
                    <button type="button" className="project-emergency-stop" disabled={emergencyStopBusy}
                        onClick={async () => {
                            setEmergencyStopBusy(true);
                            setEmergencyStopStatus("");
                            try {
                                const result = await emergencyStopProject(project.id);
                                mutateDraft((d) => { d.automaticTaskPickupEnabled = false; });
                                onReplaceProject?.(result.project);
                                setEmergencyStopStatus(result.warnings?.length
                                    ? `Automatic pickup disabled. Stop needs attention: ${result.warnings.join(" ")}`
                                    : "Executions stopped. Automatic pickup is disabled.");
                            } catch (error) {
                                setEmergencyStopStatus(error.message || "Emergency stop failed. Try again.");
                            } finally {
                                setEmergencyStopBusy(false);
                            }
                        }}>
                        {emergencyStopBusy ? "Stopping…" : "Stop all task executions"}
                    </button>
                </div>
                {emergencyStopStatus && <p role="status">{emergencyStopStatus}</p>}
                <div className="review-section-divider" />
                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">play_circle</span>
                        <div>
                            <strong>Automatic task pickup</strong>
                            <p className="review-toggle-desc">
                                Enabled by default. Workers automatically pick up Ready to work tasks.
                                Turn off to pause automatic pickup and autopilot scheduling. Running tasks continue.
                            </p>
                        </div>
                    </div>
                    <label className="agent-tools-switch">
                        <input
                            type="checkbox"
                            aria-label="Automatic task pickup"
                            checked={draft.automaticTaskPickupEnabled}
                            onChange={(e) => mutateDraft((d) => {
                                d.automaticTaskPickupEnabled = e.target.checked;
                            })}
                        />
                        <span className="agent-tools-switch-track" />
                    </label>
                </div>
                <div className="review-section-divider" />
                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">robot_2</span>
                        <div>
                            <strong>Project Autopilot</strong>
                            <p className="review-toggle-desc">
                                VISOR decomposes eligible backlog tasks and delegates child tasks through project workers.
                            </p>
                        </div>
                    </div>
                    <label className="agent-tools-switch">
                        <input
                            type="checkbox"
                            checked={settings.enabled}
                            onChange={(e) => mutateDraft((d) => {
                                d.autopilotSettings.enabled = e.target.checked;
                            })}
                        />
                        <span className="agent-tools-switch-track" />
                    </label>
                </div>

                <div className="review-section-divider" />
                <div className="review-approval-section">
                    <p className="review-approval-title">Mode</p>
                    <div className="review-approval-options">
                    {AUTOPILOT_MODES.map((mode) => {
                        const active = settings.mode === mode.id;
                        return (
                            <button
                                key={mode.id}
                                type="button"
                                className={`review-approval-option ${active ? "active" : ""}`}
                                onClick={() => mutateDraft((d) => {
                                    d.autopilotSettings.mode = mode.id;
                                })}
                            >
                                <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                <strong className="review-approval-name">{mode.label}</strong>
                                <span className="review-approval-desc">{mode.description}</span>
                                {active && (
                                    <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                )}
                            </button>
                        );
                    })}
                    </div>
                </div>

                <div className="entry-form-grid autopilot-form-grid" style={{ marginTop: 16 }}>
                    <label>
                        Default agent
                        <AgentPickerDropdown
                            agents={agentOptions}
                            value={settings.defaultAgentId}
                            placeholder="Choose default agent"
                            onChange={(agentId) => mutateDraft((d) => { d.autopilotSettings.defaultAgentId = agentId; })}
                        />
                    </label>
                    <label>
                        Reviewer agent
                        <AgentPickerDropdown
                            agents={agentOptions}
                            value={settings.reviewerAgentId}
                            placeholder="Choose reviewer agent"
                            onChange={(agentId) => mutateDraft((d) => { d.autopilotSettings.reviewerAgentId = agentId; })}
                        />
                    </label>
                    <label>
                        Included tags
                        <input
                            placeholder="Empty means all tasks"
                            value={listText(settings.includedTags)}
                            onChange={(e) => mutateDraft((d) => {
                                d.autopilotSettings.includedTags = parseList(e.target.value);
                            })}
                        />
                        <small className="project-settings-field-hint">
                            Leave empty to allow Autopilot to pick any eligible backlog task. Set one or more tags to include only matching tasks.
                        </small>
                    </label>
                    <label>
                        Ignored tags
                        <input
                            placeholder="blocked, manual, no-autopilot"
                            value={listText(settings.ignoredTags)}
                            onChange={(e) => mutateDraft((d) => {
                                d.autopilotSettings.ignoredTags = parseList(e.target.value);
                            })}
                        />
                        <small className="project-settings-field-hint">
                            Autopilot skips tasks that have any ignored tag. Ignore tags take precedence over included tags.
                        </small>
                    </label>
                    <label>
                        Trusted authors
                        <input
                            value={listText(settings.trustedAuthors)}
                            onChange={(e) => mutateDraft((d) => {
                                d.autopilotSettings.trustedAuthors = parseList(e.target.value);
                            })}
                        />
                        <small className="project-settings-field-hint">Author logins or stable IDs. Tracker authors are available after syncing with the updated plugin.</small>
                    </label>
                    <label>
                        Max parallel tasks
                        <input
                            type="number"
                            min={1}
                            value={settings.maxParallelTasks}
                            onChange={(e) => mutateDraft((d) => {
                                const value = parseInt(e.target.value, 10);
                                d.autopilotSettings.maxParallelTasks = Number.isFinite(value) && value > 0 ? value : 1;
                            })}
                        />
                    </label>
                </div>

                <div className="review-section-divider" />
                <TaskPickupRulesEditor rules={settings.pickupRules} tasks={project?.tasks || []}
                    onChange={(rules) => mutateDraft((d) => { d.autopilotSettings.pickupRules = rules; })} />
                <div className="task-sync-token-mode-field">
                    <span className="task-sync-field-label">Worker permissions</span>
                    <div className="autopilot-permission-grid">
                        {AUTOPILOT_PERMISSIONS.map((permission) => {
                            const active = Boolean(settings[permission.id]);
                            return (
                                <button
                                    key={permission.id}
                                    type="button"
                                    className={`task-sync-token-option ${active ? "active" : ""}`}
                                    onClick={() => mutateDraft((d) => {
                                        d.autopilotSettings[permission.id] = !d.autopilotSettings[permission.id];
                                    })}
                                >
                                    <span className="material-symbols-rounded">{permission.icon}</span>
                                    <strong>{permission.label}</strong>
                                </button>
                            );
                        })}
                    </div>
                </div>
            </section>
        );
    }

    function renderReview() {
        const isEnabled = draft.reviewSettings.enabled;
        const repoPath = draft.repoPath.trim();
        const worktreeRootPath = String(project?.worktreeRootPath || "").trim();
        const selectedProvider = sourceControlProviders.find((provider) => provider.id === draft.sourceControlProviderId)
            || sourceControlProviders[0]
            || DEFAULT_SOURCE_CONTROL_PROVIDER;
        return (
            <section className="entry-editor-card">
                <h3>Git Worktree &amp; Review</h3>

                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">account_tree</span>
                        <div>
                            <strong>Git Worktree Isolation</strong>
                            <p className="review-toggle-desc">
                                Each task runs in a dedicated git branch and worktree. Changes go through review before merging into the main branch.
                            </p>
                        </div>
                    </div>
                    <label className="agent-tools-switch">
                        <input
                            type="checkbox"
                            checked={isEnabled}
                            onChange={(e) => mutateDraft((d) => {
                                d.reviewSettings.enabled = e.target.checked;
                                if (e.target.checked && !d.repoPath.trim()) {
                                    d.repoPath = `/projects/${project.id}`;
                                }
                            })}
                        />
                        <span className="agent-tools-switch-track" />
                    </label>
                </div>

                <div className="entry-form-grid" style={{ marginTop: 16 }}>
                    <div className="review-worktree-path" style={{ gridColumn: "1 / -1" }}>
                        <span className="task-sync-field-label">Worktree root</span>
                        <code>{worktreeRootPath || `.sloppy/worktrees/${project.id}`}</code>
                        <span className="entry-form-hint">
                            {repoPath
                                ? "Dedicated task worktrees are created outside the workspace path."
                                : "Set the workspace path above before enabling worktree isolation."}
                        </span>
                    </div>
                </div>

                <div className="review-section-divider" />
                <div className="review-provider-section">
                    <div className="review-provider-copy">
                        <p className="review-approval-title">Worktree provider</p>
                        <p className="review-approval-subtitle">
                            Pick the source-control plugin used to create task branches and worktrees.
                        </p>
                    </div>
                    <SourceControlProviderDropdown
                        providers={sourceControlProviders}
                        value={selectedProvider.id}
                        onChange={(providerId) => mutateDraft((d) => { d.sourceControlProviderId = providerId; })}
                    />
                    {Array.isArray(selectedProvider.capabilities) && selectedProvider.capabilities.length > 0 ? (
                        <div className="source-control-provider-capabilities">
                            {selectedProvider.capabilities.map((capability) => (
                                <span key={capability}>{capability}</span>
                            ))}
                            <button
                                type="button"
                                className="source-control-debug-button"
                                onClick={openDebugWorktreeModal}
                                title="Debug worktree actions"
                                aria-label="Debug worktree actions"
                            >
                                <span className="material-symbols-rounded">bug_report</span>
                            </button>
                        </div>
                    ) : null}
                </div>

                <div className="review-section-divider" />
                <div className="review-approval-section">
                    <p className="review-approval-title">Approval mode</p>
                    <p className="review-approval-subtitle">
                        Choose how tasks are approved when they reach the Review stage.
                    </p>
                    <div className="review-approval-options">
                        {APPROVAL_MODES.map((mode) => {
                            const active = draft.reviewSettings.approvalMode === mode.id;
                            return (
                                <button
                                    key={mode.id}
                                    type="button"
                                    className={`review-approval-option ${active ? "active" : ""}`}
                                    onClick={() => mutateDraft((d) => { d.reviewSettings.approvalMode = mode.id; })}
                                >
                                    <span className="material-symbols-rounded review-approval-icon">{mode.icon}</span>
                                    <strong className="review-approval-name">{mode.label}</strong>
                                    <span className="review-approval-desc">{mode.description}</span>
                                    {active && (
                                        <span className="material-symbols-rounded review-approval-check">check_circle</span>
                                    )}
                                </button>
                            );
                        })}
                    </div>
                </div>

                {draft.reviewSettings.approvalMode === "agent" && (
                    <div className="review-agent-hint">
                        <span className="material-symbols-rounded" style={{ fontSize: "1rem", color: "var(--accent)" }}>info</span>
                        <span>
                            Add an actor with the <strong>Reviewer</strong> system role to the team in the Actor Board. The task will be handed off to that actor for review.
                        </span>
                    </div>
                )}
            </section>
        );
    }

    function renderDebugWorktreeModal() {
        if (!debugWorktreeOpen) return null;
        return (
            <div className="project-visor-preview-modal-backdrop" onClick={() => setDebugWorktreeOpen(false)}>
                <form className="review-debug-modal" onSubmit={createDebugWorktree} onClick={(event) => event.stopPropagation()}>
                    <div className="project-visor-preview-modal-head">
                        <div>
                            <h4>Debug worktree</h4>
                            <p className="review-debug-modal-subtitle">Create a dedicated worktree through the configured provider.</p>
                        </div>
                        <button
                            type="button"
                            className="project-visor-preview-modal-close"
                            onClick={() => setDebugWorktreeOpen(false)}
                            aria-label="Close debug worktree modal"
                        >
                            <span className="material-symbols-rounded">close</span>
                        </button>
                    </div>
                    <label className="entry-form-field">
                        <span className="task-sync-field-label">Worktree name</span>
                        <input
                            value={debugWorktreeName}
                            onChange={(event) => setDebugWorktreeName(event.target.value)}
                            placeholder="debug-worktree"
                            autoFocus
                        />
                    </label>
                    <div className="review-debug-actions">
                        <button type="submit" className="hover-levitate" disabled={debugWorktreeBusy}>
                            {debugWorktreeBusy ? "Creating..." : "Create"}
                        </button>
                    </div>
                    {debugWorktreeStatus ? (
                        <p className={`review-debug-status ${debugWorktreeResult ? "success" : ""}`}>{debugWorktreeStatus}</p>
                    ) : null}
                    {debugWorktreeResult ? (
                        <div className="review-debug-result">
                            <span>Branch</span>
                            <code>{debugWorktreeResult.branchName}</code>
                            <span>Path</span>
                            <code>{debugWorktreeResult.worktreePath}</code>
                        </div>
                    ) : null}
                </form>
            </div>
        );
    }

    async function runTaskSyncAction(action) {
        setTaskSyncBusy(true);
        setStatusText("");
        try {
            const result = await action();
            applyTaskSyncResponse(result);
            return result;
        } catch (error) {
            setStatusText(error?.message || "Task sync failed");
            return null;
        } finally {
            setTaskSyncBusy(false);
        }
    }

    const taskSyncStatusOptions = useMemo(() => {
        const options = new Map();
        const addOption = (rawOption) => {
            const label = String(rawOption || "").trim().replace(/\s+/g, " ");
            const key = normalizedExternalStatusKey(label);
            if (!key) return;
            options.set(key, preferredExternalStatusLabel(options.get(key), label));
        };
        if (Array.isArray(taskSyncDraft.linkedProjects)) {
            taskSyncDraft.linkedProjects.forEach((p) => {
                if (Array.isArray(p.statusOptions)) {
                    p.statusOptions.forEach(addOption);
                }
            });
        }
        Object.keys(taskSyncDraft.inboundStatusMappings || {}).forEach(addOption);
        (project?.tasks || []).forEach((task) => {
            const status = task?.externalMetadata?.externalStatus;
            if (status?.display) addOption(status.display);
            else if (status?.key) addOption(status.key);
        });
        return Array.from(options, ([key, label]) => ({ key, label }))
            .sort((a, b) => a.label.localeCompare(b.label));
    }, [taskSyncDraft.linkedProjects, taskSyncDraft.inboundStatusMappings, project?.tasks]);

    function renderTaskSync() {
        const health = taskSyncDraft.health || {};
        const webhook = taskSyncDraft.webhook || {};
        const linkedProjects = Array.isArray(taskSyncDraft.linkedProjects) ? taskSyncDraft.linkedProjects : [];
        const providerId = taskSyncDraft.providerId || "github";
        const isStartrek = providerId === "startrek";
        const providerName = taskSyncProviders.find((provider) => provider.id === providerId)?.displayName || providerId;
        const taskSyncLinked = Boolean(taskSyncDraft.enabled && providerId && linkedProjects.length > 0);
        const taskSyncOverrideCount = taskSyncStatusOptions.filter(({ key }) => (
            Boolean(taskSyncDraft.inboundStatusMappings?.[key])
        )).length;
        return (
            <section className="entry-editor-card">
                <h3>{providerName}</h3>
                <div className="task-sync-token-options" style={{ marginBottom: 16 }}>
                    {taskSyncProviders.map((provider) => (
                        <button
                            key={provider.id}
                            type="button"
                            className={`task-sync-token-option ${provider.id === providerId ? "active" : ""}`}
                            onClick={async () => {
                                mutateTaskSync((draft) => { draft.providerId = provider.id; });
                                setTaskSyncTokenStatus(await fetchProjectTaskSyncToken(project.id, provider.id));
                            }}
                        >
                            <strong>{provider.displayName || provider.id}</strong>
                        </button>
                    ))}
                </div>
                <div className="review-toggle-row">
                    <div className="review-toggle-label">
                        <span className="material-symbols-rounded review-toggle-icon">sync_alt</span>
                        <div>
                            <strong>External task sync</strong>
                            <p className="review-toggle-desc">
                                Enter a source and press Save. Sloppy will validate, link, and run the first sync automatically.
                            </p>
                        </div>
                    </div>
                </div>

                <div className="entry-form-grid task-sync-form-grid" style={{ marginTop: 16 }}>
                    {isStartrek ? (
                        <label style={{ gridColumn: "1 / -1" }} htmlFor="task-sync-startrek-source">
                            Tracker source
                            <input
                                id="task-sync-startrek-source"
                                type="text"
                                placeholder="Queue key, saved filter URL, or query — e.g. Boards: 153966"
                                value={taskSyncDraft.source?.value || ""}
                                onChange={(e) => mutateTaskSync((d) => {
                                    d.enabled = true;
                                    d.source = { ...(d.source || {}), value: e.target.value };
                                })}
                            />
                        </label>
                    ) : (
                        <label style={{ gridColumn: "1 / -1" }} htmlFor="task-sync-github-repository">
                            Repository
                            <input
                                id="task-sync-github-repository"
                                type="text"
                                placeholder="Auto-detected from project git remote, or enter https://github.com/org/repo"
                                value={taskSyncDraft.repositoryURL || taskSyncDraft.repositorySlug}
                                onChange={(e) => mutateTaskSync((d) => {
                                    d.enabled = true;
                                    d.repositoryURL = e.target.value;
                                })}
                            />
                        </label>
                    )}
                    <label className="task-sync-default-repo-field">
                        Sync interval
                        <input
                            type="number"
                            min="1"
                            value={taskSyncDraft.syncSchedule?.intervalMinutes || 15}
                            onChange={(e) => mutateTaskSync((d) => {
                                d.syncSchedule = d.syncSchedule || {};
                                d.syncSchedule.intervalMinutes = Math.max(1, Number(e.target.value) || 15);
                            })}
                        />
                    </label>
                    <label className="task-sync-schedule-toggle">
                        <span className="task-sync-field-label">Periodic sync</span>
                        <label className="agent-tools-switch">
                            <input
                                type="checkbox"
                                checked={Boolean(taskSyncDraft.syncSchedule?.enabled)}
                                onChange={(e) => mutateTaskSync((d) => {
                                    d.syncSchedule = d.syncSchedule || {};
                                    d.syncSchedule.enabled = e.target.checked;
                                })}
                            />
                            <span className="agent-tools-switch-track" />
                        </label>
                    </label>
                    <div className="task-sync-linked-projects">
                        <span className="task-sync-field-label">Detected source</span>
                        {linkedProjects.length === 0 ? (
                            <p className="placeholder-text">No external source detected yet.</p>
                        ) : (
                            <div className="task-sync-project-list">
                                {linkedProjects.map((p) => (
                                    <a
                                        key={p.projectNodeId || p.projectURL || p.tag}
                                        className="task-sync-project-chip"
                                        href={p.projectURL || undefined}
                                        target="_blank"
                                        rel="noreferrer"
                                    >
                                        <span className="material-symbols-rounded" aria-hidden="true">view_kanban</span>
                                        <strong>{p.title}</strong>
                                        <code>{isStartrek ? (taskSyncDraft.source?.value || p.tag) : p.tag}</code>
                                    </a>
                                ))}
                            </div>
                        )}
                    </div>
                    <details className="task-sync-status-mappings task-sync-status-overrides">
                        <summary className="task-sync-status-summary">
                            <span>
                                <strong>Advanced status overrides</strong>
                                <small>Sloppy maps {isStartrek ? "StartTrack" : "GitHub"} statuses automatically</small>
                            </span>
                            <span className="task-sync-status-summary-meta">
                                {taskSyncOverrideCount > 0
                                    ? `${taskSyncOverrideCount} custom override${taskSyncOverrideCount === 1 ? "" : "s"}`
                                    : "No setup needed"}
                                <span className="material-symbols-rounded" aria-hidden="true">expand_more</span>
                            </span>
                        </summary>
                        <p className="task-sync-status-help">
                            Open this only if a task lands in the wrong Sloppy column. Automatic mapping uses the external status key and type.
                        </p>
                        <div className="task-sync-status-list">
                            {taskSyncStatusOptions.length === 0 ? (
                                <p className="placeholder-text">External statuses appear after the first Save.</p>
                            ) : taskSyncStatusOptions.map(({ key, label }) => {
                                return (
                                    <label key={key} className="task-sync-status-row">
                                        <span className="task-sync-status-name">
                                            <strong>{label}</strong>
                                            <code>{isStartrek ? "StartTrack status" : "GitHub Status"}</code>
                                        </span>
                                        <SloppyStatusDropdown
                                            value={taskSyncDraft.inboundStatusMappings?.[key] || ""}
                                            onChange={(status) => mutateTaskSync((d) => {
                                                d.inboundStatusMappings = d.inboundStatusMappings || {};
                                                d.statusMappings = d.statusMappings || {};
                                                const previousStatus = d.inboundStatusMappings[key];
                                                if (previousStatus && d.statusMappings[previousStatus] === key) {
                                                    delete d.statusMappings[previousStatus];
                                                }
                                                if (status) {
                                                    d.inboundStatusMappings[key] = status;
                                                    d.statusMappings[status] = key;
                                                } else {
                                                    delete d.inboundStatusMappings[key];
                                                }
                                            })}
                                        />
                                    </label>
                                );
                            })}
                        </div>
                    </details>
                </div>

                {taskSyncLinked ? (
                    <div className="settings-danger-confirm-actions" style={{ marginTop: 16 }}>
                        <button
                            type="button"
                            className="hover-levitate"
                            disabled={taskSyncBusy}
                            onClick={async () => {
                                const result = await runTaskSyncAction(() => syncProjectTasksNow(project.id));
                                if (result) {
                                    setStatusText(`Sync finished · ${Number(result.imported || 0)} imported · ${Number(result.updated || 0)} updated`);
                                }
                            }}
                        >
                            Sync Now
                        </button>
                        <button
                            type="button"
                            className="danger hover-levitate"
                            disabled={taskSyncBusy}
                            onClick={async () => {
                                const result = await runTaskSyncAction(() => unlinkProjectTaskSync(project.id));
                                if (result) setStatusText("Task sync disconnected");
                            }}
                        >
                            Disconnect
                        </button>
                    </div>
                ) : null}

                <div className="review-section-divider" />
                <div className="entry-form-grid">
                    <label style={{ gridColumn: "1 / -1" }}>
                        Access token <span className="placeholder-text">(optional — leave blank to keep the current token)</span>
                        <input
                            type="password"
                            placeholder={taskSyncTokenStatus?.maskedToken || `${providerName} token`}
                            value={taskSyncToken}
                            onChange={(e) => setTaskSyncToken(e.target.value)}
                        />
                    </label>
                </div>
                {taskSyncTokenStatus?.hasOverrideToken ? (
                    <div className="settings-danger-confirm-actions" style={{ marginTop: 12 }}>
                        <button
                            type="button"
                            className="danger hover-levitate"
                            disabled={taskSyncBusy}
                            onClick={async () => {
                                const result = await runTaskSyncAction(() => clearProjectTaskSyncToken(project.id, providerId));
                                setTaskSyncTokenStatus(result || null);
                                if (result) {
                                    mutateTaskSync((draft) => { draft.tokenMode = "inherit"; });
                                    setSavedTaskSyncDraft((saved) => ({ ...saved, tokenMode: "inherit" }));
                                    setStatusText("Saved token forgotten");
                                }
                            }}
                        >
                            Forget saved token
                        </button>
                    </div>
                ) : null}

                <div className="review-agent-hint" style={{ marginTop: 16 }}>
                    <span className="material-symbols-rounded" style={{ fontSize: "1rem", color: "var(--accent)" }}>info</span>
                    <span>
                        Health: <strong>{health.status || "unknown"}</strong>
                        {health.message ? ` - ${health.message}` : ""}
                        {webhook.webhookURL ? ` Webhook: ${webhook.webhookURL}` : ""}
                    </span>
                </div>
            </section>
        );
    }

    function renderSettingsContent() {
        switch (selectedSettings) {
            case "general":
                return renderGeneral();
            case "actors":
                return renderActors();
            case "models":
                return renderModels();
            case "agent_files":
                return renderAgentFiles();
            case "channels":
                return renderChannels();
            case "heartbeat":
                return renderHeartbeat();
            case "loop":
                return renderLoop();
            case "autopilot":
                return renderAutopilot();
            case "review":
                return renderReview();
            case "task_sync":
                return renderTaskSync();
            case "mesh":
                return renderMeshSharing();
            default:
                return null;
        }
    }

    return (
        <section className="settings-shell project-settings-shell">
            <aside className="settings-side">
                <div className="settings-title-row">
                    <h2>Project Settings</h2>
                </div>

                <div className="settings-nav" role="navigation" aria-label="Project settings">
                    {SETTINGS_TABS.map((item) => (
                        <button
                            key={item.id}
                            type="button"
                            className={`settings-nav-item ${selectedSettings === item.id ? "active" : ""}`}
                            aria-current={selectedSettings === item.id ? "page" : undefined}
                            onClick={() => setSelectedSettings(item.id)}
                        >
                            <span className="material-symbols-rounded settings-nav-icon">{item.icon}</span>
                            <span>{item.title}</span>
                        </button>
                    ))}
                </div>
            </aside>

            <section className="settings-main">
                {statusText && <header className="settings-main-head">
                    <div className="settings-main-status">
                        <span>{statusText}</span>
                    </div>
                </header>}

                <div className={`settings-toast ${hasChanges ? "settings-toast--visible" : ""}`}>
                    <span className="settings-toast-label">Unsaved changes</span>
                    <div className="settings-toast-actions">
                        <button type="button" className="danger hover-levitate" onClick={cancelChanges} disabled={taskSyncBusy}>
                            Cancel
                        </button>
                        <button type="button" className="hover-levitate" onClick={saveSettings} disabled={taskSyncBusy || Boolean(pickupRulesError(draft.autopilotSettings.pickupRules))}>
                            {taskSyncBusy ? "Saving..." : "Save"}
                        </button>
                    </div>
                </div>

                {renderSettingsContent()}
            </section>
            {renderDebugWorktreeModal()}
        </section>
    );
}
