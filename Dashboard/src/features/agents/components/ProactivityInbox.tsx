import React, { useCallback, useEffect, useRef, useState } from "react";
import { fetchProactiveInbox, updateProactiveFinding } from "../../../shared/api/coreApi";
import type { ProactiveInbox, ProactiveFinding } from "../../../shared/api/proactivity";
import { navigateToTaskScreen } from "../../../app/routing/navigateToTaskScreen";
import { useNotifications } from "../../notifications/NotificationContext";
import "./proactivity.css";

export function ProactivityInbox({ agentId, onOpenSession }: { agentId: string; onOpenSession: (agentId: string, sessionId: string) => void }) {
  const [inbox, setInbox] = useState<ProactiveInbox | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [showHistory, setShowHistory] = useState(false);
  const openedFinding = useRef("");
  const { notifications, markRead } = useNotifications();
  const load = useCallback(async () => {
    try { setInbox(await fetchProactiveInbox(agentId)); setError(""); }
    catch (error) { setError(String((error as Error).message)); }
  }, [agentId]);
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try { const next = await fetchProactiveInbox(agentId); if (!cancelled) { setInbox(next); setError(""); } }
      catch (error) { if (!cancelled) setError(String((error as Error).message)); }
    };
    void refresh(); const timer = window.setInterval(refresh, 30_000);
    const reconnect = () => { if (document.visibilityState === "visible") void refresh(); };
    window.addEventListener("online", reconnect); document.addEventListener("visibilitychange", reconnect);
    return () => { cancelled = true; window.clearInterval(timer); window.removeEventListener("online", reconnect); document.removeEventListener("visibilitychange", reconnect); };
  }, [agentId]);
  const act = async (finding: ProactiveFinding, action: "read" | "snooze" | "dismiss") => {
    setBusy(finding.id);
    try {
      const updated = await updateProactiveFinding(agentId, finding.id, action);
      for (const notification of notifications) {
        if (notification.type !== "proactive_attention" || notification.metadata?.agentId !== agentId) continue;
        const ids = (notification.metadata.findingIds || notification.metadata.findingId || "").split(",");
        if (ids.includes(finding.id) && ids.every((id) => {
          const value = id === finding.id ? updated : inbox?.findings.find((item) => item.id === id);
          return value && (value.readAt || value.dismissedAt || value.resolvedAt || value.snoozedUntil);
        })) markRead(notification.id);
      }
      await load();
    }
    catch (error) { setError(String((error as Error).message)); }
    finally { setBusy(""); }
  };
  useEffect(() => {
    const rawId = window.location.hash.startsWith("#finding-") ? window.location.hash.slice(9) : "";
    let id = "";
    try { id = decodeURIComponent(rawId); } catch { return; }
    const key = `${agentId}:${id}`;
    if (!id || openedFinding.current === key || !inbox?.findings.some((finding) => finding.id === id)) return;
    openedFinding.current = key;
    setShowHistory(true);
    window.requestAnimationFrame(() => document.getElementById(`finding-${id}`)?.scrollIntoView({ block: "center" }));
  }, [inbox, agentId]);
  const findings = inbox?.findings.filter((finding) => showHistory || (!finding.dismissedAt && !finding.resolvedAt)) ?? [];
  return <section className="proactivity-inbox" data-testid="proactivity-inbox">
    <header className="proactivity-header">
      <div><div className="proactivity-eyebrow"><span className="material-symbols-rounded" aria-hidden="true">notifications_active</span> Agent updates</div>
        <h2>Attention</h2><p>Your agent watches for changes that need your next step.</p></div>
      <button type="button" className="proactivity-button proactivity-refresh" onClick={load}><span className="material-symbols-rounded" aria-hidden="true">refresh</span>Refresh</button>
    </header>
    <div className="proactivity-toolbar">
      <div className="proactivity-filter" role="group" aria-label="Finding history">
        <button type="button" aria-pressed={!showHistory} onClick={() => setShowHistory(false)}>Active</button>
        <button type="button" aria-pressed={showHistory} onClick={() => setShowHistory(true)}>All history</button>
      </div>
      <div className="proactivity-check-meta">
        {inbox?.lastCheckedAt && <span>Checked {new Date(inbox.lastCheckedAt).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</span>}
        {!!inbox?.pendingAnalysisCount && <span>{inbox.pendingAnalysisCount} reviews queued</span>}
      </div>
    </div>
    {error && <p className="proactivity-notice" role="alert">{error}</p>}
    {Object.entries(inbox?.sourceErrors ?? {}).map(([source, message]) => <p className="proactivity-notice" role="status" key={source}>{source}: {message}</p>)}
    {inbox?.lastAnalysisError && <p className="proactivity-notice" role="status">Review could not finish: {inbox.lastAnalysisError}</p>}
    {!findings.length && <div className="proactivity-empty"><span className="material-symbols-rounded" aria-hidden="true">task_alt</span><h3>{inbox ? "You're all caught up" : "Loading findings…"}</h3><p>{inbox ? "New findings will appear here when your agent spots something actionable." : "Checking your agent's updates."}</p></div>}
    <div className="proactivity-findings">
    {findings.map((finding) => <article className="proactivity-finding" id={`finding-${finding.id}`} key={finding.id}>
      <header className="proactivity-finding-header">
        <div className="proactivity-source-icon"><span className="material-symbols-rounded" aria-hidden="true">{finding.source.kind === "task" ? "checklist" : "merge"}</span></div>
        <div className="proactivity-finding-title"><span className="proactivity-source-label">{finding.source.kind === "task" ? "Task" : "Pull request"}</span><h3>{finding.source.title}</h3></div>
        <span className={`proactivity-badge ${finding.resolvedAt ? "is-resolved" : ""}`}>{finding.resolvedAt ? "Resolved" : finding.outcome === "needs_input" ? "Input needed" : "Suggested action"}</span>
      </header>
      <div className="proactivity-finding-body">
        <div className="proactivity-detail"><h4>Why it matters</h4><p>{finding.reason}</p></div>
        <div className="proactivity-detail"><h4>What happened</h4><p>{finding.evidence}</p></div>
        <div className="proactivity-next-step"><span className="material-symbols-rounded" aria-hidden="true">subdirectory_arrow_right</span><div><h4>Next step</h4><p>{finding.nextStep}</p></div></div>
      </div>
      <footer className="proactivity-finding-footer">
        <div className="proactivity-primary-actions">
          <button type="button" className="proactivity-button is-primary" onClick={() => { void act(finding, "read"); onOpenSession(agentId, finding.sessionId); }}><span className="material-symbols-rounded" aria-hidden="true">chat_bubble</span>Discuss with agent</button>
          {finding.source.taskId && <button type="button" className="proactivity-button" onClick={() => navigateToTaskScreen(finding.source.taskId!)}>Open task<span className="material-symbols-rounded" aria-hidden="true">arrow_outward</span></button>}
          {finding.source.url && /^https?:\/\//i.test(finding.source.url) && <a className="proactivity-button" href={finding.source.url} target="_blank" rel="noreferrer">Open source<span className="material-symbols-rounded" aria-hidden="true">arrow_outward</span></a>}
        </div>
        <div className="proactivity-secondary-actions">
          <button type="button" disabled={busy === finding.id || !!finding.readAt} onClick={() => act(finding, "read")}><span className="material-symbols-rounded" aria-hidden="true">check</span>{finding.readAt ? "Read" : "Mark read"}</button>
          <button type="button" disabled={busy === finding.id} onClick={() => act(finding, "snooze")}><span className="material-symbols-rounded" aria-hidden="true">schedule</span>Snooze 24h</button>
          <button type="button" disabled={busy === finding.id || !!finding.dismissedAt} onClick={() => act(finding, "dismiss")}><span className="material-symbols-rounded" aria-hidden="true">close</span>Dismiss</button>
        </div>
      </footer>
      {finding.snoozedUntil && <div className="proactivity-snoozed">Snoozed until {new Date(finding.snoozedUntil).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</div>}
    </article>)}
    </div>
  </section>;
}
