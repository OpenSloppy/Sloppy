export const TOP_LEVEL_SECTIONS = [
  "chats",
  "projects",
  "workspaces",
  "artifacts",
  "sessions",
  "overview",
  "costs",
  "actors",
  "agents",
  "memory",
  "visor",
  "usafe",
  "nodes",
  "config",
  "logs",
  "debug",
  "not_found"
] as const;

export const AGENT_TABS = ["overview", "attention", "chat", "workers", "memories", "tasks", "skills", "tools", "channels", "cron", "config"] as const;
export const PROJECT_TABS = ["overview", "chat", "files", "workspaces", "initiatives", "tasks", "analytics", "workers", "visor", "memory", "workflows", "settings", "review"] as const;

const TOP_LEVEL_SECTION_SET = new Set<string>(TOP_LEVEL_SECTIONS);
const AGENT_TAB_SET = new Set<string>(AGENT_TABS);
const PROJECT_TAB_SET = new Set<string>(PROJECT_TABS);

export type TopLevelSection = (typeof TOP_LEVEL_SECTIONS)[number];
export type AgentTab = (typeof AGENT_TABS)[number];
export type ProjectTab = (typeof PROJECT_TABS)[number];

export const DEFAULT_SECTION_ID: TopLevelSection = "overview";
export const DEFAULT_AGENT_TAB: AgentTab = "overview";
export const DEFAULT_PROJECT_TAB: ProjectTab = "overview";

export interface DashboardRoute {
  artifactId?: string | null;
  memoryTab?: string;
  memoryScopeType?: string;
  memoryScopeId?: string | null;
  section: TopLevelSection;
  configSection: string | null;
  projectId: string | null;
  projectTab: ProjectTab | null;
  projectTaskReference: string | null;
  projectWorkflowId: string | null;
  projectWorkflowRunId: string | null;
  workspaceId: string | null;
  agentId: string | null;
  agentTab: AgentTab | null;
  agentInitialChatSessionId: string | null;
  sessionAgentId: string | null;
  sessionId: string | null;
  /** Project-scoped agent chat in /projects/:projectId/chat. */
  chatProjectId: string | null;
  chatAgentId: string | null;
  chatSessionId: string | null;
}

function decodePathSegment(value: string) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function normalizeTopLevelSection(value: string): TopLevelSection {
  if (!value) {
    return DEFAULT_SECTION_ID;
  }
  if (TOP_LEVEL_SECTION_SET.has(value)) {
    return value as TopLevelSection;
  }
  return "not_found";
}

export function normalizeAgentTab(value: string): AgentTab {
  if (AGENT_TAB_SET.has(value)) {
    return value as AgentTab;
  }
  return DEFAULT_AGENT_TAB;
}

export function normalizeProjectTab(value: string): ProjectTab {
  if (value === "channels") {
    return "chat";
  }
  if (PROJECT_TAB_SET.has(value)) {
    return value as ProjectTab;
  }
  return DEFAULT_PROJECT_TAB;
}

