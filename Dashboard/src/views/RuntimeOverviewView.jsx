import { RequestPerformanceSection } from "../features/runtime-overview/RequestPerformanceSection";
import React, { useEffect, useMemo, useState } from "react";
import { fetchActorsBoard, fetchAgents, fetchProjects, fetchAllAgentSessions, fetchChannelSessions, fetchRuntimePerformance } from "../api";
import { gatewayBindingChannelId } from "../shared/channelGatewayScope";
import { Breadcrumbs } from "../components/Breadcrumbs/Breadcrumbs";
import { LoadingSkeleton } from "../components/LoadingSkeleton";
import { AgentPetIcon } from "../features/agents/components/AgentPetSprite";

// ─── Helpers ─────────────────────────────────────────────────────────────────

const ACTIVE_WORKER_STATUSES = new Set(["queued", "running", "waitinginput", "waiting_input"]);
const AGENT_USAGE_DAYS = 365;
const AGENT_USAGE_TREND_WEEKS = 16;
const AGENT_USAGE_MONTH_LABELS = 12;

function formatRelativeTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "—";
  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.round(diffMs / 60000);
  if (Math.abs(diffMinutes) < 1) return "just now";
  if (Math.abs(diffMinutes) < 60) return `${diffMinutes}m ago`;
  const diffHours = Math.round(diffMinutes / 60);
  if (Math.abs(diffHours) < 24) return `${diffHours}h ago`;
  return `${Math.round(diffHours / 24)}d ago`;
}

function buildActivityData(sessions, agentId, days = 14) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Array.from({ length: days }, (_, i) => {
    const d = new Date(today);
    d.setDate(today.getDate() - (days - 1 - i));
    const count = (sessions || []).filter((s) => {
      if (String(s?.agentId || "") !== String(agentId)) return false;
      const ts = s?.createdAt;
      if (!ts) return false;
      const sd = new Date(ts);
      return (
        sd.getFullYear() === d.getFullYear() &&
        sd.getMonth() === d.getMonth() &&
        sd.getDate() === d.getDate()
      );
    }).length;
    return { dateStr: `${d.getMonth() + 1}/${d.getDate()}`, value: count };
  });
}

function startOfDay(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) {
    return null;
  }
  date.setHours(0, 0, 0, 0);
  return date;
}

function dayKey(dateValue) {
  const date = startOfDay(dateValue);
  if (!date) return "";
  return date.toISOString().slice(0, 10);
}

function formatDurationCompact(totalMs) {
  if (!Number.isFinite(totalMs) || totalMs <= 0) {
    return "0m";
  }
  const totalMinutes = Math.round(totalMs / 60000);
  if (totalMinutes < 60) {
    return `${totalMinutes}m`;
  }
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours < 24) {
    return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  }
  const days = Math.floor(hours / 24);
  const remainingHours = hours % 24;
  return remainingHours > 0 ? `${days}d ${remainingHours}h` : `${days}d`;
}

function formatLargeNumber(value) {
  const numeric = Number(value || 0);
  if (!Number.isFinite(numeric)) return "0";
  if (Math.abs(numeric) >= 1000000) {
    return `${(numeric / 1000000).toFixed(numeric >= 10000000 ? 0 : 1)}M`;
  }
  if (Math.abs(numeric) >= 1000) {
    return `${(numeric / 1000).toFixed(numeric >= 10000 ? 0 : 1)}K`;
  }
  return numeric.toLocaleString();
}

function computeStreaks(dayCounts) {
  let current = 0;
  let longest = 0;
  let running = 0;

  for (const day of dayCounts) {
    if (day.value > 0) {
      running += 1;
      if (running > longest) {
        longest = running;
      }
    } else {
      running = 0;
    }
  }

  for (let index = dayCounts.length - 1; index >= 0; index -= 1) {
    if (dayCounts[index].value > 0) {
      current += 1;
    } else {
      break;
    }
  }

  return { current, longest };
}

