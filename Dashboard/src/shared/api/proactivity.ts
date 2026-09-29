import { requestJson, formatHttpError } from "./httpClient";

export interface ProactiveSettings {
  projectIds: string[];
  reviewProviderIds: string[];
  analysisModel: string;
  notificationStartHour: number;
  notificationEndHour: number;
  timeZone: string;
}
export interface HeartbeatSettings {
  enabled: boolean;
  intervalMinutes: number;
  mode: "checklist" | "proactive";
  proactive: ProactiveSettings;
}
export const defaultProactiveSettings = (): ProactiveSettings => ({
  projectIds: [], reviewProviderIds: [], analysisModel: "", notificationStartHour: 9,
  notificationEndHour: 21, timeZone: "Europe/Moscow"
});
export interface ProactiveFinding {
  id: string;
  agentId: string;
  source: { id: string; kind: string; title: string; url?: string; projectId?: string; taskId?: string; providerId?: string; reviewId?: string };
  revision: string;
  outcome: "notify" | "needs_input";
  reason: string;
  evidence: string;
  nextStep: string;
  sessionId: string;
  createdAt: string;
  readAt?: string;
  dismissedAt?: string;
  snoozedUntil?: string;
  deliveredAt?: string;
  resolvedAt?: string;
}
export interface ProactiveInbox {
  findings: ProactiveFinding[];
  lastCheckedAt?: string;
  pendingAnalysisCount: number;
  sourceErrors: Record<string, string>;
  lastAnalysisError?: string;
}

async function checked<T>(path: string, method: "GET" | "POST" = "GET", body?: unknown): Promise<T> {
  const response = await requestJson<T>({ path, method, body });
  if (!response.ok || !response.data) { throw new Error(formatHttpError(response.status, response.data)); }
  return response.data;
}
const base = (agentId: string) => `/v1/agents/${encodeURIComponent(agentId)}/proactivity`;
export const fetchProactiveInbox = (agentId: string) => checked<ProactiveInbox>(base(agentId));
export const updateProactiveFinding = (agentId: string, id: string, action: "read" | "snooze" | "dismiss") =>
  checked<ProactiveFinding>(`${base(agentId)}/findings/${encodeURIComponent(id)}/action`, "POST", { action });
export const fetchProactiveReviewProviders = () => checked<Array<{ id: string; displayName: string }>>("/v1/code-reviews/providers");

export async function fetchAllProactiveFindings(): Promise<ProactiveFinding[]> {
  const agents = await checked<Array<{ id: string }>>("/v1/agents");
  const results = await Promise.allSettled(agents.map((agent) => fetchProactiveInbox(agent.id)));
  return results.flatMap((result) => result.status === "fulfilled" ? result.value.findings : []);
}
