import React from "react";
import { AggregatedModelPicker } from "./AggregatedModelPicker";
import type { AggregatedModelOption } from "../../agents/utils/aggregateProviderModels";

function embeddingRuntimeModelId(modelId: string) {
  const trimmed = String(modelId || "").trim();
  if (!trimmed) {
    return "";
  }

  const knownPrefixes = ["openai-api:", "openai-oauth:", "openrouter:", "ollama:", "gemini:", "anthropic:"];
  const prefix = knownPrefixes.find((candidate) => trimmed.startsWith(candidate));
  return prefix ? trimmed.slice(prefix.length) : trimmed;
}

function isEmbeddingModel(model: AggregatedModelOption) {
  const id = embeddingRuntimeModelId(model.id).toLowerCase();
  const title = String(model.title || "").toLowerCase();
  return id.includes("embed") || title.includes("embed");
}

function inferEmbeddingDimensions(modelId: string, fallback: number) {
  const id = embeddingRuntimeModelId(modelId).toLowerCase();
  if (id.includes("text-embedding-3-large")) {
    return 3072;
  }
  if (id.includes("text-embedding-3-small")) {
    return 1536;
  }
  if (id.includes("nomic-embed-text")) {
    return 768;
  }
  if (id.includes("mxbai-embed-large") || id.includes("snowflake-arctic-embed")) {
    return 1024;
  }
  return fallback;
}

type VisorEditorProps = {
  section?: "supervision" | "memory" | "dreams";
  draftConfig: Record<string, any>;
  mutateDraft: (mutator: (draft: Record<string, any>) => void) => void;
  parseLines: (value: string) => string[];
  modelRoutingCatalog?: AggregatedModelOption[];
  modelRoutingCatalogStatus?: string;
};

