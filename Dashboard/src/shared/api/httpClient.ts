import { emitNotification } from "../../features/notifications/notificationBus";
import {
  captureDashboardAuth,
  invalidateDashboardAuthToken
} from "./dashboardAuth";

type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

interface JsonRequestOptions<TBody = unknown> {
  path: string;
  /** Explicit destination for a workflow that must not follow server changes. */
  apiBase?: string;
  method?: HttpMethod;
  body?: TBody;
  signal?: AbortSignal;
  headers?: HeadersInit;
}

export interface JsonResponse<TData> {
  ok: boolean;
  status: number;
  data: TData | null;
}

export async function requestBlob(path: string, signal?: AbortSignal): Promise<Blob | null> {
  const headers = new Headers();
  const auth = captureDashboardAuth();
  const requestURL = buildApiURL(path);
  if (isProtectedDashboardRequest(path) && auth.token) {
    headers.set("authorization", `Bearer ${auth.token}`);
  }
  try {
    const response = await fetch(requestURL, { method: "GET", headers, signal });
    markNetworkConnected();
    if (response.status === 401 && headers.has("authorization") && requestURL === buildApiURL(path) && !signal?.aborted) {
      invalidateDashboardAuthToken(auth);
    }
    if (!response.ok) {
      return null;
    }
    return await response.blob();
  } catch {
    emitNetworkError();
    return null;
  }
}

export const API_BASE_OVERRIDE_STORAGE_KEY = "sloppy_api_base_override";
const DEFAULT_API_BASE = "http://localhost:25101";
const API_BASE_QUERY_PARAMETER = "apiBase";

export function normalizeApiBaseInput(value: string) {
  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }

  const withProtocol = /^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(trimmed) ? trimmed : `http://${trimmed}`;

  try {
    const url = new URL(withProtocol);
    if (!/^https?:$/.test(url.protocol) || !url.hostname || url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
      return "";
    }
    return url.toString().replace(/\/+$/, "");
  } catch {
    return "";
  }
}

export function getStoredApiBaseOverride() {
  try {
    const stored = window.localStorage.getItem(API_BASE_OVERRIDE_STORAGE_KEY);
    if (typeof stored !== "string") {
      return "";
    }
    return normalizeApiBaseInput(stored);
  } catch {
    return "";
  }
}

export function getLocationApiBaseOverride() {
  try {
    const value = new URLSearchParams(window.location.search).get(API_BASE_QUERY_PARAMETER);
    return typeof value === "string" ? normalizeApiBaseInput(value) : "";
  } catch {
    return "";
  }
}

export function setStoredApiBaseOverride(value: string) {
  try {
    const normalized = normalizeApiBaseInput(value);
    if (!normalized) {
      window.localStorage.removeItem(API_BASE_OVERRIDE_STORAGE_KEY);
      return "";
    }
    window.localStorage.setItem(API_BASE_OVERRIDE_STORAGE_KEY, normalized);
    return normalized;
  } catch {
    return "";
  }
}

export function resolveApiBase() {
  const locationOverride = getLocationApiBaseOverride();
  if (locationOverride) {
    return locationOverride;
  }

  const storedOverride = getStoredApiBaseOverride();
  if (storedOverride) {
    return storedOverride;
  }

  const configured = window.__SLOPPY_CONFIG__?.apiBase;
  if (typeof configured === "string" && configured.trim().length > 0) {
    return normalizeApiBaseInput(configured) || configured.trim().replace(/\/+$/, "");
  }

  const envConfigured = import.meta.env.VITE_API_BASE;
  if (typeof envConfigured === "string" && envConfigured.trim().length > 0) {
    return normalizeApiBaseInput(envConfigured) || envConfigured.trim().replace(/\/+$/, "");
  }

  return DEFAULT_API_BASE;
}

