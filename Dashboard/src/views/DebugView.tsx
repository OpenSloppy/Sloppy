import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CoreApi } from "../shared/api/coreApi";
import { TeamAssignmentPicker } from "../features/actors/TeamAssignmentPicker";
import { MemoryDiagnosticsPanel, MemoryDiagnosticsData, ContextLedgerData } from "../features/debug/MemoryDiagnosticsPanel";

type AnyRecord = Record<string, unknown>;

interface Props {
  coreApi: CoreApi;
}

interface Agent {
  id: string;
  displayName: string;
}

interface Session {
  id: string;
  title: string;
  source: "agent" | "channel";
}

interface DocumentSizes {
  agentsMarkdown: number;
  userMarkdown: number;
  identityMarkdown: number;
  soulMarkdown: number;
  friendReminderMarkdown?: number;
  memoryMarkdown?: number;
}

interface SessionContextData {
  agentId: string;
  sessionId: string;
  channelId: string;
  bootstrapContent: string | null;
  bootstrapChars: number;
  documentSizes: DocumentSizes;
  skillsCount: number;
  installedSkillIds: string[];
  contextUtilization: number | null;
  channelMessageCount: number | null;
  activeWorkerIds: string[] | null;
  selectedModel: string | null;
  runtimeType: string | null;
  conversationHistoryChars: number | null;
  conversationHistoryMessageCount: number | null;
  memoryDiagnostics?: MemoryDiagnosticsData;
  contextLedger?: ContextLedgerData;
}

interface ChannelInfo {
  channelId: string;
  messageCount: number;
  contextUtilization: number;
  bootstrapChars: number;
  activeWorkerIds: string[];
}

interface PromptTemplate {
  name: string;
  content: string;
  chars: number;
}

const DEBUG_CHANNELS_PAGE_SIZE = 20;

