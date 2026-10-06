export type UsageGrouping = "tool" | "server" | "skill";
export interface UsageQuery {
  from?: string; to?: string; channelId?: string; sessionId?: string;
  provider?: string; model?: string; serverId?: string;
  groupBy?: UsageGrouping; groupId?: string; cursor?: string; limit?: number;
}
export interface UsageGroup {
  id: string; calls: number; failures: number;
  argumentsTokens: number; resultTokens: number; replayTokens: number;
  schemaTokens: number; catalogTokens: number;
  tokenizerMeasurements: number; estimatedMeasurements: number; unavailableMeasurements: number;
}
export interface UsageCall {
  id: string; requestId: string; channelId: string; sessionId?: string; agentId?: string;
  tool: string; serverId?: string; skillId?: string; ok?: boolean; createdAt: string;
  argumentsTokens: number; resultTokens: number; replayTokens: number;
  tokenizerMeasurements: number; estimatedMeasurements: number; unavailableMeasurements: number;
}
export interface UsageBreakdown {
  collectionStartedAt?: string; requestCount: number; reportedRequestCount: number; completeRequestCount: number;
  providerUsage: { prompt: number; completion: number; cachedInput: number; cacheCreationInput: number; reasoning: number };
  groups: UsageGroup[]; calls: UsageCall[]; nextCursor?: string;
}
export function groupTokens(group: UsageGroup): number {
  return group.argumentsTokens + group.resultTokens + group.replayTokens + group.schemaTokens + group.catalogTokens;
}
export function averageCallTokens(group: UsageGroup): number | null {
  return group.calls > 0 && group.unavailableMeasurements === 0 ? (group.argumentsTokens + group.resultTokens) / group.calls : null;
}
export function countingLabel(group: UsageGroup): string {
  const labels = [];
  if (group.tokenizerMeasurements) labels.push("Local count");
  if (group.estimatedMeasurements) labels.push("Estimate");
  if (group.unavailableMeasurements) labels.push("No data");
  return labels.join(" · ") || "No data";
}
