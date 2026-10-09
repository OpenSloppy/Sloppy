import React, { useCallback, useEffect, useMemo, useState } from "react";
import type { CoreApi } from "../shared/api/coreApi";

type AnyRecord = Record<string, unknown>;
type MeshModal = "network" | "invite" | "accept" | "join" | "node" | "disconnect" | null;
type MeshGraphNode = {
  id: string;
  name: string;
  endpoint: string;
  ip: string;
  status: string;
  kind: "relay" | "worker";
  roles: string;
  capabilities: string;
  lastSeen: string;
  x: number;
  y: number;
};

const CAPABILITY_OPTIONS = [
  { id: "run_agent", label: "Run agent", detail: "Can execute assigned Sloppy work" },
  { id: "git", label: "Git", detail: "Can branch, commit, and push" },
  { id: "run_shell", label: "Shell", detail: "Can run local commands" },
  { id: "local_files", label: "Local files", detail: "Can inspect local paths" },
  { id: "sloppy.core.remote", label: "Full Sloppy", detail: "Can use this instance through the encrypted relay" },
  { id: "sloppy.terminal.control", label: "Remote terminal", detail: "Can open an interactive terminal through the encrypted relay" },
];

const ROLE_OPTIONS = [
  { id: "worker", label: "worker", tooltip: "Executes assigned mesh tasks on this node and reports lifecycle state back to the relay." },
  { id: "client", label: "client", tooltip: "Connects to the mesh as a consumer of relay services without receiving worker execution tasks." },
  { id: "controller", label: "controller", tooltip: "Coordinates mesh control-plane actions such as routing, registry updates, and node operations." },
  { id: "reviewer", label: "reviewer", tooltip: "Reviews worker output and participates in approval or verification flows before work is accepted." },
];
function text(value: unknown, fallback = "") {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function records(value: unknown) {
  return Array.isArray(value) ? (value as AnyRecord[]) : [];
}

function list(value: unknown) {
  return Array.isArray(value) ? value.map((item) => String(item || "").trim()).filter(Boolean) : [];
}

function csv(value: string) {
  return value.split(",").map((part) => part.trim()).filter(Boolean);
}

function toCsv(values: string[]) {
  return values.join(",");
}

function meshInviteToken(invite: AnyRecord) {
  return text(invite.bundleToken, text(invite.token));
}

function parseMeshInviteBundle(token: string) {
  const prefix = "slp_mesh_";
  if (!token.startsWith(prefix)) {
    return null;
  }
  try {
    const encoded = token.slice(prefix.length).replace(/-/g, "+").replace(/_/g, "/");
    const padded = encoded.padEnd(encoded.length + ((4 - encoded.length % 4) % 4), "=");
    return JSON.parse(atob(padded)) as AnyRecord;
  } catch {
    return null;
  }
}

function relayURLFromInviteToken(token: string) {
  return text(parseMeshInviteBundle(token)?.relayURL);
}

function statusLabel(value: unknown) {
  return text(value, "offline").replace(/_/g, " ");
}

function statusClass(value: unknown) {
  const raw = text(value, "offline");
  return ["online", "degraded", "offline"].includes(raw) ? raw : "offline";
}

function endpointHost(value: unknown) {
  const raw = text(value);
  if (!raw) {
    return "No endpoint";
  }
  try {
    return new URL(raw).host || raw;
  } catch {
    return raw.split("/")[0] || raw;
  }
}

function formatTime(value: unknown) {
  const raw = text(value);
  if (!raw) {
    return "never";
  }
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) {
    return raw;
  }
  return date.toLocaleString();
}

function utf8ToBase64(value: string) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary);
}

