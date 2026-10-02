import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Network, DataSet } from "vis-network/standalone";
import { AgentMemoriesToolbar } from "../../features/agents/components/AgentMemoriesToolbar";
import { fetchProjectMemories, fetchProjectMemoryGraph } from "../../api";
import { LoadingSkeleton } from "../../components/LoadingSkeleton";

const PAGE_SIZE = 20;

const GRAPH_SETTINGS_KEY = "sloppy:memory-graph-settings";

interface GraphSettings {
  physics: boolean;
  nodeSize: number;
  edgeWidth: number;
  showLabels: boolean;
  showEdgeLabels: boolean;
  stabilize: boolean;
  layout: "physics" | "hierarchical";
}

const DEFAULT_GRAPH_SETTINGS: GraphSettings = {
  physics: true,
  nodeSize: 28,
  edgeWidth: 2,
  showLabels: true,
  showEdgeLabels: true,
  stabilize: true,
  layout: "physics",
};

function loadGraphSettings(): GraphSettings {
  try {
    const raw = localStorage.getItem(GRAPH_SETTINGS_KEY);
    if (!raw) return { ...DEFAULT_GRAPH_SETTINGS };
    const parsed = JSON.parse(raw);
    return { ...DEFAULT_GRAPH_SETTINGS, ...parsed };
  } catch {
    return { ...DEFAULT_GRAPH_SETTINGS };
  }
}

function saveGraphSettings(settings: GraphSettings) {
  localStorage.setItem(GRAPH_SETTINGS_KEY, JSON.stringify(settings));
}

type MemoryFilter = "all" | "persistent" | "temporary" | "todo";
type MemoryView = "list" | "graph";

interface MemoryScopeInfo {
  type: string;
  id: string;
  channelId?: string | null;
  projectId?: string | null;
  agentId?: string | null;
}

interface MemorySourceInfo {
  type: string;
  id?: string | null;
}

interface MemoryItem {
  id: string;
  note: string;
  summary?: string | null;
  kind: string;
  memoryClass: string;
  scope: MemoryScopeInfo;
  source?: MemorySourceInfo | null;
  importance: number;
  confidence: number;
  createdAt: string;
  updatedAt: string;
  expiresAt?: string | null;
  derivedCategory: Exclude<MemoryFilter, "all">;
}

interface MemoryEdgeRecord {
  fromMemoryId: string;
  toMemoryId: string;
  relation: string;
  weight: number;
  provenance?: string | null;
  createdAt: string;
}

interface MemoryListResponse {
  projectId: string;
  items: MemoryItem[];
  total: number;
  limit: number;
  offset: number;
}

interface MemoryGraphResponse {
  projectId: string;
  nodes: MemoryItem[];
  edges: MemoryEdgeRecord[];
  seedIds: string[];
  truncated: boolean;
}

function asString(value: unknown, fallback = "") {
  const text = String(value ?? "").trim();
  return text || fallback;
}