export function VisorEditor({
  section = "supervision",
  draftConfig,
  mutateDraft,
  parseLines,
  modelRoutingCatalog = [],
  modelRoutingCatalogStatus = ""
}: VisorEditorProps) {
  const visor = draftConfig.visor || {};
  const scheduler = visor.scheduler || {};
  const schedulerEnabled = Boolean(scheduler.enabled !== false);
  const intervalSeconds = scheduler.intervalSeconds ?? 300;
  const jitterSeconds = scheduler.jitterSeconds ?? 60;
  const bootstrapBulletin = Boolean(visor.bootstrapBulletin !== false);
  const bulletinMaxWords = visor.bulletinMaxWords ?? 300;
  const model = String(visor.model || "");
  const tickIntervalSeconds = visor.tickIntervalSeconds ?? 30;
  const branchTimeoutSeconds = visor.branchTimeoutSeconds ?? 60;
  const maintenanceIntervalSeconds = visor.maintenanceIntervalSeconds ?? 3600;
  const decayRatePerDay = visor.decayRatePerDay ?? 0.05;
  const pruneImportanceThreshold = visor.pruneImportanceThreshold ?? 0.1;
  const pruneMinAgeDays = visor.pruneMinAgeDays ?? 30;
  const channelDegradedFailureCount = visor.channelDegradedFailureCount ?? 3;
  const channelDegradedWindowSeconds = visor.channelDegradedWindowSeconds ?? 600;
  const idleThresholdSeconds = visor.idleThresholdSeconds ?? 1800;
  const webhookURLs = Array.isArray(visor.webhookURLs) ? visor.webhookURLs : [];
  const mergeEnabled = Boolean(visor.mergeEnabled);
  const mergeSimilarityThreshold = visor.mergeSimilarityThreshold ?? 0.80;
  const mergeMaxPerRun = visor.mergeMaxPerRun ?? 10;
  const autodream = visor.autodream || {};
  const autodreamEnabled = Boolean(autodream.enabled !== false);
  const autodreamIntervalSeconds = autodream.intervalSeconds ?? 21600;
  const autodreamJitterSeconds = autodream.jitterSeconds ?? 1800;
  const autodreamSessionLimitPerRun = autodream.sessionLimitPerRun ?? 10;
  const autodreamModel = String(autodream.model || "");

  const embedding = draftConfig.memory?.embedding || {};
  const embeddingEnabled = Boolean(embedding.enabled);
  const embeddingModel = String(embedding.model || "text-embedding-3-small");
  const embeddingDimensions = embedding.dimensions ?? 1536;
  const embeddingEndpoint = String(embedding.endpoint || "");
  const embeddingApiKeyEnv = String(embedding.apiKeyEnv || "");
  const embeddingModelCatalog = modelRoutingCatalog.filter(isEmbeddingModel);
  const embeddingModelValue = embeddingModelCatalog.find((entry) => embeddingRuntimeModelId(entry.id) === embeddingModel)?.id ?? embeddingModel;

  function setVisor(field, value) {
    mutateDraft((draft) => {
      if (!draft.visor) draft.visor = {};
      draft.visor[field] = value;
    });
  }

  function setScheduler(field, value) {
    mutateDraft((draft) => {
      if (!draft.visor) draft.visor = {};
      if (!draft.visor.scheduler) draft.visor.scheduler = {};
      draft.visor.scheduler[field] = value;
    });
  }

  function setAutodream(field, value) {
    mutateDraft((draft) => {
      if (!draft.visor) draft.visor = {};
      if (!draft.visor.autodream) draft.visor.autodream = {};
      draft.visor.autodream[field] = value;
    });
  }

  function setEmbedding(patch) {
    mutateDraft((draft) => {
      if (!draft.memory) draft.memory = {};
      if (!draft.memory.embedding) draft.memory.embedding = {};
      Object.assign(draft.memory.embedding, patch);
    });
  }

  function parseIntField(raw, fallback) {
    const parsed = parseInt(raw, 10);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  function parseFloatField(raw, fallback) {
    const parsed = parseFloat(raw);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  return (
    <div className="tg-settings-shell visor-settings-shell">
      {section === "supervision" && (
      <section className="entry-editor-card providers-intro-card">
        <h3>Visor</h3>
        <p className="placeholder-text">
          Visor is the runtime supervision layer. It monitors worker and branch health, maintains memory over time, and generates periodic bulletins that keep agents aware of what's happening in the system.
        </p>
      </section>
      )}

      {section === "supervision" && (
      <section className="entry-editor-card">
        <h3>Bulletin Scheduler</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Scheduler
            <select
              value={schedulerEnabled ? "enabled" : "disabled"}
              onChange={(event) => setScheduler("enabled", event.target.value === "enabled")}
            >
              <option value="enabled">Enabled</option>
              <option value="disabled">Disabled</option>
            </select>
            <span className="entry-form-hint">When enabled, Visor generates a bulletin on a regular schedule. Disable if you prefer on-demand bulletin generation only.</span>
          </label>

          <label>
            Interval (seconds)
            <input
              type="number"
              min={30}
              disabled={!schedulerEnabled}
              value={intervalSeconds}
              onChange={(event) => setScheduler("intervalSeconds", parseIntField(event.target.value, 300))}
            />
            <span className="entry-form-hint">How often to generate a bulletin. Default: 300 s (5 min).</span>
          </label>

          <label>
            Jitter (seconds)
            <input
              type="number"
              min={0}
              disabled={!schedulerEnabled}
              value={jitterSeconds}
              onChange={(event) => setScheduler("jitterSeconds", parseIntField(event.target.value, 60))}
            />
            <span className="entry-form-hint">Random delay added to each interval to avoid bursts. Default: 60 s.</span>
          </label>

          <label style={{ gridColumn: "1 / -1" }}>
            Bootstrap Bulletin
            <select
              value={bootstrapBulletin ? "enabled" : "disabled"}
              onChange={(event) => setVisor("bootstrapBulletin", event.target.value === "enabled")}
            >
              <option value="enabled">Generate on startup</option>
              <option value="disabled">Skip on startup</option>
            </select>
            <span className="entry-form-hint">When enabled, a bulletin is generated immediately when Sloppy starts so agents have context from the first message.</span>
          </label>
        </div>
      </section>
      )}

      {section === "supervision" && (
      <section className="entry-editor-card">
        <h3>Bulletin Content</h3>
        <div className="entry-form-grid">
          <AggregatedModelPicker
            label="Model"
            value={model}
            onChange={(id) => setVisor("model", id || null)}
            aggregatedModels={modelRoutingCatalog}
            hint={
              modelRoutingCatalogStatus || "Model used to synthesize bulletin text. When set to default, the first configured system model is used."
            }
            emptyOptionTitle="Default system model"
            emptyOptionSubtitle="Use the first configured system model"
          />

          <label>
            Max Words
            <input
              type="number"
              min={50}
              max={1000}
              value={bulletinMaxWords}
              onChange={(event) => setVisor("bulletinMaxWords", parseIntField(event.target.value, 300))}
            />
            <span className="entry-form-hint">Target word count for the bulletin digest. Default: 300.</span>
          </label>
        </div>
      </section>
      )}

      {section === "dreams" && (
      <section className="entry-editor-card">
        <h3>Autodream</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Autodream
            <input type="checkbox" checked={autodreamEnabled} onChange={(event) => setAutodream("enabled", event.target.checked)} />
            <span className="entry-form-hint">When enabled, Visor periodically reviews recent changed sessions and records memory checkpoints without revisiting unchanged sessions.</span>
          </label>

          <AggregatedModelPicker
            label="Model"
            value={autodreamModel}
            onChange={(id) => setAutodream("model", id || null)}
            aggregatedModels={modelRoutingCatalog}
            disabled={!autodreamEnabled}
            hint={
              modelRoutingCatalogStatus || "Small model used for autodream checkpoints. When set to default, autodream falls back to the Visor model, then the normal agent/default model."
            }
            emptyOptionTitle="Default Visor model"
            emptyOptionSubtitle="Fall back to Visor, agent, or system default"
          />

          <label>
            Interval (seconds)
            <input
              type="number"
              min={60}
              disabled={!autodreamEnabled}
              value={autodreamIntervalSeconds}
              onChange={(event) => setAutodream("intervalSeconds", parseIntField(event.target.value, 21600))}
            />
            <span className="entry-form-hint">How often to scan recent sessions. Default: 21600 s (6 hours).</span>
          </label>

          <label>
            Jitter (seconds)
            <input
              type="number"
              min={0}
              disabled={!autodreamEnabled}
              value={autodreamJitterSeconds}
              onChange={(event) => setAutodream("jitterSeconds", parseIntField(event.target.value, 1800))}
            />
            <span className="entry-form-hint">Random delay added to each interval to avoid predictable bursts. Default: 1800 s (30 min).</span>
          </label>

          <label>
            Sessions / Run
            <input
              type="number"
              min={1}
              disabled={!autodreamEnabled}
              value={autodreamSessionLimitPerRun}
              onChange={(event) => setAutodream("sessionLimitPerRun", parseIntField(event.target.value, 10))}
            />
            <span className="entry-form-hint">Maximum changed chat sessions reviewed in one autodream pass. Default: 10.</span>
          </label>
        </div>
      </section>
      )}

      {section === "supervision" && (
      <section className="entry-editor-card">
        <h3>Supervision</h3>
        <div className="entry-form-grid">
          <label>
            Tick Interval (seconds)
            <input
              type="number"
              min={5}
              value={tickIntervalSeconds}
              onChange={(event) => setVisor("tickIntervalSeconds", parseIntField(event.target.value, 30))}
            />
            <span className="entry-form-hint">How often the supervision loop runs. Default: 30 s.</span>
          </label>

          <label>
            Branch Timeout (seconds)
            <input
              type="number"
              min={5}
              value={branchTimeoutSeconds}
              onChange={(event) => setVisor("branchTimeoutSeconds", parseIntField(event.target.value, 60))}
            />
            <span className="entry-form-hint">How long a branch may stay active before Visor force-concludes it. Default: 60 s.</span>
          </label>
        </div>
      </section>
      )}

      {section === "memory" && (
      <section className="entry-editor-card">
        <h3>Memory Maintenance</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Maintenance Interval (seconds)
            <input
              type="number"
              min={60}
              value={maintenanceIntervalSeconds}
              onChange={(event) => setVisor("maintenanceIntervalSeconds", parseIntField(event.target.value, 3600))}
            />
            <span className="entry-form-hint">How often decay, pruning, and merge passes run. Default: 3600 s (1 hour).</span>
          </label>

          <label>
            Decay Rate / Day
            <input
              type="number"
              min={0}
              max={1}
              step={0.01}
              value={decayRatePerDay}
              onChange={(event) => setVisor("decayRatePerDay", parseFloatField(event.target.value, 0.05))}
            />
            <span className="entry-form-hint">Fraction of importance lost each day. 0.05 = 5% per day. Set to 0 to disable decay.</span>
          </label>

          <label>
            Prune Threshold
            <input
              type="number"
              min={0}
              max={1}
              step={0.01}
              value={pruneImportanceThreshold}
              onChange={(event) => setVisor("pruneImportanceThreshold", parseFloatField(event.target.value, 0.1))}
            />
            <span className="entry-form-hint">Memories below this importance score become candidates for pruning. Default: 0.1.</span>
          </label>

          <label>
            Prune Min Age (days)
            <input
              type="number"
              min={1}
              value={pruneMinAgeDays}
              onChange={(event) => setVisor("pruneMinAgeDays", parseIntField(event.target.value, 30))}
            />
            <span className="entry-form-hint">A memory must be at least this old before it can be pruned. Default: 30 days.</span>
          </label>
        </div>
      </section>
      )}

      {section === "supervision" && (
      <section className="entry-editor-card">
        <h3>Channel Health</h3>
        <div className="entry-form-grid">
          <label>
            Degraded Failure Count
            <input
              type="number"
              min={1}
              value={channelDegradedFailureCount}
              onChange={(event) => setVisor("channelDegradedFailureCount", parseIntField(event.target.value, 3))}
            />
            <span className="entry-form-hint">Number of worker failures in a channel within the window to trigger a degraded signal. Default: 3.</span>
          </label>

          <label>
            Failure Window (seconds)
            <input
              type="number"
              min={60}
              value={channelDegradedWindowSeconds}
              onChange={(event) => setVisor("channelDegradedWindowSeconds", parseIntField(event.target.value, 600))}
            />
            <span className="entry-form-hint">Sliding time window for counting failures. Default: 600 s (10 min).</span>
          </label>

          <label style={{ gridColumn: "1 / -1" }}>
            Idle Threshold (seconds)
            <input
              type="number"
              min={60}
              value={idleThresholdSeconds}
              onChange={(event) => setVisor("idleThresholdSeconds", parseIntField(event.target.value, 1800))}
            />
            <span className="entry-form-hint">Inactivity period before an idle signal is emitted. Default: 1800 s (30 min).</span>
          </label>
        </div>
      </section>
      )}

      {section === "supervision" && (
      <section className="entry-editor-card">
        <h3>Webhooks</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Webhook URLs
            <textarea
              rows={4}
              placeholder={"https://hooks.example.com/alert\nhttps://hooks.example.com/other"}
              value={webhookURLs.join("\n")}
              onChange={(event) => setVisor("webhookURLs", parseLines(event.target.value))}
            />
            <span className="entry-form-hint">One URL per line. POSTed with the event payload when a <code>visor.signal.*</code> event fires (channel degraded, idle).</span>
          </label>
        </div>
      </section>
      )}

      {section === "memory" && (
      <section className="entry-editor-card">
        <h3>Memory Merge</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Memory Merge
            <input type="checkbox" checked={mergeEnabled} onChange={(event) => setVisor("mergeEnabled", event.target.checked)} />
            <span className="entry-form-hint">When enabled, Visor consolidates similar memory entries into one during each maintenance pass. Requires a good recall backend to work effectively.</span>
          </label>

          <label>
            Similarity Threshold
            <input
              type="number"
              min={0}
              max={1}
              step={0.01}
              disabled={!mergeEnabled}
              value={mergeSimilarityThreshold}
              onChange={(event) => setVisor("mergeSimilarityThreshold", parseFloatField(event.target.value, 0.80))}
            />
            <span className="entry-form-hint">Minimum recall score (0–1) to consider two memories as merge candidates. Default: 0.80.</span>
          </label>

          <label>
            Max Merges / Run
            <input
              type="number"
              min={1}
              max={100}
              disabled={!mergeEnabled}
              value={mergeMaxPerRun}
              onChange={(event) => setVisor("mergeMaxPerRun", parseIntField(event.target.value, 10))}
            />
            <span className="entry-form-hint">Maximum number of merge operations per maintenance pass. Default: 10.</span>
          </label>
        </div>
      </section>
      )}

      {section === "memory" && (
      <section className="entry-editor-card">
        <h3>Embedding Model</h3>
        <div className="entry-form-grid">
          <label style={{ gridColumn: "1 / -1" }}>
            Embedding
            <input type="checkbox" checked={embeddingEnabled} onChange={(event) => setEmbedding({ enabled: event.target.checked })} />
            <span className="entry-form-hint">When enabled, memory entries are vectorized using the configured embedding model for semantic recall. Requires a compatible endpoint.</span>
          </label>

          <AggregatedModelPicker
            label="Model"
            value={embeddingModelValue}
            onChange={(id) => {
              const nextModel = embeddingRuntimeModelId(id);
              if (!nextModel) {
                return;
              }
              setEmbedding({
                model: nextModel,
                dimensions: inferEmbeddingDimensions(nextModel, embeddingDimensions)
              });
            }}
            aggregatedModels={embeddingModelCatalog}
            disabled={!embeddingEnabled}
            hint={
              modelRoutingCatalogStatus || "Search embedding-capable models returned by configured providers. Endpoint, dimensions, and auth can still be adjusted below."
            }
            emptyOptionTitle="Keep current model"
            emptyOptionSubtitle={embeddingModel}
          />

          <label>
            Model ID
            <input
              type="text"
              disabled={!embeddingEnabled}
              placeholder="text-embedding-3-small"
              value={embeddingModel}
              onChange={(event) => setEmbedding({ model: event.target.value })}
            />
            <span className="entry-form-hint">Model identifier sent to the embedding endpoint.</span>
          </label>

          <label>
            Dimensions
            <input
              type="number"
              min={1}
              disabled={!embeddingEnabled}
              value={embeddingDimensions}
              onChange={(event) => setEmbedding({ dimensions: parseIntField(event.target.value, 1536) })}
            />
            <span className="entry-form-hint">Output vector dimensionality. Must match the model (e.g. 1536 for text-embedding-3-small, 768 for nomic-embed-text).</span>
          </label>

          <label style={{ gridColumn: "1 / -1" }}>
            Endpoint
            <input
              type="text"
              disabled={!embeddingEnabled}
              placeholder="Leave empty to auto-detect from configured providers"
              value={embeddingEndpoint}
              onChange={(event) => setEmbedding({ endpoint: event.target.value })}
            />
            <span className="entry-form-hint">Full URL to the embeddings endpoint. For Ollama: <code>http://127.0.0.1:11434/v1/embeddings</code>. Leave empty to use the first configured OpenAI provider.</span>
          </label>

          <label style={{ gridColumn: "1 / -1" }}>
            API Key Env Var
            <input
              type="text"
              disabled={!embeddingEnabled}
              placeholder="OPENAI_API_KEY"
              value={embeddingApiKeyEnv}
              onChange={(event) => setEmbedding({ apiKeyEnv: event.target.value })}
            />
            <span className="entry-form-hint">Name of the environment variable holding the API key. Leave empty for Ollama (no auth required) or to use <code>OPENAI_API_KEY</code> as default.</span>
          </label>
        </div>
      </section>
      )}
    </div>
  );
}
