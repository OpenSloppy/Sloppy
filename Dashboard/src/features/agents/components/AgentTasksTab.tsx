import React, { useCallback, useEffect, useMemo, useState } from "react";
import { fetchAgentTasks, fetchAgents } from "../../../api";
import { navigateToTaskScreen } from "../../../app/routing/navigateToTaskScreen";
import { AgentPetIcon } from "./AgentPetSprite";

const COLUMN_ORDER = [
  "in_progress",
  "needs_review",
  "ready",
  "backlog",
  "pending_approval",
  "done",
  "blocked",
  "cancelled"
];

function formatStatusLabel(status: string): string {
  const trimmed = String(status || "").trim();
  if (!trimmed) {
    return "unknown";
  }
  return trimmed.split("_").join(" ");
}

function columnHeading(statusKey: string): string {
  const words = formatStatusLabel(statusKey).split(/\s+/);
  return words.map((w) => (w ? w.charAt(0).toUpperCase() + w.slice(1) : "")).join(" ");
}

function formatRelativeTime(iso: string | undefined | null): string {
  if (!iso) {
    return "";
  }
  const t = new Date(String(iso)).getTime();
  if (Number.isNaN(t)) {
    return "";
  }
  let sec = Math.round((Date.now() - t) / 1000);
  if (sec < 0) {
    sec = 0;
  }
  if (sec < 60) {
    return `${sec}s ago`;
  }
  const min = Math.floor(sec / 60);
  if (min < 60) {
    return `${min}m ago`;
  }
  const hr = Math.floor(min / 60);
  if (hr < 24) {
    return `${hr}h ago`;
  }
  const day = Math.floor(hr / 24);
  if (day < 14) {
    return `${day}d ago`;
  }
  return new Date(t).toLocaleDateString();
}

