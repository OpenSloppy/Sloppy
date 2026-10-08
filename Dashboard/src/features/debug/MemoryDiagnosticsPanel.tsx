import React from "react";

interface MemoryHit {
  ref: { id: string; score: number; kind?: string; class?: string };
  note: string;
  summary?: string;
}

interface MemoryQuery {
  id: string;
  recordedAt: string;
  operationId?: string;
  source: string;
  query: string;
  queryCharacters: number;
  scope?: { type: string; id: string };
  kinds?: string[];
  classes?: string[];
  limit: number;
  durationMs: number;
  resultCount: number;
  resultCharacters: number;
  estimatedResultTokens: number;
  hits: MemoryHit[];
  truncated: boolean;
  stages: { name: string; durationMs: number; candidateCount: number; error?: string }[];
}

export interface MemoryDiagnosticsData {
  collectionStartedAt: string;
  retentionLimit: number;
  queries: MemoryQuery[];
  modelContext?: {
    recordedAt: string;
    model: string;
    entries: { id: string; kind: string; content: string; characters: number; estimatedTokens: number; truncated: boolean }[];
    entryCount: number;
    characters: number;
    estimatedTokens: number;
    imageCount: number;
    toolNames: string[];
    truncated: boolean;
    memoryInjection?: {
      operationId: string;
      durationMs: number;
      hitIds: string[];
      content: string;
      characters: number;
      estimatedTokens: number;
    };
  };
}

export interface ContextLedgerData {
  contextWindowTokens: number;
  reservedOutputTokens: number;
  entries: { category: string; label: string; estimatedTokens: number; cachePolicy: string }[];
  lastTurnUsage?: { prompt: number; completion: number; cachedInput?: number };
}

function ms(value: number) {
  return `${value.toFixed(1)} ms`;
}

function time(value: string) {
  return new Date(value).toLocaleString();
}