function kilo(n: number) {
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

function pct(n: number) {
  return `${(n * 100).toFixed(1)}%`;
}

function UtilBar({ value }: { value: number }) {
  const pctNum = Math.min(1, Math.max(0, value)) * 100;
  const color = pctNum > 80 ? "var(--danger)" : pctNum > 50 ? "var(--warn)" : "var(--success)";
  return (
    <div className="debug-util-bar-track">
      <div className="debug-util-bar-fill" style={{ width: `${pctNum}%`, background: color }} />
      <span className="debug-util-bar-label">{pct(value)}</span>
    </div>
  );
}

function SectionSizeBar({ label, chars, total }: { label: string; chars: number; total: number }) {
  const pctNum = total > 0 ? Math.min(100, (chars / total) * 100) : 0;
  return (
    <div className="debug-section-row">
      <span className="debug-section-label">{label}</span>
      <div className="debug-section-bar-track">
        <div className="debug-section-bar-fill" style={{ width: `${pctNum}%` }} />
      </div>
      <span className="debug-section-chars">{kilo(chars)}c</span>
    </div>
  );
}

function Panel({ title, children, action }: { title: string; children: React.ReactNode; action?: React.ReactNode }) {
  return (
    <section className="debug-panel">
      <header className="debug-panel-header">
        <h3 className="debug-panel-title">{title}</h3>
        {action}
      </header>
      <div className="debug-panel-body">{children}</div>
    </section>
  );
}

function SessionContextPanel({ coreApi }: { coreApi: CoreApi }) {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [selectedAgent, setSelectedAgent] = useState("");
  const [selectedSession, setSelectedSession] = useState("");
  const [data, setData] = useState<SessionContextData | null>(null);
  const [loading, setLoading] = useState(false);
  const [showBootstrap, setShowBootstrap] = useState(false);
  const [error, setError] = useState("");
  const selection = useRef("");
  const latestRequest = useRef(0);
  const pendingSelection = useRef<string | null>(null);
  selection.current = `${selectedAgent}:${selectedSession}`;

  useEffect(() => {
    coreApi.fetchAgents().then((result) => {
      if (!Array.isArray(result)) return;
      setAgents(result.map((a) => ({ id: String(a.id ?? ""), displayName: String(a.displayName ?? a.id ?? "") })));
    });
  }, [coreApi]);

  useEffect(() => {
    if (!selectedAgent) {
      setSessions([]);
      setSelectedSession("");
      setData(null);
      return;
    }
    let cancelled = false;
    Promise.all([
      coreApi.fetchAgentSessions(selectedAgent).catch(() => null),
      coreApi.fetchChannelSessions({ agentId: selectedAgent }).catch(() => null)
    ]).then(([agentSessionsResult, channelSessionsResult]) => {
      if (cancelled) return;
      const dedup = new Map<string, Session>();

      if (Array.isArray(agentSessionsResult)) {
        for (const session of agentSessionsResult) {
          const id = String(session?.id ?? "").trim();
          if (!id) continue;
          dedup.set(id, {
            id,
            title: String(session?.title ?? id),
            source: "agent"
          });
        }
      }

      if (Array.isArray(channelSessionsResult)) {
        for (const channelSession of channelSessionsResult) {
          const id = String(channelSession?.sessionId ?? "").trim();
          if (!id) continue;
          const channelId = String(channelSession?.channelId ?? "").trim();
          const preview = String(channelSession?.lastMessagePreview ?? "").trim();
          const labelParts = [channelId ? `[channel] ${channelId}` : "[channel]", preview].filter(Boolean);
          const title = labelParts.join(" · ") || id;
          const existing = dedup.get(id);
          if (!existing) {
            dedup.set(id, { id, title, source: "channel" });
          } else if (existing.source !== "channel") {
            dedup.set(id, {
              id,
              title: `${existing.title} [channel]`,
              source: existing.source
            });
          }
        }
      }

      const merged = Array.from(dedup.values()).sort((a, b) => a.title.localeCompare(b.title));
      setSessions(merged);
    });
    return () => {
      cancelled = true;
    };
  }, [coreApi, selectedAgent]);

  const load = useCallback(async () => {
    if (!selectedAgent || !selectedSession) return;
    const requestedSelection = `${selectedAgent}:${selectedSession}`;
    if (pendingSelection.current === requestedSelection) return;
    pendingSelection.current = requestedSelection;
    const requestId = ++latestRequest.current;
    setLoading(true);
    try {
      const result = await coreApi.fetchDebugSessionContext(selectedAgent, selectedSession);
      if (selection.current !== requestedSelection || latestRequest.current !== requestId) return;
      setError(result ? "" : "Could not load session diagnostics.");
      if (result) setData(result as unknown as SessionContextData);
    } catch {
      if (selection.current === requestedSelection && latestRequest.current === requestId) setError("Could not load session diagnostics.");
    } finally {
      if (latestRequest.current === requestId) {
        pendingSelection.current = null;
        setLoading(false);
      }
    }
  }, [coreApi, selectedAgent, selectedSession]);

  useEffect(() => {
    if (!selectedAgent || !selectedSession) return;
    void load();
    const timer = window.setInterval(() => { void load(); }, 5000);
    return () => window.clearInterval(timer);
  }, [load, selectedAgent, selectedSession]);

  const docTotal = useMemo(() => {
    if (!data) return 0;
    return (
      data.documentSizes.agentsMarkdown +
      data.documentSizes.userMarkdown +
      data.documentSizes.identityMarkdown +
      data.documentSizes.soulMarkdown +
      Number(data.documentSizes.friendReminderMarkdown || 0) +
      Number(data.documentSizes.memoryMarkdown || 0)
    );
  }, [data]);

  return (
    <Panel
      title="Session Context Inspector"
      action={
        <button type="button" className="hover-levitate" onClick={load} disabled={!selectedAgent || !selectedSession || loading}>
          {loading ? "Loading..." : "Inspect"}
        </button>
      }
    >
      <div className="debug-selectors">
        <div className="debug-select-label">
          <span>Agent</span>
          <TeamAssignmentPicker
            label="Debug agent"
            value={selectedAgent}
            options={agents.map((agent) => ({ id: agent.id, name: agent.displayName }))}
            emptyLabel="Select agent"
            onChange={(value) => { setSelectedAgent(value); setSelectedSession(""); setData(null); setError(""); }}
          />
        </div>
        <div className="debug-select-label">
          <span>Session</span>
          <TeamAssignmentPicker
            label="Debug session"
            value={selectedSession}
            options={sessions.map((session) => ({ id: session.id, name: session.title || session.id }))}
            emptyLabel="Select session"
            onChange={(value) => { setSelectedSession(value); setData(null); setError(""); }}
            disabled={!selectedAgent}
          />
        </div>
      </div>
      {error && <p role="alert">{error}</p>}

      {data && (
        <div className="debug-context-result">
          <div className="debug-meta-grid">
            <div className="debug-meta-item">
              <span className="debug-meta-key">Channel ID</span>
              <code className="debug-meta-val">{data.channelId}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Model</span>
              <code className="debug-meta-val">{data.selectedModel ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Runtime</span>
              <code className="debug-meta-val">{data.runtimeType ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Skills</span>
              <code className="debug-meta-val">{data.skillsCount}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Channel messages</span>
              <code className="debug-meta-val">{data.channelMessageCount ?? "—"}</code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">History injected</span>
              <code className="debug-meta-val">
                {data.conversationHistoryMessageCount != null
                  ? `${data.conversationHistoryMessageCount} msgs / ${kilo(data.conversationHistoryChars ?? 0)}c`
                  : "none"}
              </code>
            </div>
            <div className="debug-meta-item">
              <span className="debug-meta-key">Active workers</span>
              <code className="debug-meta-val">{data.activeWorkerIds?.join(", ") || "—"}</code>
            </div>
          </div>

          {data.contextUtilization != null && (
            <div className="debug-util-section">
              <span className="debug-meta-key">Context utilization</span>
              <UtilBar value={data.contextUtilization} />
            </div>
          )}

          <div className="debug-section-breakdown">
            <p className="debug-subsection-title">Document sizes (total {kilo(docTotal)}c)</p>
            <SectionSizeBar label="AGENTS.md" chars={data.documentSizes.agentsMarkdown} total={docTotal} />
            <SectionSizeBar label="USER.md" chars={data.documentSizes.userMarkdown} total={docTotal} />
            <SectionSizeBar label="MEMORY.md" chars={data.documentSizes.memoryMarkdown || 0} total={docTotal} />
            <SectionSizeBar label="IDENTITY.md" chars={data.documentSizes.identityMarkdown} total={docTotal} />
            <SectionSizeBar label="SOUL.md" chars={data.documentSizes.soulMarkdown} total={docTotal} />
            <SectionSizeBar label="FRIEND_REMINDER.md" chars={data.documentSizes.friendReminderMarkdown || 0} total={docTotal} />
          </div>

          {data.installedSkillIds.length > 0 && (
            <div className="debug-skills-list">
              <p className="debug-subsection-title">Installed skills</p>
              {data.installedSkillIds.map((id) => (
                <code key={id} className="debug-skill-tag">{id}</code>
              ))}
            </div>
          )}

          <div className="debug-bootstrap-toggle">
            <button
              type="button"
              className="hover-levitate"
              onClick={() => setShowBootstrap((v) => !v)}
              disabled={!data.bootstrapContent}
            >
              {showBootstrap ? "Hide" : "Show"} bootstrap prompt ({kilo(data.bootstrapChars)}c)
            </button>
          </div>

          {showBootstrap && data.bootstrapContent && (
            <pre className="debug-bootstrap-pre">{data.bootstrapContent}</pre>
          )}
          <MemoryDiagnosticsPanel data={data.memoryDiagnostics} ledger={data.contextLedger} />
        </div>
      )}
    </Panel>
  );
}

function ChannelsPanel({ coreApi }: { coreApi: CoreApi }) {
  const [channels, setChannels] = useState<ChannelInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedChannelId, setSelectedChannelId] = useState("");
  const [statusText, setStatusText] = useState("");
  const [visibleCount, setVisibleCount] = useState(DEBUG_CHANNELS_PAGE_SIZE);

  function parseSessionScopedChannel(channelId: string): { agentId: string; sessionId: string } | null {
    const normalized = String(channelId || "").trim();
    const marker = ":session:";
    if (!normalized.startsWith("agent:") || !normalized.includes(marker)) {
      return null;
    }
    const markerIndex = normalized.indexOf(marker);
    if (markerIndex <= "agent:".length) {
      return null;
    }
    const agentId = normalized.slice("agent:".length, markerIndex).trim();
    const sessionId = normalized.slice(markerIndex + marker.length).trim();
    if (!agentId || !sessionId) {
      return null;
    }
    return { agentId, sessionId };
  }

  const load = useCallback(async () => {
    setLoading(true);
    setStatusText("");
    const result = await coreApi.fetchDebugChannels();
    setLoading(false);
    if (!result || !Array.isArray((result as AnyRecord).channels)) return;
    setChannels((result as AnyRecord).channels as ChannelInfo[]);
    setVisibleCount(DEBUG_CHANNELS_PAGE_SIZE);
  }, [coreApi]);

  useEffect(() => {
    load();
  }, [load]);

  async function deleteSelectedChannel() {
    if (!selectedChannelId) {
      setStatusText("Select a channel first.");
      return;
    }
    const scoped = parseSessionScopedChannel(selectedChannelId);
    if (!scoped) {
      setStatusText("Only session-scoped channels can be deleted from this panel.");
      return;
    }
    const ok = await coreApi.deleteAgentSession(scoped.agentId, scoped.sessionId);
    if (!ok) {
      setStatusText("Failed to delete channel session.");
      return;
    }
    setStatusText(`Deleted session channel ${selectedChannelId}.`);
    setSelectedChannelId("");
    await load();
  }

  const visibleChannels = channels.slice(0, visibleCount);
  const remainingChannels = Math.max(0, channels.length - visibleChannels.length);

  return (
    <Panel
      title="Active Channels"
      action={
        <div className="debug-panel-actions">
          <button type="button" className="hover-levitate" onClick={deleteSelectedChannel} disabled={!selectedChannelId || loading}>
            Delete selected
          </button>
          <button type="button" className="hover-levitate" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "Refresh"}
          </button>
        </div>
      }
    >
      {channels.length === 0 ? (
        <p className="placeholder-text">{loading ? "Loading..." : "No active channels."}</p>
      ) : (
        <>
          <div className="debug-channels-table">
            <div className="debug-table-head">
              <span>Channel</span>
              <span>Msgs</span>
              <span>Utilization</span>
              <span>Bootstrap</span>
              <span>Workers</span>
              <span>Actions</span>
            </div>
            {visibleChannels.map((ch) => (
              <div
                key={ch.channelId}
                className={`debug-table-row ${selectedChannelId === ch.channelId ? "selected" : ""}`}
                onClick={() => setSelectedChannelId(ch.channelId)}
                role="button"
                tabIndex={0}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    setSelectedChannelId(ch.channelId);
                  }
                }}
              >
                <code className="debug-channel-id">{ch.channelId}</code>
                <span>{ch.messageCount}</span>
                <UtilBar value={ch.contextUtilization} />
                <span>{kilo(ch.bootstrapChars)}c</span>
                <span>{ch.activeWorkerIds.length > 0 ? ch.activeWorkerIds.join(", ") : "—"}</span>
                <div className="debug-row-actions">
                  <button
                    type="button"
                    className="hover-levitate"
                    onClick={(event) => {
                      event.stopPropagation();
                      setSelectedChannelId(ch.channelId);
                    }}
                  >
                    {selectedChannelId === ch.channelId ? "Selected" : "Select"}
                  </button>
                </div>
              </div>
            ))}
          </div>
          {remainingChannels > 0 && (
            <div className="debug-load-more">
              <span>
                Showing {visibleChannels.length} of {channels.length} channels
              </span>
              <button
                type="button"
                className="hover-levitate"
                onClick={() => setVisibleCount((count) => count + DEBUG_CHANNELS_PAGE_SIZE)}
              >
                Load more ({remainingChannels} remaining)
              </button>
            </div>
          )}
        </>
      )}
      {statusText ? <p className="placeholder-text">{statusText}</p> : null}
      {selectedChannelId ? <p className="placeholder-text">Selected channel: <code>{selectedChannelId}</code></p> : null}
    </Panel>
  );
}

