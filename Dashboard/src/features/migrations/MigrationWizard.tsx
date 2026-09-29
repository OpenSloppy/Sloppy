import { useEffect, useMemo, useState } from "react";
import { createCoreApi, migrationRequest } from "../../shared/api/coreApi";
import type { MigrationCatalog, MigrationCategory, MigrationItem, MigrationJob, MigrationPreview, MigrationSelection, MigrationSource, MigrationSourceKind } from "./migrationTypes";
import { resolveApiBase } from "../../shared/api/httpClient";
import { captureDashboardAuth } from "../../shared/api/dashboardAuth";
import "./migration.css";

const stages = ["Sources", "Data", "Agents & projects", "Preview", "Transfer", "Result"];
const categories: MigrationCategory[] = ["skill", "mcp", "project", "session", "memory", "instructions"];
const kinds: MigrationSourceKind[] = ["codex", "claude", "openclaw", "hermes"];
const terminal = new Set(["completed", "completedWithIssues", "waitingForModel", "cancelled", "failed"]);
function offeredSources(): Set<string> {
  try { return new Set<string>(JSON.parse(localStorage.getItem(`migration.offeredSources:${resolveApiBase()}`) ?? "[]")); } catch { return new Set(); }
}
function profileKey(item: MigrationItem) { return `${item.source.id}:${item.profile}`; }
function itemBytes(item: MigrationItem) { return item.files.reduce((sum, file) => sum + Math.floor(file.content.length * 3 / 4), 0) + item.messages.reduce((sum, message) => sum + new TextEncoder().encode(message.text).length, 0); }