export function parseRouteFromPath(pathname: string): DashboardRoute {
  const [sectionRaw = "", sectionArgRaw = "", sectionArg2Raw = "", sectionArg3Raw = "", sectionArg4Raw = ""] = pathname
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean);

  const sectionRawDecoded = decodePathSegment(sectionRaw);
  const sectionRawLower = sectionRawDecoded.toLowerCase();
  if (sectionRawLower === "tasks") {
    return {
      section: "projects",
      configSection: null,
      projectId: null,
      projectTab: "tasks",
      projectTaskReference: decodePathSegment(sectionArgRaw) || null,
      projectWorkflowId: null,
      projectWorkflowRunId: null,
      workspaceId: null,
      agentId: null,
      agentTab: null,
      agentInitialChatSessionId: null,
      sessionAgentId: null,
      sessionId: null,
      chatProjectId: null,
      chatAgentId: null,
      chatSessionId: null
    };
  }

  const section = normalizeTopLevelSection(sectionRaw);
  const sectionArg = decodePathSegment(sectionArgRaw);
  const sectionArg2 = decodePathSegment(sectionArg2Raw);
  const sectionArg3 = decodePathSegment(sectionArg3Raw);
  const sectionArg4 = decodePathSegment(sectionArg4Raw);

  if (section === "agents" && sectionArg2 === "memories") {
    return parseRouteFromPath(`/memory/memories/agent/${encodeURIComponent(sectionArg)}`);
  }
  if (section === "projects" && sectionArg2 === "memory") {
    return parseRouteFromPath(`/memory/memories/project/${encodeURIComponent(sectionArg)}`);
  }
  if (section === "config" && ["memory", "memory-dreams"].includes(sectionArg)) {
    return parseRouteFromPath(sectionArg === "memory" ? "/memory/settings" : "/memory/dreams");
  }

  if (section === "chats") {
    return {
      section: "projects",
      configSection: null,
      projectId: sectionArg || null,
      projectTab: sectionArg ? "chat" : null,
      projectTaskReference: null,
      projectWorkflowId: null,
      projectWorkflowRunId: null,
      workspaceId: null,
      agentId: null,
      agentTab: null,
      agentInitialChatSessionId: null,
      sessionAgentId: null,
      sessionId: null,
      chatProjectId: sectionArg || null,
      chatAgentId: sectionArg2 || null,
      chatSessionId: sectionArg3 || null
    };
  }

  const sectionArgLower = sectionArg.toLowerCase();
  const sectionArg2Lower = sectionArg2.toLowerCase();

  const isDirectProjectTaskRoute = !TOP_LEVEL_SECTION_SET.has(sectionRaw) && sectionArgLower === "tasks";

  if (isDirectProjectTaskRoute) {
    return {
      section: "projects",
      configSection: null,
      projectId: decodePathSegment(sectionRaw),
      projectTab: "tasks",
      projectTaskReference: sectionArg2 || null,
      projectWorkflowId: null,
      projectWorkflowRunId: null,
      workspaceId: null,
      agentId: null,
      agentTab: null,
      agentInitialChatSessionId: null,
      sessionAgentId: null,
      sessionId: null,
      chatProjectId: null,
      chatAgentId: null,
      chatSessionId: null
    };
  }

  const configSection = section === "config" && sectionArg ? sectionArg : null;
  const workspaceId = section === "workspaces" && sectionArg ? sectionArg : null;
  const artifactId = section === "artifacts" && sectionArg ? sectionArg : null;
  const projectId = section === "projects" && sectionArg ? sectionArg : null;
  const isWorkflowRunRoute = section === "projects" && Boolean(projectId) && sectionArg2Lower === "workflow-runs";
  const projectTab = isWorkflowRunRoute
    ? "workflows"
    : section === "projects" && projectId
      ? normalizeProjectTab(sectionArg2Lower)
      : null;
  const projectTaskReference = section === "projects" && (projectTab === "tasks" || projectTab === "review") ? sectionArg3 || null : null;
  const projectWorkflowId = section === "projects" && projectTab === "workflows" && !isWorkflowRunRoute ? sectionArg3 || null : null;
  const projectWorkflowRunId = isWorkflowRunRoute ? sectionArg3 || null : null;
  const chatProjectId = section === "projects" && projectTab === "chat" && projectId ? projectId : null;
  const chatAgentId = chatProjectId ? sectionArg3 || null : null;
  const chatSessionId = chatProjectId && chatAgentId ? sectionArg4 || null : null;
  const agentId = section === "agents" && sectionArg ? sectionArg : null;
  const agentTab = section === "agents" && agentId ? normalizeAgentTab(sectionArg2Lower) : null;
  const agentInitialChatSessionId = section === "agents" && agentTab === "chat" && sectionArg3 ? sectionArg3 : null;
  const legacySessionAgentId = section === "sessions" && sectionArg2 ? sectionArg : null;
  const sessionId = section === "sessions"
    ? (sectionArg2 ? sectionArg2 : sectionArg || null)
    : null;
  const sessionAgentId = legacySessionAgentId;

  return {
    section,
    ...(section === "memory" ? {
      memoryTab: ["overview", "memories", "dreams", "settings"].includes(sectionArg) ? sectionArg : "overview",
      memoryScopeType: ["agent", "project", "global"].includes(sectionArg2) ? sectionArg2 : "all",
      memoryScopeId: sectionArg2 === "agent" || sectionArg2 === "project" ? sectionArg3 || null : null
    } : {}),
    configSection,
    projectId,
    projectTab,
    projectTaskReference,
    projectWorkflowId,
    projectWorkflowRunId,
    workspaceId,
    artifactId,
    agentId,
    agentTab,
    agentInitialChatSessionId,
    sessionAgentId,
    sessionId,
    chatProjectId,
    chatAgentId,
    chatSessionId
  };
}

