import { useCallback, useEffect, useMemo, useState } from "react";
import type { CoreApi } from "../../../shared/api/coreApi";

type AnyRecord = Record<string, unknown>;

interface RuntimeMessage {
  id: string;
  userId: string;
  content: string;
  [key: string]: unknown;
}

interface RuntimeTask {
  id: string;
  title: string;
  status: string;
  reason: string;
}

interface RuntimeState {
  channelId?: string;
  messages?: RuntimeMessage[];
  lastDecision?: {
    action?: string;
    reason?: string;
  };
  [key: string]: unknown;
}

interface RuntimeBulletin {
  id: string;
  headline: string;
  digest: string;
  [key: string]: unknown;
}

type RuntimeWorker = Record<string, unknown>;

interface RuntimeEvent {
  id: string;
  messageType: string;
  ts: string;
  taskId?: string;
  branchId?: string;
  workerId?: string;
  payload?: unknown;
  extensions?: AnyRecord;
}

interface SubmitEventLike {
  preventDefault?: () => void;
}

export interface RuntimeOverviewModel {
  text: string;
  setText: (value: string) => void;
  messages: RuntimeMessage[];
  channelState: RuntimeState | null;
  events: RuntimeEvent[];
  workers: RuntimeWorker[];
  bulletins: RuntimeBulletin[];
  tasks: RuntimeTask[];
  artifactId: string;
  setArtifactId: (value: string) => void;
  artifactContent: string;
  sendMessage: (event?: SubmitEventLike) => Promise<void>;
  loadArtifact: () => Promise<void>;
  refreshRuntime: () => Promise<void>;
}

const CHANNEL_ID = "general";
const DEFAULT_MESSAGE_TEXT = "Implement branch workflow and review";
const DEFAULT_ARTIFACT_CONTENT = "Select artifact id to preview";

function normalizeRuntimeEvents(payload: unknown): RuntimeEvent[] {
  if (!payload || typeof payload !== "object") {
    return [];
  }

  const items = (payload as AnyRecord).items;
  if (!Array.isArray(items)) {
    return [];
  }

  const result: RuntimeEvent[] = [];
  for (const entry of items) {
    if (!entry || typeof entry !== "object") {
      continue;
    }

    const row = entry as AnyRecord;
    const id = typeof row.messageId === "string" ? row.messageId : "";
    const messageType = typeof row.messageType === "string" ? row.messageType : "";
    const ts = typeof row.ts === "string" ? row.ts : "";
    if (!id || !messageType || !ts) {
      continue;
    }

    result.push({
      id,
      messageType,
      ts,
      taskId: typeof row.taskId === "string" ? row.taskId : undefined,
      branchId: typeof row.branchId === "string" ? row.branchId : undefined,
      workerId: typeof row.workerId === "string" ? row.workerId : undefined,
      payload: row.payload,
      extensions: row.extensions && typeof row.extensions === "object" ? (row.extensions as AnyRecord) : undefined
    });
  }

  return result;
}

export function useRuntimeOverview(coreApi: CoreApi, section = "debug"): RuntimeOverviewModel {
  const [text, setText] = useState(DEFAULT_MESSAGE_TEXT);
  const [messages, setMessages] = useState<RuntimeMessage[]>([]);
  const [channelState, setChannelState] = useState<RuntimeState | null>(null);
  const [events, setEvents] = useState<RuntimeEvent[]>([]);
  const [workers, setWorkers] = useState<RuntimeWorker[]>([]);
  const [bulletins, setBulletins] = useState<RuntimeBulletin[]>([]);
  const [artifactId, setArtifactId] = useState("");
  const [artifactContent, setArtifactContent] = useState(DEFAULT_ARTIFACT_CONTENT);

  const tasks = useMemo(() => {
    if (!channelState) {
      return [];
    }
    const last = channelState.lastDecision;
    return [
      {
        id: "task-live",
        title: "Current channel route",
        status: last?.action || "unknown",
        reason: last?.reason || "not available"
      }
    ];
  }, [channelState]);

  const refreshRuntime = useCallback(async () => {
    const [nextState, nextEvents, nextBulletins, nextWorkers] = await Promise.all([
      coreApi.fetchChannelState(CHANNEL_ID),
      coreApi.fetchChannelEvents(CHANNEL_ID, { limit: 100 }),
      coreApi.fetchBulletins(),
      coreApi.fetchWorkers()
    ]);

    const normalizedState = (nextState as RuntimeState | null) ?? null;
    setChannelState(normalizedState);
    setMessages(Array.isArray(normalizedState?.messages) ? normalizedState.messages : []);
    setEvents(normalizeRuntimeEvents(nextEvents));
    setBulletins(Array.isArray(nextBulletins) ? (nextBulletins as RuntimeBulletin[]) : []);
    setWorkers(Array.isArray(nextWorkers) ? nextWorkers : []);
  }, [coreApi]);

  const sendMessage = useCallback(
    async (event?: SubmitEventLike) => {
      event?.preventDefault?.();
      if (!text.trim()) {
        return;
      }

      await coreApi.sendChannelMessage(CHANNEL_ID, {
        userId: "dashboard",
        content: text
      });
      setText("");
      await refreshRuntime();
    },
    [coreApi, refreshRuntime, text]
  );

  const loadArtifact = useCallback(async () => {
    if (!artifactId.trim()) {
      return;
    }

    const artifact = await coreApi.fetchArtifact(artifactId.trim());
    const content = artifact && typeof artifact.content === "string" ? artifact.content : null;
    setArtifactContent(content || "Artifact not found");
  }, [artifactId, coreApi]);

  useEffect(() => {
    if (section === "debug") {
      refreshRuntime().catch(() => {});
    } else if (section === "overview") {
      let cancelled = false;
      coreApi.fetchWorkers().then((next) => { if (!cancelled) setWorkers(next); }).catch(() => {});
      return () => { cancelled = true; };
    }
  }, [coreApi, refreshRuntime, section]);

  return {
    text,
    setText,
    messages,
    channelState,
    events,
    workers,
    bulletins,
    tasks,
    artifactId,
    setArtifactId,
    artifactContent,
    sendMessage,
    loadArtifact,
    refreshRuntime
  };
}
