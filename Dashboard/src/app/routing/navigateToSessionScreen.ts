import type { SessionReference } from "../../shared/sessionReferences";

export function agentSessionPath(reference: SessionReference): string {
  return `/agents/${encodeURIComponent(reference.agentId)}/chat/${encodeURIComponent(reference.sessionId)}`;
}

export function navigateToSessionScreen(reference: SessionReference): void {
  const path = agentSessionPath(reference);
  window.history.pushState({}, "", `${path}${window.location.search}${window.location.hash}`);
  window.dispatchEvent(new PopStateEvent("popstate"));
}