function asNumber(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeScope(raw: unknown): MemoryScopeInfo {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  return {
    type: asString(item.type, "global"),
    id: asString(item.id, "global"),
    channelId: asString(item.channelId ?? item.channel_id ?? "", "") || null,
    projectId: asString(item.projectId ?? item.project_id ?? "", "") || null,
    agentId: asString(item.agentId ?? item.agent_id ?? "", "") || null,
  };
}

function normalizeSource(raw: unknown): MemorySourceInfo | null {
  if (!raw || typeof raw !== "object") return null;
  const item = raw as Record<string, unknown>;
  const type = asString(item.type);
  if (!type) return null;
  return { type, id: asString(item.id, "") || null };
}

function normalizeMemoryItem(raw: unknown, index = 0): MemoryItem | null {
  if (!raw || typeof raw !== "object") return null;
  const item = raw as Record<string, unknown>;
  const id = asString(item.id, `memory-${index + 1}`);
  const note = asString(item.note);
  if (!id || !note) return null;

  const derivedCategory = asString(item.derivedCategory ?? item.derived_category, "temporary");
  const normalizedCategory: Exclude<MemoryFilter, "all"> =
    derivedCategory === "persistent" || derivedCategory === "todo" ? derivedCategory : "temporary";

  return {
    id,
    note,
    summary: asString(item.summary, "") || null,
    kind: asString(item.kind, "fact"),
    memoryClass: asString(item.memoryClass ?? item.memory_class, "semantic"),
    scope: normalizeScope(item.scope),
    source: normalizeSource(item.source),
    importance: asNumber(item.importance, 0),
    confidence: asNumber(item.confidence, 0),
    createdAt: asString(item.createdAt ?? item.created_at, new Date(0).toISOString()),
    updatedAt: asString(item.updatedAt ?? item.updated_at, new Date(0).toISOString()),
    expiresAt: asString(item.expiresAt ?? item.expires_at, "") || null,
    derivedCategory: normalizedCategory,
  };
}

function normalizeListResponse(raw: unknown): MemoryListResponse {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const items = Array.isArray(item.items)
    ? (item.items.map(normalizeMemoryItem).filter(Boolean) as MemoryItem[])
    : [];
  return {
    projectId: asString(item.projectId ?? item.project_id),
    items,
    total: asNumber(item.total, items.length),
    limit: asNumber(item.limit, PAGE_SIZE),
    offset: asNumber(item.offset, 0),
  };
}

function normalizeEdge(raw: unknown): MemoryEdgeRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const item = raw as Record<string, unknown>;
  const fromMemoryId = asString(item.fromMemoryId ?? item.from_memory_id);
  const toMemoryId = asString(item.toMemoryId ?? item.to_memory_id);
  if (!fromMemoryId || !toMemoryId) return null;
  return {
    fromMemoryId,
    toMemoryId,
    relation: asString(item.relation, "about"),
    weight: asNumber(item.weight, 1),
    provenance: asString(item.provenance, "") || null,
    createdAt: asString(item.createdAt ?? item.created_at, new Date(0).toISOString()),
  };
}

function normalizeGraphResponse(raw: unknown): MemoryGraphResponse {
  const item = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const rawSeedIds = item.seedIds ?? item.seed_ids;
  return {
    projectId: asString(item.projectId ?? item.project_id),
    nodes: Array.isArray(item.nodes)
      ? (item.nodes.map(normalizeMemoryItem).filter(Boolean) as MemoryItem[])
      : [],
    edges: Array.isArray(item.edges)
      ? (item.edges.map(normalizeEdge).filter(Boolean) as MemoryEdgeRecord[])
      : [],
    seedIds: Array.isArray(rawSeedIds)
      ? rawSeedIds.map((e: unknown) => asString(e)).filter(Boolean)
      : [],
    truncated: Boolean(item.truncated),
  };
}

function formatRelativeDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown time";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function formatScore(value: number) {
  return `${Math.round(Math.max(0, Math.min(1, value)) * 100)}%`;
}

function scopeHint(scope: MemoryScopeInfo) {
  if (scope.type === "agent") return `Agent scope · ${scope.agentId || scope.id}`;
  if (scope.type === "channel") return `Session channel · ${scope.channelId || scope.id}`;
  if (scope.type === "project") return `Project scope · ${scope.projectId || scope.id}`;
  return `Global scope · ${scope.id}`;
}

function memoryCardTitle(item: MemoryItem) {
  if (item.summary) return item.summary;
  return item.note.length > 72 ? `${item.note.slice(0, 72)}…` : item.note;
}

function categoryLabel(value: Exclude<MemoryFilter, "all">) {
  if (value === "persistent") return "Persistent";
  if (value === "temporary") return "Temporary";
  return "Todo";
}

const NODE_COLOR = "#555555";
const NODE_COLOR_SEED = "#777777";
const DIMMED_OPACITY = 0.15;
const ANIM_DURATION = 220;

const ACCENT_STORAGE_KEY = "sloppy_accent_color";
const DEFAULT_ACCENT = "#ccff00";

