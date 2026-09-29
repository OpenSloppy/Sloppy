import type { ProactiveFinding } from "../../shared/api/proactivity";

export function proactiveNotificationGroups(findings: ProactiveFinding[]) {
  const groups = new Map<string, ProactiveFinding[]>();
  for (const finding of findings) {
    if (!finding.deliveredAt) continue;
    const key = `${finding.agentId}:${finding.deliveredAt}`;
    groups.set(key, [...(groups.get(key) ?? []), finding]);
  }
  return [...groups.values()].map((items) => {
    const first = items[0];
    return {
      id: `proactive:${items.map((item) => item.id).sort().join(":")}`,
      title: items.length === 1 ? first.source.title : `${items.length} items need your attention`,
      message: items.map((item) => `${item.source.title}: ${item.reason}`).join("\n"),
      metadata: { agentId: first.agentId, sessionId: first.sessionId, findingId: first.id,
        findingIds: items.map((item) => item.id).join(","), source: "proactivity" },
      timestamp: Date.parse(first.deliveredAt!),
      read: items.every((item) => !!(item.readAt || item.dismissedAt || item.resolvedAt))
    };
  });
}