function base64ToUTF8(value: string) {
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function nodeName(nodes: AnyRecord[], nodeId: string) {
  return text(nodes.find((node) => text(node.id) === nodeId)?.name, nodeId);
}

function segmentsToText(segments: unknown) {
  return records(segments).map((segment) => {
    if (text(segment.kind) === "text") {
      return text(segment.text);
    }
    const attachment = segment.attachment as AnyRecord | undefined;
    if (text(segment.kind) === "attachment" && text(attachment?.name)) {
      return `[Attachment: ${text(attachment?.name)}]`;
    }
    return "";
  }).filter(Boolean).join("\n").trim();
}

function sessionMessages(detail: AnyRecord | null) {
  const direct = records(detail?.recentMessages);
  if (direct.length > 0) {
    return direct.map((message, index) => ({
      id: text(message.id, text(message.createdAt, `message-${index}`)),
      role: text(message.role, text(message.authorRole, "event")),
      content: text(message.content, text(message.text, text(message.summary)))
    })).filter((message) => message.content);
  }
  return records(detail?.events).map((event, index) => ({
    id: text(event.id, text(event.createdAt, `event-${index}`)),
    role: text((event.message as AnyRecord | undefined)?.role, text(event.type, "event")),
    content: segmentsToText((event.message as AnyRecord | undefined)?.segments)
      || text(event.content, text(event.text, text(event.summary, text(event.message))))
  })).filter((message) => message.content);
}

function toggleCsvValue(raw: string, value: string) {
  const current = new Set(csv(raw));
  if (current.has(value)) {
    current.delete(value);
  } else {
    current.add(value);
  }
  return toCsv(Array.from(current));
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="nodes-field">
      <span>{label}</span>
      {children}
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}

function ChipPicker({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: Array<{ id: string; label: string; detail?: string; tooltip?: string }>;
  onChange: (value: string) => void;
}) {
  const selected = new Set(csv(value));
  return (
    <div className="nodes-picker" role="group" aria-label={label}>
      <div className="nodes-picker-label">{label}</div>
      <div className="nodes-chip-grid">
        {options.map((option) => (
          <button
            key={option.id}
            type="button"
            className={selected.has(option.id) ? "active" : ""}
            data-tooltip={option.tooltip || undefined}
            aria-label={option.tooltip ? `${option.label}. ${option.tooltip}` : option.label}
            onClick={() => onChange(toggleCsvValue(value, option.id))}
          >
            <span>{option.label}</span>
            {option.detail ? <small>{option.detail}</small> : null}
          </button>
        ))}
      </div>
    </div>
  );
}

function MeshModalFrame({
  title,
  description,
  icon,
  onClose,
  children,
  className = "",
}: {
  title: string;
  description: string;
  icon: string;
  onClose: () => void;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div className="nodes-modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className={`nodes-modal ${className}`.trim()}
        role="dialog"
        aria-modal="true"
        aria-labelledby="nodes-modal-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="nodes-modal-head">
          <span className="material-symbols-rounded" aria-hidden="true">{icon}</span>
          <div>
            <h3 id="nodes-modal-title">{title}</h3>
            <p>{description}</p>
          </div>
          <button type="button" className="nodes-icon-button" onClick={onClose} aria-label="Close modal">
            <span className="material-symbols-rounded" aria-hidden="true">close</span>
          </button>
        </header>
        {children}
      </section>
    </div>
  );
}

export function NodesView({ coreApi }: { coreApi: CoreApi }) {
  const [nodes, setNodes] = useState<AnyRecord[]>([]);
  const [localNode, setLocalNode] = useState<AnyRecord | null>(null);
  const [projects, setProjects] = useState<AnyRecord[]>([]);
  const [tasks, setTasks] = useState<AnyRecord[]>([]);
  const [invites, setInvites] = useState<AnyRecord[]>([]);
  const [auditLog, setAuditLog] = useState<AnyRecord[]>([]);
  const [networkId, setNetworkId] = useState("personal");
  const [networkName, setNetworkName] = useState("personal");
  const [activeSystemId, setActiveSystemId] = useState("personal");
  const [activeModal, setActiveModal] = useState<MeshModal>(null);
  const [disconnectTarget, setDisconnectTarget] = useState<{ nodeId: string; name: string; relayURL: string } | null>(null);
  const [notice, setNotice] = useState("");
  const [inviteName, setInviteName] = useState("");
  const [inviteRoles, setInviteRoles] = useState("worker");
  const [inviteCapabilities, setInviteCapabilities] = useState("run_agent,git");
  const [inviteTtlSeconds, setInviteTtlSeconds] = useState("86400");
  const [inviteRelayURL, setInviteRelayURL] = useState(() => (typeof window === "undefined" ? "" : window.location.origin));
  const [inviteNodeId, setInviteNodeId] = useState("");
  const [invitePublicKey, setInvitePublicKey] = useState("");
  const [acceptInviteToken, setAcceptInviteToken] = useState("");
  const [joinInviteToken, setJoinInviteToken] = useState("");
  const [joinNodeName, setJoinNodeName] = useState("");
  const [joinForce, setJoinForce] = useState(false);
  const [detectedRemoteRelayURL, setDetectedRemoteRelayURL] = useState("");
  const [latestInvite, setLatestInvite] = useState<AnyRecord | null>(null);
  const [nodeId, setNodeId] = useState("");
  const [nodeDisplayName, setNodeDisplayName] = useState("");
  const [nodePublicKey, setNodePublicKey] = useState("");
  const [nodeRoles, setNodeRoles] = useState("worker");
  const [nodeCapabilities, setNodeCapabilities] = useState("run_agent,git");
  const [selectedNodeId, setSelectedNodeId] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [busyAction, setBusyAction] = useState("");
  const [error, setError] = useState("");
  const [hoveredGraphNodeId, setHoveredGraphNodeId] = useState("");
  const [remoteProjects, setRemoteProjects] = useState<AnyRecord[]>([]);
  const [remoteAgents, setRemoteAgents] = useState<AnyRecord[]>([]);
  const [remoteSessions, setRemoteSessions] = useState<AnyRecord[]>([]);
  const [remoteSessionDetail, setRemoteSessionDetail] = useState<AnyRecord | null>(null);
  const [remoteInspectNodeId, setRemoteInspectNodeId] = useState("");
  const [remoteProjectId, setRemoteProjectId] = useState("");
  const [remoteAgentId, setRemoteAgentId] = useState("");
  const [remoteSessionId, setRemoteSessionId] = useState("");
  const [remoteMessage, setRemoteMessage] = useState("");

  const onlineNodes = useMemo(() => nodes.filter((node) => text(node.status) === "online"), [nodes]);
  const selectedRegisteredNode = useMemo(
    () => nodes.find((node) => text(node.id) === selectedNodeId) || null,
    [nodes, selectedNodeId]
  );
  const remoteThreadMessages = useMemo(() => sessionMessages(remoteSessionDetail), [remoteSessionDetail]);
  const activeInvites = useMemo(
    () => invites.filter((invite) => text(invite.networkId, networkId) === activeSystemId),
    [activeSystemId, invites, networkId]
  );
  const systems = useMemo(() => {
    const map = new Map<string, { id: string; name: string; inviteCount: number; current: boolean }>();
    map.set(networkId, { id: networkId, name: networkName, inviteCount: 0, current: true });
    for (const invite of invites) {
      const id = text(invite.networkId, networkId);
      const current = map.get(id) || { id, name: id, inviteCount: 0, current: id === networkId };
      current.inviteCount += 1;
      map.set(id, current);
    }
    return Array.from(map.values()).sort((a, b) => Number(b.current) - Number(a.current) || a.id.localeCompare(b.id));
  }, [invites, networkId, networkName]);
  const meshHealth = useMemo(() => {
    if (localNode && text(localNode.relayURL)) {
      const remoteName = text(localNode.networkName, text(localNode.networkId, networkName));
      return { label: "Joined remote mesh", className: "online", detail: `${remoteName} / ${endpointHost(localNode.relayURL)}.` };
    }
    if (nodes.length === 0) {
      return { label: "Setup needed", className: "empty", detail: "Register at least one node public key." };
    }
    if (onlineNodes.length === 0) {
      return { label: "Waiting for nodes", className: "degraded", detail: "Registered nodes exist, but none are connected." };
    }
    return { label: "Online", className: "online", detail: `${onlineNodes.length} connected node${onlineNodes.length === 1 ? "" : "s"}.` };
  }, [localNode, networkName, nodes.length, onlineNodes.length]);
  const graphNodes = useMemo<MeshGraphNode[]>(() => {
    const centerX = 50;
    const centerY = 43;
    const graphSourceNodes = localNode && !nodes.some((node) => text(node.id) === text(localNode.id))
      ? [localNode, ...nodes]
      : nodes;
    const workerNodes = graphSourceNodes.map((node, index) => {
      const total = Math.max(graphSourceNodes.length, 1);
      const angle = -Math.PI / 2 + (index * Math.PI * 2) / total;
      const x = centerX + Math.cos(angle) * 36;
      const y = centerY + Math.sin(angle) * 26;
      const nodeId = text(node.id, `node-${index + 1}`);
      const isLocal = localNode && nodeId === text(localNode.id);
      return {
        id: nodeId,
        name: text(node.name, nodeId),
        endpoint: isLocal ? "This machine" : text(node.endpoint, "No endpoint advertised"),
        ip: isLocal ? "local" : endpointHost(node.endpoint),
        status: isLocal ? "online" : text(node.status, "offline"),
        kind: "worker" as const,
        roles: list(node.roles).join(", ") || "No roles",
        capabilities: list(node.capabilities).join(", ") || "No capabilities",
        lastSeen: isLocal ? "active session" : formatTime(node.lastSeenAt),
        x: Math.max(10, Math.min(90, x)),
        y: Math.max(12, Math.min(74, y))
      };
    });
    const relayURL = text(localNode?.relayURL);
    const relayName = text(localNode?.networkName, networkName || text(localNode?.networkId, networkId));
    const relayOnline = !!relayURL || onlineNodes.length > 0;
    return [
      {
        id: "relay",
        name: relayName || networkId,
        endpoint: relayURL || "Current Sloppy relay",
        ip: relayURL ? endpointHost(relayURL) : "localhost",
        status: relayOnline ? "online" : nodes.length === 0 ? "offline" : "degraded",
        kind: "relay" as const,
        roles: relayURL ? "remote coordinator" : "coordinator",
        capabilities: "invites, registry, dispatch",
        lastSeen: "active session",
        x: centerX,
        y: centerY
      },
      ...workerNodes
    ];
  }, [localNode, networkId, networkName, nodes, onlineNodes.length]);
  const activeGraphNode = graphNodes.find((node) => node.id === hoveredGraphNodeId) || graphNodes[0];

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError("");
    try {
      const state = await coreApi.fetchMeshState();
      if (!state) {
        throw new Error("missing mesh state");
      }
      const nextNodes = records(state.nodes);
      const nextProjects = records(state.sharedProjects);
      const nextTasks = records(state.tasks);
      const nextInvites = records(state.invites);
      const nextAuditLog = records(state.auditLog);
      const nextLocalNode = state.localNode && typeof state.localNode === "object" ? state.localNode as AnyRecord : null;
      const nextNetworkId = text(state.networkId, "personal");
      setNodes(nextNodes);
      setLocalNode(nextLocalNode);
      setProjects(nextProjects);
      setTasks(nextTasks);
      setInvites(nextInvites);
      setAuditLog(nextAuditLog.slice(0, 12));
      setNetworkId(nextNetworkId);
      setNetworkName(text(state.networkName, nextNetworkId));
      setActiveSystemId((current) => current || nextNetworkId);

      const firstNodeId = text(nextLocalNode?.id) || text(nextNodes[0]?.id);
      setSelectedNodeId((current) => {
        const knownNodeIds = [text(nextLocalNode?.id), ...nextNodes.map((node) => text(node.id))].filter(Boolean);
        return current && knownNodeIds.includes(current) ? current : firstNodeId;
      });
    } catch {
      setError("Mesh state could not be loaded.");
    } finally {
      setIsLoading(false);
    }
  }, [coreApi]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function runAction(name: string, action: () => Promise<boolean>) {
    if (busyAction) {
      return;
    }
    setBusyAction(name);
    setError("");
    setNotice("");
    try {
      const ok = await action();
      if (ok) {
        setActiveModal(null);
        await refresh();
      }
    } catch (error) {
      setError(error instanceof Error ? error.message : "Mesh update failed.");
    } finally {
      setBusyAction("");
    }
  }

  async function configureNetwork() {
    const id = networkId.trim();
    if (!id) {
      setError("Network id is required.");
      return;
    }
    await runAction("network", async () => {
      const updated = await coreApi.configureMeshNetwork({ id, name: networkName.trim() || id });
      if (!updated) {
        setError("Network could not be saved.");
        return false;
      }
      setActiveSystemId(id);
      return true;
    });
  }

  async function createInvite() {
    const id = activeSystemId.trim() || networkId.trim() || "personal";
    const relayURL = inviteRelayURL.trim();
    const inviteeNodeId = inviteNodeId.trim();
    const publicKey = invitePublicKey.trim();
    if (!relayURL) {
      setError("Relay URL is required for a bundled invite token.");
      return;
    }
    await runAction("invite", async () => {
      const invite = await coreApi.createMeshInvite({
        networkId: id,
        name: inviteName.trim() || null,
        roles: csv(inviteRoles),
        capabilities: csv(inviteCapabilities),
        ttlSeconds: Number(inviteTtlSeconds) || 86400,
        relayURL,
        nodeId: inviteeNodeId || null,
        publicKey: publicKey || null
      });
      if (!invite) {
        setError("Invite could not be created.");
        return false;
      }
      setLatestInvite(invite);
      setInviteName("");
      setInviteNodeId("");
      setInvitePublicKey("");
      return true;
    });
  }

  async function acceptInvite() {
    const token = acceptInviteToken.trim();
    if (!token) {
      setError("Invite token is required.");
      return;
    }
    if (busyAction) {
      return;
    }
    setBusyAction("accept");
    setError("");
    try {
      const node = await coreApi.acceptMeshInvite({ token });
      if (!node) {
        setError("Invite could not be accepted.");
        return;
      }
      setAcceptInviteToken("");
      setSelectedNodeId(text(node.id));
      setActiveModal(null);
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invite could not be accepted.";
      const relayURL = relayURLFromInviteToken(token);
      if (relayURL && message.includes("not found in this coordinator state")) {
        setDetectedRemoteRelayURL(relayURL);
        setJoinInviteToken(token);
        setActiveModal("join");
        setError("");
      } else {
        setError(message);
      }
    } finally {
      setBusyAction("");
    }
  }

  async function joinRemoteMesh() {
    const token = joinInviteToken.trim();
    if (!token) {
      setError("Invite token is required.");
      return;
    }
    await runAction("join", async () => {
      const result = await coreApi.joinRemoteMesh({
        token,
        name: joinNodeName.trim() || null,
        force: joinForce
      });
      if (!result) {
        setError("Remote mesh could not be joined.");
        return false;
      }
      setJoinInviteToken("");
      setJoinNodeName("");
      setJoinForce(false);
      setDetectedRemoteRelayURL(text(result.relayURL));
      return true;
    });
  }

  async function disconnectManualRelay() {
    if (!disconnectTarget) {
      return;
    }
    await runAction("disconnect-relay", async () => {
      const node = await coreApi.disconnectManualMeshRelay({
        nodeId: disconnectTarget.nodeId,
        relayURL: disconnectTarget.relayURL
      });
      if (!node) {
        throw new Error("Manual relay could not be disconnected.");
      }
      setLocalNode(node);
      setDetectedRemoteRelayURL("");
      setNotice(`Manual relay disconnected for ${disconnectTarget.name}. Node identity and Console binding were preserved.`);
      return true;
    });
  }

  async function revokeInvite(invite: AnyRecord) {
    const token = meshInviteToken(invite);
    if (!token) {
      setError("Invite token is required.");
      return;
    }
    await runAction("revoke-invite", async () => {
      const deleted = await coreApi.deleteMeshInvite(token);
      if (!deleted) {
        setError("Invite could not be revoked.");
        return false;
      }
      setLatestInvite((current) => text(current?.token) === text(invite.token) ? null : current);
      return true;
    });
  }

  async function registerNode() {
    const id = nodeId.trim();
    const publicKey = nodePublicKey.trim();
    if (!id || !publicKey) {
      setError("Node id and public key are required.");
      return;
    }
    await runAction("node", async () => {
      const node = await coreApi.registerMeshNode({
        id,
        name: nodeDisplayName.trim() || id,
        publicKey,
        roles: csv(nodeRoles),
        capabilities: csv(nodeCapabilities)
      });
      if (!node) {
        setError("Node could not be registered.");
        return false;
      }
      setNodeId("");
      setNodeDisplayName("");
      setNodePublicKey("");
      return true;
    });
  }

  async function deleteSelectedNode() {
    const id = text(selectedRegisteredNode?.id);
    if (!id) {
      setError("Select a registered node to remove.");
      return;
    }
    await runAction("delete-node", async () => {
      const deleted = await coreApi.deleteMeshNode(id);
      if (!deleted) {
        setError("Node could not be removed.");
        return false;
      }
      setSelectedNodeId("");
      return true;
    });
  }

  function decodeProxyJSON(payload: AnyRecord | null) {
    const body = text(payload?.bodyBase64);
    if (!body) {
      return null;
    }
    return JSON.parse(base64ToUTF8(body));
  }

  async function proxyNodeJSON(nodeId: string, method: string, path: string, body?: AnyRecord) {
    const payload: AnyRecord = { method, path };
    if (body) {
      payload.headers = { "content-type": "application/json" };
      payload.bodyBase64 = utf8ToBase64(JSON.stringify(body));
    }
    return decodeProxyJSON(await coreApi.proxyMeshCoreRequest(nodeId, payload));
  }

  function resetRemoteWorkspace(nodeId = "") {
    setRemoteInspectNodeId(nodeId);
    setRemoteProjects([]);
    setRemoteAgents([]);
    setRemoteSessions([]);
    setRemoteSessionDetail(null);
    setRemoteProjectId("");
    setRemoteAgentId("");
    setRemoteSessionId("");
    setRemoteMessage("");
  }

  async function inspectNode(nodeId: string, options: { preserveWorkspace?: boolean } = {}) {
    const id = nodeId.trim();
    if (!id) {
      return;
    }
    setBusyAction("inspect-node");
    setError("");
    try {
      const [projects, agents] = await Promise.all([
        proxyNodeJSON(id, "GET", "/v1/projects"),
        proxyNodeJSON(id, "GET", "/v1/agents?includeSystem=false")
      ]);
      const nextProjects = Array.isArray(projects) ? projects : [];
      const nextAgents = Array.isArray(agents) ? agents : [];
      if (!options.preserveWorkspace) {
        resetRemoteWorkspace(id);
      } else {
        setRemoteInspectNodeId(id);
      }
      setRemoteProjects(nextProjects);
      setRemoteAgents(nextAgents);
      if (options.preserveWorkspace && remoteAgentId) {
        const nextProjectStillExists = !remoteProjectId || nextProjects.some((project) => text(project.id) === remoteProjectId);
        const nextAgentStillExists = nextAgents.some((agent) => text(agent.id) === remoteAgentId);
        if (!nextProjectStillExists) {
          setRemoteProjectId("");
        }
        if (!nextAgentStillExists) {
          setRemoteAgentId("");
          setRemoteSessions([]);
          setRemoteSessionId("");
          setRemoteSessionDetail(null);
        }
      }
    } catch (error) {
      setError(error instanceof Error ? error.message : "Mesh node could not be inspected.");
      resetRemoteWorkspace("");
    } finally {
      setBusyAction("");
    }
  }

  async function inspectSelectedNode() {
    await inspectNode(selectedNodeId);
  }

  async function selectRemoteProject(projectId: string) {
    setRemoteProjectId(projectId);
    setRemoteSessions([]);
    setRemoteSessionDetail(null);
    setRemoteSessionId("");
    if (remoteAgentId) {
      await loadRemoteSessions(remoteAgentId, projectId);
    }
  }

  async function loadRemoteSessions(agentId: string, projectId: string) {
    const nodeId = remoteInspectNodeId;
    if (!nodeId || !agentId) {
      return;
    }
    setRemoteSessionId("");
    setRemoteSessionDetail(null);
    setBusyAction("remote-agent");
    setError("");
    try {
      const params = new URLSearchParams();
      if (projectId) {
        params.set("projectId", projectId);
      }
      params.set("limit", "12");
      const sessions = await proxyNodeJSON(nodeId, "GET", `/v1/agents/${encodeURIComponent(agentId)}/sessions?${params.toString()}`);
      setRemoteSessions(Array.isArray(sessions) ? sessions : []);
    } catch (error) {
      setError(error instanceof Error ? error.message : "Remote agent sessions could not be loaded.");
      setRemoteSessions([]);
    } finally {
      setBusyAction("");
    }
  }

  async function selectRemoteAgent(agentId: string) {
    setRemoteAgentId(agentId);
    await loadRemoteSessions(agentId, remoteProjectId);
  }

  async function openRemoteSession(sessionId: string) {
    const nodeId = remoteInspectNodeId;
    if (!nodeId || !remoteAgentId || !sessionId) {
      return;
    }
    setBusyAction("remote-session");
    setError("");
    try {
      const detail = await proxyNodeJSON(
        nodeId,
        "GET",
        `/v1/agents/${encodeURIComponent(remoteAgentId)}/sessions/${encodeURIComponent(sessionId)}`
      );
      setRemoteSessionId(sessionId);
      setRemoteSessionDetail(detail && typeof detail === "object" ? detail : null);
    } catch (error) {
      setError(error instanceof Error ? error.message : "Remote session could not be opened.");
      setRemoteSessionDetail(null);
    } finally {
      setBusyAction("");
    }
  }

  async function createRemoteSession() {
    const nodeId = remoteInspectNodeId;
    if (!nodeId || !remoteAgentId) {
      return;
    }
    setBusyAction("remote-create-session");
    setError("");
    try {
      const project = remoteProjects.find((item) => text(item.id) === remoteProjectId);
      const session = await proxyNodeJSON(
        nodeId,
        "POST",
        `/v1/agents/${encodeURIComponent(remoteAgentId)}/sessions`,
        {
          title: `Mesh / ${text(project?.name, remoteProjectId || "Chat")}`,
          projectId: remoteProjectId || undefined,
        }
      );
      const sessionId = text((session as AnyRecord | null)?.id);
      if (!sessionId) {
        setError("Remote session was not created.");
        return;
      }
      setRemoteSessions((items) => [session as AnyRecord, ...items.filter((item) => text(item.id) !== sessionId)]);
      await openRemoteSession(sessionId);
    } catch (error) {
      setError(error instanceof Error ? error.message : "Remote session could not be created.");
    } finally {
      setBusyAction("");
    }
  }

  async function sendRemoteMessage() {
    const nodeId = remoteInspectNodeId;
    const message = remoteMessage.trim();
    if (!nodeId || !remoteAgentId || !remoteSessionId || !message) {
      return;
    }
    setBusyAction("remote-send");
    setError("");
    try {
      await proxyNodeJSON(
        nodeId,
        "POST",
        `/v1/agents/${encodeURIComponent(remoteAgentId)}/sessions/${encodeURIComponent(remoteSessionId)}/messages`,
        { userId: "dashboard", content: message, mode: "auto" }
      );
      setRemoteMessage("");
      await openRemoteSession(remoteSessionId);
    } catch (error) {
      setError(error instanceof Error ? error.message : "Remote message could not be sent.");
    } finally {
      setBusyAction("");
    }
  }

  useEffect(() => {
    const nodeId = remoteInspectNodeId;
    const agentId = remoteAgentId;
    const sessionId = remoteSessionId;
    if (!nodeId || !agentId || !sessionId) {
      return;
    }
    let cancelled = false;

    async function refreshSession() {
      try {
        const detail = await proxyNodeJSON(
          nodeId,
          "GET",
          `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`
        );
        if (!cancelled) {
          setRemoteSessionDetail(detail && typeof detail === "object" ? detail : null);
        }
      } catch {
        // Keep existing transcript; explicit open/send paths surface errors.
      }
    }

    const interval = window.setInterval(() => {
      void refreshSession();
    }, 1500);
    void refreshSession();
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [remoteInspectNodeId, remoteAgentId, remoteSessionId]);

  function renderModal() {
    if (!activeModal) {
      return null;
    }

    if (activeModal === "network") {
      return (
        <MeshModalFrame title="Mesh System" description="Name the coordinator state that this running Sloppy instance owns." icon="hub" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <section className="nodes-graph-section" aria-label="Mesh node graph">
              <div className="nodes-graph-head">
                <div>
                  <h4>Node graph</h4>
                  <p>Hover or focus a node to inspect its name, IP, endpoint, and capabilities.</p>
                </div>
                <span className={`nodes-health-pill ${meshHealth.className}`}>{meshHealth.label}</span>
              </div>
              <div className="nodes-graph" role="group" aria-label={`${graphNodes.length - 1} visible mesh node${graphNodes.length === 2 ? "" : "s"}`}>
                <div className="nodes-graph-canvas">
                  <svg className="nodes-graph-lines" viewBox="0 0 100 100" aria-hidden="true">
                    {graphNodes.filter((node) => node.kind === "worker").map((node) => (
                      <line key={node.id} x1="50" y1="43" x2={node.x} y2={node.y} />
                    ))}
                  </svg>
                  {graphNodes.map((node) => (
                    <button
                      key={node.id}
                      type="button"
                      className={`nodes-graph-node ${node.kind} ${statusClass(node.status)}`}
                      style={{ left: `${node.x}%`, top: `${node.y}%` }}
                      onMouseEnter={() => setHoveredGraphNodeId(node.id)}
                      onMouseLeave={() => setHoveredGraphNodeId("")}
                      onFocus={() => setHoveredGraphNodeId(node.id)}
                      onBlur={() => setHoveredGraphNodeId("")}
                      aria-label={`${node.name}, ${node.ip}, ${statusLabel(node.status)}`}
                    >
                      <span className="material-symbols-rounded" aria-hidden="true">{node.kind === "relay" ? "hub" : "dns"}</span>
                    </button>
                  ))}
                  {nodes.length === 0 && !localNode ? (
                    <div className="nodes-graph-empty">
                      <span className="material-symbols-rounded" aria-hidden="true">add_link</span>
                      <strong>No registered workers</strong>
                      <small>Create an invite or register a public key to grow this mesh.</small>
                    </div>
                  ) : null}
                </div>
                <div className="nodes-graph-tooltip" aria-live="polite">
                  <span>{activeGraphNode.kind === "relay" ? "Coordinator" : "Worker node"}</span>
                  <strong>{activeGraphNode.name}</strong>
                  <dl>
                    <div>
                      <dt>IP</dt>
                      <dd>{activeGraphNode.ip}</dd>
                    </div>
                    <div>
                      <dt>Endpoint</dt>
                      <dd>{activeGraphNode.endpoint}</dd>
                    </div>
                    <div>
                      <dt>Status</dt>
                      <dd>{statusLabel(activeGraphNode.status)}</dd>
                    </div>
                    <div>
                      <dt>Roles</dt>
                      <dd>{activeGraphNode.roles}</dd>
                    </div>
                    <div>
                      <dt>Capabilities</dt>
                      <dd>{activeGraphNode.capabilities}</dd>
                    </div>
                    <div>
                      <dt>Last seen</dt>
                      <dd>{activeGraphNode.lastSeen}</dd>
                    </div>
                  </dl>
                </div>
              </div>
            </section>
            <Field label="System id" hint="Stable id used by invites and local registry state.">
              <input id="mesh-network-id" type="text" value={networkId} onChange={(event) => setNetworkId(event.target.value)} />
            </Field>
            <Field label="Display name">
              <input id="mesh-network-name" type="text" value={networkName} onChange={(event) => setNetworkName(event.target.value)} />
            </Field>
          </div>
          <div className="nodes-modal-actions">
            <button type="button" onClick={() => setActiveModal(null)}>Cancel</button>
            <button type="button" className="nodes-primary-button" disabled={!networkId.trim() || !!busyAction} onClick={() => void configureNetwork()}>
              {busyAction === "network" ? "Saving" : "Save system"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    if (activeModal === "invite") {
      return (
        <MeshModalFrame title="Invite Node" description="Create one bundled token with relay URL, invite secret, and worker public key." icon="key" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <div className="nodes-selected-system">
              <span>System</span>
              <strong>{activeSystemId}</strong>
            </div>
            <Field label="Expected node name" hint="Optional, shown to you when the token is created.">
              <input type="text" value={inviteName} onChange={(event) => setInviteName(event.target.value)} />
            </Field>
            <Field label="Relay URL" hint="Included in the bundled token so the worker does not need a separate --relay value.">
              <input type="url" value={inviteRelayURL} onChange={(event) => setInviteRelayURL(event.target.value)} />
            </Field>
            <Field label="Worker node id" hint="Optional. Use only when binding the invite to a known node identity.">
              <input type="text" value={inviteNodeId} onChange={(event) => setInviteNodeId(event.target.value)} />
            </Field>
            <Field label="Worker public key" hint="Optional. Leave empty for a generic invite accepted by the joining machine.">
              <textarea value={invitePublicKey} onChange={(event) => setInvitePublicKey(event.target.value)} rows={4} />
            </Field>
            <ChipPicker
              label="Roles"
              value={inviteRoles}
              options={ROLE_OPTIONS}
              onChange={setInviteRoles}
            />
            <ChipPicker
              label="Capabilities"
              value={inviteCapabilities}
              options={CAPABILITY_OPTIONS}
              onChange={setInviteCapabilities}
            />
            <Field label="TTL seconds">
              <input type="number" min="1" value={inviteTtlSeconds} onChange={(event) => setInviteTtlSeconds(event.target.value)} />
            </Field>
          </div>
          <div className="nodes-modal-actions">
            <button type="button" onClick={() => setActiveModal(null)}>Cancel</button>
            <button type="button" className="nodes-primary-button" disabled={!activeSystemId.trim() || !inviteRelayURL.trim() || !!busyAction} onClick={() => void createInvite()}>
              {busyAction === "invite" ? "Creating" : "Create invite"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    if (activeModal === "accept") {
      return (
        <MeshModalFrame title="Accept Invite Here" description="Coordinator operation: consume an invite that belongs to this local mesh state." icon="move_to_inbox" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <Field label="Invite token" hint="Accepts slp_mesh bundled tokens. Legacy slp_invite tokens still work when the invite exists in this coordinator state.">
              <textarea value={acceptInviteToken} onChange={(event) => setAcceptInviteToken(event.target.value)} rows={6} />
            </Field>
          </div>
          <div className="nodes-modal-actions">
            <button type="button" onClick={() => setActiveModal(null)}>Cancel</button>
            <button type="button" className="nodes-primary-button" disabled={!acceptInviteToken.trim() || !!busyAction} onClick={() => void acceptInvite()}>
              {busyAction === "accept" ? "Accepting" : "Accept invite"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    if (activeModal === "join") {
      const relayURL = relayURLFromInviteToken(joinInviteToken) || detectedRemoteRelayURL;
      return (
        <MeshModalFrame title="Join Remote Mesh" description="Connect this local Sloppy node to the relay embedded in a mesh invite." icon="hub" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <Field label="Invite token" hint="Paste the bundled slp_mesh token from the coordinator. The dashboard API base stays local.">
              <textarea value={joinInviteToken} onChange={(event) => setJoinInviteToken(event.target.value)} rows={6} />
            </Field>
            {relayURL ? (
              <div className="nodes-join-relay">
                <span>Remote relay</span>
                <code>{relayURL}</code>
              </div>
            ) : null}
            <Field label="Local node name" hint="Used only if this machine does not already have a node identity.">
              <input type="text" value={joinNodeName} onChange={(event) => setJoinNodeName(event.target.value)} />
            </Field>
            <label className="nodes-checkbox-row">
              <input type="checkbox" checked={joinForce} onChange={(event) => setJoinForce(event.target.checked)} />
              <span>Replace existing local node identity</span>
            </label>
          </div>
          <div className="nodes-modal-actions">
            <button type="button" onClick={() => setActiveModal(null)}>Cancel</button>
            <button type="button" className="nodes-primary-button" disabled={!joinInviteToken.trim() || !!busyAction} onClick={() => void joinRemoteMesh()}>
              {busyAction === "join" ? "Joining" : "Join mesh"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    if (activeModal === "disconnect" && disconnectTarget) {
      return (
        <MeshModalFrame title="Disconnect manual relay" description="Stop this computer’s manual relay connection without restarting Core." icon="link_off" className="nodes-disconnect-modal" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <div className="nodes-disconnect-target">
              <span>Computer</span>
              <strong>{disconnectTarget.name}</strong>
              <code>{disconnectTarget.nodeId}</code>
              <span>Manual relay / coordinator registry</span>
              <code>{disconnectTarget.relayURL}</code>
            </div>
            <p>Node identity and Console binding are preserved. The node’s registration stays in the coordinator registry.</p>
            {error ? <p role="alert">{error}</p> : null}
          </div>
          <div className="nodes-modal-actions">
            <button type="button" disabled={!!busyAction} onClick={() => setActiveModal(null)}>Keep connected</button>
            <button type="button" className="nodes-manual-relay-button" disabled={!!busyAction} onClick={() => void disconnectManualRelay()}>
              {busyAction === "disconnect-relay" ? "Disconnecting…" : "Disconnect relay"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    if (activeModal === "node") {
      return (
        <MeshModalFrame title="Register Node" description="Allow a worker identity to authenticate with this relay by adding its public key." icon="add_link" onClose={() => setActiveModal(null)}>
          <div className="nodes-modal-body">
            <Field label="Node id">
              <input type="text" value={nodeId} onChange={(event) => setNodeId(event.target.value)} />
            </Field>
            <Field label="Display name">
              <input type="text" value={nodeDisplayName} onChange={(event) => setNodeDisplayName(event.target.value)} />
            </Field>
            <Field label="Public key" hint="Paste the ed25519 public key from the worker identity.">
              <textarea value={nodePublicKey} onChange={(event) => setNodePublicKey(event.target.value)} rows={4} />
            </Field>
            <ChipPicker
              label="Roles"
              value={nodeRoles}
              options={ROLE_OPTIONS}
              onChange={setNodeRoles}
            />
            <ChipPicker
              label="Capabilities"
              value={nodeCapabilities}
              options={CAPABILITY_OPTIONS}
              onChange={setNodeCapabilities}
            />
          </div>
          <div className="nodes-modal-actions">
            <button type="button" onClick={() => setActiveModal(null)}>Cancel</button>
            <button type="button" className="nodes-primary-button" disabled={!nodeId.trim() || !nodePublicKey.trim() || !!busyAction} onClick={() => void registerNode()}>
              {busyAction === "node" ? "Registering" : "Register node"}
            </button>
          </div>
        </MeshModalFrame>
      );
    }

    return null;
  }

  return (
    <main className="nodes-shell">
      <header className="nodes-hero">
        <div>
          <span className={`nodes-health-pill ${meshHealth.className}`}>{meshHealth.label}</span>
          <h1>Node Mesh</h1>
          <p>Coordinate remote worker nodes, shared repositories, invites, and task dispatch from this running Sloppy relay.</p>
        </div>
        <div className="nodes-hero-actions">
          <button type="button" className="nodes-secondary-button" onClick={() => setActiveModal("network")}>
            <span className="material-symbols-rounded" aria-hidden="true">hub</span>
            System
          </button>
          <button type="button" className="nodes-primary-button" onClick={() => setActiveModal("invite")}>
            <span className="material-symbols-rounded" aria-hidden="true">key</span>
            Invite Node
          </button>
          <button type="button" className="nodes-secondary-button" onClick={() => setActiveModal("accept")}>
            <span className="material-symbols-rounded" aria-hidden="true">move_to_inbox</span>
            Accept Invite Here
          </button>
          <button type="button" className="nodes-secondary-button" onClick={() => setActiveModal("join")}>
            <span className="material-symbols-rounded" aria-hidden="true">hub</span>
            Join Remote Mesh
          </button>
          <button type="button" className="nodes-icon-button" onClick={() => void refresh()} disabled={isLoading} title="Refresh">
            <span className="material-symbols-rounded" aria-hidden="true">refresh</span>
          </button>
        </div>
      </header>

      {error ? <div className="nodes-error">{error}</div> : null}
      {notice ? <div className="nodes-relay-notice" role="status">{notice}</div> : null}

      <section className="nodes-status-strip" aria-label="Mesh system status">
        <article>
          <span>Active system</span>
          <strong>{networkName}</strong>
          <small>{networkId}</small>
        </article>
        <article>
          <span>Relay state</span>
          <strong>{meshHealth.label}</strong>
          <small>{meshHealth.detail}</small>
        </article>
        <article>
          <span>Local node</span>
          <strong>{localNode ? text(localNode.name, text(localNode.id)) : "Not joined"}</strong>
          <small>{localNode ? text(localNode.relayURL, "No relay configured") : "Use Join Remote Mesh"}</small>
          {localNode && text(localNode.relayURL) ? (
            <button type="button" className="nodes-manual-relay-button" disabled={!!busyAction} onClick={() => {
              setDisconnectTarget({ nodeId: text(localNode.id), name: text(localNode.name, text(localNode.id)), relayURL: text(localNode.relayURL) });
              setActiveModal("disconnect");
            }}>Disconnect relay</button>
          ) : null}
        </article>
        <article>
          <span>Capacity</span>
          <strong>{onlineNodes.length}/{nodes.length} online</strong>
          <small>{projects.length} projects, {tasks.length} tasks</small>
        </article>
        <article>
          <span>Invites</span>
          <strong>{invites.length}</strong>
          <small>{activeInvites.length} for selected system</small>
        </article>
      </section>

      <section className="nodes-layout">
        <aside className="nodes-systems">
          <div className="nodes-section-head">
            <div>
              <h2>Mesh Systems</h2>
              <p>View current coordinator state and other systems seen in invite history.</p>
            </div>
          </div>
          <div className="nodes-system-list">
            {systems.map((system) => (
              <button
                key={system.id}
                type="button"
                className={activeSystemId === system.id ? "active" : ""}
                onClick={() => setActiveSystemId(system.id)}
              >
                <span className="material-symbols-rounded" aria-hidden="true">{system.current ? "radio_button_checked" : "radio_button_unchecked"}</span>
                <span>
                  <strong>{system.name}</strong>
                  <small>{system.id} / {system.inviteCount} invites</small>
                </span>
              </button>
            ))}
          </div>
          <div className="nodes-guidance">
            <strong>{activeSystemId === networkId ? "Current system" : "Historical system"}</strong>
            <span>{activeSystemId === networkId ? "Actions write into this coordinator state." : "This system is visible from invite history; switch the active system to manage it."}</span>
          </div>
        </aside>

        <div className="nodes-main">
          {latestInvite ? (
            <section className="nodes-token-banner">
              <div>
                <span>Latest invite token</span>
                <strong>{meshInviteToken(latestInvite)}</strong>
                <small>{text(latestInvite.name, "node")} / expires {formatTime(latestInvite.expiresAt)}</small>
              </div>
              <button type="button" className="nodes-secondary-button" onClick={() => setActiveModal("invite")}>Create another</button>
            </section>
          ) : null}

          <section className="nodes-grid">
            <div className="nodes-panel nodes-panel-wide">
              <div className="nodes-panel-head">
                <div>
                  <h2>Nodes</h2>
                  <p>Registered identities and live relay presence.</p>
                </div>
                <div className="nodes-panel-actions">
                  <button
                    type="button"
                    className="nodes-secondary-button"
                    disabled={!selectedRegisteredNode || !!busyAction}
                    onClick={() => void deleteSelectedNode()}
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">delete</span>
                    Remove
                  </button>
                  <button
                    type="button"
                    className="nodes-secondary-button"
                    disabled={!selectedNodeId || !!busyAction}
                    onClick={() => void inspectSelectedNode()}
                  >
                    <span className="material-symbols-rounded" aria-hidden="true">lan</span>
                    Inspect
                  </button>
                  <button type="button" className="nodes-secondary-button" onClick={() => setActiveModal("node")}>
                    <span className="material-symbols-rounded" aria-hidden="true">add</span>
                    Register
                  </button>
                </div>
              </div>
              <div className="nodes-list">
                {localNode ? (
                  <button
                    type="button"
                    className={`nodes-row ${selectedNodeId === text(localNode.id) ? "selected" : ""}`}
                    onClick={() => setSelectedNodeId(text(localNode.id))}
                  >
                    <span className="nodes-status-dot online" />
                    <span>
                      <strong>{text(localNode.name, text(localNode.id))}</strong>
                      <small>{list(localNode.roles).join(", ") || "node"} / {list(localNode.capabilities).join(", ") || "no capabilities"}</small>
                      <small>{text(localNode.relayURL, "No relay configured")}</small>
                    </span>
                    <em>This machine</em>
                  </button>
                ) : null}
                {nodes.length === 0 ? <p className="nodes-empty">{localNode ? "No remote registry nodes cached locally." : "No mesh nodes registered."}</p> : nodes.map((node) => (
                  <button
                    key={text(node.id)}
                    type="button"
                    className={`nodes-row ${selectedNodeId === text(node.id) ? "selected" : ""}`}
                    onClick={() => setSelectedNodeId(text(node.id))}
                  >
                    <span className={`nodes-status-dot ${statusLabel(node.status)}`} />
                    <span>
                      <strong>{text(node.name, text(node.id))}</strong>
                      <small>{list(node.roles).join(", ") || "node"} / {list(node.capabilities).join(", ") || "no capabilities"}</small>
                    </span>
                    <em>{statusLabel(node.status)}</em>
                  </button>
                ))}
              </div>
              {remoteInspectNodeId ? (
                <div className="nodes-remote-inspector">
                  <div className="nodes-remote-head">
                    <div>
                      <h3>Mesh Remote</h3>
                      <p>{nodeName([...nodes, localNode || {}], remoteInspectNodeId)}</p>
                    </div>
                    <button
                      type="button"
                      className="nodes-secondary-button"
                      disabled={busyAction === "inspect-node"}
                      onClick={() => void inspectNode(remoteInspectNodeId, { preserveWorkspace: true })}
                    >
                      <span className="material-symbols-rounded" aria-hidden="true">refresh</span>
                      Refresh
                    </button>
                  </div>
                  <div className="nodes-remote-columns">
                    <section>
                      <h4>Projects</h4>
                      <div className="nodes-remote-list">
                        {remoteProjects.length === 0 ? <p className="nodes-empty">No projects returned.</p> : remoteProjects.map((project) => {
                          const id = text(project.id);
                          return (
                            <button
                              key={id}
                              type="button"
                              className={remoteProjectId === id ? "active" : ""}
                              onClick={() => void selectRemoteProject(id)}
                            >
                              <strong>{text(project.name, id)}</strong>
                              <small>{id}</small>
                            </button>
                          );
                        })}
                      </div>
                    </section>
                    <section>
                      <h4>Agents</h4>
                      <div className="nodes-remote-list">
                        {remoteAgents.length === 0 ? <p className="nodes-empty">No agents returned.</p> : remoteAgents.map((agent) => {
                          const id = text(agent.id);
                          return (
                            <button
                              key={id}
                              type="button"
                              className={remoteAgentId === id ? "active" : ""}
                              onClick={() => void selectRemoteAgent(id)}
                            >
                              <strong>{text(agent.displayName, id)}</strong>
                              <small>{text(agent.role, "agent")}</small>
                            </button>
                          );
                        })}
                      </div>
                    </section>
                  </div>
                  <div className="nodes-remote-chat">
                    <section className="nodes-remote-sessions">
                      <div className="nodes-remote-section-head">
                        <h4>Sessions</h4>
                        <button
                          type="button"
                          className="nodes-secondary-button"
                          disabled={!remoteAgentId || !!busyAction}
                          onClick={() => void createRemoteSession()}
                        >
                          <span className="material-symbols-rounded" aria-hidden="true">add</span>
                          New
                        </button>
                      </div>
                      <div className="nodes-remote-list">
                        {remoteSessions.length === 0 ? <p className="nodes-empty">Choose agent or create session.</p> : remoteSessions.map((session) => {
                          const id = text(session.id);
                          return (
                            <button
                              key={id}
                              type="button"
                              className={remoteSessionId === id ? "active" : ""}
                              onClick={() => void openRemoteSession(id)}
                            >
                              <strong>{text(session.title, id)}</strong>
                              <small>{formatTime(session.updatedAt || session.createdAt)}</small>
                            </button>
                          );
                        })}
                      </div>
                    </section>
                    <section className="nodes-remote-thread">
                      <h4>Chat</h4>
                      <div className="nodes-remote-messages">
                        {remoteThreadMessages.length === 0 ? (
                          <p className="nodes-empty">{remoteSessionId ? "No messages yet." : "Open or create session."}</p>
                        ) : remoteThreadMessages.map((message) => (
                          <article key={message.id} className={`nodes-remote-message ${message.role}`}>
                            <span>{message.role}</span>
                            <p>{message.content}</p>
                          </article>
                        ))}
                      </div>
                      <div className="nodes-remote-compose">
                        <textarea
                          value={remoteMessage}
                          onChange={(event) => setRemoteMessage(event.target.value)}
                          placeholder="Message selected mesh node..."
                          disabled={!remoteSessionId || busyAction === "remote-send"}
                        />
                        <button
                          type="button"
                          className="nodes-primary-button"
                          disabled={!remoteSessionId || !remoteMessage.trim() || busyAction === "remote-send"}
                          onClick={() => void sendRemoteMessage()}
                        >
                          <span className="material-symbols-rounded" aria-hidden="true">send</span>
                          Send
                        </button>
                      </div>
                    </section>
                  </div>
                </div>
              ) : null}
            </div>

            <div className="nodes-panel">
              <div className="nodes-panel-head">
                <div>
                  <h2>Invites</h2>
                  <p>Tokens issued for the selected system.</p>
                </div>
                <span>{activeInvites.length}</span>
              </div>
              <div className="nodes-list">
                {activeInvites.length === 0 ? <p className="nodes-empty">No invites for this system.</p> : activeInvites.map((invite) => (
                  <article key={text(invite.token)} className="nodes-invite-row">
                    <div className="nodes-invite-main">
                      <strong>{text(invite.name, "unnamed node")}</strong>
                      <small>{list(invite.roles).join(", ") || "worker"} / {list(invite.capabilities).join(", ") || "no capabilities"}</small>
                      <code>{meshInviteToken(invite)}</code>
                    </div>
                    <button
                      type="button"
                      className="nodes-secondary-button nodes-inline-action"
                      disabled={!!busyAction}
                      onClick={() => void revokeInvite(invite)}
                    >
                      {busyAction === "revoke-invite" ? "Revoking" : "Revoke"}
                    </button>
                  </article>
                ))}
              </div>
            </div>

            <div className="nodes-panel nodes-panel-wide">
              <div className="nodes-panel-head">
                <div>
                  <h2>Remote Lifecycle</h2>
                  <p>Task state reported by workers.</p>
                </div>
                <span>{tasks.length}</span>
              </div>
              <div className="nodes-task-list">
                {tasks.length === 0 ? <p className="nodes-empty">No remote tasks dispatched.</p> : tasks.map((task) => (
                  <article key={text(task.id)} className="nodes-task">
                    <div className="nodes-task-main">
                      <strong>{text(task.title, text(task.id))}</strong>
                      <small>{text(task.projectId)} / {nodeName(nodes, text(task.assignedNodeId))}</small>
                    </div>
                    <span className={`nodes-task-status ${statusLabel(task.status)}`}>{statusLabel(task.status)}</span>
                    <div className="nodes-task-review">
                      <span>{text(task.branch, "no branch")}</span>
                      <span>{text(task.commit, "no commit")}</span>
                      <span>{text(task.summary, "no summary")}</span>
                    </div>
                  </article>
                ))}
              </div>
            </div>

            <div className="nodes-panel">
              <div className="nodes-panel-head">
                <div>
                  <h2>Audit</h2>
                  <p>Recent coordinator state changes.</p>
                </div>
                <span>{auditLog.length}</span>
              </div>
              <div className="nodes-audit-list">
                {auditLog.length === 0 ? <p className="nodes-empty">No audit events.</p> : auditLog.map((entry) => (
                  <div key={text(entry.id, `${text(entry.action)}-${text(entry.time)}`)} className="nodes-audit-row">
                    <strong>{text(entry.action)}</strong>
                    <small>{text(entry.actor)} / {formatTime(entry.time)}</small>
                  </div>
                ))}
              </div>
            </div>
          </section>
        </div>
      </section>

      {renderModal()}
    </main>
  );
}
