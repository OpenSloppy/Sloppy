import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { subscribeNotificationBus } from "./notificationBus";

export type NotificationType =
  | "confirmation"
  | "agent_error"
  | "system_error"
  | "pending_approval"
  | "tool_approval"
  | "task_completed"
  | "input_required"
  | "cron_attention"
  | "proactive_attention";

export interface Notification {
  id: string;
  type: NotificationType;
  title: string;
  message: string;
  timestamp: number;
  read: boolean;
  silent?: boolean;
  metadata?: Record<string, string>;
}

interface NotificationContextValue {
  notifications: Notification[];
  unreadCount: number;
  push: (
    type: NotificationType,
    title: string,
    message: string,
    metadata?: Record<string, string>,
    options?: NotificationPushOptions
  ) => void;
  markRead: (id: string) => void;
  markAllRead: () => void;
  dismiss: (id: string) => void;
  clearAll: () => void;
}

const NotificationContext = createContext<NotificationContextValue | null>(null);

let nextId = 1;

interface NotificationPushOptions {
  id?: string;
  timestamp?: number;
  silent?: boolean;
  read?: boolean;
}

export function NotificationProvider({ children }: { children: React.ReactNode }) {
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const browserShownRef = React.useRef<Set<string>>(new Set());

  const push = useCallback((
    type: NotificationType,
    title: string,
    message: string,
    metadata?: Record<string, string>,
    options?: NotificationPushOptions
  ) => {
    const id = options?.id || `notif-${nextId++}-${Date.now()}`;
    const notification: Notification = {
      id,
      type,
      title,
      message,
      timestamp: options?.timestamp || Date.now(),
      read: options?.read ?? false,
      silent: options?.silent ?? false,
      metadata
    };
    setNotifications((prev) => {
      if (prev.some((item) => item.id === notification.id)) {
        return prev;
      }
      return [notification, ...prev];
    });
  }, []);

  const markRead = useCallback((id: string) => {
    setNotifications((prev) => prev.map((n) => (n.id === id ? { ...n, read: true } : n)));
  }, []);

  const markAllRead = useCallback(() => {
    setNotifications((prev) => prev.map((n) => (n.read ? n : { ...n, read: true })));
  }, []);

  const dismiss = useCallback((id: string) => {
    setNotifications((prev) => prev.filter((n) => n.id !== id));
  }, []);

  const clearAll = useCallback(() => {
    setNotifications([]);
  }, []);

  const unreadCount = useMemo(() => notifications.filter((n) => !n.read).length, [notifications]);

  const value = useMemo<NotificationContextValue>(
    () => ({ notifications, unreadCount, push, markRead, markAllRead, dismiss, clearAll }),
    [notifications, unreadCount, push, markRead, markAllRead, dismiss, clearAll]
  );

  useEffect(() => {
    return subscribeNotificationBus((event) => {
      push(event.type, event.title, event.message, event.metadata);
    });
  }, [push]);

  useEffect(() => {
    if (!("Notification" in window) || window.Notification.permission !== "granted") {
      return;
    }

    for (const notification of notifications) {
      if (notification.silent) { browserShownRef.current.add(notification.id); continue; }
      if (browserShownRef.current.has(notification.id)) {
        continue;
      }
      browserShownRef.current.add(notification.id);
      try {
        new window.Notification(notification.title, {
          body: notification.message || undefined,
          tag: notification.id,
          silent: false
        });
      } catch {
        // Browser notification support varies by context; the in-app bell still carries the event.
      }
    }
  }, [notifications]);

  return <NotificationContext.Provider value={value}>{children}</NotificationContext.Provider>;
}

export function useNotifications() {
  const ctx = useContext(NotificationContext);
  if (!ctx) {
    throw new Error("useNotifications must be used within NotificationProvider");
  }
  return ctx;
}