function summarizeAgentUsage(sessions, selectedAgentId) {
  const allSessions = Array.isArray(sessions) ? sessions : [];
  const filteredSessions = selectedAgentId === "all"
    ? allSessions
    : allSessions.filter((session) => String(session?.agentId || "") === String(selectedAgentId));

  const today = startOfDay(new Date());
  const dailyWindowStart = new Date(today);
  dailyWindowStart.setDate(today.getDate() - (AGENT_USAGE_DAYS - 1));

  const byDay = new Map();
  const weekData = Array.from({ length: AGENT_USAGE_TREND_WEEKS }, (_, index) => {
    const start = new Date(today);
    start.setDate(today.getDate() - ((AGENT_USAGE_TREND_WEEKS - 1 - index) * 7 + 6));
    start.setHours(0, 0, 0, 0);
    const end = new Date(start);
    end.setDate(start.getDate() + 7);
    return {
      key: `week-${index}`,
      start,
      end,
      label: `${start.toLocaleString(undefined, { month: "short" })} ${start.getDate()}`,
      value: 0
    };
  });

  let totalTurns = 0;
  let totalMessages = 0;
  let totalDurationMs = 0;
  let longestDurationMs = 0;
  let longestSession = null;
  let mostRecentSessionAt = null;
  const kindCounts = new Map();
  const projectCounts = new Map();

  for (const session of filteredSessions) {
    const createdAt = new Date(session?.createdAt || "");
    const updatedAt = new Date(session?.updatedAt || session?.createdAt || "");
    if (Number.isNaN(createdAt.getTime())) {
      continue;
    }

    const safeUpdatedAt = Number.isNaN(updatedAt.getTime()) ? createdAt : updatedAt;
    const durationMs = Math.max(0, safeUpdatedAt.getTime() - createdAt.getTime());
    totalDurationMs += durationMs;
    totalTurns += Number(session?.userTurnCount || 0);
    totalMessages += Number(session?.messageCount || 0);

    if (durationMs > longestDurationMs) {
      longestDurationMs = durationMs;
      longestSession = session;
    }
    if (!mostRecentSessionAt || safeUpdatedAt.getTime() > mostRecentSessionAt.getTime()) {
      mostRecentSessionAt = safeUpdatedAt;
    }

    const kind = String(session?.kind || "chat");
    kindCounts.set(kind, (kindCounts.get(kind) || 0) + 1);

    const projectId = String(session?.projectId || "").trim();
    if (projectId) {
      projectCounts.set(projectId, (projectCounts.get(projectId) || 0) + 1);
    }

    const key = dayKey(createdAt);
    if (key) {
      const current = byDay.get(key) || 0;
      byDay.set(key, current + 1);
    }

    for (const week of weekData) {
      if (createdAt >= week.start && createdAt < week.end) {
        week.value += 1;
        break;
      }
    }
  }

  const daily = [];
  for (let offset = 0; offset < AGENT_USAGE_DAYS; offset += 1) {
    const date = new Date(dailyWindowStart);
    date.setDate(dailyWindowStart.getDate() + offset);
    const key = dayKey(date);
    daily.push({
      key,
      date,
      value: byDay.get(key) || 0
    });
  }

  const cumulative = [];
  let runningTotal = 0;
  for (const week of weekData) {
    runningTotal += week.value;
    cumulative.push({
      ...week,
      value: runningTotal
    });
  }

  const streaks = computeStreaks(daily);
  const maxDaily = Math.max(...daily.map((item) => item.value), 0);
  const maxWeekly = Math.max(...weekData.map((item) => item.value), 0);
  const maxCumulative = Math.max(...cumulative.map((item) => item.value), 0);
  const activeDays = daily.filter((item) => item.value > 0).length;
  const averagePerActiveDay = activeDays > 0 ? filteredSessions.length / activeDays : 0;
  const monthStep = Math.floor(AGENT_USAGE_DAYS / AGENT_USAGE_MONTH_LABELS);
  const monthLabels = daily
    .filter((_, index) => index % monthStep === 0)
    .slice(0, AGENT_USAGE_MONTH_LABELS)
    .map((item) => item.date.toLocaleString(undefined, { month: "short" }));

  let topKind = "chat";
  let topKindCount = 0;
  for (const [kind, count] of kindCounts.entries()) {
    if (count > topKindCount) {
      topKind = kind;
      topKindCount = count;
    }
  }

  return {
    filteredSessions,
    daily,
    weekly: weekData,
    cumulative,
    monthLabels,
    stats: {
      totalSessions: filteredSessions.length,
      totalTurns,
      totalMessages,
      totalDurationMs,
      longestDurationMs,
      activeDays,
      currentStreak: streaks.current,
      longestStreak: streaks.longest,
      averagePerActiveDay,
      topKind,
      topKindCount,
      projectCount: projectCounts.size,
      mostRecentSessionAt,
      longestSession
    },
    maxDaily,
    maxWeekly,
    maxCumulative
  };
}

const CHANNEL_MESSAGES_LIMIT = 9;

const USER_COLORS = [
  "#c084fc", "#67e8f9", "#f472b6", "#fbbf24", "#6ee7b7",
  "#fb923c", "#a78bfa", "#38bdf8", "#f87171", "#a3e635"
];

function userColor(name) {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = name.charCodeAt(i) + ((hash << 5) - hash);
  }
  return USER_COLORS[Math.abs(hash) % USER_COLORS.length];
}

function formatCompactTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "";
  let hours = date.getHours();
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const suffix = hours >= 12 ? "p" : "a";
  hours = hours % 12 || 12;
  return `${hours}:${minutes}${suffix}`;
}

function extractSessionMessages(sessionDetail) {
  const recentMessages = Array.isArray(sessionDetail?.recentMessages) ? sessionDetail.recentMessages : [];
  if (recentMessages.length > 0) {
    return recentMessages.map((msg) => ({
      id: String(msg?.id || ""),
      userId: msg?.isBot ? "bot" : String(msg?.userId || "user"),
      content: String(msg?.content || "").replace(/\s+/g, " ").trim(),
      createdAt: msg?.createdAt || "",
      isBot: Boolean(msg?.isBot)
    }));
  }

  const events = Array.isArray(sessionDetail?.events) ? sessionDetail.events : [];
  return events
    .filter((e) => {
      const type = String(e?.type || "");
      return type === "user_message" || type === "assistant_message";
    })
    .map((e) => {
      const type = String(e?.type || "");
      const isBot = type === "assistant_message";
      return {
        id: String(e?.id || ""),
        userId: isBot ? "bot" : String(e?.userId || "user"),
        content: String(e?.content || "").replace(/\s+/g, " ").trim(),
        createdAt: e?.createdAt || "",
        isBot
      };
    });
}