export function buildPathFromRoute(route: DashboardRoute) {
  if (route.section === "chats") {
    let nextPathname = "/chats";
    if (route.chatProjectId) {
      nextPathname += `/${encodeURIComponent(route.chatProjectId)}`;
      if (route.chatAgentId) {
        nextPathname += `/${encodeURIComponent(route.chatAgentId)}`;
        if (route.chatSessionId) {
          nextPathname += `/${encodeURIComponent(route.chatSessionId)}`;
        }
      }
    }
    return nextPathname;
  }

  let nextPathname = `/${route.section}`;

  if (route.section === "memory") {
    nextPathname = `/memory/${route.memoryTab || "overview"}`;
    if (route.memoryTab === "memories" && route.memoryScopeType && route.memoryScopeType !== "all") {
      nextPathname += `/${route.memoryScopeType}`;
      if (route.memoryScopeId) nextPathname += `/${encodeURIComponent(route.memoryScopeId)}`;
    }
    return nextPathname;
  }

  if (route.section === "config" && route.configSection) {
    nextPathname = `${nextPathname}/${encodeURIComponent(route.configSection)}`;
  }

  if (route.section === "projects") {
    if (route.projectTab === "tasks" && route.projectTaskReference) {
      nextPathname = `/tasks/${encodeURIComponent(route.projectTaskReference)}`;
    } else if (route.projectTab === "review" && route.projectId && route.projectTaskReference) {
      nextPathname = `/projects/${encodeURIComponent(route.projectId)}/review/${encodeURIComponent(route.projectTaskReference)}`;
    } else if (route.projectTab === "workflows" && route.projectId && route.projectWorkflowRunId) {
      nextPathname = `/projects/${encodeURIComponent(route.projectId)}/workflow-runs/${encodeURIComponent(route.projectWorkflowRunId)}`;
    } else if (route.projectTab === "workflows" && route.projectId && route.projectWorkflowId) {
      nextPathname = `/projects/${encodeURIComponent(route.projectId)}/workflows/${encodeURIComponent(route.projectWorkflowId)}`;
    } else if (route.projectId) {
      nextPathname = `/projects/${encodeURIComponent(route.projectId)}`;
      if (route.projectTab && route.projectTab !== DEFAULT_PROJECT_TAB) {
        nextPathname = `${nextPathname}/${route.projectTab}`;
        if (route.projectTab === "chat" && route.chatAgentId) {
          nextPathname = `${nextPathname}/${encodeURIComponent(route.chatAgentId)}`;
          if (route.chatSessionId) {
            nextPathname = `${nextPathname}/${encodeURIComponent(route.chatSessionId)}`;
          }
        }
      }
    }
  }

  if (route.section === "workspaces" && route.workspaceId) {
    nextPathname = `/workspaces/${encodeURIComponent(route.workspaceId)}`;
  }

  if (route.section === "artifacts" && route.artifactId) {
    nextPathname = `/artifacts/${encodeURIComponent(route.artifactId)}`;
  }

  if (route.section === "agents") {
    nextPathname = "/agents";
    if (route.agentId) {
      nextPathname = `/agents/${encodeURIComponent(route.agentId)}`;
      if (route.agentTab && route.agentTab !== DEFAULT_AGENT_TAB) {
        nextPathname = `${nextPathname}/${route.agentTab}`;
        if (route.agentTab === "chat" && route.agentInitialChatSessionId) {
          nextPathname = `${nextPathname}/${encodeURIComponent(route.agentInitialChatSessionId)}`;
        }
      }
    }
  }

  if (route.section === "sessions") {
    nextPathname = "/sessions";
    if (route.sessionId) {
      nextPathname = `/sessions/${encodeURIComponent(route.sessionId)}`;
    }
  }

  return nextPathname;
}

export function pushRouteToHistory(route: DashboardRoute) {
  const nextPathname = buildPathFromRoute(route);
  if (window.location.pathname === nextPathname) {
    return;
  }
  window.history.pushState({}, "", `${nextPathname}${window.location.search}${window.location.hash}`);
}

export function subscribeToPopState(listener: () => void) {
  window.addEventListener("popstate", listener);
  return () => window.removeEventListener("popstate", listener);
}
