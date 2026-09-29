import React, { useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Prism as SyntaxHighlighter } from "react-syntax-highlighter";
import { oneDark } from "react-syntax-highlighter/dist/esm/styles/prism";
import { answerChannelInputRequest, deleteChannelSession, fetchActorsBoard, fetchAgents, fetchChannelEvents, fetchChannelModel, fetchChannelSession, fetchProjects, fetchTokenUsage, postChannelControl } from "../api";
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";
import { LoadingSkeleton } from "../components/LoadingSkeleton";
import { PlanInputPanel } from "../components/PlanInputPanel/PlanInputPanel";
import { AgentPetIcon } from "../features/agents/components/AgentPetSprite";

const SHOW_DEBUG_ACTIONS = Boolean(import.meta.env.DEV);

function formatRelativeTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "just now";
  }
  const diffMinutes = Math.max(0, Math.round((Date.now() - date.getTime()) / 60000));
  if (diffMinutes < 1) {
    return "just now";
  }
  if (diffMinutes < 60) {
    return `${diffMinutes}m ago`;
  }
  const diffHours = Math.round(diffMinutes / 60);
  if (diffHours < 24) {
    return `${diffHours}h ago`;
  }
  return `${Math.round(diffHours / 24)}d ago`;
}

function formatDateTime(value) {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "—";
  }
  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function formatEventTime(value) {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  });
}

function agentInitials(name) {
  const parts = String(name || "?")
    .trim()
    .split(/[\s_-]+/)
    .filter(Boolean);
  if (parts.length === 0) {
    return "??";
  }
  if (parts.length === 1) {
    return parts[0].slice(0, 2).toUpperCase();
  }
  return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
}

function previewText(value, fallback = "No details") {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (!normalized) {
    return fallback;
  }
  if (normalized.length > 140) {
    return `${normalized.slice(0, 140)}...`;
  }
  return normalized;
}

function formatTurnTokenCount(value) {
  const numeric = Number(value || 0);
  if (!Number.isFinite(numeric) || numeric <= 0) return "0";
  return String(Math.round(numeric));
}

function formatRunStatusTokenUsage(runStatus) {
  const usage = runStatus?.tokenUsage;
  if (!usage || typeof usage !== "object") return "";
  const prompt = usage.prompt ?? usage.promptTokens ?? usage.inputTokens ?? 0;
  const completion = usage.completion ?? usage.completionTokens ?? usage.outputTokens ?? 0;
  if (!Number(prompt) && !Number(completion)) return "";
  return `(${formatTurnTokenCount(prompt)} ↑ / ${formatTurnTokenCount(completion)} ↓)`;
}

function formatRunStatusLabel(runStatus) {
  const label = String(runStatus?.label || runStatus?.stage || "Status").trim();
  const usage = formatRunStatusTokenUsage(runStatus);
  return usage ? `${label} ${usage}` : label;
}

