import { useEffect, useState, useRef } from "react";
import { averageCallTokens, countingLabel, groupTokens, type UsageBreakdown, type UsageGrouping, type UsageQuery, type UsageCall } from "./usageModel";
import "./usage.css";

interface Props {
  coreApi: { fetchUsageBreakdown: (query?: UsageQuery) => Promise<UsageBreakdown> };
  from: string;
  to: string;
  revision: number;
}
const labels: Record<UsageGrouping, string> = { tool: "Tools", server: "MCP", skill: "Skills" };

export function UsageBreakdownView({ coreApi, from, to, revision }: Props) {
  const [provider, setProvider] = useState("");
  const [model, setModel] = useState("");
  const [serverId, setServerId] = useState("");
  const activeDetailKey = useRef("");
  const [groupBy, setGroupBy] = useState<UsageGrouping>("tool");
  const [data, setData] = useState<UsageBreakdown | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [calls, setCalls] = useState<UsageCall[]>([]);
  const [cursor, setCursor] = useState<string | undefined>();
  const [detailError, setDetailError] = useState("");
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailRevision, setDetailRevision] = useState(0);
  useEffect(() => {
    let cancelled = false;
    setLoading(true); setData(null); setError(""); setSelected(null);
    coreApi.fetchUsageBreakdown({ from, to, provider, model, serverId, groupBy }).then((value) => {
      if (!cancelled) setData(value);
    }).catch((cause: unknown) => {
      if (!cancelled) setError(cause instanceof Error ? cause.message : "Usage is unavailable.");
    }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [coreApi, from, to, groupBy, provider, model, serverId, revision]);
  useEffect(() => {
    let cancelled = false;
    activeDetailKey.current = JSON.stringify([from, to, provider, model, serverId, groupBy, selected]);
    setCalls([]); setCursor(undefined); setDetailError("");
    if (!selected) { setDetailLoading(false); return; }
    setDetailLoading(true);
    coreApi.fetchUsageBreakdown({ from, to, provider, model, serverId, groupBy, groupId: selected }).then((value) => {
      if (!cancelled) { setCalls(value.calls); setCursor(value.nextCursor); }
    }).catch((cause: unknown) => {
      if (!cancelled) setDetailError(cause instanceof Error ? cause.message : "Calls are unavailable.");
    }).finally(() => { if (!cancelled) setDetailLoading(false); });
    return () => { cancelled = true; };
  }, [coreApi, from, to, groupBy, provider, model, serverId, selected, revision, detailRevision]);
  async function loadMore() {
    if (!selected || !cursor) return;
    const selection = activeDetailKey.current;
    setDetailLoading(true); setDetailError("");
    try {
      const value = await coreApi.fetchUsageBreakdown({ from, to, provider, model, serverId, groupBy, groupId: selected, cursor });
      // The button is disabled while loading; navigation resets the detail selection.
      if (selection === activeDetailKey.current) {
        setCalls((old) => [...old, ...value.calls.filter((call) => !old.some((item) => item.channelId === call.channelId && item.id === call.id))]);
        setCursor(value.nextCursor);
      }
    } catch (cause) { if (selection === activeDetailKey.current) setDetailError(cause instanceof Error ? cause.message : "Calls are unavailable."); }
    finally { if (selection === activeDetailKey.current) setDetailLoading(false); }
  }
  const usage = data?.providerUsage;
  return <section className="usage-breakdown" aria-label="Tool and skill token usage">
    <div className="usage-heading"><div><h2>Usage</h2><p>Tools, MCP servers and skill instructions in model context.</p></div>
      <div className="usage-tabs" aria-label="Usage grouping">{(Object.keys(labels) as UsageGrouping[]).map((key) =>
        <button type="button" key={key} aria-pressed={groupBy === key} onClick={() => setGroupBy(key)}>{labels[key]}</button>)}</div>
    </div>
    <div className="usage-filters">
      <label>Provider<input value={provider} onChange={(event) => setProvider(event.target.value)} placeholder="All providers" /></label>
      <label>Model<input value={model} onChange={(event) => setModel(event.target.value)} placeholder="Exact model identifier" /></label>
      <label>MCP server<input value={serverId} onChange={(event) => setServerId(event.target.value)} placeholder="All servers" /></label>
    </div>
    {loading ? <p role="status">Loading usage…</p> : null}
    {error ? <p role="alert">{error}</p> : null}
    {data && usage ? <>
      <div className="usage-totals"><span><strong>{(usage.prompt + usage.completion).toLocaleString()}</strong> provider reported tokens</span>
        <span>{usage.prompt.toLocaleString()} input · {usage.completion.toLocaleString()} output</span>
        <span>{usage.cachedInput.toLocaleString()} cached · {usage.cacheCreationInput.toLocaleString()} cache creation · {usage.reasoning.toLocaleString()} reasoning</span></div>
      <p className="usage-note">Usage reported for {data.reportedRequestCount} of {data.requestCount} observed requests; full attribution for {data.completeRequestCount}.
        {data.collectionStartedAt ? ` Collection started ${new Date(data.collectionStartedAt).toLocaleString()}.` : " No requests collected yet."}</p>
      <p className="usage-note">Local counts describe visible payloads; estimates are approximate. Neither is exact billing. Replay counts include repeated context. Tool and skill views overlap and must not be added together. MCP server internal model usage and token savings are unavailable.</p>
      {data.groups.length === 0 ? <p>No {labels[groupBy].toLowerCase()} measurements in this period.</p> : <div className="usage-table-wrap"><table className="usage-table">
        <thead><tr><th>{labels[groupBy]}</th><th>{groupBy === "skill" ? "Loads / errors" : "Calls / errors"}</th><th>Arguments</th><th>Result input</th><th>Replay</th><th>{groupBy === "skill" ? "Catalog" : "Schemas"}</th><th>Total</th><th>Average / call</th><th>Counting</th></tr></thead>
        <tbody>{data.groups.map((group) => <tr key={group.id}>
          <td><button type="button" className="usage-group-button" aria-expanded={selected === group.id} onClick={() => setSelected(selected === group.id ? null : group.id)}>{group.id}</button></td>
          <td>{group.calls.toLocaleString()} / {group.failures.toLocaleString()}</td><td>{group.argumentsTokens.toLocaleString()}</td>
          <td>{group.resultTokens.toLocaleString()}</td><td>{group.replayTokens.toLocaleString()}</td>
          <td>{(groupBy === "skill" ? group.catalogTokens : group.schemaTokens).toLocaleString()}</td><td>{groupTokens(group).toLocaleString()}</td>
          <td>{averageCallTokens(group)?.toLocaleString(undefined, { maximumFractionDigits: 1 }) ?? "—"}</td><td>{countingLabel(group)}</td>
        </tr>)}</tbody></table></div>}
      {selected ? <div className="usage-calls"><h3>{selected}</h3>
        {detailLoading ? <p role="status">Loading calls…</p> : null}
        {detailError ? <p role="alert">{detailError} <button type="button" onClick={() => setDetailRevision((v) => v + 1)}>Retry</button></p> : null}
        {calls.map((call) => <div className="usage-call" key={`${call.channelId}:${call.id}`}>
          <span>{call.tool} · {new Date(call.createdAt).toLocaleString()}</span><span>{call.argumentsTokens.toLocaleString()} arguments · {call.resultTokens.toLocaleString()} result · {call.replayTokens.toLocaleString()} replay</span>
          <span>{call.tokenizerMeasurements ? "Local count" : call.estimatedMeasurements ? "Estimate" : "No data"}</span>
          <span>{call.ok === true ? "Succeeded" : call.ok === false ? "Failed" : "Outcome unavailable"}</span>
          {call.agentId && call.sessionId ? <a href={`/agents/${encodeURIComponent(call.agentId)}/chat/${encodeURIComponent(call.sessionId)}`}>Open chat</a> : <span>{call.channelId}</span>}
        </div>)}
        {!detailLoading && !detailError && calls.length === 0 ? <p>No calls generated in this period. Catalog and replay measurements can exist without new calls.</p> : null}
        {cursor ? <button type="button" disabled={detailLoading} onClick={() => void loadMore()}>Load more</button> : null}
      </div> : null}
    </> : null}
  </section>;
}
