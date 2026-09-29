import React, { useCallback, useEffect, useRef, useState } from "react";
import { useNotifications } from "./NotificationContext";
import type { Notification, NotificationType } from "./NotificationContext";

const TOAST_DURATION_MS = 5000;
const MAX_VISIBLE_TOASTS = 3;

const TYPE_META: Record<NotificationType, { icon: string; color: string }> = {
  confirmation: { icon: "help_outline", color: "var(--warn)" },
  agent_error: { icon: "error_outline", color: "var(--danger)" },
  system_error: { icon: "warning", color: "var(--danger)" },
  pending_approval: { icon: "person_add", color: "var(--accent)" },
  tool_approval: { icon: "approval", color: "var(--warn)" },
  task_completed: { icon: "task_alt", color: "var(--success)" },
  input_required: { icon: "front_hand", color: "var(--warn)" },
  cron_attention: { icon: "schedule", color: "var(--accent)" },
  proactive_attention: { icon: "notifications_active", color: "var(--warn)" }
};

interface ToastEntry {
  notification: Notification;
  exiting: boolean;
}

export function NotificationToastContainer() {
  const { notifications } = useNotifications();
  const [toasts, setToasts] = useState<ToastEntry[]>([]);
  const seenRef = useRef<Set<string>>(new Set());
  const timersRef = useRef<Map<string, number>>(new Map());

  const removeToast = useCallback((id: string) => {
    setToasts((prev) => prev.map((t) => (t.notification.id === id ? { ...t, exiting: true } : t)));
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.notification.id !== id));
    }, 300);
    const timer = timersRef.current.get(id);
    if (timer != null) {
      window.clearTimeout(timer);
      timersRef.current.delete(id);
    }
  }, []);

  useEffect(() => {
    const newNotifications = notifications.filter((n) => !n.silent && !seenRef.current.has(n.id));
    if (newNotifications.length === 0) return;

    for (const n of newNotifications) {
      seenRef.current.add(n.id);
    }

    setToasts((prev) => {
      const added = newNotifications.map((n) => ({ notification: n, exiting: false }));
      const merged = [...added, ...prev];
      return merged.slice(0, MAX_VISIBLE_TOASTS);
    });

    for (const n of newNotifications) {
      const timer = window.setTimeout(() => {
        timersRef.current.delete(n.id);
        removeToast(n.id);
      }, TOAST_DURATION_MS);
      timersRef.current.set(n.id, timer);
    }
  }, [notifications, removeToast]);

  useEffect(() => {
    return () => {
      for (const timer of timersRef.current.values()) {
        window.clearTimeout(timer);
      }
    };
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div className="notif-toast-container">
      {toasts.map((toast) => {
        const meta = TYPE_META[toast.notification.type];
        return (
          <div
            key={toast.notification.id}
            className={`notif-toast ${toast.exiting ? "notif-toast-exit" : "notif-toast-enter"}`}
            style={{ borderLeftColor: meta.color }}
          >
            <span className="material-symbols-rounded notif-toast-icon" style={{ color: meta.color }}>
              {meta.icon}
            </span>
            <div className="notif-toast-body">
              <div className="notif-toast-title">{toast.notification.title}</div>
              {toast.notification.message && (
                <div className="notif-toast-message">{toast.notification.message}</div>
              )}
            </div>
            <button
              type="button"
              className="notif-toast-close"
              onClick={() => removeToast(toast.notification.id)}
              aria-label="Close"
            >
              <span className="material-symbols-rounded">close</span>
            </button>
          </div>
        );
      })}
    </div>
  );
}
