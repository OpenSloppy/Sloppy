import React, { useEffect, useState } from "react";
import { fetchLongChat, updateLongChatTask, cancelLongChatTasks } from "../../../api";
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

  return <section className="long-chat-panel" data-testid="long-chat-panel" aria-label="Worker assignments">
    <div className="long-chat-summary">
      <strong>Long chat</strong><span>{active.length} active · {tasks.length} tasks</span>
      <button type="button" onClick={() => setExpanded(!expanded)}>{expanded ? "Hide history" : "Task history"}</button>
      {active.length > 0 && <button type="button" disabled={Boolean(busy)} onClick={() => void act(null, "cancel")}>Stop all tasks</button>}
    </div>
    {error && <p role="alert">{error}</p>}
    <div className="long-chat-workers">
      {(expanded ? tasks : active).map((task) => {
        const attempt = task.attempts.at(-1);
        return <article key={task.id} className="long-chat-worker" data-testid={`long-chat-task-${task.id}`}>
          <button type="button" className="long-chat-worker-open" disabled={!attempt.sessionId} onClick={() => onOpenWorker(attempt.sessionId, task.title)}>
            <strong>{task.title}</strong><span>{agentId} · {attempt.status.replaceAll("_", " ")} · attempt {attempt.number}</span>
            {attempt.summary && <p>{attempt.summary}</p>}
          </button>
          <div className="long-chat-worker-actions">
            {["queued", "running", "waiting_input"].includes(attempt.status) && <button type="button" disabled={Boolean(busy)} onClick={() => void act(task.id, "cancel")}>Cancel</button>}
            {["failed", "cancelled"].includes(attempt.status) && <button type="button" disabled={Boolean(busy)} onClick={() => void act(task.id, "retry")}>Retry</button>}
          </div>
          {expanded && task.attempts.length > 1 && <details><summary>Previous attempts</summary>{task.attempts.slice(0, -1).map((previous) => <button type="button" key={previous.id} disabled={!previous.sessionId} onClick={() => onOpenWorker(previous.sessionId, task.title)}>Attempt {previous.number}: {previous.status} — {previous.summary}</button>)}</details>}
        </article>;
      })}
    </div>
  </section>;
}
