import { useEffect, useRef } from "react";
import { buildWebSocketURL } from "../../shared/api/httpClient";
import { useNotifications } from "./NotificationContext";
import type { NotificationType } from "./NotificationContext";
import { fetchAllProactiveFindings } from "../../shared/api/coreApi";
import { proactiveNotificationGroups } from "./proactiveNotificationGroups";

interface ServerNotification {
  id: string;
  type: string;
  title: string;
  message: string;
  timestamp: string;
  metadata?: Record<string, string>;
}

const RECONNECT_DELAY_MS = 3000;
const VALID_TYPES: NotificationType[] = [
  "confirmation",
  "agent_error",
  "system_error",
  "pending_approval",
  "tool_approval",
  "task_completed",
  "input_required",
  "cron_attention",
  "proactive_attention"
];
const CONNECTION_LOST_DISPLAY_THRESHOLD = 5;

function mapServerType(raw: string): NotificationType {
  if (VALID_TYPES.includes(raw as NotificationType)) return raw as NotificationType;
  return "system_error";
}

export function useNotificationSocket() {
  const { push } = useNotifications();
  const pushRef = useRef(push);
  pushRef.current = push;

  useEffect(() => {
    let socket: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    let disposed = false;
    let reconnectAttempts = 0;
    let connectionLostShown = false;

    function connect() {
      if (disposed) return;

      const url = buildWebSocketURL("/v1/notifications/ws");
      socket = new WebSocket(url);

      socket.onopen = () => {
        reconnectAttempts = 0;
        connectionLostShown = false;
        const connectedSocket = socket;
        void fetchAllProactiveFindings().then((findings) => {
          if (disposed || socket !== connectedSocket) return;
          for (const group of proactiveNotificationGroups(findings)) {
            pushRef.current("proactive_attention", group.title, group.message, group.metadata,
              { id: group.id, timestamp: group.timestamp, silent: true, read: group.read });
          }
        }).catch(() => { /* The persistent agent inbox remains available on the Attention tab. */ });
      };

      socket.onmessage = (event) => {
        if (!event?.data) return;
        try {
          const payload = JSON.parse(String(event.data)) as ServerNotification;
          if (payload && typeof payload.title === "string") {
            const metadata = payload.metadata && typeof payload.metadata === "object" ? payload.metadata : undefined;
            const timestamp = typeof payload.timestamp === "string" ? Date.parse(payload.timestamp) : NaN;
            pushRef.current(
              mapServerType(payload.type),
              payload.title,
              payload.message || "",
              metadata,
              {
                id: typeof payload.id === "string" && payload.id.trim() ? payload.id : undefined,
                timestamp: Number.isFinite(timestamp) ? timestamp : undefined
              }
            );
          }
        } catch {
          // ignore malformed
        }
      };

      socket.onclose = () => {
        socket = null;
        if (disposed) return;
        reconnectAttempts += 1;
        if (!connectionLostShown && reconnectAttempts >= CONNECTION_LOST_DISPLAY_THRESHOLD) {
          connectionLostShown = true;
          pushRef.current("system_error", "Connection lost", "Failed to reach the backend notification stream.");
        }
        reconnectTimer = window.setTimeout(() => {
          reconnectTimer = null;
          connect();
        }, RECONNECT_DELAY_MS);
      };

      socket.onerror = () => {
        socket?.close();
      };
    }

    connect();

    return () => {
      disposed = true;
      if (reconnectTimer != null) {
        window.clearTimeout(reconnectTimer);
      }
      if (socket) {
        socket.close();
        socket = null;
      }
    };
  }, []);
}