export function MigrationWizard() {
  const api = useMemo(() => createCoreApi(), []);
  const destination = useMemo(() => resolveApiBase(), []);
  const request = useMemo(() => {
    const token = captureDashboardAuth().token;
    return <T,>(path: string, body?: unknown) => migrationRequest<T>(path, body, destination, token);
  }, [destination]);
  const [step, setStep] = useState(0);
  const [sources, setSources] = useState<MigrationSource[]>([]);
  const [sourceIds, setSourceIds] = useState<Set<string>>(new Set());
  const [catalog, setCatalog] = useState<MigrationCatalog>({ sources: [], items: [], warnings: [] });
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [agentMappings, setAgentMappings] = useState<Record<string, string>>({});
  const [projectMappings, setProjectMappings] = useState<Record<string, string>>({});
  const [agents, setAgents] = useState<Array<{ id: string; displayName: string }>>([]);
  const [preview, setPreview] = useState<MigrationPreview | null>(null);
  const [job, setJob] = useState<MigrationJob | null>(null);
  const [history, setHistory] = useState<MigrationJob[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [manualKind, setManualKind] = useState<MigrationSourceKind>("codex");
  const [manualPath, setManualPath] = useState("");
  const [mcpStatus, setMcpStatus] = useState("");
  const selection: MigrationSelection = useMemo(() => ({ items: catalog.items.filter(item => selected.has(item.id)), agentMappings, projectMappings, warnings: catalog.warnings }), [catalog, selected, agentMappings, projectMappings]);
  const profiles = [...new Set(selection.items.map(profileKey))];
  const projectPaths = [...new Set(selection.items.map(item => item.projectPath).filter((path): path is string => Boolean(path)))];
  async function run(action: () => Promise<void>) {
    setBusy(true); setError("");
    try { await action(); } catch (error) { setError(error instanceof Error ? error.message : String(error)); }
    finally { setBusy(false); }
  }
  useEffect(() => {
    let active = true;
    Promise.all([request<MigrationSource[]>("/sources"), request<MigrationJob[]>(""), api.fetchAgents()]).then(([roots, jobs, agents]) => {
      if (!active) return;
      setSources(roots); setSourceIds(new Set(roots.map(source => source.id))); setHistory(jobs);
      setAgents((agents ?? []) as Array<{ id: string; displayName: string }>);
    }).catch(error => { if (active) setError(String(error.message)); });
    return () => { active = false; };
  }, [api]);
  useEffect(() => {
    if (!job || step !== 4) return;
    let active = true;
    const timer = window.setInterval(() => {
      request<MigrationJob>(`/${job.id}`).then(next => {
        if (!active) return;
        setJob(next);
        if (terminal.has(next.status)) setStep(5);
      }).catch(error => { if (active) setError(String(error.message)); });
    }, 1500);
    return () => { active = false; window.clearInterval(timer); };
  }, [job?.id, step]);
  function toggle(id: string, set: Set<string>, update: (next: Set<string>) => void) {
    const next = new Set(set); if (next.has(id)) next.delete(id); else next.add(id); update(next);
  }
  async function resume(previous: MigrationJob) {
    await run(async () => {
      if (previous.stage === "transfer" && previous.uploadedBytes < previous.totalBytes) throw new Error("Resume this upload in Data Migration on the originating Mac.");
      setJob(await request<MigrationJob>(`/${previous.id}/resume`, {})); setStep(4);
    });
  }
  return <section className="migration-wizard" aria-label="Data migration">
    <h2>Bring your work to Sloppy</h2>
    <p>Scan on the <strong>Core machine</strong>. Import selected data into this Core. Source files are preserved.</p><p><small>Destination: {destination}</small></p>
    <nav className="migration-steps" aria-label="Migration steps">{stages.map((title, index) => <span key={title} aria-current={index === step ? "step" : undefined}>{index + 1}. {title}</span>)}</nav>
    {error && <p className="migration-error" role="alert">{error}</p>}
    {busy && <p role="status">{step === 0 ? "Analyzing selected sources…" : "Preparing…"}</p>}
    {step === 0 && <>
      {sources.map(source => <label className="migration-row" key={source.id}><input type="checkbox" checked={sourceIds.has(source.id)} onChange={() => toggle(source.id, sourceIds, setSourceIds)} /><span><strong>{source.kind}</strong><small>{source.path}</small></span></label>)}
      <div className="migration-manual">
        <details className="actor-team-search"><summary>{manualKind}</summary>{kinds.map(kind => <button type="button" key={kind} onClick={() => setManualKind(kind)}>{kind}</button>)}</details>
        <input aria-label="Source folder on Core" placeholder="Custom agent folder on Core" value={manualPath} onChange={event => setManualPath(event.target.value)} />
      </div>
      <p><small>For data on your Mac, use Data Migration in the macOS client.</small></p>
      {history.length > 0 && <details><summary>Previous migrations</summary>{history.map(previous => <div className="migration-row" key={previous.id}>{previous.createdAt} · {previous.status}<button type="button" onClick={() => void resume(previous)}>Open / resume</button></div>)}</details>}
    </>}
    {step === 1 && <>
      {categories.map(category => {
        const items = catalog.items.filter(item => item.category === category);
        if (!items.length) return null;
        return <details key={category} open><summary><label><input type="checkbox" checked={items.every(item => selected.has(item.id))} onChange={event => {
          const next = new Set(selected); items.forEach(item => event.target.checked ? next.add(item.id) : next.delete(item.id)); setSelected(next);
        }} />{category} · {items.length}</label></summary>
          {items.map(item => <label className="migration-row" key={item.id}><input type="checkbox" checked={selected.has(item.id)} onChange={() => toggle(item.id, selected, setSelected)} /><span>{item.title}<small>{item.source.kind} · {item.profile} · {itemBytes(item).toLocaleString()} bytes {item.projectPath && `· ${item.projectPath}`}</small>{item.warnings.map((warning, index) => <small className="migration-warning" key={index}>{warning}</small>)}</span></label>)}
        </details>;
      })}
      {catalog.warnings.map((warning, index) => <p className="migration-warning" key={index}>{warning}</p>)}
      {!catalog.items.length && <p>No supported data found. Choose another source folder.</p>}
    </>}
    {step === 2 && <>
      <p>Keep separate agent profiles, or choose an existing native agent.</p>
      {profiles.map(key => {
        const item = selection.items.find(item => profileKey(item) === key)!;
        return <div className="migration-row" key={key}><span>{item.source.kind} · {item.profile}</span><details className="actor-team-search"><summary>{agents.find(agent => agent.id === agentMappings[key])?.displayName ?? "Create separate profile"}</summary>
          <button type="button" onClick={() => setAgentMappings(previous => { const next = { ...previous }; delete next[key]; return next; })}>Create separate profile</button>
          {agents.map(agent => <button type="button" key={agent.id} onClick={() => setAgentMappings(previous => ({ ...previous, [key]: agent.id }))}>{agent.displayName}</button>)}
        </details></div>;
      })}
      <h3>Project folders on Core</h3><p>Leave blank to import history and context without binding a folder. Project source files are excluded.</p>
      {projectPaths.map(path => <label className="migration-mapping" key={path}>{path}<input placeholder="Destination folder (optional)" value={projectMappings[path] ?? ""} onChange={event => setProjectMappings(previous => ({ ...previous, [path]: event.target.value }))} /></label>)}
    </>}
    {step === 3 && preview && <>
      <h3>{selection.items.length} objects · {preview.totalBytes.toLocaleString()} bytes</h3>
      <p>{preview.duplicates.length} already imported · {preview.conflicts.length} separate variants / instruction merges</p>
      <p>Selected data remains on this Core. MCP environment and headers are included; provider credentials are excluded.</p>
      <p>Existing data is preserved. MCP servers stay disabled until you choose to check and enable them.</p>
      {[...catalog.warnings, ...preview.warnings].map((warning, index) => <p className="migration-warning" key={index}>{warning}</p>)}
    </>}
    {step === 4 && job && <>
      <h3>{job.stage}</h3><progress value={job.outcomes.length} max={Math.max(1, job.totalItems)} /><p>{job.outcomes.length} / {job.totalItems} objects checked</p>
      {categories.map(category => { const outcomes = job.outcomes.filter(item => item.category === category); return outcomes.length > 0 && <p key={category}>{category}: {outcomes.filter(item => item.status === "imported").length} imported · {outcomes.filter(item => item.status === "duplicate").length} already present · {outcomes.filter(item => item.status === "error").length} errors</p>; })}
      {job.memoryTotalUnits > 0 && <p>Memory: {job.memoryCompletedUnits} / {job.memoryTotalUnits} verified parts</p>}
      <button type="button" onClick={() => void run(async () => { setJob(await request<MigrationJob>(`/${job.id}/cancel`, {})); setStep(5); })}>Cancel remaining work</button>
    </>}
    {step === 5 && job && <>
      <h3>{job.status}</h3>
      {job.outcomes.map(outcome => <div className="migration-row" key={outcome.id}><span>{outcome.title} · {outcome.status}<small>{outcome.message}</small></span>
        {outcome.agentID && <a href={`/agents/${encodeURIComponent(outcome.agentID)}/chat${outcome.sessionID ? `/${encodeURIComponent(outcome.sessionID)}` : ""}`}>Open agent / chat</a>}
        {outcome.projectID && <a href={`/projects/${encodeURIComponent(outcome.projectID)}/chats`}>Open project</a>}
      </div>)}
      {job.warnings.map((warning, index) => <p className="migration-warning" key={index}>{warning}</p>)}
      {job.outcomes.some(item => item.mcpID) && <button type="button" onClick={() => void run(async () => {
        const statuses = await request<Array<{ id: string; connected?: boolean; error?: string }>>(`/${job.id}/enable-mcp`, { ids: job.outcomes.flatMap(item => item.mcpID ? [item.mcpID] : []) });
        setMcpStatus(statuses.map(status => `${status.id}: ${status.error ?? (status.connected ? "Connected" : "Check MCP settings")}`).join("\n"));
      })}>Check and enable imported MCP servers</button>}
      {mcpStatus && <pre>{mcpStatus}</pre>}
      {job.status !== "completed" && <button type="button" onClick={() => void resume(job)}>Retry / resume</button>}
    </>}
    <footer className="migration-actions">
      {step > 0 && step < 4 && <button type="button" disabled={busy} onClick={() => setStep(previous => previous - 1)}>Back</button>}
      {step === 0 && <button type="button" disabled={busy || (!sourceIds.size && !manualPath.trim())} onClick={() => void run(async () => {
        const roots = sources.filter(source => sourceIds.has(source.id));
        if (manualPath.trim()) roots.push({ id: "manual", kind: manualKind, path: manualPath.trim(), readable: true });
        const result = await request<MigrationCatalog>("/scan", { sources: roots });
        setCatalog(result); setSelected(new Set(result.items.map(item => item.id))); setStep(1);
      })}>Analyze sources</button>}
      {step === 1 && <button type="button" disabled={!selected.size} onClick={() => setStep(2)}>Choose destinations</button>}
      {step === 2 && <button type="button" disabled={busy} onClick={() => void run(async () => { setPreview(await request<MigrationPreview>("/preview", selection)); setStep(3); })}>Preview</button>}
      {step === 3 && <button type="button" disabled={busy} onClick={() => void run(async () => { setJob(await request<MigrationJob>("/import", selection)); setStep(4); })}>Transfer selected data</button>}
    </footer>
  </section>;
}

export function MigrationLaunchNotice({ onboarding = false }: { onboarding?: boolean }) {
  const [sources, setSources] = useState<MigrationSource[]>([]);
  const [open, setOpen] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  useEffect(() => {
    let active = true;
    migrationRequest<MigrationSource[]>("/sources").then(roots => {
      const seen = offeredSources();
      if (active) {
        const fresh = roots.filter(source => !seen.has(source.id));
        setSources(fresh);
        if (fresh.length) {
          fresh.forEach(source => seen.add(source.id));
          localStorage.setItem(`migration.offeredSources:${resolveApiBase()}`, JSON.stringify([...seen]));
        }
      }
    }).catch(() => {});
    return () => { active = false; };
  }, []);
  function markOffered() {
    const seen = offeredSources();
    sources.forEach(source => seen.add(source.id)); localStorage.setItem(`migration.offeredSources:${resolveApiBase()}`, JSON.stringify([...seen]));
  }
  if ((!sources.length || dismissed) && !open) return null;
  return <>
    {!open && <aside className="migration-notice"><strong>Found {sources.map(source => source.kind).join(", ")} on Core.</strong><span>Bring skills, MCP, conversations and memory to Sloppy.</span><button type="button" onClick={() => { markOffered(); setOpen(true); }}>Import data</button><button type="button" onClick={() => { markOffered(); setDismissed(true); }}>{onboarding ? "Skip" : "Later"}</button></aside>}
    {open && <div className="migration-modal" role="dialog" aria-modal="true" aria-label="Data migration"><div><button className="migration-close" type="button" onClick={() => { setOpen(false); setDismissed(true); }}>Close</button><MigrationWizard /></div></div>}
  </>;
}