export function buildApiURL(path: string) {
  const base = resolveApiBase();
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${base}${normalizedPath}`;
}

export function buildWebSocketURL(path: string) {
  const apiURL = new URL(buildApiURL(path));
  apiURL.protocol = apiURL.protocol === "https:" ? "wss:" : "ws:";
  return apiURL.toString();
}

function isProtectedDashboardRequest(path: string) {
  if (!path.startsWith("/v1/")) {
    return false;
  }
  return true;
}

async function parseJSONSafely<TData>(response: Response): Promise<TData | null> {
  try {
    return (await response.json()) as TData;
  } catch {
    return null;
  }
}

/** Builds a short message for failed API calls (dashboard status lines, thrown errors). */
export function formatHttpError(status: number, data: unknown): string {
  if (status === 0) {
    return "Could not reach Sloppy. Is the core running and is the API base URL correct?";
  }
  let code = "";
  let message = "";
  if (data && typeof data === "object" && "error" in data && data.error != null) {
    code = String((data as Record<string, unknown>).error);
  }
  if (data && typeof data === "object" && "message" in data && data.message != null) {
    message = String((data as Record<string, unknown>).message);
  }
  const hints: Record<string, string> = {
    unauthorized: "Dashboard auth is missing or invalid. Re-enter the dashboard token and try again.",
    invalid_body: "The server rejected the JSON body (wrong shape or types). Try reloading settings or editing in Raw config.",
    config_write_failed: "Could not write sloppy.json on the server (path or permissions).",
    invalid_agent_model: "This model id is not accepted for the agent. Pick another model or fix provider config.",
    invalid_agent_config_payload: "Agent config payload was rejected (validation or decode).",
    invalid_agent_id: "Invalid agent id.",
    agent_not_found: "Agent was not found.",
    agent_config_write_failed: "Agent config could not be saved.",
    agent_document_too_long: "One of agent markdown files exceeded size limits (USER.md <= 2000 chars, MEMORY.md <= 3000 chars). Shorten content and retry.",
    mesh_invalid_request: "The invite token was rejected by the mesh coordinator.",
    mesh_forbidden: "The invite token is not allowed for this mesh operation.",
    mesh_not_found: "The requested mesh record was not found."
  };
  const hint = code && hints[code] ? ` — ${hints[code]}` : "";
  const detail = message ? ` — ${message}` : "";
  const suffix = code ? `: ${code}` : "";
  return `Request failed (HTTP ${status})${suffix}${detail}${hint}`;
}

export async function requestJson<TResponse, TBody = unknown>(
  options: JsonRequestOptions<TBody>
): Promise<JsonResponse<TResponse>> {
  const headers = new Headers(options.headers ?? undefined);
  const hasBody = options.body !== undefined;
  const method = options.method ?? (hasBody ? "POST" : "GET");

  if (hasBody && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }

  const auth = captureDashboardAuth();
  const requestURL = options.apiBase ? `${options.apiBase}${options.path.startsWith("/") ? options.path : `/${options.path}`}` : buildApiURL(options.path);
  // Explicit credentials belong to a caller's validation/probe, not the
  // global session. Its failure is returned to that caller without logging out.
  const usesDashboardSession = isProtectedDashboardRequest(options.path) && !headers.has("authorization");
  if (usesDashboardSession) {
    if (auth.token) {
      headers.set("authorization", `Bearer ${auth.token}`);
    }
  }

  const requestInit: RequestInit = {
    method,
    signal: options.signal
  };

  requestInit.headers = headers;

  if (hasBody) {
    requestInit.body = JSON.stringify(options.body);
  }

  try {
    const response = await fetch(requestURL, requestInit);
    markNetworkConnected();
    const data = await parseJSONSafely<TResponse>(response);
    if (response.status === 401 && usesDashboardSession && requestURL === buildApiURL(options.path) && !options.signal?.aborted) {
      invalidateDashboardAuthToken(auth);
    }
    return { ok: response.ok, status: response.status, data };
  } catch {
    emitNetworkError();
    return { ok: false, status: 0, data: null };
  }
}

let consecutiveNetworkErrorCount = 0;
let networkErrorShown = false;
const NETWORK_ERROR_DISPLAY_THRESHOLD = 5;

function emitNetworkError() {
  consecutiveNetworkErrorCount += 1;
  if (networkErrorShown || consecutiveNetworkErrorCount < NETWORK_ERROR_DISPLAY_THRESHOLD) return;
  networkErrorShown = true;
  emitNotification("system_error", "Connection lost", "Failed to reach the backend. Check if Sloppy is running.");
}

function markNetworkConnected() {
  consecutiveNetworkErrorCount = 0;
  networkErrorShown = false;
}
