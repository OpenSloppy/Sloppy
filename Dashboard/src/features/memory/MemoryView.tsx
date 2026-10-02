import { useEffect, useState } from "react";
import { fetchAgents, fetchProjectSummaries, fetchRuntimeConfig, fetchMemories } from "../../api";
import { ConfigView } from "../config/ConfigView";
import { AgentMemoriesTab } from "../agents/components/AgentMemoriesTab";
import { ProjectMemoryTab } from "../../views/Projects/ProjectMemoryTab";
import { MemoryScopePicker, type MemoryScopeOption } from "./MemoryScopePicker";
import { MemoryBrowser } from "./MemoryBrowser";
import { MemoryDocument } from "./MemoryDocument";
import "../../styles/memory.css";

const TABS = ["overview", "memories", "dreams", "settings"];

function intervalLabel(seconds: number) {
  if (seconds % 3600 === 0) return `${seconds / 3600} h`;
  if (seconds % 60 === 0) return `${seconds / 60} min`;
  return `${seconds} s`;
}

export function MemoryView({ tab = "overview", scopeType = "all", scopeId = null, onRouteChange, onRuntimeConfigUpdated }: {
  tab?: string;
  scopeType?: string;
  scopeId?: string | null;
  onRouteChange: (tab: string, scopeType?: string, scopeId?: string | null) => void;
  onRuntimeConfigUpdated?: (config: Record<string, unknown>) => void;
}) {
  const [options, setOptions] = useState<MemoryScopeOption[]>([]);
  const [config, setConfig] = useState<Record<string, any> | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [countLoading, setCountLoading] = useState(true);
  const [loading, setLoading] = useState(true);
  const [catalogError, setCatalogError] = useState(false);
  const [revision, setRevision] = useState(0);
  const needsScopeCatalog = tab === "overview" || tab === "memories";
  // Scope catalogs are needed by Memories and Import, not by the configuration cards.
  useEffect(() => {
    if (!needsScopeCatalog) return;
    let cancelled = false;
    Promise.allSettled([fetchAgents(), fetchProjectSummaries()]).then(([agentResult, projectResult]) => {
      if (cancelled) return;
      const agents = agentResult.status === "fulfilled" ? agentResult.value : null;
      const projects = projectResult.status === "fulfilled" ? projectResult.value : null;
      setCatalogError(!Array.isArray(agents) || !Array.isArray(projects));
      setOptions([
        { type: "all", id: null, label: "All memory", group: "Scopes" },
        { type: "global", id: null, label: "Shared memory", group: "Scopes" },
        ...(Array.isArray(agents) ? agents.map((agent) => ({ type: "agent", id: String(agent.id), label: String(agent.displayName || agent.id), group: "Agents" })) : []),
        ...(Array.isArray(projects) ? projects.map((project) => ({ type: "project", id: String(project.id), label: String(project.name || project.id), group: "Projects" })) : [])
      ]);
    });
    return () => { cancelled = true; };
  }, [revision, needsScopeCatalog]);
  useEffect(() => {
    if (tab !== "overview") return;
    let cancelled = false;
    setLoading(true);
    setCountLoading(true);
    fetchRuntimeConfig().then((runtimeConfig) => {
      if (!cancelled) setConfig(runtimeConfig);
    }).catch(() => { if (!cancelled) setConfig(null); }).finally(() => {
      if (!cancelled) setLoading(false);
    });
    // Counting memory may involve storage/provider I/O. It must not block configuration.
    fetchMemories({ limit: 1 }).then((memories) => {
      if (!cancelled) setTotal(memories?.total ?? null);
    }).catch(() => { if (!cancelled) setTotal(null); }).finally(() => {
      if (!cancelled) setCountLoading(false);
    });
    return () => { cancelled = true; };
  }, [revision, tab]);
  const selected = options.find((option) => option.type === scopeType && option.id === scopeId)
    || { type: scopeType, id: scopeId, label: scopeId || "All memory", group: "Scopes" };
  const firstAgent = options.find((option) => option.type === "agent");
  const provider = config?.memory?.provider?.mode;
  const dream = config?.visor?.autodream;
  return <main className="memory-page">
    <header className="memory-page-header"><div><h1>Memory</h1><p>Browse what Sloppy remembers and manage how it learns across conversations.</p></div>
      <nav className="memory-tabs" aria-label="Memory sections">{TABS.map((item) => <button type="button" key={item} aria-current={tab === item ? "page" : undefined}
        className={tab === item ? "active" : ""} onClick={() => onRouteChange(item, scopeType, scopeId)}>{item[0].toUpperCase() + item.slice(1)}</button>)}</nav>
    </header>
    {tab === "overview" && <section className="memory-overview">
      <div className="memory-overview-intro"><div><h2>Across conversations</h2>
        <p>Preferences, decisions and project context in one place.</p></div>
        <div className="memory-overview-actions"><button type="button" onClick={() => onRouteChange("memories", "all")}>Browse memory</button>
        <button type="button" disabled={!firstAgent} onClick={() => onRouteChange("memories", "agent", firstAgent?.id)}>Import memory</button></div></div>
      <div className="memory-overview-head"><h2>Current configuration</h2><button type="button" disabled={loading} onClick={() => setRevision((value) => value + 1)}>Refresh</button></div>
      {loading ? <p role="status">Loading memory overview…</p> : <>
        <dl className="memory-summary"><div><dt>Saved records</dt><dd>{countLoading ? "Loading…" : total ?? "Unavailable"}</dd></div>
          <div><dt>Provider</dt><dd>{provider === "local" ? "Built-in local" : provider || "Unavailable"}</dd></div>
          <div><dt>Embeddings</dt><dd>{config ? config.memory?.embedding?.enabled ? `Enabled · ${config.memory.embedding.model}` : "Disabled" : "Unavailable"}</dd></div>
          <div><dt>Autodream</dt><dd>{config ? dream?.enabled !== false ? `Enabled · every ${intervalLabel(dream?.intervalSeconds ?? 21600)}` : "Disabled" : "Unavailable"}</dd></div>
          <div><dt>Memory maintenance</dt><dd>{config ? `Every ${intervalLabel(config.visor?.maintenanceIntervalSeconds ?? 3600)}` : "Unavailable"}</dd></div></dl>
        {(!config || (!countLoading && total === null)) && <p role="alert">Some memory data is unavailable. Refresh to retry.</p>}
        <p className="placeholder-text">Choose an agent or project in Memories to explore its context, or open Settings to change how memory is stored and retrieved.</p>
      </>}
    </section>}
    {tab === "memories" && <>
      <MemoryScopePicker options={options} selected={selected} onChange={(option) => onRouteChange("memories", option.type, option.id)} />
      {catalogError && <p role="alert">Some scopes could not be loaded. <button type="button" onClick={() => setRevision((value) => value + 1)}>Retry</button></p>}
      {scopeType === "agent" && scopeId ? <><MemoryDocument key={`document:${scopeId}`} agentId={scopeId} /><AgentMemoriesTab key={scopeId} agentId={scopeId} /></>
        : scopeType === "project" && scopeId ? <ProjectMemoryTab key={scopeId} projectId={scopeId} />
        : <><p className="placeholder-text">To import Markdown, choose its destination agent in the scope picker.</p><MemoryBrowser key={scopeType} sharedOnly={scopeType === "global"} /></>}
    </>}
    {(tab === "settings" || tab === "dreams") && <>
      {tab === "dreams" && <p className="memory-section-intro">Autodream periodically reviews changed sessions and records memory checkpoints. Configure its schedule and model here; inspect the resulting records in Memories.</p>}
      <ConfigView embedded sectionId={tab === "dreams" ? "memory-dreams" : "memory"} onRuntimeConfigUpdated={onRuntimeConfigUpdated} />
    </>}
  </main>;
}
