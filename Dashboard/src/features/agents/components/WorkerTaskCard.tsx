import React from "react";
import { AgentPetIcon } from "./AgentPetSprite";
import "./longChat.css";

export function WorkerTaskCard({ agentId, title, status, summary = "", sessionId, attemptNumber = null, onOpen, children = null }) {
  const label = String(status || "Status unavailable").replace(/_/g, " ");
  return (
    <article className="chat-worker-card" data-testid="chat-worker-card" data-status={status}>
      <button type="button" className="chat-worker-card-open" disabled={!sessionId} onClick={() => onOpen(sessionId, title)}>
        <AgentPetIcon agentId={agentId} className="chat-worker-avatar" />
        <div className="chat-worker-card-content">
          <span className="chat-worker-card-agent">{agentId || "Worker"}{attemptNumber ? ` · attempt ${attemptNumber}` : ""}</span>
          <strong>{title}</strong>
          <span className="chat-worker-card-status"><span aria-hidden="true" className="chat-worker-status-dot" />{label}</span>
          {summary && <p>{summary}</p>}
        </div>
        <span className="material-symbols-rounded" aria-hidden="true">chevron_right</span>
      </button>
      {children && <div className="chat-worker-card-actions">{children}</div>}
    </article>
  );
}
