import { MigrationLaunchNotice } from "./features/migrations/MigrationWizard";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createDependencies } from "./app/di/createDependencies";
import { DEFAULT_AGENT_TAB, DEFAULT_PROJECT_TAB } from "./app/routing/dashboardRouteAdapter";
import { useDashboardRoute } from "./app/routing/useDashboardRoute";
import { SidebarView } from "./components/SidebarView";
import { LoadingSkeleton } from "./components/LoadingSkeleton";
import { NotificationProvider } from "./features/notifications/NotificationContext";
import { NotificationBell } from "./features/notifications/NotificationBell";
import { NotificationToastContainer } from "./features/notifications/NotificationToast";
import { emitNotification } from "./features/notifications/notificationBus";
import { useNotificationSocket } from "./features/notifications/useNotificationSocket";
import { OnboardingView } from "./features/onboarding/OnboardingView";
import { InitStage } from "./features/onboarding/InitStage";
import { TutorialCoachmark } from "./features/tutorial/TutorialCoachmark";
import { TutorialProvider, useTutorial } from "./features/tutorial/TutorialProvider";
import { useRuntimeOverview } from "./features/runtime-overview/model/useRuntimeOverview";
import { TerminalDrawer } from "./features/terminal/TerminalDrawer";
import { UpdateBanner } from "./features/updates/UpdateBanner";
import { useUpdateCheck } from "./features/updates/useUpdateCheck";
import { ArtifactsView } from "./features/artifacts/ArtifactsView";
import { CostsView } from "./features/costs/CostsView";
import "./features/artifacts/artifacts.css";
import { WorkspacesView } from "./features/workspaces/WorkspacesView";
import "./features/workspaces/workspaces.css";
import { formatSecureSessionStatus } from "./app/sessionStatus";
import { AgentsView } from "./views/AgentsView";
import { ActorsView } from "./views/ActorsView";
import { VisorChatView } from "./features/visor/VisorChatView";
import { MemoryView } from "./features/memory/MemoryView";
import { ConfigView } from "./views/ConfigView";
import { LogsView } from "./views/LogsView";
import { DebugView } from "./views/DebugView";
import { NotFoundView } from "./views/NotFoundView";
import { NodesView } from "./views/NodesView";
import { ProjectsView } from "./views/ProjectsView";
import { ChannelSessionView } from "./views/ChannelSessionView";
import { RuntimeOverviewView } from "./views/RuntimeOverviewView";
import {
  DASHBOARD_AUTH_INVALIDATED_EVENT,
  getDashboardAuthRememberPreference,
  getDashboardAuthToken,
  setDashboardAuthRememberPreference,
  setDashboardAuthToken
} from "./shared/api/dashboardAuth";
import {
  getStoredApiBaseOverride,
  normalizeApiBaseInput,
  resolveApiBase,
  setStoredApiBaseOverride
} from "./shared/api/httpClient";
import { useHoverSoundEffect } from "./shared/ui/useHoverSoundEffect";
import { loadDashboardTheme } from "./shared/ui/dashboardTheme";
import { resolveDashboardFeatureFlags } from "./shared/ui/dashboardFeatureFlags";
import { fetchProjectSummaries } from "./api";

interface SidebarItem {
  id: string;
  label: {
    icon: string;
    title: string;
  };
  content: React.ReactNode;
}

type AnyRecord = Record<string, unknown>;

function normalizeSidebarProject(project: AnyRecord): AnyRecord | null {
  const id = String(project?.id || "").trim();
  if (!id) {
    return null;
  }
  return {
    id,
    name: String(project?.name || id).trim() || id,
    icon: String(project?.icon || "").trim() || null,
    repoPath: String(project?.repoPath || "").trim() || null,
    isFavorite: Boolean(project?.isFavorite),
    isArchived: Boolean(project?.isArchived)
  };
}

function isDashboardAuthRequired(config: AnyRecord | null) {
  const uiConfig = (config?.ui as AnyRecord | undefined) ?? null;
  const dashboardAuth = (uiConfig?.dashboardAuth as AnyRecord | undefined) ?? null;
  return Boolean(dashboardAuth?.enabled) && String(dashboardAuth?.token || "").trim().length > 0;
}

function protectedDashboardAuthConfig(): AnyRecord {
  return {
    onboarding: { completed: true },
    ui: {
      dashboardAuth: {
        enabled: true,
        token: "protected"
      }
    }
  };
}

async function copyTextToClipboard(text: string) {
  if (!text.trim()) {
    return false;
  }

  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Fall through to the textarea fallback below.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  textarea.style.top = "0";
  document.body.appendChild(textarea);
  textarea.select();

  try {
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    document.body.removeChild(textarea);
  }
}

