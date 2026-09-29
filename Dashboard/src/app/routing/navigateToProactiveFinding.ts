export function navigateToProactiveFinding(agentId: string, findingId?: string): void {
  const pathname = `/agents/${encodeURIComponent(agentId)}/attention`;
  const hash = findingId ? `#finding-${encodeURIComponent(findingId)}` : "";
  window.history.pushState({}, "", `${pathname}${window.location.search}${hash}`);
  window.dispatchEvent(new PopStateEvent("popstate"));
}