function assigneeInitials(name: string): string {
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
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

function groupItemsByStatus(rawItems: any[]): { status: string; items: any[] }[] {
  const bucket = new Map<string, any[]>();
  for (const item of rawItems) {
    const status = String(item?.task?.status || "unknown").trim().toLowerCase() || "unknown";
    const list = bucket.get(status);
    if (list) {
      list.push(item);
    } else {
      bucket.set(status, [item]);
    }
  }
  const out: { status: string; items: any[] }[] = [];
  const seen = new Set<string>();
  for (const key of COLUMN_ORDER) {
    const list = bucket.get(key);
    if (list?.length) {
      out.push({ status: key, items: list });
      seen.add(key);
    }
  }
  for (const [status, list] of bucket) {
    if (!seen.has(status) && list.length) {
      out.push({ status, items: list });
    }
  }
  return out;
}

type AgentDirEntry = { displayName: string; pet?: any };

export function AgentTasksTab({ agentId }: { agentId: string }) {
  const [items, setItems] = useState<any[]>([]);
  const [agentDirectory, setAgentDirectory] = useState<Record<string, AgentDirEntry>>({});
  const [statusText, setStatusText] = useState("Loading tasks...");

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const [tasksResponse, agentsResponse] = await Promise.all([fetchAgentTasks(agentId), fetchAgents()]);
      if (cancelled) {
        return;
      }

      const nextDir: Record<string, AgentDirEntry> = {};
      if (Array.isArray(agentsResponse)) {
        for (const a of agentsResponse) {
          const id = String(a?.id || "").trim();
          if (!id) {
            continue;
          }
          nextDir[id] = {
            displayName: String(a?.displayName || id).trim() || id,
            pet: a?.pet
          };
        }
      }
      setAgentDirectory(nextDir);

      if (!Array.isArray(tasksResponse)) {
        setItems([]);
        setStatusText("Failed to load tasks for this agent.");
        return;
      }

      setItems(tasksResponse);
      setStatusText(
        tasksResponse.length === 0 ? "No tasks claimed by this agent." : `${tasksResponse.length} task(s)`
      );
    }

    load().catch(() => {
      if (!cancelled) {
        setItems([]);
        setAgentDirectory({});
        setStatusText("Failed to load tasks for this agent.");
      }
    });

    return () => {
      cancelled = true;
    };
  }, [agentId]);

  const columns = useMemo(() => groupItemsByStatus(items), [items]);

  const openTask = useCallback((taskRef: string, event?: React.SyntheticEvent) => {
    event?.stopPropagation();
    navigateToTaskScreen(taskRef);
  }, []);

  return (
    <section className="entry-editor-card agent-content-card">
      <div className="agent-tasks-tab-header">
        <h3>Tasks</h3>
        {items.length > 0 ? <span className="agent-tasks-tab-meta">{statusText}</span> : null}
      </div>
      {items.length === 0 ? (
        <p className="app-status-text">{statusText}</p>
      ) : (
        <div className="agent-tasks-board">
          {columns.map(({ status, items: columnItems }) => (
            <div key={status} className="agent-tasks-column">
              <h4 className="agent-tasks-column-head">
                <span>{columnHeading(status)}</span>
                <span className="agent-tasks-column-count">{columnItems.length}</span>
              </h4>
              {columnItems.map((item, index) => {
                const projectId = String(item?.projectId || "");
                const projectName = String(item?.projectName || projectId || "Project");
                const task = item?.task || {};
                const taskRef = String(task?.id || "").trim();
                const title = String(task?.title || taskRef || "Task");
                const priority = String(task?.priority || "").trim();
                const description = task?.description ? String(task.description).trim() : "";
                const key = String(taskRef || `${projectId}-${index}`);
                const claimedBy = String(task?.claimedAgentId || "").trim();
                const assigneeId = claimedBy || agentId;
                const assignee = assigneeId ? agentDirectory[assigneeId] : undefined;
                const assigneeLabel = assignee?.displayName || assigneeId || "";
                const updatedAt = task?.updatedAt;
                const relative = formatRelativeTime(updatedAt);
                const displayId = taskRef.startsWith("#") ? taskRef : `#${taskRef}`;

                const footer = (
                  <div className="agent-kanban-footer">
                    {priority ? (
                      <span className="agent-kanban-priority">
                        <span className="material-symbols-rounded" aria-hidden="true">
                          flag
                        </span>
                        {priority}
                      </span>
                    ) : null}
                    {assigneeLabel ? (
                      <span className="agent-kanban-assignee">
                        <span className="agent-kanban-sloppie">
                          <AgentPetIcon agentId={assigneeId || "sloppy"} paletteId={assignee?.pet?.visual?.paletteId} />
                        </span>
                        <span>Agent: {assigneeLabel}</span>
                      </span>
                    ) : null}
                    {relative ? (
                      <span className="agent-kanban-time">
                        <span className="material-symbols-rounded" aria-hidden="true">
                          schedule
                        </span>
                        {relative}
                      </span>
                    ) : null}
                  </div>
                );

                const body = (
                  <>
                    <div className="agent-kanban-card-top">
                      <span className="agent-kanban-task-id">{displayId}</span>
                      {taskRef ? (
                        <button
                          type="button"
                          className="agent-kanban-open"
                          onClick={(e) => openTask(taskRef, e)}
                        >
                          Open
                          <span className="material-symbols-rounded" aria-hidden="true">
                            open_in_new
                          </span>
                        </button>
                      ) : null}
                    </div>
                    <p className="agent-kanban-title">{title}</p>
                    <p className="agent-kanban-project">
                      <span className="material-symbols-rounded" aria-hidden="true">
                        folder
                      </span>
                      <span>{projectName}</span>
                    </p>
                    {description ? <p className="agent-kanban-desc">{description}</p> : null}
                    {footer}
                  </>
                );

                if (taskRef) {
                  return (
                    <div
                      key={key}
                      role="button"
                      tabIndex={0}
                      className="agent-kanban-card"
                      onClick={() => openTask(taskRef)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          openTask(taskRef);
                        }
                      }}
                    >
                      {body}
                    </div>
                  );
                }

                return (
                  <div key={key} className="agent-kanban-card agent-kanban-card--static">
                    {body}
                  </div>
                );
              })}
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
