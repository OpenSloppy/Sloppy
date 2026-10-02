import React, { useEffect, useState } from "react";
import { fetchLongChat, updateLongChatTask, cancelLongChatTasks } from "../../../api";
import { AgentPetIcon } from "./AgentPetSprite";
import { WorkerTaskCard } from "./WorkerTaskCard";
import "./longChat.css";

export function LongChatPanel({ agentId, sessionId, onOpenWorker }) {
  const [conversation, setConversation] = useState<any>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    async function refresh() {
      try {
        const next = await fetchLongChat(agentId, sessionId);
        if (!disposed) { setConversation(next); setError(""); }
      } catch (failure) { if (!disposed) setError(String(failure)); }
      if (!disposed) timer = setTimeout(refresh, 2000);
    }
    setConversation(null);
    void refresh();
    return () => { disposed = true; clearTimeout(timer); };
  }, [agentId, sessionId]);

  const tasks = conversation?.assignments?.flatMap((assignment) => assignment.tasks.map((task) => ({ ...task, assignmentTitle: assignment.title }))) || [];
  const active = tasks.filter((task) => ["queued", "running", "waiting_input"].includes(task.attempts.at(-1)?.status));
  async function act(taskId, action) {
    setBusy(taskId || "all");
    try {
      if (taskId) setConversation(await updateLongChatTask(agentId, sessionId, taskId, action));
      else { await cancelLongChatTasks(agentId, sessionId); setConversation(await fetchLongChat(agentId, sessionId)); }
      setError("");
    } catch (failure) { setError(String(failure)); }
    finally { setBusy(""); }
  }

  const counts = [
    ["running", "working"], ["waiting_input", "waiting for input"], ["queued", "queued"],
    ["completed", "completed"], ["failed", "failed"], ["cancelled", "cancelled"]
  ].map(([status, label]) => ({ label, count: tasks.filter((task) => task.attempts.at(-1)?.status === status).length }))
    .filter((item) => item.count > 0);

  if (!tasks.length && !error) return null;
  return <section className="long-chat-panel" data-testid="long-chat-panel" aria-label="Worker activity">
    <div className="long-chat-summary">
      <button type="button" className="long-chat-summary-toggle" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
        <span className="chat-worker-avatar-stack" aria-hidden="true">
          {tasks.slice(0, 4).map((task) => <AgentPetIcon key={task.id} agentId={agentId} />)}
        </span>
        <span className="long-chat-summary-copy"><strong>Workers · {tasks.length}</strong>
          <span>{counts.map((item) => `${item.count} ${item.label}`).join(" · ")}</span>
        </span>
        <span className="material-symbols-rounded" aria-hidden="true">{expanded ? "expand_less" : "expand_more"}</span>
      </button>
      {active.length > 0 && <button type="button" disabled={Boolean(busy)} onClick={() => void act(null, "cancel")}>Stop all tasks</button>}
    </div>
    {error && <p role="alert">{error}</p>}
    {expanded && <div className="long-chat-workers">
      {tasks.map((task) => {
        const attempt = task.attempts.at(-1);
        return <WorkerTaskCard key={task.id} agentId={agentId} title={task.title} status={attempt.status}
          summary={attempt.summary} sessionId={attempt.sessionId} attemptNumber={attempt.number} onOpen={onOpenWorker}>
          {["queued", "running", "waiting_input"].includes(attempt.status) && <button type="button" disabled={Boolean(busy)} onClick={() => void act(task.id, "cancel")}>Cancel</button>}
          {["failed", "cancelled"].includes(attempt.status) && <button type="button" disabled={Boolean(busy)} onClick={() => void act(task.id, "retry")}>Retry</button>}
          {task.attempts.length > 1 && <details><summary>Previous attempts</summary>{task.attempts.slice(0, -1).map((previous) => <button type="button" key={previous.id} disabled={!previous.sessionId} onClick={() => onOpenWorker(previous.sessionId, task.title)}>Attempt {previous.number}: {previous.status}</button>)}</details>}
        </WorkerTaskCard>;
      })}
    </div>}
  </section>;
}