function getAccentColor(): string {
  const stored = localStorage.getItem(ACCENT_STORAGE_KEY);
  if (stored && /^#([0-9a-fA-F]{3}){1,2}$/.test(stored)) return stored;
  return DEFAULT_ACCENT;
}

function accentRgba(accent: string, alpha: number): string {
  const [r, g, b] = hexToRgb(accent);
  return `rgba(${r},${g},${b},${alpha})`;
}

type RGB = [number, number, number];

function hexToRgb(hex: string): RGB {
  const h = hex.replace("#", "");
  return [parseInt(h.substring(0, 2), 16), parseInt(h.substring(2, 4), 16), parseInt(h.substring(4, 6), 16)];
}

function rgbToHex([r, g, b]: RGB): string {
  return "#" + [r, g, b].map((c) => Math.round(c).toString(16).padStart(2, "0")).join("");
}

function lerpColor(from: string, to: string, t: number): string {
  const a = hexToRgb(from);
  const b = hexToRgb(to);
  return rgbToHex([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]);
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

interface AnimTarget {
  color: string;
  opacity: number;
}

class NodeAnimator {
  private targets = new Map<string, AnimTarget>();
  private current = new Map<string, AnimTarget>();
  private rafId: number | null = null;
  private startTime: number | null = null;
  private duration: number;
  private snapshotFrom = new Map<string, AnimTarget>();
  private accent: string;

  constructor(
    private nodesDS: DataSet<Record<string, unknown>>,
    duration = ANIM_DURATION,
    accent = DEFAULT_ACCENT,
  ) {
    this.duration = duration;
    this.accent = accent;
  }

  setTargets(entries: Array<{ id: string; color: string; opacity: number }>) {
    this.snapshotFrom.clear();
    for (const e of entries) {
      const cur = this.current.get(e.id) ?? { color: e.color, opacity: e.opacity };
      this.snapshotFrom.set(e.id, { ...cur });
      this.targets.set(e.id, { color: e.color, opacity: e.opacity });
    }
    this.startTime = null;
    if (!this.rafId) this.tick();
  }

  private tick = () => {
    if (!this.startTime) this.startTime = performance.now();
    const elapsed = performance.now() - this.startTime;
    const rawT = Math.min(elapsed / this.duration, 1);
    const t = easeOutCubic(rawT);

    const updates: Array<Record<string, unknown>> = [];
    for (const [id, target] of this.targets) {
      const from = this.snapshotFrom.get(id) ?? target;
      const c = lerpColor(from.color, target.color, t);
      const o = lerp(from.opacity, target.opacity, t);
      const state: AnimTarget = { color: c, opacity: o };
      this.current.set(id, state);
      updates.push({
        id,
        color: { background: c, border: c, highlight: { background: this.accent, border: this.accent }, hover: { background: this.accent, border: this.accent } },
        opacity: o,
      });
    }
    this.nodesDS.update(updates);

    if (rawT < 1) {
      this.rafId = requestAnimationFrame(this.tick);
    } else {
      this.rafId = null;
    }
  };

  destroy() {
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.rafId = null;
  }
}

function buildVisOptions(settings: GraphSettings, accent: string): Record<string, unknown> {
  const base: Record<string, unknown> = {
    autoResize: true,
    nodes: {
      shape: "dot",
      size: settings.nodeSize,
      font: { face: "Fira Code, monospace", size: 11, color: "rgba(240,240,240,0.85)", vadjust: 2 },
      borderWidth: 0,
      borderWidthSelected: 0,
      color: {
        background: NODE_COLOR,
        border: NODE_COLOR,
        highlight: { background: accent, border: accent },
        hover: { background: accent, border: accent },
      },
      shadow: false,
      chosen: false,
    },
    edges: {
      color: { color: "rgba(180,190,210,0.2)", highlight: accentRgba(accent, 0.7), hover: accentRgba(accent, 0.5), opacity: 1 },
      width: settings.edgeWidth,
      smooth: { type: "continuous" },
      arrows: { to: { enabled: true, scaleFactor: 0.4, type: "arrow" } },
      font: { face: "Fira Code, monospace", size: settings.showEdgeLabels ? 10 : 0, color: "#888888", strokeWidth: 3, strokeColor: "#000000" },
      chosen: false,
    },
    interaction: { hover: true, tooltipDelay: 200, zoomView: true, dragView: true, dragNodes: true, multiselect: false },
    physics: {
      enabled: settings.physics,
      barnesHut: { gravitationalConstant: -6000, centralGravity: 0.15, springLength: 320, springConstant: 0.025, damping: 0.09 },
      stabilization: { enabled: settings.stabilize, iterations: 150, updateInterval: 25 },
    },
  };

  if (settings.layout === "hierarchical") {
    base.layout = { hierarchical: { enabled: true, direction: "UD", sortMethod: "directed", levelSeparation: 200, nodeSpacing: 240 } };
    base.physics = { enabled: false };
  }

  return base;
}

function MemoryGraphSettingsPanel({
  settings,
  onChange,
  onClose,
}: {
  settings: GraphSettings;
  onChange: (next: GraphSettings) => void;
  onClose: () => void;
}) {
  const update = (patch: Partial<GraphSettings>) => {
    const next = { ...settings, ...patch };
    onChange(next);
    saveGraphSettings(next);
  };

  const reset = () => {
    onChange({ ...DEFAULT_GRAPH_SETTINGS });
    saveGraphSettings({ ...DEFAULT_GRAPH_SETTINGS });
  };

  return (
    <div className="memory-graph-settings-panel">
      <div className="memory-graph-settings-head">
        <strong>Graph Settings</strong>
        <button type="button" className="icon-btn" onClick={onClose} title="Close">
          <span className="material-symbols-rounded">close</span>
        </button>
      </div>
      <label className="memory-graph-setting-row">
        <span>Layout</span>
        <select value={settings.layout} onChange={(e) => update({ layout: e.target.value as GraphSettings["layout"] })}>
          <option value="physics">Force-directed</option>
          <option value="hierarchical">Hierarchical</option>
        </select>
      </label>
      <label className="memory-graph-setting-row">
        <span>Physics simulation</span>
        <input type="checkbox" checked={settings.physics} onChange={(e) => update({ physics: e.target.checked })} />
      </label>
      <label className="memory-graph-setting-row">
        <span>Node labels</span>
        <input type="checkbox" checked={settings.showLabels} onChange={(e) => update({ showLabels: e.target.checked })} />
      </label>
      <label className="memory-graph-setting-row">
        <span>Edge labels</span>
        <input type="checkbox" checked={settings.showEdgeLabels} onChange={(e) => update({ showEdgeLabels: e.target.checked })} />
      </label>
      <label className="memory-graph-setting-row">
        <span>Node size</span>
        <input type="range" min={16} max={48} step={2} value={settings.nodeSize} onChange={(e) => update({ nodeSize: Number(e.target.value) })} />
        <span className="memory-graph-setting-value">{settings.nodeSize}</span>
      </label>
      <label className="memory-graph-setting-row">
        <span>Edge width</span>
        <input type="range" min={1} max={6} step={0.5} value={settings.edgeWidth} onChange={(e) => update({ edgeWidth: Number(e.target.value) })} />
        <span className="memory-graph-setting-value">{settings.edgeWidth}</span>
      </label>
      <label className="memory-graph-setting-row">
        <span>Stabilize on load</span>
        <input type="checkbox" checked={settings.stabilize} onChange={(e) => update({ stabilize: e.target.checked })} />
      </label>
      <div className="memory-graph-settings-actions">
        <button type="button" onClick={reset}>Reset defaults</button>
      </div>
    </div>
  );
}

function VisNetworkGraph({
  graphData,
  settings,
  selectedMemoryId,
  onSelectNode,
}: {
  graphData: MemoryGraphResponse;
  settings: GraphSettings;
  selectedMemoryId: string | null;
  onSelectNode: (id: string | null) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const networkRef = useRef<Network | null>(null);
  const nodesDatasetRef = useRef<DataSet<Record<string, unknown>> | null>(null);
  const edgesDatasetRef = useRef<DataSet<Record<string, unknown>> | null>(null);

  const connectedMap = useMemo(() => {
    const map = new Map<string, Set<string>>();
    for (const edge of graphData.edges) {
      if (!map.has(edge.fromMemoryId)) map.set(edge.fromMemoryId, new Set());
      if (!map.has(edge.toMemoryId)) map.set(edge.toMemoryId, new Set());
      map.get(edge.fromMemoryId)!.add(edge.toMemoryId);
      map.get(edge.toMemoryId)!.add(edge.fromMemoryId);
    }
    return map;
  }, [graphData.edges]);

  const connectedEdgesMap = useMemo(() => {
    const map = new Map<string, Set<string>>();
    for (const edge of graphData.edges) {
      const edgeId = `${edge.fromMemoryId}→${edge.toMemoryId}`;
      if (!map.has(edge.fromMemoryId)) map.set(edge.fromMemoryId, new Set());
      if (!map.has(edge.toMemoryId)) map.set(edge.toMemoryId, new Set());
      map.get(edge.fromMemoryId)!.add(edgeId);
      map.get(edge.toMemoryId)!.add(edgeId);
    }
    return map;
  }, [graphData.edges]);

  const accent = getAccentColor();

  const buildNodeColor = useCallback((_item: MemoryItem, isSeed: boolean) => {
    const bg = isSeed ? NODE_COLOR_SEED : NODE_COLOR;
    return { background: bg, border: bg, highlight: { background: accent, border: accent }, hover: { background: accent, border: accent } };
  }, [accent]);

  useEffect(() => {
    if (!containerRef.current || graphData.nodes.length === 0) return;

    const seedSet = new Set(graphData.seedIds);
    const visNodes = graphData.nodes.map((item) => {
      const isSeed = seedSet.has(item.id);
      return {
        id: item.id,
        label: settings.showLabels ? memoryCardTitle(item) : "",
        title: `${categoryLabel(item.derivedCategory)} · ${item.kind}\n${item.note.slice(0, 200)}`,
        color: buildNodeColor(item, isSeed),
        size: (isSeed ? settings.nodeSize * 1.4 : settings.nodeSize) * 0.8,
        font: { size: 11, color: "rgba(240,240,240,0.85)" },
        borderWidth: 0,
      };
    });

    const visEdges = graphData.edges.map((edge) => ({
      id: `${edge.fromMemoryId}→${edge.toMemoryId}`,
      from: edge.fromMemoryId,
      to: edge.toMemoryId,
      label: settings.showEdgeLabels ? edge.relation : undefined,
      title: `${edge.relation} (weight: ${edge.weight})`,
      width: settings.edgeWidth,
    }));

    const nodesDS = new DataSet(visNodes);
    const edgesDS = new DataSet(visEdges);
    nodesDatasetRef.current = nodesDS as unknown as DataSet<Record<string, unknown>>;
    edgesDatasetRef.current = edgesDS as unknown as DataSet<Record<string, unknown>>;

    const options = buildVisOptions(settings, accent);
    const net = new Network(containerRef.current, { nodes: nodesDS, edges: edgesDS }, options);
    networkRef.current = net;

    net.on("click", (params: { nodes: string[] }) => {
      if (params.nodes.length > 0) onSelectNode(params.nodes[0]);
    });

    const animator = new NodeAnimator(nodesDS as unknown as DataSet<Record<string, unknown>>, ANIM_DURATION, accent);

    net.on("hoverNode", (params: { node: string }) => {
      const hoveredId = params.node;
      const connected = connectedMap.get(hoveredId) ?? new Set();
      const connEdges = connectedEdgesMap.get(hoveredId) ?? new Set();

      const animEntries = graphData.nodes.map((item) => {
        const isHovered = item.id === hoveredId;
        const isConnected = connected.has(item.id);
        const isSeed = seedSet.has(item.id);
        if (isHovered) return { id: item.id, color: accent, opacity: 1 };
        if (isConnected) return { id: item.id, color: isSeed ? NODE_COLOR_SEED : NODE_COLOR, opacity: 1 };
        return { id: item.id, color: isSeed ? NODE_COLOR_SEED : NODE_COLOR, opacity: DIMMED_OPACITY };
      });
      animator.setTargets(animEntries);

      const edgeUpdates = graphData.edges.map((edge) => {
        const edgeId = `${edge.fromMemoryId}→${edge.toMemoryId}`;
        if (connEdges.has(edgeId)) return { id: edgeId, color: { color: accentRgba(accent, 0.7), opacity: 1 }, width: settings.edgeWidth + 1 };
        return { id: edgeId, color: { color: "rgba(180,190,210,0.2)", opacity: DIMMED_OPACITY }, width: settings.edgeWidth };
      });
      edgesDS.update(edgeUpdates);
    });

    net.on("blurNode", () => {
      const animEntries = graphData.nodes.map((item) => {
        const isSeed = seedSet.has(item.id);
        return { id: item.id, color: isSeed ? NODE_COLOR_SEED : NODE_COLOR, opacity: 1 };
      });
      animator.setTargets(animEntries);

      const edgeResets = graphData.edges.map((edge) => ({
        id: `${edge.fromMemoryId}→${edge.toMemoryId}`,
        color: { color: "rgba(180,190,210,0.2)", opacity: 1 },
        width: settings.edgeWidth,
      }));
      edgesDS.update(edgeResets);
    });

    return () => {
      animator.destroy();
      net.destroy();
      networkRef.current = null;
    };
  }, [graphData, settings, buildNodeColor, connectedMap, connectedEdgesMap, onSelectNode]);

  useEffect(() => {
    if (!networkRef.current || !selectedMemoryId) return;
    networkRef.current.selectNodes([selectedMemoryId], false);
  }, [selectedMemoryId]);

  return <div ref={containerRef} className="memory-graph-vis-container" />;
}

function MemoryInspector({ item }: { item: MemoryItem | null }) {
  if (!item) {
    return (
      <aside className="agent-memory-inspector">
        <p className="placeholder-text">Select a memory record to inspect its full content.</p>
      </aside>
    );
  }

  return (
    <aside className="agent-memory-inspector">
      <div className="agent-memory-inspector-head">
        <div className="agent-memory-badges">
          <span className={`agent-memory-badge agent-memory-badge-${item.derivedCategory}`}>{categoryLabel(item.derivedCategory)}</span>
          <span className="agent-memory-badge agent-memory-badge-neutral">{item.kind}</span>
          <span className="agent-memory-badge agent-memory-badge-neutral">{item.memoryClass}</span>
        </div>
        <span className="agent-memory-date">{formatRelativeDate(item.createdAt)}</span>
      </div>
      <h4>{memoryCardTitle(item)}</h4>
      <p className="agent-memory-note">{item.note}</p>
      <dl className="agent-memory-inspector-meta">
        <div>
          <dt>Scope</dt>
          <dd>{scopeHint(item.scope)}</dd>
        </div>
        <div>
          <dt>Source</dt>
          <dd>{item.source ? `${item.source.type}${item.source.id ? ` · ${item.source.id}` : ""}` : "None"}</dd>
        </div>
        <div>
          <dt>Importance</dt>
          <dd>{formatScore(item.importance)}</dd>
        </div>
        <div>
          <dt>Confidence</dt>
          <dd>{formatScore(item.confidence)}</dd>
        </div>
        <div>
          <dt>Updated</dt>
          <dd>{formatRelativeDate(item.updatedAt)}</dd>
        </div>
        <div>
          <dt>Expires</dt>
          <dd>{item.expiresAt ? formatRelativeDate(item.expiresAt) : "Never"}</dd>
        </div>
      </dl>
    </aside>
  );
}

export function ProjectMemoryTab({ projectId }: { projectId: string }) {
  const [searchInput, setSearchInput] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [filter, setFilter] = useState<MemoryFilter>("all");
  const [view, setView] = useState<MemoryView>("list");
  const [offset, setOffset] = useState(0);
  const [listResponse, setListResponse] = useState<MemoryListResponse>({
    projectId,
    items: [],
    total: 0,
    limit: PAGE_SIZE,
    offset: 0,
  });
  const [graphResponse, setGraphResponse] = useState<MemoryGraphResponse>({
    projectId,
    nodes: [],
    edges: [],
    seedIds: [],
    truncated: false,
  });
  const [listStatusText, setListStatusText] = useState("Loading memories...");
  const [graphStatusText, setGraphStatusText] = useState("Loading memory graph...");
  const [isLoadingList, setIsLoadingList] = useState(true);
  const [isLoadingGraph, setIsLoadingGraph] = useState(false);
  const [selectedMemoryId, setSelectedMemoryId] = useState<string | null>(null);
  const [graphSettings, setGraphSettings] = useState<GraphSettings>(loadGraphSettings);
  const [showGraphSettings, setShowGraphSettings] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => setSearchQuery(searchInput.trim()), 300);
    return () => clearTimeout(timer);
  }, [searchInput]);

  useEffect(() => {
    setOffset(0);
  }, [searchQuery, filter]);

  useEffect(() => {
    let cancelled = false;

    async function loadMemories() {
      setIsLoadingList(true);
      const response = await fetchProjectMemories(projectId, {
        search: searchQuery || undefined,
        filter,
        limit: PAGE_SIZE,
        offset,
      });

      if (cancelled) return;

      if (!response) {
        setListResponse({ projectId, items: [], total: 0, limit: PAGE_SIZE, offset });
        setListStatusText("Failed to load project memories.");
        setIsLoadingList(false);
        return;
      }

      const normalized = normalizeListResponse(response);
      setListResponse(normalized);
      if (normalized.items.length === 0) {
        setListStatusText(
          searchQuery || filter !== "all"
            ? "No memories match the current search."
            : "No memories stored for this project."
        );
      } else {
        const from = normalized.offset + 1;
        const to = normalized.offset + normalized.items.length;
        setListStatusText(`Showing ${from}-${to} of ${normalized.total} memories.`);
      }
      setIsLoadingList(false);
    }

    loadMemories().catch(() => {
      if (!cancelled) {
        setListResponse({ projectId, items: [], total: 0, limit: PAGE_SIZE, offset });
        setListStatusText("Failed to load project memories.");
        setIsLoadingList(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [projectId, searchQuery, filter, offset]);

  useEffect(() => {
    if (view !== "graph") return;
    let cancelled = false;

    async function loadGraph() {
      setIsLoadingGraph(true);
      const response = await fetchProjectMemoryGraph(projectId, {
        search: searchQuery || undefined,
        filter,
      });

      if (cancelled) return;

      if (!response) {
        setGraphResponse({ projectId, nodes: [], edges: [], seedIds: [], truncated: false });
        setGraphStatusText("Failed to load memory graph.");
        setIsLoadingGraph(false);
        return;
      }

      const normalized = normalizeGraphResponse(response);
      setGraphResponse(normalized);
      if (normalized.nodes.length === 0) {
        setGraphStatusText(
          searchQuery || filter !== "all"
            ? "No graph nodes match the current search."
            : "No connected memory available yet."
        );
      } else if (normalized.truncated) {
        setGraphStatusText(`Graph loaded with ${normalized.nodes.length} nodes. Showing a truncated one-hop neighborhood.`);
      } else {
        setGraphStatusText(`Graph loaded with ${normalized.nodes.length} nodes and ${normalized.edges.length} edges.`);
      }
      setIsLoadingGraph(false);
    }

    loadGraph().catch(() => {
      if (!cancelled) {
        setGraphResponse({ projectId, nodes: [], edges: [], seedIds: [], truncated: false });
        setGraphStatusText("Failed to load memory graph.");
        setIsLoadingGraph(false);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [projectId, searchQuery, filter, view]);

  const visibleItems = view === "graph" ? graphResponse.nodes : listResponse.items;
  const selectedItem = useMemo(
    () => visibleItems.find((item) => item.id === selectedMemoryId) || null,
    [visibleItems, selectedMemoryId]
  );

  useEffect(() => {
    if (selectedItem) return;
    if (visibleItems.length > 0) {
      setSelectedMemoryId(visibleItems[0].id);
      return;
    }
    setSelectedMemoryId(null);
  }, [selectedItem, visibleItems]);

  const handleGraphNodeSelect = useCallback((id: string | null) => {
    setSelectedMemoryId(id);
  }, []);

  const canGoBackward = listResponse.offset > 0;
  const canGoForward = listResponse.offset + listResponse.items.length < listResponse.total;

  return (
    <section className="agent-memories-shell">
      <div className="agent-config-head">
        <div className="agent-tools-head-copy">
          <h3>Project Memory</h3>
          <p className="placeholder-text">Search and visualize memory entries scoped to this project.</p>
        </div>
        <span className="agent-tools-status">{view === "graph" ? graphStatusText : listStatusText}</span>
      </div>

      <AgentMemoriesToolbar
        searchInput={searchInput}
        onSearchInputChange={setSearchInput}
        filter={filter}
        onFilterChange={setFilter}
        view={view}
        onViewChange={setView}
      />

      <div className="agent-memories-body">
        <div className="agent-memories-main">
          {view === "list" ? (
            <div className="agent-memory-list-shell">
              {isLoadingList ? (
                <LoadingSkeleton label="Loading memory records…" variant="list" rows={5} />
              ) : listResponse.items.length === 0 ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">{listStatusText}</p>
                </div>
              ) : (
                <>
                  <div className="agent-memory-list">
                    {listResponse.items.map((item) => (
                      <button
                        key={item.id}
                        type="button"
                        className={`agent-memory-card ${selectedMemoryId === item.id ? "selected" : ""}`}
                        onClick={() => setSelectedMemoryId(item.id)}
                      >
                        <div className="agent-memory-card-head">
                          <strong>{memoryCardTitle(item)}</strong>
                          <span className="agent-memory-date">{formatRelativeDate(item.createdAt)}</span>
                        </div>
                        <p className="agent-memory-note">{item.note}</p>
                        <div className="agent-memory-badges">
                          <span className={`agent-memory-badge agent-memory-badge-${item.derivedCategory}`}>{categoryLabel(item.derivedCategory)}</span>
                          <span className="agent-memory-badge agent-memory-badge-neutral">{item.kind}</span>
                          <span className="agent-memory-badge agent-memory-badge-neutral">{item.memoryClass}</span>
                        </div>
                        <div className="agent-memory-card-foot">
                          <span>{scopeHint(item.scope)}</span>
                          <span>{item.id}</span>
                        </div>
                      </button>
                    ))}
                  </div>

                  <div className="agent-memory-pagination">
                    <button type="button" disabled={!canGoBackward} onClick={() => setOffset((current) => Math.max(0, current - PAGE_SIZE))}>
                      Previous
                    </button>
                    <span>{listStatusText}</span>
                    <button type="button" disabled={!canGoForward} onClick={() => setOffset((current) => current + PAGE_SIZE)}>
                      Next
                    </button>
                  </div>
                </>
              )}
            </div>
          ) : (
            <div className="agent-memory-graph-shell">
              <div className="agent-memory-graph-toolbar">
                <button
                  type="button"
                  className={`agent-memory-segment ${showGraphSettings ? "active" : ""}`}
                  onClick={() => setShowGraphSettings((v) => !v)}
                  title="Graph settings"
                >
                  <span className="material-symbols-rounded" style={{ fontSize: "18px" }}>tune</span>
                  Settings
                </button>
              </div>
              {showGraphSettings && (
                <MemoryGraphSettingsPanel
                  settings={graphSettings}
                  onChange={setGraphSettings}
                  onClose={() => setShowGraphSettings(false)}
                />
              )}
              {isLoadingGraph ? (
                <LoadingSkeleton label="Loading memory graph…" variant="graph" />
              ) : graphResponse.nodes.length === 0 ? (
                <div className="agent-memories-empty">
                  <p className="placeholder-text">{graphStatusText}</p>
                </div>
              ) : (
                <>
                  {graphResponse.truncated ? (
                    <div className="agent-memory-graph-notice">
                      Graph view is truncated to the top matching seeds and their one-hop neighbors.
                    </div>
                  ) : null}
                  <VisNetworkGraph
                    graphData={graphResponse}
                    settings={graphSettings}
                    selectedMemoryId={selectedMemoryId}
                    onSelectNode={handleGraphNodeSelect}
                  />
                </>
              )}
            </div>
          )}
        </div>

        <MemoryInspector item={selectedItem} />
      </div>
    </section>
  );
}