function PromptTemplatesPanel({ coreApi }: { coreApi: CoreApi }) {
  const [templates, setTemplates] = useState<PromptTemplate[]>([]);
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  useEffect(() => {
    setLoading(true);
    coreApi.fetchDebugPromptTemplates().then((result) => {
      setLoading(false);
      if (!result || !Array.isArray((result as AnyRecord).templates)) return;
      setTemplates((result as AnyRecord).templates as PromptTemplate[]);
    });
  }, [coreApi]);

  function toggle(name: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(name)) {
        next.delete(name);
      } else {
        next.add(name);
      }
      return next;
    });
  }

  return (
    <Panel title="Prompt Partials">
      {loading && <p className="placeholder-text">Loading...</p>}
      <div className="debug-templates-list">
        {templates.map((t) => (
          <div key={t.name} className="debug-template-item">
            <button
              type="button"
              className="debug-template-toggle"
              onClick={() => toggle(t.name)}
            >
              <code>{t.name}</code>
              <span className="debug-template-meta">{kilo(t.chars)}c</span>
              <span className="material-symbols-rounded debug-template-chevron" aria-hidden="true">
                {expanded.has(t.name) ? "expand_less" : "expand_more"}
              </span>
            </button>
            {expanded.has(t.name) && (
              <pre className="debug-template-content">{t.content}</pre>
            )}
          </div>
        ))}
      </div>
    </Panel>
  );
}

export function DebugView({ coreApi }: Props) {
  return (
    <main className="grid debug-view">
      <div className="debug-header">
        <h2>Debug</h2>
        <p className="placeholder-text">Dev-only. Inspect session context, channel state, and prompt templates.</p>
      </div>
      <SessionContextPanel coreApi={coreApi} />
      <ChannelsPanel coreApi={coreApi} />
      <PromptTemplatesPanel coreApi={coreApi} />
    </main>
  );
}