function agentInitials(name) {
  const parts = String(name || "?")
    .trim()
    .split(/[\s_-]+/)
    .filter(Boolean);
  if (parts.length === 0) return "??";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

// ─── Section 1 — Active Channels ─────────────────────────────────────────────

function ActiveChannelsSection({
  agents,
  sessions,
  channelSessions,
  channelSessionDetails,
  projects,
  actorBoard,
  onNavigateToProject,
  onNavigateToChannelSession
}) {
  const activeChannels = useMemo(() => {
    if (!Array.isArray(channelSessions) || channelSessions.length === 0) {
      return [];
    }

    const projectByChannel = new Map();
    for (const project of projects) {
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
          projectId: String(project.id || ""),
          projectName: String(project.name || project.id || "Project"),
          channelTitle: String(channel?.title || channelId)
        });
      }
    }

    const agentNameById = new Map(
      agents.map((agent) => [String(agent.id || ""), String(agent.displayName || agent.id || "")])
    );
    const sessionById = new Map(
      (Array.isArray(sessions) ? sessions : [])
        .map((session) => [String(session?.id || session?.sessionId || "").trim(), session])
        .filter(([sessionId]) => sessionId)
    );
    const agentsByChannel = new Map();
    const nodes = Array.isArray(actorBoard?.nodes) ? actorBoard.nodes : [];
    for (const node of nodes) {
      const channelId = String(node?.channelId || "").trim();
      const agentId = String(node?.linkedAgentId || "").trim();
      if (!channelId || !agentId) {
        continue;
      }
      if (!agentsByChannel.has(channelId)) {
        agentsByChannel.set(channelId, []);
      }
      const existing = agentsByChannel.get(channelId);
      if (existing.some((entry) => entry.id === agentId)) {
        continue;
      }
      existing.push({
        id: agentId,
        name: agentNameById.get(agentId) || agentId
      });
    }

    return channelSessions.map((session) => {
      const channelId = String(session?.channelId || "").trim();
      const baseChannelId = gatewayBindingChannelId(channelId);
      const projectMeta = projectByChannel.get(channelId) || projectByChannel.get(baseChannelId);
      const agentSession = sessionById.get(String(session?.sessionId || "").trim());
      const channelAgents = agentsByChannel.get(channelId) || agentsByChannel.get(baseChannelId) || [];
      const fallbackAgentId = channelAgents.length === 1 ? String(channelAgents[0]?.id || "").trim() : "";
      const agentId = String(agentSession?.agentId || fallbackAgentId).trim();
      const sessionId = String(session?.sessionId || "");
      const detail = channelSessionDetails?.[sessionId] || session;
      const messages = extractSessionMessages(detail).slice(-CHANNEL_MESSAGES_LIMIT);

      return {
        key: sessionId || channelId,
        sessionId,
        agentId,
        channelId,
        channelTitle: projectMeta?.channelTitle || channelId || "Channel",
        projectId: projectMeta?.projectId || "",
        projectName: projectMeta?.projectName || "Unassigned",
        updatedAt: session?.updatedAt || session?.createdAt || "",
        messageCount: Number(session?.messageCount || 0),
        lastMessagePreview: String(session?.lastMessagePreview || ""),
        agents: channelAgents,
        primaryAgentName: agentNameById.get(agentId) || "",
        canOpenSession: Boolean(agentId && session?.sessionId),
        messages
      };
    });
  }, [actorBoard, agents, channelSessions, channelSessionDetails, projects, sessions]);

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">forum</span>
          Active Channels
        </h2>
        <span className="overview-section-count">{activeChannels.length}</span>
      </div>

      {activeChannels.length === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">chat_bubble_outline</span>
          <p>No active channel sessions right now.</p>
        </div>
      ) : (
        <div className="active-channels-grid">
          {activeChannels.map((ch) => (
            <button
              key={ch.key}
              type="button"
              className="channel-card hover-levitate"
              disabled={!ch.canOpenSession && !ch.projectId}
              onClick={() => {
                if (ch.canOpenSession && onNavigateToChannelSession) {
                  onNavigateToChannelSession(ch.sessionId);
                  return;
                }
                if (ch.projectId && onNavigateToProject) {
                  onNavigateToProject(ch.projectId);
                }
              }}
            >
              <div className="channel-card-head">
                <span className="channel-card-dot channel-dot-active" />
                <span className="channel-card-title">{ch.channelTitle}</span>
                <span className="channel-card-members">
                  {ch.agents.length > 0 ? `${ch.agents.length} active member${ch.agents.length !== 1 ? "s" : ""}` : ""}
                </span>
              </div>
              <div className="channel-card-sub">
                {ch.updatedAt ? formatRelativeTime(ch.updatedAt) : "just now"}
              </div>

              {ch.messages.length > 0 ? (
                <div className="channel-card-messages">
                  {ch.messages.map((msg, i) => (
                    <div key={msg.id || i} className="channel-msg-row">
                      <span className="channel-msg-time">{formatCompactTime(msg.createdAt)}</span>
                      <span
                        className={`channel-msg-user ${msg.isBot ? "channel-msg-bot" : ""}`}
                        style={msg.isBot ? undefined : { color: userColor(msg.userId) }}
                      >
                        {msg.userId}
                      </span>
                      <span className="channel-msg-text">{msg.content || "..."}</span>
                    </div>
                  ))}
                </div>
              ) : ch.lastMessagePreview ? (
                <div className="channel-card-preview">{ch.lastMessagePreview}</div>
              ) : null}
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

// ─── Section 2 — Counters ─────────────────────────────────────────────────────

function CountersSection({ agents, workers }) {
  const agentCount = agents.length;

  const workerStats = useMemo(() => {
    const running = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "running";
    }).length;
    const queued = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "queued";
    }).length;
    const waitingInput = workers.filter((w) => {
      const s = String(w?.status || "").toLowerCase();
      return s === "waitinginput" || s === "waiting_input";
    }).length;
    const active = running + queued + waitingInput;
    return { running, queued, waitingInput, active };
  }, [workers]);

  const stats = [
    {
      id: "agents",
      icon: "support_agent",
      value: agentCount,
      label: "Agents Available",
      sub: "Registered in sloppy"
    },
    {
      id: "active",
      icon: "play_circle",
      value: workerStats.active,
      label: "Tasks In Progress",
      sub: `${workerStats.running} running · ${workerStats.queued} queued`
    },
    {
      id: "running",
      icon: "bolt",
      value: workerStats.running,
      label: "Running Now",
      sub: `Active worker processes`
    },
    {
      id: "waiting",
      icon: "hourglass_empty",
      value: workerStats.waitingInput,
      label: "Waiting Input",
      sub: `Blocked on human review`
    }
  ];

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">monitoring</span>
          System Status
        </h2>
      </div>
      <div className="stat-row">
        {stats.map((stat) => (
          <div key={stat.id} className="stat-card">
            <div className="stat-card-icon">
              <span className="material-symbols-rounded">{stat.icon}</span>
            </div>
            <div className="stat-card-value">{stat.value}</div>
            <div className="stat-card-label">{stat.label}</div>
            <div className="stat-card-sub">{stat.sub}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

// ─── Section 3 — Bot Activity ─────────────────────────────────────────────────

const BOT_ACTIVITY_LIMIT = 12;

function BotActivitySection({ agents, sessions, onNavigateToBots, onNavigateToAgent }) {
  const agentActivity = useMemo(() => {
    return agents.map((agent) => ({
      ...agent,
      activity: buildActivityData(sessions, agent.id, 14)
    }));
  }, [agents, sessions]);

  if (agents.length === 0) {
    return (
      <section className="overview-section">
        <div className="overview-section-header">
          <h2>
            <span className="material-symbols-rounded">bar_chart</span>
            Bot Activity
          </h2>
        </div>
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">smart_toy</span>
          <p>No agents found. Create an agent to see activity.</p>
        </div>
      </section>
    );
  }

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">bar_chart</span>
          Bot Activity
          <span className="overview-section-period">Last 14 days</span>
        </h2>
        <span className="overview-section-count">{agents.length} bots</span>
      </div>
      <div className="activity-charts-grid">
        {agentActivity.slice(0, BOT_ACTIVITY_LIMIT).map((agent) => {
          const max = Math.max(...agent.activity.map((d) => d.value), 1);
          const first = agent.activity[0]?.dateStr;
          const mid = agent.activity[Math.floor(agent.activity.length / 2)]?.dateStr;
          const last = agent.activity[agent.activity.length - 1]?.dateStr;

          return (
            <button
              key={agent.id}
              type="button"
              className="agent-chart-card chart-card hover-levitate"
              onClick={() => onNavigateToAgent && onNavigateToAgent(agent.id)}
            >
              <div className="chart-header">
                <div className="agent-chart-title">
                  <span className="channel-agent-avatar agent-chart-avatar">
                    {agent.pet?.parts
                      ? <AgentPetIcon pet={agent.pet} parts={agent.pet.parts} genomeHex={agent.pet.genomeHex} />
                      : agentInitials(agent.displayName || agent.id)}
                  </span>
                  <h4>{agent.displayName || agent.id}</h4>
                </div>
                <span className="chart-period">Runs</span>
              </div>
              <div className="chart-body">
                <div className="chart-bars">
                  {agent.activity.map((d, i) => (
                    <div key={i} className="chart-bar-wrap">
                      <div
                        className="chart-bar bg-accent"
                        style={{ height: `${Math.round((d.value / max) * 100)}%` }}
                      />
                    </div>
                  ))}
                </div>
                <div className="chart-x-axis">
                  <span>{first}</span>
                  <span>{mid}</span>
                  <span>{last}</span>
                </div>
              </div>
            </button>
          );
        })}
      </div>
      {agents.length > BOT_ACTIVITY_LIMIT && (
        <button
          type="button"
          className="overview-show-all-btn"
          onClick={onNavigateToBots}
        >
          All {agents.length} bots
          <span className="material-symbols-rounded">arrow_forward</span>
        </button>
      )}
    </section>
  );
}

function AgentUsageSection({ agents, sessions, onNavigateToAgent }) {
  const [selectedAgentId, setSelectedAgentId] = useState("all");
  const [agentFilterOpen, setAgentFilterOpen] = useState(false);
  const [agentFilterQuery, setAgentFilterQuery] = useState("");
  const [activityMode, setActivityMode] = useState("daily");

  useEffect(() => {
    if (selectedAgentId === "all") return;
    if (!agents.some((agent) => String(agent?.id || "") === String(selectedAgentId))) {
      setSelectedAgentId("all");
    }
  }, [agents, selectedAgentId]);

  const selectedAgent = useMemo(() => {
    if (selectedAgentId === "all") return null;
    return agents.find((agent) => String(agent?.id || "") === String(selectedAgentId)) || null;
  }, [agents, selectedAgentId]);

  const agentOptions = useMemo(() => {
    const normalizedQuery = agentFilterQuery.trim().toLowerCase();
    const allOption = {
      id: "all",
      label: "All agents",
      subtitle: `${agents.length} total`
    };
    const filtered = agents
      .map((agent) => ({
        id: String(agent?.id || ""),
        label: String(agent?.displayName || agent?.id || "Agent"),
        subtitle: String(agent?.id || "")
      }))
      .filter((agent) => {
        if (!normalizedQuery) return true;
        return agent.label.toLowerCase().includes(normalizedQuery) || agent.subtitle.toLowerCase().includes(normalizedQuery);
      });
    return [allOption, ...filtered];
  }, [agentFilterQuery, agents]);

  const usage = useMemo(() => summarizeAgentUsage(sessions, selectedAgentId), [selectedAgentId, sessions]);

  const chartBars = activityMode === "daily"
    ? usage.daily.map((item) => ({
      key: item.key,
      label: item.date.toLocaleDateString(undefined, { month: "short", day: "numeric" }),
      value: item.value,
      intensity: usage.maxDaily > 0 ? item.value / usage.maxDaily : 0
    }))
    : (activityMode === "weekly" ? usage.weekly : usage.cumulative).map((item) => ({
      key: item.key,
      label: item.label,
      value: item.value,
      intensity: (activityMode === "weekly" ? usage.maxWeekly : usage.maxCumulative) > 0
        ? item.value / (activityMode === "weekly" ? usage.maxWeekly : usage.maxCumulative)
        : 0
    }));

  const topStatCards = [
    {
      id: "sessions",
      value: formatLargeNumber(usage.stats.totalSessions),
      label: "Total runs"
    },
    {
      id: "turns",
      value: formatLargeNumber(usage.stats.totalTurns),
      label: "User turns"
    },
    {
      id: "time",
      value: formatDurationCompact(usage.stats.totalDurationMs),
      label: "Time in sessions"
    },
    {
      id: "current",
      value: `${usage.stats.currentStreak}d`,
      label: "Current streak"
    },
    {
      id: "longest",
      value: `${usage.stats.longestStreak}d`,
      label: "Longest streak"
    }
  ];

  const selectedAgentLabel = selectedAgent?.displayName || selectedAgent?.id || "All agents";
  const longestSessionTitle = usage.stats.longestSession?.title || usage.stats.longestSession?.id || "—";

  return (
    <section className="overview-section agent-usage-section">
      <div className="overview-section-header agent-usage-header">
        <h2>
          <span className="material-symbols-rounded">schedule</span>
          Agent Time
          <span className="overview-section-period">Last 12 months</span>
        </h2>
        <div className="agent-usage-toolbar">
          <div className="actor-team-search-wrap agent-usage-filter">
            <input
              className="actor-team-search"
              value={agentFilterOpen ? agentFilterQuery : selectedAgentLabel}
              onChange={(event) => {
                setAgentFilterQuery(event.target.value);
                setAgentFilterOpen(true);
              }}
              onFocus={() => {
                setAgentFilterOpen(true);
                setAgentFilterQuery("");
              }}
              onBlur={() => {
                window.setTimeout(() => {
                  setAgentFilterOpen(false);
                  setAgentFilterQuery("");
                }, 100);
              }}
              placeholder="Filter agent"
            />
            {agentFilterOpen ? (
              <ul className="actor-team-dropdown">
                {agentOptions.length === 0 ? (
                  <li className="actor-team-dropdown-empty">No agents</li>
                ) : agentOptions.map((agent) => (
                  <li
                    key={agent.id}
                    className={`actor-team-dropdown-item ${selectedAgentId === agent.id ? "selected" : ""}`}
                    onMouseDown={(event) => {
                      event.preventDefault();
                      setSelectedAgentId(agent.id);
                      setAgentFilterQuery("");
                      setAgentFilterOpen(false);
                    }}
                  >
                    <span className="actor-team-dropdown-name">{agent.label}</span>
                    <span className="actor-team-dropdown-id">{agent.subtitle}</span>
                    {selectedAgentId === agent.id ? <span className="actor-team-dropdown-check">✓</span> : null}
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        </div>
      </div>

      <div className="agent-usage-hero">
        <div className="agent-usage-identity">
          <span className="agent-usage-avatar">
            {selectedAgent?.pet?.parts
              ? <AgentPetIcon pet={selectedAgent.pet} parts={selectedAgent.pet.parts} genomeHex={selectedAgent.pet.genomeHex} />
              : selectedAgent
                ? agentInitials(selectedAgent.displayName || selectedAgent.id)
                : "AI"}
          </span>
          <div className="agent-usage-copy">
            <h3>{selectedAgent ? selectedAgentLabel : "All agents"}</h3>
            <p>
              {selectedAgent
                ? `Tracking hands-on time, streaks, and session cadence for ${selectedAgentLabel}.`
                : "Tracking aggregate session time, streaks, and activity cadence across the whole agent fleet."}
            </p>
          </div>
          {selectedAgent ? (
            <button type="button" className="overview-show-all-btn agent-usage-link" onClick={() => onNavigateToAgent?.(selectedAgent.id)}>
              Open agent
              <span className="material-symbols-rounded">arrow_forward</span>
            </button>
          ) : null}
        </div>

        <div className="agent-usage-stats">
          {topStatCards.map((stat) => (
            <div key={stat.id} className="agent-usage-stat-card">
              <strong>{stat.value}</strong>
              <span>{stat.label}</span>
            </div>
          ))}
        </div>
      </div>

      {usage.stats.totalSessions === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">schedule</span>
          <p>No session history for this filter yet.</p>
        </div>
      ) : (
        <>
          <div className="agent-usage-chart-shell">
            <div className="agent-usage-chart-head">
              <h3>Activity</h3>
              <div className="agent-usage-mode-toggle" role="tablist" aria-label="Activity mode">
                {[
                  { id: "daily", label: "Daily" },
                  { id: "weekly", label: "Weekly" },
                  { id: "cumulative", label: "Cumulative" }
                ].map((mode) => (
                  <button
                    key={mode.id}
                    type="button"
                    className={activityMode === mode.id ? "active" : ""}
                    onClick={() => setActivityMode(mode.id)}
                  >
                    {mode.label}
                  </button>
                ))}
              </div>
            </div>

            {activityMode === "daily" ? (
              <>
                <div className="agent-usage-heatmap" aria-label="Daily activity heatmap">
                  {chartBars.map((item) => (
                    <span
                      key={item.key}
                      className="agent-usage-day"
                      title={`${item.label}: ${item.value} run${item.value === 1 ? "" : "s"}`}
                      style={{
                        opacity: item.value > 0 ? 0.22 + item.intensity * 0.78 : 0.12
                      }}
                    />
                  ))}
                </div>
                <div className="agent-usage-months">
                  {usage.monthLabels.map((label, index) => (
                    <span key={`${label}-${index}`}>{label}</span>
                  ))}
                </div>
              </>
            ) : (
              <div className="agent-usage-trend">
                {chartBars.map((item) => (
                  <div key={item.key} className="agent-usage-trend-bar-wrap">
                    <div
                      className="agent-usage-trend-bar"
                      title={`${item.label}: ${item.value} run${item.value === 1 ? "" : "s"}`}
                      style={{ height: `${item.value > 0 ? Math.max(10, Math.round(item.intensity * 100)) : 0}%` }}
                    />
                    <span>{item.label}</span>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="agent-usage-insights-grid">
            <section className="agent-usage-insights-card">
              <h3>Work summary</h3>
              <dl className="agent-usage-definition-list">
                <div>
                  <dt>Messages processed</dt>
                  <dd>{formatLargeNumber(usage.stats.totalMessages)}</dd>
                </div>
                <div>
                  <dt>Active days</dt>
                  <dd>{usage.stats.activeDays}</dd>
                </div>
                <div>
                  <dt>Avg runs per active day</dt>
                  <dd>{usage.stats.averagePerActiveDay.toFixed(1)}</dd>
                </div>
                <div>
                  <dt>Projects touched</dt>
                  <dd>{usage.stats.projectCount}</dd>
                </div>
                <div>
                  <dt>Top session kind</dt>
                  <dd>{usage.stats.topKind} · {usage.stats.topKindCount}</dd>
                </div>
                <div>
                  <dt>Last activity</dt>
                  <dd>{usage.stats.mostRecentSessionAt ? formatRelativeTime(usage.stats.mostRecentSessionAt) : "—"}</dd>
                </div>
              </dl>
            </section>

            <section className="agent-usage-insights-card">
              <h3>Longest run</h3>
              <div className="agent-usage-run-highlight">
                <strong>{formatDurationCompact(usage.stats.longestDurationMs)}</strong>
                <p>{longestSessionTitle}</p>
                {usage.stats.longestSession?.updatedAt ? (
                  <span>{formatRelativeTime(usage.stats.longestSession.updatedAt)}</span>
                ) : null}
              </div>
            </section>
          </div>
        </>
      )}
    </section>
  );
}

// ─── Section 4 — Closed Tasks ─────────────────────────────────────────────────

function ClosedTasksSection({ projects }) {
  const { doneTasks, totalDone } = useMemo(() => {
    const all = [];
    for (const project of projects) {
      const tasks = Array.isArray(project?.tasks) ? project.tasks : [];
      for (const task of tasks) {
        const status = String(task?.status || "").toLowerCase();
        if (status === "done") {
          all.push({
            id: String(task.id || ""),
            title: String(task.title || "Task"),
            projectName: String(project.name || project.id || ""),
            projectId: String(project.id || ""),
            updatedAt: task.updatedAt || task.createdAt || ""
          });
        }
      }
    }
    all.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
    return { doneTasks: all.slice(0, 10), totalDone: all.length };
  }, [projects]);

  return (
    <section className="overview-section">
      <div className="overview-section-header">
        <h2>
          <span className="material-symbols-rounded">task_alt</span>
          Closed Tasks
        </h2>
        <span className="overview-section-count stat-done">{totalDone} done</span>
      </div>

      {totalDone === 0 ? (
        <div className="overview-empty-state">
          <span className="material-symbols-rounded overview-empty-icon">checklist</span>
          <p>No completed tasks yet. Tasks marked as Done will appear here.</p>
        </div>
      ) : (
        <div className="closed-tasks-list">
          {doneTasks.map((task) => (
            <div key={`${task.projectId}-${task.id}`} className="closed-task-item">
              <span className="material-symbols-rounded closed-task-check">check_circle</span>
              <div className="closed-task-body">
                <span className="closed-task-title">{task.title}</span>
                <span className="closed-task-meta">{task.projectName}</span>
              </div>
              <span className="closed-task-time">
                {task.updatedAt ? formatRelativeTime(task.updatedAt) : "—"}
              </span>
            </div>
          ))}
          {totalDone > 10 && (
            <div className="closed-tasks-more">+{totalDone - 10} more completed tasks</div>
          )}
        </div>
      )}
    </section>
  );
}

function formatTelemetryMs(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return "—";
  return numeric >= 1000 ? `${(numeric / 1000).toFixed(1)}s` : `${Math.round(numeric)}ms`;
}

function TelemetryLineChart({ title, subtitle, samples, valueKey, secondaryKey, unit = "ms" }) {
  const width = 640;
  const height = 144;
  const padding = 14;
  const values = samples.flatMap((sample) => [Number(sample?.[valueKey]), Number(sample?.[secondaryKey])])
    .filter(Number.isFinite);
  const maxValue = Math.max(...values, 1);
  const pointsFor = (key) => samples.map((sample, index) => {
    const x = padding + (index / Math.max(1, samples.length - 1)) * (width - padding * 2);
    const raw = Number(sample?.[key]);
    const value = Number.isFinite(raw) ? raw : 0;
    const y = height - padding - (value / maxValue) * (height - padding * 2);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");

  return (
    <article className="performance-chart-card">
      <div className="performance-chart-heading">
        <div>
          <h3>{title}</h3>
          <p>{subtitle}</p>
        </div>
        <span>{unit === "x" ? `${maxValue.toFixed(0)}x peak` : formatTelemetryMs(maxValue)}</span>
      </div>
      {samples.length > 0 ? (
        <svg className="performance-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={title} preserveAspectRatio="none">
          <line x1={padding} y1={height - padding} x2={width - padding} y2={height - padding} className="performance-chart-axis" />
          {secondaryKey && <polyline points={pointsFor(secondaryKey)} className="performance-chart-line secondary" />}
          <polyline points={pointsFor(valueKey)} className="performance-chart-line primary" />
        </svg>
      ) : (
        <div className="performance-chart-empty">Telemetry appears after the next model response.</div>
      )}
    </article>
  );
}

function PerformanceTelemetrySection() {
  const [snapshot, setSnapshot] = useState(null);

  useEffect(() => {
    let cancelled = false;
    async function refresh() {
      const next = await fetchRuntimePerformance(60).catch(() => null);
      if (!cancelled && next) setSnapshot(next);
    }
    let timer;
    async function poll() {
      if (!document.hidden) await refresh();
      if (!cancelled) timer = window.setTimeout(poll, 5000);
    }
    poll();
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, []);

  const samples = Array.isArray(snapshot?.samples) ? snapshot.samples : [];
  const summary = snapshot?.summary || {};
  return (
    <section className="overview-section performance-telemetry-section">
      <div className="overview-section-header">
        <h2><span className="material-symbols-rounded">monitoring</span>Runtime performance</h2>
        <span className="overview-section-period">Live · 5s refresh · {samples.length} runs</span>
      </div>
      <div className="performance-kpi-grid">
        <div><span>TTFT avg / p95</span><strong>{formatTelemetryMs(summary.averageTimeToFirstTokenMs)} / {formatTelemetryMs(summary.p95TimeToFirstTokenMs)}</strong></div>
        <div><span>Delta interval</span><strong>{formatTelemetryMs(summary.averageDeltaIntervalMs)}</strong></div>
        <div><span>Generation</span><strong>{formatTelemetryMs(summary.averageGenerationDurationMs)}</strong></div>
        <div><span>Text throughput</span><strong>{Number(summary.averageCharactersPerSecond || 0).toFixed(0)} char/s</strong></div>
        <div><span>Tool calls</span><strong>{Number(summary.totalToolCalls || 0)}</strong></div>
        <div><span>Peak tool parallelism</span><strong>{Number(summary.peakParallelToolCalls || 0)}x</strong></div>
      </div>
      <div className="performance-chart-grid">
        <TelemetryLineChart
          title="Response latency"
          subtitle="TTFT (bright) and full generation (muted)"
          samples={samples}
          valueKey="timeToFirstTokenMs"
          secondaryKey="generationDurationMs"
        />
        <TelemetryLineChart
          title="Delta cadence"
          subtitle="Average (bright) and worst inter-delta gap (muted)"
          samples={samples}
          valueKey="averageDeltaIntervalMs"
          secondaryKey="maxDeltaIntervalMs"
        />
        <TelemetryLineChart
          title="Tool parallelism"
          subtitle="Concurrent tool calls observed in each run"
          samples={samples}
          valueKey="maxParallelToolCalls"
          unit="x"
        />
      </div>
    </section>
  );
}

// ─── Main View ────────────────────────────────────────────────────────────────

export function RuntimeOverviewView({ workers, events, onNavigateToProject, onNavigateToChannelSession, onNavigateToBots, onNavigateToAgent }) {
  const [agents, setAgents] = useState([]);
  const [projects, setProjects] = useState([]);
  const [sessions, setSessions] = useState([]);
  const [activityStatus, setActivityStatus] = useState("loading");
  const [channelSessions, setChannelSessions] = useState([]);
  const [channelSessionDetails, setChannelSessionDetails] = useState({});
  const [actorBoard, setActorBoard] = useState({ nodes: [], links: [], teams: [] });
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setIsLoading(true);
      const [agentsRes, projectsRes, boardRes, channelSessionsRes] = await Promise.all([
        fetchAgents().catch(() => null),
        fetchProjects().catch(() => null),
        fetchActorsBoard().catch(() => null),
        fetchChannelSessions({ status: "open", recentMessagesLimit: CHANNEL_MESSAGES_LIMIT }).catch(() => null)
      ]);
      if (cancelled) return;
      const loadedAgents = Array.isArray(agentsRes) ? agentsRes : [];
      setAgents(loadedAgents);
      setProjects(Array.isArray(projectsRes) ? projectsRes : []);
      setActorBoard(boardRes && Array.isArray(boardRes.nodes) ? boardRes : { nodes: [], links: [], teams: [] });
      const loadedChannelSessions = Array.isArray(channelSessionsRes) ? channelSessionsRes : [];
      setChannelSessions(loadedChannelSessions);
      setChannelSessionDetails({});

      if (!cancelled) setIsLoading(false);
    }
    // Activity loads alongside the core cards and never holds the whole page hostage.
    fetchAllAgentSessions().then((result) => {
      if (cancelled) return;
      if (Array.isArray(result)) {
        setSessions(result);
        setActivityStatus("ready");
      } else {
        setActivityStatus("unavailable");
      }
    }).catch(() => { if (!cancelled) setActivityStatus("unavailable"); });
    load();
    return () => { cancelled = true; };
  }, []);

  const normalizedWorkers = Array.isArray(workers) ? workers : [];

  return (
    <main className="overview-shell">
      <Breadcrumbs
        items={[
          { id: 'overview', label: 'Overview' },
        ]}
        style={{ marginBottom: '20px' }}
      />

      {isLoading ? (
        <LoadingSkeleton label="Loading runtime overview…" variant="page" rows={4} />
      ) : (
        <>
          <CountersSection agents={agents} workers={normalizedWorkers} />

          <ActiveChannelsSection
            agents={agents}
            sessions={sessions}
            channelSessions={channelSessions}
            channelSessionDetails={channelSessionDetails}
            projects={projects}
            actorBoard={actorBoard}
            onNavigateToProject={onNavigateToProject}
            onNavigateToChannelSession={onNavigateToChannelSession}
          />

          {activityStatus === "loading" ? <LoadingSkeleton label="Loading agent activity…" variant="cards" cards={3} />
            : activityStatus === "unavailable" ? <p role="alert">Agent activity is unavailable. Reload to retry.</p>
            : <>
              <BotActivitySection agents={agents} sessions={sessions} onNavigateToBots={onNavigateToBots} onNavigateToAgent={onNavigateToAgent} />
              <AgentUsageSection agents={agents} sessions={sessions} onNavigateToAgent={onNavigateToAgent} />
            </>}

          <ClosedTasksSection projects={projects} />

          <RequestPerformanceSection />
          <PerformanceTelemetrySection />
        </>
      )}
    </main>
  );
}