function DashboardShell({
  dependencies,
  debugEnabled,
  terminalEnabled,
  onRuntimeConfigUpdated,
  autoStartTutorialAfterOnboarding
}: {
  dependencies: ReturnType<typeof createDependencies>;
  debugEnabled: boolean;
  terminalEnabled: boolean;
  onRuntimeConfigUpdated: (nextConfig: AnyRecord) => void;
  autoStartTutorialAfterOnboarding: boolean;
}) {
  const { route, setSection, setConfigSection, setProjectRoute, setWorkspaceRoute, setAgentRoute, setSessionRoute, setChatsRoute, setMemoryRoute } =
    useDashboardRoute();
  const runtime = useRuntimeOverview(dependencies.coreApi, route.section);
  const [sidebarCompact, setSidebarCompact] = useState(() => loadDashboardTheme() === "brutalist");
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const [sidebarProjects, setSidebarProjects] = useState<AnyRecord[]>([]);
  const showSidebarProjectChats = resolveDashboardFeatureFlags(window.__SLOPPY_CONFIG__).sidebarProjectChats;
  const [terminalClosedHost, setTerminalClosedHost] = useState<HTMLDivElement | null>(null);
  const [issueReportLoading, setIssueReportLoading] = useState(false);
  const [runtimeProcessId, setRuntimeProcessId] = useState<number | null>(null);
  const sidebarChatRepairRef = useRef<string | null>(null);
  const { status: updateStatus } = useUpdateCheck();
  const { activeStep, startTutorial, startTutorialFromOnboarding } = useTutorial();
  useNotificationSocket();
  useHoverSoundEffect();

  const refreshSidebarProjects = useCallback(() => {
    fetchProjectSummaries()
      .then((list) => {
        if (Array.isArray(list)) {
          setSidebarProjects(
            list
              .map((project) => normalizeSidebarProject(project as AnyRecord))
              .filter((project): project is AnyRecord => Boolean(project) && !project.isArchived)
              .sort((left, right) => {
                const favoriteDelta = Number(Boolean(right.isFavorite)) - Number(Boolean(left.isFavorite));
                if (favoriteDelta !== 0) {
                  return favoriteDelta;
                }
                return String(left.name || "").localeCompare(String(right.name || ""), undefined, { sensitivity: "base" });
              })
          );
        }
      })
      .catch(() => {
        setSidebarProjects([]);
      });
  }, []);

  useEffect(() => {
    document.body.classList.toggle("mobile-menu-open", mobileSidebarOpen);
    return () => {
      document.body.classList.remove("mobile-menu-open");
    };
  }, [mobileSidebarOpen]);

  useEffect(() => {
    refreshSidebarProjects();
  }, [refreshSidebarProjects]);

  useEffect(() => {
    let disposed = false;

    async function loadHealth() {
      const health = await dependencies.coreApi.fetchHealth();
      if (disposed) {
        return;
      }
      const pid = Number(health?.pid);
      setRuntimeProcessId(Number.isFinite(pid) && pid > 0 ? pid : null);
    }

    void loadHealth();

    return () => {
      disposed = true;
    };
  }, [dependencies]);

  useEffect(() => {
    if (autoStartTutorialAfterOnboarding) {
      startTutorialFromOnboarding();
    }
  }, [autoStartTutorialAfterOnboarding, startTutorialFromOnboarding]);

  useEffect(() => {
    if (!activeStep) {
      return;
    }

    const firstProjectId = String((sidebarProjects[0] as AnyRecord | undefined)?.id || "").trim() || null;
    if (activeStep.route.section === "actors") {
      setSection("actors");
      return;
    }

    setSection("projects");
    if (firstProjectId && activeStep.route.projectTab) {
      setProjectRoute(firstProjectId, activeStep.route.projectTab, null);
    } else if (firstProjectId) {
      setProjectRoute(null, null, null);
    }
  }, [activeStep, sidebarProjects, setProjectRoute, setSection]);

  /** If a project chat route targets a project missing from the rail (e.g. created before refresh), refetch once. */
  useEffect(() => {
    if (route.section !== "projects" || route.projectTab !== "chat" || !route.projectId) {
      sidebarChatRepairRef.current = null;
      return;
    }
    const pid = String(route.projectId).trim();
    if (!pid) {
      return;
    }
    const found = sidebarProjects.some((p) => String((p as AnyRecord)?.id || "").trim() === pid);
    if (found) {
      sidebarChatRepairRef.current = null;
      return;
    }
    if (sidebarChatRepairRef.current === pid) {
      return;
    }
    sidebarChatRepairRef.current = pid;
    refreshSidebarProjects();
  }, [route.section, route.projectId, route.projectTab, sidebarProjects, refreshSidebarProjects]);

  useEffect(() => {
    const mediaQuery = window.matchMedia("(min-width: 1001px)");
    function handleChange(event: MediaQueryListEvent | MediaQueryList) {
      if (event.matches) {
        setMobileSidebarOpen(false);
      }
    }
    handleChange(mediaQuery);

    if (typeof mediaQuery.addEventListener === "function") {
      mediaQuery.addEventListener("change", handleChange);
      return () => mediaQuery.removeEventListener("change", handleChange);
    }

    mediaQuery.addListener(handleChange);
    return () => mediaQuery.removeListener(handleChange);
  }, []);

  function onSelectSidebar(nextSection: string) {
    setSection(nextSection);
    setMobileSidebarOpen(false);
  }

  function onAgentRouteChange(
    agentId: string | null,
    agentTab: string | null = DEFAULT_AGENT_TAB,
    initialChatSessionId: string | null = null
  ) {
    setAgentRoute(agentId, agentTab, initialChatSessionId);
  }

  function onProjectRouteChange(
    projectId: string | null,
    projectTab: string | null = DEFAULT_PROJECT_TAB,
    projectTaskReference: string | null = null
  ) {
    setProjectRoute(projectId, projectTab, projectTaskReference);
  }

  async function handleReportIssue() {
    if (issueReportLoading) {
      return;
    }

    setIssueReportLoading(true);
    const popup = window.open("about:blank", "_blank");
    if (!popup) {
      emitNotification("system_error", "Issue report blocked", "Allow popups for this dashboard, then try Report an Issue again.");
      setIssueReportLoading(false);
      return;
    }
    popup.opener = null;

    try {
      const report = await dependencies.coreApi.createIssueReport({ logLimit: 200 });
      const issueUrl = typeof report?.issueUrl === "string" ? report.issueUrl : "";
      const logs = typeof report?.logs === "string" ? report.logs : "";
      const logsUrl = typeof report?.logsUrl === "string" ? report.logsUrl : "";
      if (!issueUrl) {
        popup.close();
        emitNotification("system_error", "Issue report failed", "Sloppy could not prepare a sanitized GitHub issue URL.");
        return;
      }

      const copiedLogs = logsUrl ? false : await copyTextToClipboard(logs);
      popup.location.href = issueUrl;
      setMobileSidebarOpen(false);
      emitNotification(
        logsUrl || copiedLogs ? "confirmation" : "system_error",
        logsUrl || copiedLogs ? "Issue report ready" : "Issue report opened",
        logsUrl
          ? "Sanitized logs were uploaded and linked in the GitHub log field. Review the report before submitting."
          : copiedLogs
          ? "Sanitized logs were copied to the clipboard. Paste them into the GitHub log field before submitting."
          : "GitHub opened, but Sloppy could not copy logs to the clipboard. Open Logs and copy the relevant lines manually."
      );
    } catch {
      popup.close();
      emitNotification("system_error", "Issue report failed", "Sloppy could not prepare a sanitized GitHub issue URL.");
    } finally {
      setIssueReportLoading(false);
    }
  }

  const runtimeContent = (
    <RuntimeOverviewView
      workers={runtime.workers}
      events={runtime.events}
      onNavigateToProject={(projectId: string) => {
        setSection("projects");
        if (projectId) {
          onProjectRouteChange(projectId, DEFAULT_PROJECT_TAB, null);
        }
      }}
      onNavigateToChannelSession={(sessionId: string) => {
        setSessionRoute(sessionId);
      }}
      onNavigateToBots={() => setSection("agents")}
      onNavigateToAgent={(agentId: string) => {
        setSection("agents");
        onAgentRouteChange(agentId, "overview");
      }}
    />
  );

  const sidebarItems: SidebarItem[] = [
    {
      id: "overview",
      label: { icon: "dashboard", title: "Overview" },
      content: runtimeContent
    },
    {
      id: "costs",
      label: { icon: "monitoring", title: "Costs" },
      content: <CostsView coreApi={dependencies.coreApi} onOpenSemanticSettings={() => {
        setSection("config");
        setConfigSection("semantic-decisions");
      }} />
    },
    {
      id: "projects",
      label: { icon: "folder", title: "Projects" },
      content: (
        <ProjectsView
          channelState={runtime.channelState}
          workers={runtime.workers}
          bulletins={runtime.bulletins}
          routeProjectId={route.projectId}
          routeProjectTab={route.projectTab}
          routeProjectTaskReference={route.projectTaskReference}
          routeProjectWorkflowId={route.projectWorkflowId}
          routeProjectWorkflowRunId={route.projectWorkflowRunId}
          routeProjectChatAgentId={route.projectTab === "chat" ? route.chatAgentId : null}
          routeProjectChatSessionId={route.projectTab === "chat" ? route.chatSessionId : null}
          onRouteProjectChange={onProjectRouteChange as any}
          onRouteProjectChatChange={(projectId: string, agentId: string | null, sessionId: string | null) => {
            setChatsRoute(projectId, agentId, sessionId);
          }}
          onSidebarProjectsListChanged={refreshSidebarProjects}
          onWorkersChanged={runtime.refreshRuntime}
          onNavigateToChannelSession={(sessionId: string) => {
            setSessionRoute(sessionId);
          }}
        />
      )
    },
    {
      id: "workspaces",
      label: { icon: "space_dashboard", title: "Workspaces" },
      content: (
        <WorkspacesView
          coreApi={dependencies.coreApi}
          workspaceId={route.workspaceId}
          onWorkspaceRouteChange={setWorkspaceRoute}
        />
      )
    },
    {
      id: "artifacts",
      label: { icon: "widgets", title: "Artifacts" },
      content: <ArtifactsView coreApi={dependencies.coreApi} artifactId={route.artifactId} />
    },
    {
      id: "agents",
      label: { icon: "support_agent", title: "Agents" },
      content: (
        <AgentsView
          routeAgentId={route.agentId}
          routeTab={route.agentTab}
          routeAgentInitialChatSessionId={route.agentInitialChatSessionId}
          onRouteChange={onAgentRouteChange}
          onNavigateToChannelSession={(sessionId: string) => {
            setSessionRoute(sessionId);
          }}
        />
      )
    },
    {
      id: "actors",
      label: { icon: "group", title: "Actors" },
      content: <ActorsView />
    },
    {
      id: "visor",
      label: { icon: "visibility", title: "Visor" },
      content: <VisorChatView />
    },
    {
      id: "memory",
      label: { icon: "neurology", title: "Memory" },
      content: <MemoryView tab={route.memoryTab} scopeType={route.memoryScopeType} scopeId={route.memoryScopeId} onRouteChange={setMemoryRoute} onRuntimeConfigUpdated={onRuntimeConfigUpdated} />
    },
    {
      id: "nodes",
      label: { icon: "hub", title: "Nodes" },
      content: <NodesView coreApi={dependencies.coreApi} />
    },
    {
      id: "config",
      label: { icon: "settings", title: "Settings" },
      content: (
        <ConfigView
          sectionId={route.configSection}
          onSectionChange={setConfigSection}
          onRuntimeConfigUpdated={onRuntimeConfigUpdated}
        />
      )
    },
    {
      id: "logs",
      label: { icon: "description", title: "Logs" },
      content: <LogsView coreApi={dependencies.coreApi} />
    },
    ...(debugEnabled
      ? [{
          id: "debug" as const,
          label: { icon: "bug_report", title: "Debug" },
          content: <DebugView coreApi={dependencies.coreApi} />
        }]
      : [])
  ];

  const isNotFound = route.section === "not_found";
  const activeProjectId =
    typeof route.projectId === "string" && route.projectId.trim().length > 0 ? route.projectId : null;
  const activeProjectRecord =
    activeProjectId != null
      ? sidebarProjects.find((project) => String((project as AnyRecord)?.id || "").trim() === activeProjectId)
      : null;
  const activeProjectRepoPath = activeProjectRecord
    ? String((activeProjectRecord as AnyRecord)?.repoPath || "").trim() || null
    : null;
  const sidebarActiveItemId =
    sidebarItems.find((item) => item.id === route.section)?.id ?? sidebarItems[0].id;
  const pageContent = isNotFound ? (
    <NotFoundView />
  ) : route.section === "sessions" ? (
    <ChannelSessionView
      sessionId={route.sessionId}
      onNavigateBack={() => setSection("overview")}
    />
  ) : (
    (sidebarItems.find((item) => item.id === route.section) || sidebarItems[0]).content
  );
  const isEmbeddedWorkspace =
    route.section === "workspaces"
    && new URLSearchParams(window.location.search).get("embed") === "workspace";

  if (isEmbeddedWorkspace) {
    return (
      <div className="layout workspace-embed">
        <div className="page workspace-embed-page">
          {pageContent}
        </div>
        <NotificationToastContainer />
      </div>
    );
  }

  return (
    <div
      className="layout"
      style={
        {
          "--terminal-drawer-inset-left": sidebarCompact ? "76px" : "228px"
        } as React.CSSProperties
      }
    >
      <SidebarView
        items={sidebarItems}
        activeItemId={sidebarActiveItemId}
        isCompact={sidebarCompact}
        onToggleCompact={() => setSidebarCompact((value) => !value)}
        onSelect={onSelectSidebar}
        isMobileOpen={mobileSidebarOpen}
        onRequestClose={() => setMobileSidebarOpen(false)}
        projectRailProjects={sidebarProjects}
        showProjectChatsRail={showSidebarProjectChats}
        selectedChatProjectId={route.section === "projects" && route.projectTab === "chat" ? route.projectId : null}
        onSelectChatProject={(projectId: string) => {
          setChatsRoute(projectId, null, null);
        }}
        footer={
          <>
            <a
              href="https://docs.sloppy.team"
              target="_blank"
              rel="noopener noreferrer"
              className="sidebar-docs-link"
              title="Documentation"
              aria-label="Documentation"
            >
              <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
                menu_book
              </span>
              {!sidebarCompact && <span className="sidebar-docs-label">[ DOCS ]</span>}
            </a>
            <button
              type="button"
              className="sidebar-tutorial-link"
              title="Tutorial"
              aria-label="Tutorial"
              onClick={() => {
                startTutorial();
                setMobileSidebarOpen(false);
              }}
            >
              <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
                school
              </span>
              {!sidebarCompact && <span className="sidebar-tutorial-label">[ TUTORIAL ]</span>}
            </button>
            <button
              type="button"
              className="sidebar-report-link"
              title="Report an Issue"
              aria-label="Report an Issue"
              onClick={handleReportIssue}
              disabled={issueReportLoading}
            >
              <span className="material-symbols-rounded sidebar-icon" aria-hidden="true">
                campaign
              </span>
              {!sidebarCompact && (
                <span className="sidebar-report-label">{issueReportLoading ? "[ PREPARING ]" : "[ REPORT ISSUE ]"}</span>
              )}
            </button>
            <div className="sidebar-footer-tray">
              <NotificationBell
                isCompact={sidebarCompact}
                onNavigateToAgent={(agentId: string, sessionId?: string) => {
                  onAgentRouteChange(agentId, "chat", sessionId ?? null);
                }}
              />
              {terminalEnabled ? <div className="sidebar-footer-terminal-host" ref={setTerminalClosedHost} /> : null}
            </div>
          </>
        }
      />
      <button
        type="button"
        className={`sidebar-mobile-overlay ${mobileSidebarOpen ? "open" : ""}`}
        onClick={() => setMobileSidebarOpen(false)}
        aria-label="Close menu"
      />

      <div className={`page page-${route.section} ${route.section === "config" ? "page-config" : ""}`} style={{ position: "relative" }}>
        <div
          className="dashboard-secure-session-status"
          style={{
            position: "absolute",
            top: "2px",
            right: "20px",
            fontSize: "10px",
            color: "var(--accent)",
            zIndex: 1000,
            pointerEvents: "none",
            opacity: 0.6,
            letterSpacing: "0.1em"
          }}
        >
          {formatSecureSessionStatus(runtimeProcessId)}
        </div>
        <div
          className="dashboard-uplink-status"
          style={{
            position: "absolute",
            bottom: "10px",
            right: "20px",
            fontSize: "10px",
            color: "var(--muted)",
            zIndex: 1000,
            pointerEvents: "none",
            opacity: 0.5
          }}
        >
          UPLINK: ESTABLISHED / LATENCY: 12MS
        </div>
        <button
          type="button"
          className="mobile-page-menu-button"
          onClick={() =>
            setMobileSidebarOpen((value) => {
              const next = !value;
              if (next) {
                setSidebarCompact(false);
              }
              return next;
            })
          }
          aria-label={mobileSidebarOpen ? "Close menu" : "Open menu"}
          aria-expanded={mobileSidebarOpen}
        >
          <span className="material-symbols-rounded" aria-hidden="true">
            menu
          </span>
        </button>
        {updateStatus && <UpdateBanner status={updateStatus} />}
        {pageContent}
        {terminalEnabled ? (
          <TerminalDrawer
            coreApi={dependencies.coreApi}
            currentProjectId={activeProjectId}
            currentProjectRepoPath={activeProjectRepoPath}
            closedHostElement={terminalClosedHost}
            isSidebarCompact={sidebarCompact}
          />
        ) : null}
      </div>
      <TutorialCoachmark hasProjects={sidebarProjects.length > 0} />
      <NotificationToastContainer />
    </div>
  );
}