export function MemoryDiagnosticsPanel({ data, ledger }: { data?: MemoryDiagnosticsData; ledger?: ContextLedgerData }) {
  const queries = data?.queries ?? [];
  const context = data?.modelContext;
  const injection = context?.memoryInjection;
  const durations = queries.map((query) => query.durationMs).sort((a, b) => a - b);
  const mean = durations.length ? durations.reduce((sum, value) => sum + value, 0) / durations.length : 0;
  const p95 = durations.length ? durations[Math.ceil(durations.length * 0.95) - 1] : 0;
  const hits = queries.filter((query) => query.resultCount > 0).length;
  const failures = queries.filter((query) => query.stages.some((stage) => stage.error)).length;

  return (
    <section className="debug-memory" aria-label="Memory diagnostics">
      <h3>Memory requests</h3>
      <p className="debug-memory-note">
        Bootstrap selection, automatic retrieval, and memory.search / memory.recall for this session. Metrics cover retained requests;
        the process keeps up to {data?.retentionLimit ?? 200} requests across sessions and resets on restart.
        {data && ` Collection started ${time(data.collectionStartedAt)}.`}
      </p>
      <dl className="debug-memory-metrics">
        <div><dt>Requests</dt><dd>{queries.length}</dd></div>
        <div><dt>Mean / p95 latency</dt><dd>{queries.length ? `${ms(mean)} / ${ms(p95)}` : "—"}</dd></div>
        <div><dt>Requests with hits</dt><dd>{queries.length ? `${hits}/${queries.length} (${(hits / queries.length * 100).toFixed(0)}%)` : "—"}</dd></div>
        <div><dt>Retrieval errors</dt><dd>{failures}</dd></div>
      </dl>

      {!queries.length && <p className="debug-memory-note">No recorded memory requests for this session.</p>}
      <div className="debug-memory-queries">
        {queries.map((query) => (
          <details key={query.id} className="debug-memory-detail">
            <summary>
              <span>{query.source} · {query.scope ? `${query.scope.type}: ${query.scope.id}` : "all scopes"}</span>
              <span>{ms(query.durationMs)} · {query.resultCount} hits</span>
            </summary>
            <p className="debug-memory-note">
              {time(query.recordedAt)} · limit {query.limit} · {query.resultCharacters} result characters · ~{query.estimatedResultTokens} result tokens
              {query.truncated && " · Preview truncated"}
            </p>
            <p className="debug-memory-note">Classes: {query.classes?.join(", ") || "all"} · kinds: {query.kinds?.join(", ") || "all"}</p>
            {query.source === "bootstrap" ? <p className="debug-memory-note">Bootstrap selection check, ordered by profile, importance, and recency. Score is importance. This check may reuse an existing bootstrap; inspect Model context for the input actually used.</p> : (
              <><p className="debug-memory-note">Query ({query.queryCharacters} characters)</p><pre>{query.query}</pre></>
            )}
            {query.operationId && <p className="debug-memory-note">Automatic retrieval operation: <code>{query.operationId}</code></p>}
            {query.stages.map((stage) => (
              <p className="debug-memory-stage" key={stage.name}>
                {stage.name}: {ms(stage.durationMs)} · {stage.candidateCount} candidates
                {stage.error && <span className="debug-memory-error"> · {stage.error}</span>}
              </p>
            ))}
            <p className="debug-memory-note">Returned matches. Automatic retrieval injects only the final bounded selection shown below.</p>
            {query.hits.map((hit) => (
              <div className="debug-memory-hit" key={hit.ref.id}>
                <code>{hit.ref.id} · score {hit.ref.score.toFixed(3)} · {hit.ref.kind} / {hit.ref.class}</code>
                {hit.summary && <p>{hit.summary}</p>}
                <pre>{hit.note}</pre>
              </div>
            ))}
          </details>
        ))}
      </div>

      <h3>Model context</h3>
      <p className="debug-memory-note">
        Latest turn input captured after context preparation, before the provider tool loop. Instructions include tool definitions.
        Token counts are estimates. Images are represented by metadata; provider wire payloads and subsequent internal requests are not captured.
      </p>
      {!context ? <p className="debug-memory-note">No model turn captured in this process for this session.</p> : (
        <>
          <p className="debug-memory-note">{context.model} · {time(context.recordedAt)}{context.truncated && " · Context preview truncated"}</p>
          <dl className="debug-memory-metrics">
            <div><dt>Context entries</dt><dd>{context.entryCount}</dd></div>
            <div><dt>Context size</dt><dd>{context.characters} chars · ~{context.estimatedTokens} tokens</dd></div>
            <div><dt>Tools / images</dt><dd>{context.toolNames.length} / {context.imageCount}</dd></div>
            <div><dt>Injected memory</dt><dd>{injection ? `${injection.hitIds.length} hits · ~${injection.estimatedTokens} tokens` : "none"}</dd></div>
          </dl>
          {injection && (
            <details className="debug-memory-detail">
              <summary><span>Injected memory text</span><span>{injection.characters} chars · {ms(injection.durationMs)}</span></summary>
              <p className="debug-memory-note">Operation: <code>{injection.operationId}</code></p>
              <p className="debug-memory-note">Included IDs: <code>{injection.hitIds.join(", ")}</code></p>
              <pre>{injection.content}</pre>
            </details>
          )}
          <details className="debug-memory-detail">
            <summary>Available tools ({context.toolNames.length})</summary>
            <pre>{context.toolNames.join("\n")}</pre>
          </details>
          {context.entries.map((entry, index) => (
            <details key={`${index}:${entry.id}`} className="debug-memory-detail">
              <summary><span>{index + 1}. {entry.kind}</span><span>{entry.characters} chars · ~{entry.estimatedTokens} tokens{entry.truncated && " · truncated"}</span></summary>
              <pre>{entry.content}</pre>
            </details>
          ))}
        </>
      )}
      {ledger && (
        <details className="debug-memory-detail">
          <summary>Context budget · {ledger.contextWindowTokens} tokens · {ledger.reservedOutputTokens} reserved for output</summary>
          {ledger.entries.map((entry, index) => (
            <p className="debug-memory-stage" key={index}>{entry.label}: ~{entry.estimatedTokens} tokens · {entry.cachePolicy}</p>
          ))}
          {ledger.lastTurnUsage && <p className="debug-memory-note">Provider-reported last turn: {ledger.lastTurnUsage.prompt} input tokens · {ledger.lastTurnUsage.cachedInput ?? 0} cached · {ledger.lastTurnUsage.completion} output tokens</p>}
        </details>
      )}
    </section>
  );
}