function formatStructuredData(value) {
  if (value == null) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function normalizeRuntimeEvents(payload) {
  if (!payload || typeof payload !== "object") {
    return [];
  }

  const items = payload.items;
  if (!Array.isArray(items)) {
    return [];
  }

  const result = [];
  for (const entry of items) {
    if (!entry || typeof entry !== "object") {
      continue;
    }
    const id = String(entry.messageId || "").trim();
    const messageType = String(entry.messageType || "").trim();
    const ts = String(entry.ts || "").trim();
    if (!id || !messageType || !ts) {
      continue;
    }

    result.push({
      id,
      messageType,
      ts,
      taskId: typeof entry.taskId === "string" ? entry.taskId : "",
      branchId: typeof entry.branchId === "string" ? entry.branchId : "",
      workerId: typeof entry.workerId === "string" ? entry.workerId : "",
      payload: entry.payload,
      extensions: entry.extensions && typeof entry.extensions === "object" ? entry.extensions : null
    });
  }

  return result;
}

function normalizeEventTypeLabel(type) {
  const normalized = String(type || "").replace(/_/g, " ").trim();
  if (!normalized) {
    return "event";
  }
  return normalized;
}

function parseContextWindowTokens(value) {
  if (!value || typeof value !== "string") return 0;
  const normalized = value.trim().toUpperCase();
  const match = normalized.match(/^([\d.]+)\s*([KMB])?$/);
  if (!match) return 0;
  const num = parseFloat(match[1]);
  const suffix = match[2] || "";
  if (suffix === "M") return Math.round(num * 1_000_000);
  if (suffix === "K") return Math.round(num * 1_000);
  if (suffix === "B") return Math.round(num * 1_000_000_000);
  return Math.round(num);
}

function formatTokenCount(count) {
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
  if (count >= 1_000) return `${(count / 1_000).toFixed(1)}K`;
  return String(count);
}

function isMessageEvent(type) {
  return type === "user_message" || type === "assistant_message" || type === "system_message";
}

function eventRole(type, userId) {
  if (type === "assistant_message") {
    return "assistant";
  }
  if (type === "user_message") {
    return "user";
  }
  if (type === "system_message") {
    return "system";
  }
  const normalizedUserId = String(userId || "").trim().toLowerCase();
  if (normalizedUserId === "assistant") {
    return "assistant";
  }
  if (normalizedUserId === "system") {
    return "system";
  }
  return "system";
}

function buildProjectByChannel(projects) {
  const projectByChannel = new Map();
  for (const project of Array.isArray(projects) ? projects : []) {
    const channels = Array.isArray(project?.channels)
      ? project.channels
      : Array.isArray(project?.chats)
        ? project.chats
        : [];
    for (const channel of channels) {
      const channelId = String(channel?.channelId || "").trim();
      if (!channelId || projectByChannel.has(channelId)) {
        continue;
      }
      projectByChannel.set(channelId, {
        projectId: String(project?.id || ""),
        projectName: String(project?.name || project?.id || "Project"),
        channelTitle: String(channel?.title || channelId)
      });
    }
  }
  return projectByChannel;
}

function ContextPanel({ tokenUsage, channelModelInfo }) {
  const selectedModel = channelModelInfo?.selectedModel || null;
  const availableModels = Array.isArray(channelModelInfo?.availableModels) ? channelModelInfo.availableModels : [];
  const activeModel = availableModels.find((m) => m.id === selectedModel) || availableModels[0] || null;
  const modelName = activeModel?.title || selectedModel || "—";
  const contextWindowStr = activeModel?.contextWindow || null;
  const contextWindowTokens = parseContextWindowTokens(contextWindowStr);

  const promptTokens = tokenUsage?.totalPromptTokens ?? 0;
  const completionTokens = tokenUsage?.totalCompletionTokens ?? 0;
  const totalTokens = tokenUsage?.totalTokens ?? (promptTokens + completionTokens);
  const semanticDecisionUsage = tokenUsage?.semanticDecisionUsage || null;
  const semanticDecisionCost = Number(semanticDecisionUsage?.totalCostUSD || 0);
  const semanticDecisionCostPrefix = Number(semanticDecisionUsage?.estimatedCostUSD || 0) > 0 ? "~" : "";

  const usagePercent = contextWindowTokens > 0
    ? Math.min(100, Math.round((totalTokens / contextWindowTokens) * 100))
    : 0;

  const barColor = usagePercent >= 90 ? "#e57272" : usagePercent >= 70 ? "#f5a623" : "#6ec6a5";

  return (
    <section className="channel-session-panel">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">token</span>
          Context
        </h2>
      </div>
      <dl className="channel-session-meta-list">
        <div>
          <dt>Model</dt>
          <dd>{modelName}</dd>
        </div>
        {contextWindowStr ? (
          <div>
            <dt>Context Window</dt>
            <dd>{contextWindowStr} tokens</dd>
          </div>
        ) : null}
        <div>
          <dt>Prompt Tokens</dt>
          <dd>{promptTokens.toLocaleString()}</dd>
        </div>
        <div>
          <dt>Completion Tokens</dt>
          <dd>{completionTokens.toLocaleString()}</dd>
        </div>
        <div>
          <dt>Total Tokens Used</dt>
          <dd>{totalTokens.toLocaleString()}</dd>
        </div>
        {semanticDecisionUsage ? (
          <div>
            <dt>Routing Decisions</dt>
            <dd>
              {Number(semanticDecisionUsage.requestCount || 0).toLocaleString()} calls · {Number(semanticDecisionUsage.inputTokens || 0).toLocaleString()} input tokens · {semanticDecisionCostPrefix}${semanticDecisionCost.toFixed(4)}
            </dd>
          </div>
        ) : null}
        {contextWindowTokens > 0 ? (
          <div className="context-usage-bar-wrapper">
            <dt>Usage</dt>
            <dd>
              <div className="context-usage-row">
                <span>{formatTokenCount(totalTokens)} / {contextWindowStr}</span>
                <span className="context-usage-pct">{usagePercent}%</span>
              </div>
              <div className="context-usage-bar">
                <div
                  className="context-usage-bar-fill"
                  style={{ width: `${usagePercent}%`, background: barColor }}
                />
              </div>
            </dd>
          </div>
        ) : null}
      </dl>
    </section>
  );
}

export function ChannelSessionView({ sessionId, onNavigateBack }) {
  const [sessionDetail, setSessionDetail] = useState(null);
  const [runtimeEvents, setRuntimeEvents] = useState([]);
  const [projects, setProjects] = useState([]);
  const [agents, setAgents] = useState([]);
  const [actorBoard, setActorBoard] = useState({ nodes: [], links: [], teams: [] });
  const [isLoading, setIsLoading] = useState(true);
  const [errorText, setErrorText] = useState("");
  const [controlBusy, setControlBusy] = useState(false);
  const [tokenUsage, setTokenUsage] = useState(null);
  const [channelModelInfo, setChannelModelInfo] = useState(null);
  const [isShareMenuOpen, setIsShareMenuOpen] = useState(false);
  const [isDeleteBusy, setIsDeleteBusy] = useState(false);
  const shareMenuRef = useRef(null);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      if (!sessionId) {
        setErrorText("Session route is incomplete.");
        setIsLoading(false);
        return;
      }

      setIsLoading(true);
      setErrorText("");

      const [detail, projectsResponse, agentsResponse, boardResponse] = await Promise.all([
        fetchChannelSession(sessionId).catch(() => null),
        fetchProjects().catch(() => null),
        fetchAgents({ includeSystem: true }).catch(() => null),
        fetchActorsBoard().catch(() => null)
      ]);

      if (cancelled) {
        return;
      }

      if (!detail) {
        setSessionDetail(null);
        setErrorText("Failed to load channel session.");
        setIsLoading(false);
        return;
      }

      setSessionDetail(detail);
      setProjects(Array.isArray(projectsResponse) ? projectsResponse : []);
      setAgents(Array.isArray(agentsResponse) ? agentsResponse : []);
      setActorBoard(boardResponse && Array.isArray(boardResponse.nodes) ? boardResponse : { nodes: [], links: [], teams: [] });
      setIsLoading(false);
    }

    load().catch(() => {
      if (!cancelled) {
        setSessionDetail(null);
        setErrorText("Failed to load channel session.");
        setIsLoading(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  useEffect(() => {
    const channelId = String(sessionDetail?.summary?.channelId || "").trim();
    const createdAt = sessionDetail?.summary?.createdAt || "";
    const closedAt = sessionDetail?.summary?.closedAt || "";
    if (!sessionId || !channelId) {
      return undefined;
    }

    let cancelled = false;

    async function refreshLive(silent = false) {
      const [detail, channelEventsResponse, tokenData, modelData] = await Promise.all([
        fetchChannelSession(sessionId).catch(() => null),
        fetchChannelEvents(channelId, { limit: 200 }).catch(() => null),
        fetchTokenUsage({ channelId }).catch(() => null),
        fetchChannelModel(channelId).catch(() => null)
      ]);

      if (cancelled) {
        return;
      }

      if (detail) {
        setSessionDetail(detail);
      } else if (!silent) {
        setErrorText("Failed to refresh channel session.");
      }

      if (tokenData) setTokenUsage(tokenData);
      if (modelData) setChannelModelInfo(modelData);

      const allRuntimeEvents = normalizeRuntimeEvents(channelEventsResponse);
      const windowStart = createdAt ? new Date(createdAt).getTime() : Number.NEGATIVE_INFINITY;
      const windowEnd = closedAt ? new Date(closedAt).getTime() : Number.POSITIVE_INFINITY;
      const filteredRuntimeEvents = allRuntimeEvents.filter((event) => {
        const eventTs = new Date(event.ts).getTime();
        if (Number.isNaN(eventTs)) {
          return false;
        }
        return eventTs >= windowStart && eventTs <= windowEnd;
      });
      setRuntimeEvents(filteredRuntimeEvents);
    }

    refreshLive(true).catch(() => { });
    const timerId = window.setInterval(() => {
      refreshLive(true).catch(() => { });
    }, 2000);

    return () => {
      cancelled = true;
      window.clearInterval(timerId);
    };
  }, [sessionDetail?.summary?.channelId, sessionDetail?.summary?.closedAt, sessionDetail?.summary?.createdAt, sessionId]);

  const summary = sessionDetail?.summary || null;
  const events = Array.isArray(sessionDetail?.events) ? sessionDetail.events : [];

  const channelMeta = useMemo(() => {
    const channelId = String(summary?.channelId || "").trim();
    const projectByChannel = buildProjectByChannel(projects);
    const projectMeta = projectByChannel.get(channelId);

    const agentNameById = new Map(
      (Array.isArray(agents) ? agents : []).map((agent) => [
        String(agent?.id || ""),
        String(agent?.displayName || agent?.id || "")
      ])
    );

    const agentById = new Map(
      (Array.isArray(agents) ? agents : []).map((agent) => [String(agent?.id || ""), agent])
    );

    const nodes = Array.isArray(actorBoard?.nodes) ? actorBoard.nodes : [];
    const linkedAgents = nodes
      .filter((node) => String(node?.channelId || "").trim() === channelId && String(node?.linkedAgentId || "").trim())
      .map((node) => {
        const agentId = String(node?.linkedAgentId || "").trim();
        return {
          id: agentId,
          name: agentNameById.get(agentId) || agentId
        };
      })
      .filter((value, index, array) => array.findIndex((item) => item.id === value.id) === index);

    const primaryAgentParts = linkedAgents.length > 0
      ? agentById.get(linkedAgents[0].id)?.pet?.parts ?? null
      : null;
    const primaryAgentPet = linkedAgents.length > 0
      ? agentById.get(linkedAgents[0].id)?.pet ?? null
      : null;

    const primaryAgentGenomeHex =
      linkedAgents.length > 0 ? agentById.get(linkedAgents[0].id)?.pet?.genomeHex : undefined;

    return {
      channelId,
      channelTitle: projectMeta?.channelTitle || channelId || "Channel",
      projectName: projectMeta?.projectName || "",
      linkedAgents,
      primaryAgentPet,
      primaryAgentParts,
      primaryAgentGenomeHex
    };
  }, [actorBoard, agents, projects, summary?.channelId]);

  const transcriptItems = useMemo(() => {
    const answeredInputs = new Set(
      events
        .filter((eventItem) => eventItem?.type === "input_response" && eventItem?.inputResponse?.requestId)
        .map((eventItem) => String(eventItem.inputResponse.requestId))
    );
    return events.map((eventItem, index) => ({
      id: String(eventItem?.id || `event-${index}`),
      index,
      type: String(eventItem?.type || ""),
      role: eventRole(eventItem?.type, eventItem?.userId),
      userId: String(eventItem?.userId || ""),
      content: String(eventItem?.content || ""),
      createdAt: eventItem?.createdAt || "",
      metadata: eventItem?.metadata || null,
      runStatus: eventItem?.runStatus || null,
      inputRequest: eventItem?.inputRequest || null,
      inputAnswered: answeredInputs.has(String(eventItem?.inputRequest?.id || "")),
      isMessage: isMessageEvent(String(eventItem?.type || ""))
    }));
  }, [events]);

  const isSessionOpen = summary?.status === "open" || !summary?.status;

  useEffect(() => {
    if (!isShareMenuOpen) return;
    function handlePointerDown(event) {
      if (shareMenuRef.current && !shareMenuRef.current.contains(event.target)) {
        setIsShareMenuOpen(false);
      }
    }
    document.addEventListener("mousedown", handlePointerDown);
    return () => document.removeEventListener("mousedown", handlePointerDown);
  }, [isShareMenuOpen]);

  function downloadChannelSessionSnapshot() {
    if (!summary) return;
    const payload = {
      summary,
      events,
      runtimeEvents,
      exportedAt: new Date().toISOString()
    };
    const pretty = `${JSON.stringify(payload, null, 2)}\n`;
    const blob = new Blob([pretty], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    const safeSessionId = String(summary.sessionId || "channel-session").replace(/[^a-zA-Z0-9._-]+/g, "_");
    anchor.href = url;
    anchor.download = `${safeSessionId}.json`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
    setIsShareMenuOpen(false);
  }

  async function copyChannelSessionLink() {
    if (!summary?.sessionId) return;
    const deepLink = `${window.location.origin}/channels/sessions/${encodeURIComponent(summary.sessionId)}`;
    try {
      await navigator.clipboard.writeText(deepLink);
    } catch {
      // ignore clipboard failures in restricted contexts
    }
    setIsShareMenuOpen(false);
  }

  async function handleAnswerInputRequest(requestId, payload) {
    if (!summary?.sessionId || !requestId) return;
    setErrorText("");
    const detail = await answerChannelInputRequest(summary.sessionId, requestId, payload);
    if (!detail) {
      setErrorText("Failed to submit plan input.");
      return;
    }
    setSessionDetail(detail);
  }

  async function handleChannelControl(action) {
    if (controlBusy || !channelMeta.channelId) {
      return;
    }
    setControlBusy(true);
    try {
      await postChannelControl(channelMeta.channelId, {
        action,
        requestedBy: "dashboard"
      });
    } catch {
      // silently handled
    } finally {
      setControlBusy(false);
    }
  }

  async function handleDeleteSession() {
    if (!summary?.sessionId || isDeleteBusy) return;
    if (!window.confirm("Delete this channel session permanently? This cannot be undone.")) return;
    setIsDeleteBusy(true);
    try {
      const ok = await deleteChannelSession(summary.sessionId);
      if (ok) {
        onNavigateBack?.();
      } else {
        setErrorText("Failed to delete channel session.");
      }
    } catch {
      setErrorText("Failed to delete channel session.");
    } finally {
      setIsDeleteBusy(false);
    }
  }

  const breadcrumbItems = [
    { id: "overview", label: "Overview", onClick: onNavigateBack },
    { id: "session", label: channelMeta.channelTitle || "Channel Session" }
  ];

  if (isLoading) {
    return (
      <main className="channel-session-shell">
        <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />
        <LoadingSkeleton label="Loading channel session…" variant="page" rows={4} />
      </main>
    );
  }

  if (errorText || !summary) {
    return (
      <main className="channel-session-shell">
        <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">error</span>
          <p>{errorText || "Session not found."}</p>
        </div>
      </main>
    );
  }

  return (
    <main className="channel-session-shell">
      <Breadcrumbs items={breadcrumbItems} style={{ marginBottom: "20px" }} />

      <section className="channel-session-hero">
        <div className="channel-session-titlebar">
          <div className="channel-session-avatar">
            {channelMeta.primaryAgentParts ? (
              <AgentPetIcon
                className="channel-session-avatar-pet"
                pet={channelMeta.primaryAgentPet}
                parts={channelMeta.primaryAgentParts}
                genomeHex={channelMeta.primaryAgentGenomeHex}
              />
            ) : channelMeta.linkedAgents.length > 0 ? (
              <AgentPetIcon
                className="channel-session-avatar-pet"
                genomeHex={channelMeta.primaryAgentGenomeHex}
              />
            ) : (
              agentInitials(channelMeta.channelTitle)
            )}
          </div>
          <div className="channel-session-copy">
            <h1>{channelMeta.channelTitle || "Channel Session"}</h1>
            <p>
              {channelMeta.channelId}
              {channelMeta.projectName ? ` · ${channelMeta.projectName}` : ""}
            </p>
          </div>
        </div>
        <div className="channel-session-badges">
          {SHOW_DEBUG_ACTIONS ? (
            <div className="agent-chat-share-menu-container" ref={shareMenuRef}>
              <button
                type="button"
                className="agent-chat-icon-button"
                onClick={() => setIsShareMenuOpen((prev) => !prev)}
                title={summary?.sessionId ? "Share session" : "Session is unavailable"}
                disabled={!summary?.sessionId}
              >
                <span className="material-symbols-rounded" aria-hidden="true">share</span>
              </button>
              {summary?.sessionId && isShareMenuOpen ? (
                <div className="agent-chat-share-dropdown">
                  <button type="button" onClick={copyChannelSessionLink}>
                    <span className="material-symbols-rounded" aria-hidden="true">link</span>
                    Copy session link
                  </button>
                  <button type="button" onClick={downloadChannelSessionSnapshot}>
                    <span className="material-symbols-rounded" aria-hidden="true">download</span>
                    Download session JSON
                  </button>
                </div>
              ) : null}
            </div>
          ) : null}
          <button
            className="channel-session-control-btn channel-session-control-btn--danger"
            disabled={isDeleteBusy || !summary?.sessionId}
            onClick={handleDeleteSession}
            title="Permanently delete this session"
          >
            <span className="material-symbols-rounded">delete</span>
            Delete
          </button>
          {isSessionOpen ? (
            <>
              <button
                className="channel-session-control-btn"
                disabled={controlBusy}
                onClick={() => handleChannelControl("pause")}
              >
                <span className="material-symbols-rounded">pause</span>
                Pause
              </button>
              <button
                className="channel-session-control-btn"
                disabled={controlBusy}
                onClick={() => handleChannelControl("resume")}
              >
                <span className="material-symbols-rounded">play_arrow</span>
                Resume
              </button>
              <button
                className="channel-session-control-btn channel-session-control-btn--danger"
                disabled={controlBusy}
                onClick={() => handleChannelControl("interrupt")}
              >
                <span className="material-symbols-rounded">stop</span>
                Abort
              </button>
            </>
          ) : null}
          <span className="channel-session-badge">{summary.status || "open"}</span>
          <span className="channel-session-badge">{summary.messageCount || 0} messages</span>
          <span className="channel-session-badge">Updated {formatRelativeTime(summary.updatedAt)}</span>
        </div>
      </section>

      <div className="channel-session-layout">
        <aside className="channel-session-sidebar">
          <section className="channel-session-panel">
            <div className="overview-section-header">
              <h2>
                <span className="material-symbols-rounded">info</span>
                Session
              </h2>
            </div>
            <dl className="channel-session-meta-list">
              <div>
                <dt>Session ID</dt>
                <dd>{summary.sessionId}</dd>
              </div>
              <div>
                <dt>Channel</dt>
                <dd>{channelMeta.channelId}</dd>
              </div>
              <div>
                <dt>Status</dt>
                <dd>{summary.status || "open"}</dd>
              </div>
              <div>
                <dt>Messages</dt>
                <dd>{summary.messageCount || 0}</dd>
              </div>
              <div>
                <dt>Created</dt>
                <dd>{formatDateTime(summary.createdAt)}</dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd>{formatDateTime(summary.updatedAt)}</dd>
              </div>
              {summary.closedAt ? (
                <div>
                  <dt>Closed</dt>
                  <dd>{formatDateTime(summary.closedAt)}</dd>
                </div>
              ) : null}
              {channelMeta.projectName ? (
                <div>
                  <dt>Project</dt>
                  <dd>{channelMeta.projectName}</dd>
                </div>
              ) : null}
              {channelMeta.linkedAgents.length > 0 ? (
                <div>
                  <dt>Agents</dt>
                  <dd>{channelMeta.linkedAgents.map((agent) => agent.name).join(", ")}</dd>
                </div>
              ) : null}
            </dl>
          </section>

          <ContextPanel
            tokenUsage={tokenUsage}
            channelModelInfo={channelModelInfo}
          />

          {summary.lastMessagePreview ? (
            <section className="channel-session-panel">
              <div className="overview-section-header">
                <h2>
                  <span className="material-symbols-rounded">notes</span>
                  Preview
                </h2>
              </div>
              <p className="channel-session-preview">{summary.lastMessagePreview}</p>
            </section>
          ) : null}
        </aside>

        <section className="channel-session-main">
          <div className="overview-section-header">
            <h2>
              <span className="material-symbols-rounded">article</span>
              Full Session
            </h2>
            <span className="overview-section-count">{transcriptItems.length}</span>
          </div>

          <div className="channel-session-transcript-panel">
            <div className="agent-chat-events channel-session-events">
              {transcriptItems.length === 0 ? (
                <p className="placeholder-text">No transcript available yet.</p>
              ) : (
                transcriptItems.map((item) => {
                  if (item.type === "input_request" && item.inputRequest) {
                    return (
                      <PlanInputPanel
                        key={item.id}
                        request={item.inputRequest}
                        disabled={item.inputAnswered}
                        onSubmit={(payload) => handleAnswerInputRequest(String(item.inputRequest.id || ""), payload)}
                      />
                    );
                  }

                  if (item.type === "compact_lifecycle") {
                    const status = String(item.metadata?.status || "").toLowerCase();
                    const title = status === "started" ? "Compacting context" : item.content || "Compact";
                    return (
                      <div key={item.id} className="agent-chat-tech-entry">
                        <div className={`agent-chat-tech-trigger ${status === "started" ? "shimmer" : ""}`}>
                          <span className="agent-chat-tech-trigger-label">{title}</span>
                          <span className="agent-chat-tech-trigger-time">{formatEventTime(item.createdAt)}</span>
                        </div>
                      </div>
                    );
                  }

                  if (!item.isMessage) {
                    const technicalTitle = item.runStatus
                      ? formatRunStatusLabel(item.runStatus)
                      : normalizeEventTypeLabel(item.type);
                    return (
                      <article key={item.id} className="agent-chat-technical">
                        <div className="agent-chat-technical-body">
                          <div className="channel-session-technical-copy">
                            <strong>{technicalTitle}</strong>
                            <small>{formatEventTime(item.createdAt)}</small>
                          </div>
                          <pre className="agent-chat-expandable-pre">
                            {[
                              item.content ? `Content:\n${item.content}` : "",
                              item.runStatus ? `Run status:\n${formatStructuredData(item.runStatus)}` : "",
                              item.userId ? `User: ${item.userId}` : "",
                              item.metadata ? `Metadata:\n${formatStructuredData(item.metadata)}` : ""
                            ]
                              .filter(Boolean)
                              .join("\n\n") || "No details."}
                          </pre>
                        </div>
                      </article>
                    );
                  }

                  return (
                    <article key={item.id} className={`agent-chat-message ${item.role} channel-session-message`}>
                      <div className="agent-chat-message-head">
                        <strong>{item.userId || item.role}</strong>
                        <span>{formatEventTime(item.createdAt)}</span>
                      </div>
                      <div className="agent-chat-message-body">
                        <div className="markdown-body">
                          <ReactMarkdown
                            remarkPlugins={[remarkGfm]}
                            components={{
                              code({ node, inline, className, children, ...props }) {
                                const match = /language-(\w+)/.exec(className || "");
                                return !inline && match ? (
                                  <SyntaxHighlighter
                                    style={oneDark}
                                    language={match[1]}
                                    PreTag="div"
                                    {...props}
                                  >
                                    {String(children).replace(/\n$/, "")}
                                  </SyntaxHighlighter>
                                ) : (
                                  <code className={className} {...props}>
                                    {children}
                                  </code>
                                );
                              }
                            }}
                          >
                            {item.content || "No message content."}
                          </ReactMarkdown>
                        </div>
                        {item.metadata ? (
                          <pre className="agent-chat-expandable-pre">
                            {previewText(formatStructuredData(item.metadata), "No metadata")}
                          </pre>
                        ) : null}
                      </div>
                    </article>
                  );
                })
              )}
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