export function App() {
  const dependencies = useMemo(() => createDependencies(), []);
  const [bootState, setBootState] = useState<{
    isLoading: boolean;
    config: AnyRecord | null;
    error: string;
  }>({
    isLoading: true,
    config: null,
    error: ""
  });
  const [apiBaseInput, setApiBaseInput] = useState(() => getStoredApiBaseOverride() || resolveApiBase());
  const [apiBaseError, setApiBaseError] = useState("");
  const [isApiBaseEditorOpen, setIsApiBaseEditorOpen] = useState(false);
  const [bootAttempt, setBootAttempt] = useState(0);
  const [autoStartTutorialAfterOnboarding, setAutoStartTutorialAfterOnboarding] = useState(false);
  const [dashboardTokenInput, setDashboardTokenInput] = useState("");
  const [identityLoginInput, setIdentityLoginInput] = useState("");
  const [identityNameInput, setIdentityNameInput] = useState("");
  const [identityPasswordInput, setIdentityPasswordInput] = useState("");
  const [identityNewPasswordInput, setIdentityNewPasswordInput] = useState("");
  const [identityRecoverySecretInput, setIdentityRecoverySecretInput] = useState("");
  const [identityAuthFormMode, setIdentityAuthFormMode] = useState<"login" | "reset">("login");
  const [authChallenge, setAuthChallenge] = useState<AnyRecord | null>(null);
  const [rememberDashboardToken, setRememberDashboardToken] = useState(getDashboardAuthRememberPreference);
  const [authState, setAuthState] = useState<{
    status: "checking" | "required" | "authenticated";
    error: string;
  }>({
    status: "checking",
    error: ""
  });

  useEffect(() => {
    if (isApiBaseEditorOpen) {
      return;
    }

    let isCancelled = false;

    async function runBootstrap() {
      setBootState((current) => ({
        ...current,
        isLoading: true,
        error: ""
      }));

      try {
        const config = await dependencies.coreApi.fetchRuntimeConfig();
        if (isCancelled) {
          return;
        }

        if (!config) {
          const challenge = await dependencies.coreApi.fetchAuthChallenge();
          if (isCancelled) {
            return;
          }
          setAuthChallenge(challenge);
          if (challenge?.mode === "login_password") {
            const existingToken = getDashboardAuthToken();
            if (existingToken) {
              setAuthState({ status: "checking", error: "" });
              const validation = await dependencies.coreApi.validateDashboardAuthToken(existingToken);
              if (isCancelled) {
                return;
              }
              if (validation) {
                retryBootstrap();
                return;
              }
              setRememberDashboardToken(getDashboardAuthRememberPreference());
              setAuthState({
                status: "required",
                error: "Saved login session is no longer valid."
              });
            } else {
              setAuthState({ status: "required", error: "" });
            }
            setBootState({
              isLoading: false,
              config: protectedDashboardAuthConfig(),
              error: ""
            });
            return;
          }
          const authStatus = await dependencies.coreApi.fetchDashboardAuthStatus();
          if (isCancelled) {
            return;
          }
          if (authStatus?.enabled) {
            const existingToken = getDashboardAuthToken();
            if (existingToken) {
              setAuthState({ status: "checking", error: "" });
              const validation = await dependencies.coreApi.validateDashboardAuthToken(existingToken);
              if (isCancelled) {
                return;
              }
              if (validation) {
                retryBootstrap();
                return;
              }
              setRememberDashboardToken(getDashboardAuthRememberPreference());
              setAuthState({
                status: "required",
                error: "Saved dashboard token is no longer valid."
              });
            } else {
              setAuthState({ status: "required", error: "" });
            }
            setBootState({
              isLoading: false,
              config: protectedDashboardAuthConfig(),
              error: ""
            });
            return;
          }
          setBootState({
            isLoading: false,
            config: null,
            error: "Failed to load runtime config."
          });
          return;
        }

        const requiresDashboardAuth = isDashboardAuthRequired(config);
        if (requiresDashboardAuth) {
          const existingToken = getDashboardAuthToken();
          if (existingToken) {
            setAuthState({ status: "checking", error: "" });
            const validation = await dependencies.coreApi.validateDashboardAuthToken(existingToken);
            if (isCancelled) {
              return;
            }
            if (validation) {
              setRememberDashboardToken(getDashboardAuthRememberPreference());
              setAuthState({ status: "authenticated", error: "" });
            } else {
              setRememberDashboardToken(getDashboardAuthRememberPreference());
              setAuthState({
                status: "required",
                error: "Saved dashboard token is no longer valid."
              });
            }
          } else {
            setAuthState({ status: "required", error: "" });
          }
        } else {
          setAuthState({ status: "authenticated", error: "" });
        }

        setBootState({
          isLoading: false,
          config,
          error: ""
        });
      } catch {
        if (isCancelled) {
          return;
        }
        setBootState({
          isLoading: false,
          config: null,
          error: "Failed to load runtime config."
        });
      }
    }

    void runBootstrap();

    return () => {
      isCancelled = true;
    };
  }, [dependencies, bootAttempt, isApiBaseEditorOpen]);

  useEffect(() => {
    function handleDashboardAuthInvalidated() {
      if (!isDashboardAuthRequired(bootState.config as AnyRecord | null)) {
        return;
      }
      setRememberDashboardToken(getDashboardAuthRememberPreference());
      setAuthState({
        status: "required",
        error: "Dashboard token is invalid or expired."
      });
      setDashboardTokenInput("");
    }

    window.addEventListener(DASHBOARD_AUTH_INVALIDATED_EVENT, handleDashboardAuthInvalidated);
    return () => {
      window.removeEventListener(DASHBOARD_AUTH_INVALIDATED_EVENT, handleDashboardAuthInvalidated);
    };
  }, [bootState.config]);

  function retryBootstrap() {
    setApiBaseError("");
    setBootAttempt((value) => value + 1);
  }

  function applyApiBaseInput() {
    const trimmed = apiBaseInput.trim();
    if (!trimmed) {
      setStoredApiBaseOverride("");
      setApiBaseInput(resolveApiBase());
      setApiBaseError("");
      return true;
    }

    const normalized = normalizeApiBaseInput(trimmed);
    if (!normalized) {
      setApiBaseError("Enter host:port or full http(s) URL.");
      return false;
    }

    setStoredApiBaseOverride(normalized);
    setApiBaseInput(normalized);
    setApiBaseError("");
    return true;
  }

  function handleApiBaseConnect() {
    if (!applyApiBaseInput()) {
      return;
    }

    setIsApiBaseEditorOpen(false);
    retryBootstrap();
  }

  function openApiBaseEditor() {
    setApiBaseInput(resolveApiBase());
    setApiBaseError("");
    setIsApiBaseEditorOpen(true);
  }

  function closeApiBaseEditor() {
    setApiBaseInput(resolveApiBase());
    setApiBaseError("");
    setIsApiBaseEditorOpen(false);
  }

  async function handleDashboardAuthSubmit() {
    if (!applyApiBaseInput()) {
      return;
    }

    const token = dashboardTokenInput.trim();
    if (!token) {
      setAuthState({
        status: "required",
        error: "Enter the dashboard token."
      });
      return;
    }

    setAuthState({ status: "checking", error: "" });
    const validation = await dependencies.coreApi.validateDashboardAuthToken(token);
    if (!validation) {
      setAuthState({
        status: "required",
        error: "Token invalid. Check the value and try again."
      });
      return;
    }

    setDashboardAuthToken(token, { persist: rememberDashboardToken });
    setAuthState({ status: "authenticated", error: "" });
    setDashboardTokenInput("");
    retryBootstrap();
  }

  async function handleIdentityLoginSubmit() {
    if (!applyApiBaseInput()) {
      return;
    }
    const login = identityLoginInput.trim();
    const password = identityPasswordInput;
    if (!login || !password) {
      setAuthState({
        status: "required",
        error: "Enter login and password."
      });
      return;
    }
    setAuthState({ status: "checking", error: "" });
    const session = await dependencies.coreApi.loginIdentityUser({ login, password });
    const accessToken = typeof session?.accessToken === "string" ? session.accessToken.trim() : "";
    if (!accessToken) {
      setAuthState({
        status: "required",
        error: "Login failed. Check credentials and try again."
      });
      return;
    }
    setDashboardAuthToken(accessToken, { persist: rememberDashboardToken });
    setAuthState({ status: "authenticated", error: "" });
    setIdentityPasswordInput("");
    setIdentityAuthFormMode("login");
    retryBootstrap();
  }

  async function handleIdentityBootstrapSubmit() {
    if (!applyApiBaseInput()) {
      return;
    }
    const login = identityLoginInput.trim();
    const name = identityNameInput.trim() || login;
    const password = identityPasswordInput;
    if (!login || !password) {
      setAuthState({
        status: "required",
        error: "Enter admin login and password."
      });
      return;
    }
    setAuthState({ status: "checking", error: "" });
    const session = await dependencies.coreApi.bootstrapIdentityAdmin({ login, name, password });
    const accessToken = typeof session?.accessToken === "string" ? session.accessToken.trim() : "";
    if (!accessToken) {
      setAuthState({
        status: "required",
        error: "Failed to create the first Admin account."
      });
      return;
    }
    setDashboardAuthToken(accessToken, { persist: rememberDashboardToken });
    setAuthState({ status: "authenticated", error: "" });
    setIdentityPasswordInput("");
    setIdentityNameInput("");
    setIdentityAuthFormMode("login");
    retryBootstrap();
  }

  async function handleIdentityPasswordResetSubmit() {
    if (!applyApiBaseInput()) {
      return;
    }
    const login = identityLoginInput.trim();
    const newPassword = identityNewPasswordInput;
    const secret = identityRecoverySecretInput.trim();
    if (!login || !newPassword || !secret) {
      setAuthState({
        status: "required",
        error: "Enter login, recovery code or reset token, and new password."
      });
      return;
    }
    const payload: AnyRecord = {
      login,
      newPassword
    };
    if (secret.startsWith("slp_reset_")) {
      payload.resetToken = secret;
    } else {
      payload.recoveryCode = secret;
    }
    setAuthState({ status: "checking", error: "" });
    const session = await dependencies.coreApi.resetIdentityPassword(payload);
    const accessToken = typeof session?.accessToken === "string" ? session.accessToken.trim() : "";
    if (!accessToken) {
      setAuthState({
        status: "required",
        error: "Password reset failed. Check the recovery code or reset token."
      });
      return;
    }
    setDashboardAuthToken(accessToken, { persist: rememberDashboardToken });
    setAuthState({ status: "authenticated", error: "" });
    setIdentityPasswordInput("");
    setIdentityNewPasswordInput("");
    setIdentityRecoverySecretInput("");
    setIdentityAuthFormMode("login");
    retryBootstrap();
  }

  function renderDashboardAuthForm(scope: "onboarding" | "runtime") {
    const suffix = scope === "onboarding" ? "-onboarding" : "";
    const isIdentityAuth = authChallenge?.mode === "login_password";
    const bootstrapRequired = Boolean(authChallenge?.bootstrapRequired);
    const isResetMode = isIdentityAuth && !bootstrapRequired && identityAuthFormMode === "reset";

    return (
      <>
        <div className="onboarding-loading-form">
          {isIdentityAuth ? (
            <>
              {bootstrapRequired ? (
                <>
                  <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-name${suffix}`}>
                    Admin name
                  </label>
                  <input
                    id={`sloppy-dashboard-name${suffix}`}
                    className="onboarding-loading-input"
                    type="text"
                    value={identityNameInput}
                    onChange={(event) => {
                      setIdentityNameInput(event.target.value);
                      if (authState.error) {
                        setAuthState((current) => ({ ...current, error: "" }));
                      }
                    }}
                  />
                </>
              ) : null}
              <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-login${suffix}`}>
                Login
              </label>
              <input
                id={`sloppy-dashboard-login${suffix}`}
                className="onboarding-loading-input"
                type="text"
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                value={identityLoginInput}
                onChange={(event) => {
                  setIdentityLoginInput(event.target.value);
                  if (authState.error) {
                    setAuthState((current) => ({ ...current, error: "" }));
                  }
                }}
              />
              {isResetMode ? (
                <>
                  <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-reset-secret${suffix}`}>
                    Recovery code or reset token
                  </label>
                  <input
                    id={`sloppy-dashboard-reset-secret${suffix}`}
                    className="onboarding-loading-input"
                    type="password"
                    value={identityRecoverySecretInput}
                    onChange={(event) => {
                      setIdentityRecoverySecretInput(event.target.value);
                      if (authState.error) {
                        setAuthState((current) => ({ ...current, error: "" }));
                      }
                    }}
                  />
                  <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-new-password${suffix}`}>
                    New password
                  </label>
                  <input
                    id={`sloppy-dashboard-new-password${suffix}`}
                    className="onboarding-loading-input"
                    type="password"
                    value={identityNewPasswordInput}
                    onChange={(event) => {
                      setIdentityNewPasswordInput(event.target.value);
                      if (authState.error) {
                        setAuthState((current) => ({ ...current, error: "" }));
                      }
                    }}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        event.preventDefault();
                        void handleIdentityPasswordResetSubmit();
                      }
                    }}
                  />
                </>
              ) : (
                <>
                  <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-password${suffix}`}>
                    Password
                  </label>
                  <input
                    id={`sloppy-dashboard-password${suffix}`}
                    className="onboarding-loading-input"
                    type="password"
                    value={identityPasswordInput}
                    onChange={(event) => {
                      setIdentityPasswordInput(event.target.value);
                      if (authState.error) {
                        setAuthState((current) => ({ ...current, error: "" }));
                      }
                    }}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        event.preventDefault();
                        void (bootstrapRequired ? handleIdentityBootstrapSubmit() : handleIdentityLoginSubmit());
                      }
                    }}
                  />
                </>
              )}
              {!bootstrapRequired ? (
                <button
                  type="button"
                  className="onboarding-ghost-button"
                  onClick={() => {
                    setIdentityAuthFormMode(isResetMode ? "login" : "reset");
                    setAuthState((current) => ({ ...current, error: "" }));
                  }}
                >
                  {isResetMode ? "Back to login" : "Reset password"}
                </button>
              ) : null}
            </>
          ) : (
            <>
              <label className="onboarding-loading-label" htmlFor={`sloppy-dashboard-token${suffix}`}>
                Token
              </label>
              <input
                id={`sloppy-dashboard-token${suffix}`}
                className="onboarding-loading-input"
                type="password"
                placeholder="Paste dashboard operator token"
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                value={dashboardTokenInput}
                onChange={(event) => {
                  setDashboardTokenInput(event.target.value);
                  if (authState.error) {
                    setAuthState((current) => ({
                      ...current,
                      error: ""
                    }));
                  }
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    void handleDashboardAuthSubmit();
                  }
                }}
              />
            </>
          )}
          <label className="onboarding-loading-label" htmlFor={`sloppy-api-base-auth${suffix}`}>
            Core API URL
          </label>
          <input
            id={`sloppy-api-base-auth${suffix}`}
            className="onboarding-loading-input"
            type="text"
            inputMode="url"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            placeholder="192.168.1.50:25101"
            value={apiBaseInput}
            onChange={(event) => {
              setApiBaseInput(event.target.value);
              if (apiBaseError) {
                setApiBaseError("");
              }
            }}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                handleApiBaseConnect();
              }
            }}
          />
          <span className="onboarding-loading-hint">
            Enter `ip:port` or a full `http://` / `https://` URL for `sloppy-core`.
          </span>
          {apiBaseError ? <span className="onboarding-loading-error">{apiBaseError}</span> : null}
          <label className="agent-tools-guardrail agent-tools-guardrail-toggle">
            <span className="agent-tools-guardrail-copy">
              <span className="agent-tools-guardrail-title">Remember this token in this browser</span>
            </span>
            <span className="agent-tools-switch">
              <input
                type="checkbox"
                checked={rememberDashboardToken}
                onChange={(event) => {
                  const remember = event.target.checked;
                  setRememberDashboardToken(remember);
                  setDashboardAuthRememberPreference(remember);
                }}
              />
              <span className="agent-tools-switch-track" />
            </span>
          </label>
          <span className="onboarding-loading-hint">
            This is a convenience-first local operator mode. Stored tokens use `localStorage`.
          </span>
          {authState.error ? <span className="onboarding-loading-error">{authState.error}</span> : null}
        </div>
        <div className="onboarding-loading-actions">
          <button
            type="button"
            className="onboarding-ghost-button"
            onClick={handleApiBaseConnect}
          >
            Retry
          </button>
          <button
            type="button"
            className="onboarding-primary-button"
            onClick={() => {
              if (!isIdentityAuth) {
                void handleDashboardAuthSubmit();
              } else if (bootstrapRequired) {
                void handleIdentityBootstrapSubmit();
              } else if (isResetMode) {
                void handleIdentityPasswordResetSubmit();
              } else {
                void handleIdentityLoginSubmit();
              }
            }}
          >
            {!isIdentityAuth ? "Unlock" : bootstrapRequired ? "Create Admin" : isResetMode ? "Reset password" : "Login"}
          </button>
        </div>
      </>
    );
  }

  if (bootState.isLoading && isApiBaseEditorOpen) {
    return (
      <InitStage state="editing">
        <div className="onboarding-loading-card">
          <span className="onboarding-loading-kicker">Sloppy init</span>
          <strong>Change server</strong>
          <div className="onboarding-loading-form">
            <label className="onboarding-loading-label" htmlFor="sloppy-api-base-loading">
              Core API URL
            </label>
            <input
              id="sloppy-api-base-loading"
              className="onboarding-loading-input"
              type="text"
              inputMode="url"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              autoFocus
              placeholder="192.168.1.50:25101"
              value={apiBaseInput}
              onChange={(event) => {
                setApiBaseInput(event.target.value);
                if (apiBaseError) {
                  setApiBaseError("");
                }
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  handleApiBaseConnect();
                }
                if (event.key === "Escape") {
                  closeApiBaseEditor();
                }
              }}
            />
            <span className="onboarding-loading-hint">
              Enter `ip:port` or a full `http://` / `https://` URL for `sloppy-core`.
            </span>
            {apiBaseError ? <span className="onboarding-loading-error">{apiBaseError}</span> : null}
          </div>
          <div className="onboarding-loading-actions">
            <button
              type="button"
              className="onboarding-ghost-button"
              onClick={closeApiBaseEditor}
            >
              Cancel
            </button>
            <button
              type="button"
              className="onboarding-primary-button"
              onClick={handleApiBaseConnect}
            >
              Connect
            </button>
          </div>
        </div>
      </InitStage>
    );
  }

  if (bootState.isLoading) {
    return (
      <InitStage>
        <div className="onboarding-loading-card">
          <span className="onboarding-loading-kicker">Sloppy init</span>
          <strong>Loading runtime config...</strong>
          <div className="onboarding-loading-server">
            <span className="onboarding-loading-server-label">Connecting to</span>
            <code className="onboarding-loading-server-url" title={resolveApiBase()}>
              {resolveApiBase()}
            </code>
            <button
              type="button"
              className="onboarding-ghost-button onboarding-loading-server-action"
              onClick={openApiBaseEditor}
            >
              Change server
            </button>
          </div>
          <div className="init-progress" role="status">
            <span className="init-progress-dot" aria-hidden="true" />
            <span>Preparing dashboard…</span>
          </div>
        </div>
      </InitStage>
    );
  }

  if (bootState.error || !bootState.config) {
    return (
      <InitStage state="error">
        <div className="onboarding-loading-card onboarding-loading-card-error">
          <span className="onboarding-loading-kicker">Sloppy init</span>
          <strong>{bootState.error || "Runtime config is unavailable."}</strong>
          <div className="onboarding-loading-form">
            <label className="onboarding-loading-label" htmlFor="sloppy-api-base">
              Core API URL
            </label>
            <input
              id="sloppy-api-base"
              className="onboarding-loading-input"
              type="text"
              inputMode="url"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder="192.168.1.50:25101"
              value={apiBaseInput}
              onChange={(event) => {
                setApiBaseInput(event.target.value);
                if (apiBaseError) {
                  setApiBaseError("");
                }
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  handleApiBaseConnect();
                }
              }}
            />
            <span className="onboarding-loading-hint">
              Enter `ip:port` or a full `http://` / `https://` URL for `sloppy-core`.
            </span>
            {apiBaseError ? <span className="onboarding-loading-error">{apiBaseError}</span> : null}
          </div>
          <div className="onboarding-loading-actions">
            <button
              type="button"
              className="onboarding-ghost-button"
              onClick={retryBootstrap}
            >
              Retry
            </button>
            <button
              type="button"
              className="onboarding-primary-button"
              onClick={handleApiBaseConnect}
            >
              Connect
            </button>
          </div>
        </div>
      </InitStage>
    );
  }

  if (!Boolean((bootState.config.onboarding as AnyRecord | undefined)?.completed)) {
    if (isDashboardAuthRequired(bootState.config) && authState.status !== "authenticated") {
      if (authState.status === "checking") {
        return (
          <div className="onboarding-loading-shell">
            <div className="onboarding-loading-card">
              <span className="onboarding-loading-kicker">Dashboard auth</span>
              <strong>Validating dashboard token...</strong>
              <LoadingSkeleton label="Checking access…" variant="panel" rows={2} />
            </div>
          </div>
        );
      }

      return (
        <div className="onboarding-loading-shell">
          <div className="onboarding-loading-card onboarding-loading-card-error">
            <span className="onboarding-loading-kicker">Dashboard auth</span>
            <strong>
              {authChallenge?.mode === "login_password"
                ? Boolean(authChallenge?.bootstrapRequired) ? "Create the first Admin account" : "Login to Sloppy"
                : "Enter the dashboard operator token"}
            </strong>
            {renderDashboardAuthForm("onboarding")}
          </div>
        </div>
      );
    }

    return (
      <OnboardingView
        coreApi={dependencies.coreApi}
        initialConfig={bootState.config}
        onAuthenticated={() => {
          setRememberDashboardToken(getDashboardAuthRememberPreference());
          setAuthState({ status: "authenticated", error: "" });
        }}
        onCompleted={(config) => {
          setAutoStartTutorialAfterOnboarding(true);
          setBootState({
            isLoading: false,
            config,
            error: ""
          });
        }}
      />
    );
  }

  const runtimeConfig = bootState.config as Record<string, unknown> | null;
  const uiConfig = (runtimeConfig?.ui as AnyRecord | undefined) ?? null;
  const terminalConfig = (uiConfig?.dashboardTerminal as AnyRecord | undefined) ?? null;
  const dashboardAuthRequired = isDashboardAuthRequired(runtimeConfig);

  if (dashboardAuthRequired && authState.status !== "authenticated") {
    if (authState.status === "checking") {
      return (
        <div className="onboarding-loading-shell">
          <div className="onboarding-loading-card">
            <span className="onboarding-loading-kicker">Dashboard auth</span>
            <strong>Validating dashboard token...</strong>
          </div>
        </div>
      );
    }

    return (
      <div className="onboarding-loading-shell">
        <div className="onboarding-loading-card onboarding-loading-card-error">
          <span className="onboarding-loading-kicker">Dashboard auth</span>
          <strong>
            {authChallenge?.mode === "login_password"
              ? Boolean(authChallenge?.bootstrapRequired) ? "Create the first Admin account" : "Login to Sloppy"
              : "Enter the dashboard operator token"}
          </strong>
          {renderDashboardAuthForm("runtime")}
        </div>
      </div>
    );
  }

  return (
    <NotificationProvider>
      <MigrationLaunchNotice />
      <TutorialProvider>
        <DashboardShell
          dependencies={dependencies}
          debugEnabled={Boolean(runtimeConfig?.debugEnabled)}
          terminalEnabled={Boolean(terminalConfig?.enabled)}
          autoStartTutorialAfterOnboarding={autoStartTutorialAfterOnboarding}
          onRuntimeConfigUpdated={(nextConfig) => {
            if (isDashboardAuthRequired(nextConfig as AnyRecord)) {
              setRememberDashboardToken(getDashboardAuthRememberPreference());
              setAuthState({
                status: getDashboardAuthToken() ? "authenticated" : "required",
                error: ""
              });
            } else {
              setAuthState({ status: "authenticated", error: "" });
            }
            setBootState((current) => ({
              ...current,
              config: nextConfig
            }));
          }}
        />
      </TutorialProvider>
    </NotificationProvider>
  );
}
