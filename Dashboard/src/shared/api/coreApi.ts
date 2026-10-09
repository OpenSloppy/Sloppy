import type { UsageBreakdown, UsageQuery } from "../../features/usage/usageModel";
import { sessionReferencesInText } from "../sessionReferences";
import { buildApiURL, buildWebSocketURL, formatHttpError, requestBlob, requestJson } from "./httpClient";
export { fetchProactiveInbox, updateProactiveFinding, fetchProactiveReviewProviders, fetchAllProactiveFindings } from "./proactivity";
import { type MemoryImportAttachment } from "../../features/agents/memoryImport";
import {
  clearDashboardAuthToken,
  captureDashboardAuth,
  type DashboardAuthSnapshot,
  getDashboardAuthToken,
  invalidateDashboardAuthToken,
  isDashboardAuthTokenPersisted,
  setDashboardAuthToken
} from "./dashboardAuth";

type AnyRecord = Record<string, unknown>;

export interface DevicePairingRecord {
  id: string;
  token: string;
  clientName: string;
  createdAt: string;
  expiresAt: string;
  user: { id: string; login: string; name: string };
  setupCode?: string;
  serverURL?: string;
}

export type ClientConnection =
  | { mode: "token" }
  | { mode: "login_password"; pairing: DevicePairingRecord };

export async function prepareClientConnection(signal?: AbortSignal): Promise<ClientConnection> {
  const challenge = await requestJson<{ mode: string }>({ path: "/v1/auth/challenge", signal });
  signal?.throwIfAborted();
  if (!challenge.ok || !challenge.data) {
    throw new Error(formatHttpError(challenge.status, challenge.data));
  }
  if (challenge.data.mode === "token") {
    return { mode: "token" };
  }
  if (challenge.data.mode !== "login_password") {
    throw new Error("The server returned an unsupported authentication mode. Retry after checking the server configuration.");
  }
  const response = await requestJson<DevicePairingRecord>({
    path: "/v1/auth/device-pairing",
    method: "POST",
    body: { clientName: "Sloppy Client", ttlSeconds: 120 },
    signal
  });
  signal?.throwIfAborted();
  if (!response.ok || !response.data) {
    throw new Error(formatHttpError(response.status, response.data));
  }
  return { mode: "login_password", pairing: response.data };
}

export interface TLSCertificateFingerprintResponse {
  url: string;
  algorithm: "sha256";
  fingerprint: string;
}

export async function detectClientTLSFingerprint(): Promise<TLSCertificateFingerprintResponse> {
  const response = await requestJson<TLSCertificateFingerprintResponse>({
    path: "/v1/auth/device-pairing/tls-fingerprint",
    method: "POST",
    body: {}
  });
  if (!response.ok || !response.data) {
    throw new Error(formatHttpError(response.status, response.data));
  }
  return response.data;
}

export interface MemoryBrowserItem {
  id: string;
  note: string;
  summary?: string;
  kind: string;
  scope: { type: string; id: string };
  source?: { type: string; id?: string };
}
export interface MemoryBrowserResponse {
  items: MemoryBrowserItem[];
  total: number;
  limit: number;
  offset: number;
}

interface RequestOptions {
  signal?: AbortSignal;
}

interface ChannelEventsQuery {
  limit?: number;
  cursor?: string;
  before?: string;
  after?: string;
}

interface ChannelSessionsQuery {
  status?: string;
  agentId?: string;
  recentMessagesLimit?: number;
  limit?: number;
  offset?: number;
}

interface AgentMemoryQuery {
  search?: string;
  filter?: string;
  limit?: number;
  offset?: number;
}

interface AgentSessionStreamHandlers {
  onUpdate?: (update: AnyRecord) => void;
  onOpen?: () => void;
  onError?: () => void;
}

interface ProjectChangeStreamHandlers {
  onBatch?: (batch: AnyRecord) => void;
  onOpen?: () => void;
  onError?: () => void;
}

interface DashboardTerminalHandlers {
  onMessage?: (payload: AnyRecord) => void;
  onOpen?: () => void;
  onClose?: (details?: { code: number; reason: string; wasClean: boolean }) => void;
  onError?: () => void;
}

export interface DashboardTerminalConnection {
  send: (payload: AnyRecord) => boolean;
  close: () => void;
}

export interface CoreApi {
  fetchAllAgentSessions: (options?: { query?: string; includeWorkers?: boolean; limit?: number }) => Promise<AnyRecord[] | null>;
  fetchMemories: (query?: AgentMemoryQuery & { scope?: "all" | "global" }) => Promise<MemoryBrowserResponse | null>;
  fetchHealth: () => Promise<AnyRecord | null>;
  sendChannelMessage: (channelId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchChannelState: (channelId: string) => Promise<AnyRecord | null>;
  fetchChannelEvents: (channelId: string, query?: ChannelEventsQuery) => Promise<AnyRecord | null>;
  fetchChannelSessions: (query?: ChannelSessionsQuery) => Promise<AnyRecord[] | null>;
  fetchChannelSession: (sessionId: string) => Promise<AnyRecord | null>;
  answerChannelInputRequest: (sessionId: string, requestId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteChannelSession: (sessionId: string) => Promise<boolean>;
  postChannelControl: (channelId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchBulletins: () => Promise<AnyRecord[]>;
  fetchChannelSlashCommands: () => Promise<{
    commands: Array<{ name: string; description: string; argument?: string | null }>;
  } | null>;
  fetchAgentChatSlashCommands: (agentId: string) => Promise<{
    commands: Array<{
      source: string;
      name: string;
      description: string;
      argument?: string | null;
      skillId?: string | null;
    }>;
  } | null>;
  fetchChannelPlugins: () => Promise<AnyRecord[] | null>;
  installPlugin: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchWorkers: () => Promise<AnyRecord[]>;
  cancelWorker: (workerId: string, payload?: AnyRecord) => Promise<AnyRecord | null>;
  fetchMeshState: () => Promise<AnyRecord | null>;
  configureMeshNetwork: (payload: AnyRecord) => Promise<AnyRecord | null>;
  createMeshInvite: (payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteMeshInvite: (token: string) => Promise<boolean>;
  acceptMeshInvite: (payload: AnyRecord) => Promise<AnyRecord | null>;
  joinRemoteMesh: (payload: AnyRecord) => Promise<AnyRecord | null>;
  disconnectManualMeshRelay: (payload: { nodeId: string; relayURL: string }) => Promise<AnyRecord | null>;
  fetchMeshNodes: () => Promise<AnyRecord[]>;
  registerMeshNode: (payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteMeshNode: (nodeId: string) => Promise<boolean>;
  proxyMeshCoreRequest: (nodeId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchMeshSharedProjects: () => Promise<AnyRecord[]>;
  createMeshSharedProject: (payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteMeshSharedProject: (projectId: string) => Promise<boolean>;
  attachMeshSharedProjectMember: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchMeshTasks: (projectId?: string | null) => Promise<AnyRecord[]>;
  fetchMeshAuditLog: () => Promise<AnyRecord[]>;
  createMeshTask: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateMeshTask: (taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchArtifacts: () => Promise<AnyRecord[]>;
  fetchWorkspaces: (options?: { projectId?: string; archived?: boolean; query?: string }) => Promise<AnyRecord[]>;
  createWorkspace: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchWorkspace: (workspaceId: string) => Promise<AnyRecord | null>;
  updateWorkspace: (workspaceId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchWorkspaceDocument: (workspaceId: string, revision?: number) => Promise<AnyRecord | null>;
  applyWorkspaceTransaction: (workspaceId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  undoWorkspaceTransaction: (workspaceId: string, transactionId: string) => Promise<AnyRecord | null>;
  fetchWorkspaceTemplates: (visibility?: string) => Promise<AnyRecord[]>;
  applyWorkspaceTemplate: (workspaceId: string, templateId: string, payload?: AnyRecord) => Promise<AnyRecord | null>;
  createWorkspaceRealtimeTicket: (workspaceId: string) => Promise<AnyRecord | null>;
  fetchArtifact: (id: string) => Promise<AnyRecord | null>;
  fetchArtifactMetadata: (id: string) => Promise<AnyRecord | null>;
  fetchArtifactFile: (id: string, signal?: AbortSignal) => Promise<Blob | null>;
  fetchWidgetArtifact: (id: string) => Promise<AnyRecord | null>;
  planArtifactWebUrl: (projectId: string, planName: string) => string;
  fetchPlanArtifact: (projectId: string, planName: string) => Promise<AnyRecord | null>;
  fetchProjectInitiatives: (projectId: string) => Promise<AnyRecord[]>;
  createProjectInitiative: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateProjectInitiative: (projectId: string, initiativeId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchInitiativeDecisionPackets: (projectId: string, initiativeId: string) => Promise<AnyRecord[]>;
  updateInitiativeDecisionPacket: (
    projectId: string,
    initiativeId: string,
    packetId: string,
    payload: AnyRecord
  ) => Promise<AnyRecord | null>;
  fetchInitiativeArtifacts: (projectId: string, initiativeId: string) => Promise<AnyRecord[]>;
  fetchInitiativeActivities: (projectId: string, initiativeId: string) => Promise<AnyRecord[]>;
  fetchRuntimeConfig: () => Promise<AnyRecord | null>;
  fetchVoiceConfig: () => Promise<AnyRecord | null>;
  fetchVoiceCapabilities: () => Promise<AnyRecord | null>;
  transcribeVoice: (payload: AnyRecord) => Promise<AnyRecord | null>;
  synthesizeVoice: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchDashboardAuthStatus: () => Promise<AnyRecord | null>;
  validateDashboardAuthToken: (token: string) => Promise<AnyRecord | null>;
  fetchAuthChallenge: () => Promise<AnyRecord | null>;
  loginIdentityUser: (payload: { login: string; password: string }) => Promise<AnyRecord | null>;
  enableIdentityAuthMode: () => Promise<AnyRecord | null>;
  bootstrapIdentityAdmin: (payload: AnyRecord) => Promise<AnyRecord | null>;
  resetIdentityPassword: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchIdentityUsers: () => Promise<AnyRecord[] | null>;
  updateIdentityUser: (login: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  createIdentityInvite: (payload: AnyRecord) => Promise<AnyRecord | null>;
  generateIdentityRecoveryCodes: () => Promise<AnyRecord | null>;
  createIdentityPasswordResetToken: (login: string) => Promise<AnyRecord | null>;
  updateRuntimeConfig: (config: AnyRecord) => Promise<AnyRecord>;
  runWorkspaceGitSync: () => Promise<AnyRecord | null>;
  fetchSystemLogs: () => Promise<AnyRecord | null>;
  fetchRuntimePerformance: (limit?: number) => Promise<AnyRecord | null>;
  createIssueReport: (payload?: { logLimit?: number }) => Promise<AnyRecord | null>;
  selectDirectory: () => Promise<AnyRecord | null>;
  selectDirectories: () => Promise<AnyRecord | null>;
  fetchAvailableModels: () => Promise<AnyRecord[] | null>;
  fetchOpenAIModels: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchOpenAIProviderStatus: () => Promise<AnyRecord | null>;
  fetchAnthropicProviderStatus: () => Promise<AnyRecord | null>;
  fetchGeminiProviderStatus: () => Promise<AnyRecord | null>;
  startOpenAIOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  completeOpenAIOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  importOpenAICodexCredentials: () => Promise<AnyRecord | null>;
  startOpenAIDeviceCode: () => Promise<AnyRecord | null>;
  pollOpenAIDeviceCode: (payload: AnyRecord) => Promise<AnyRecord | null>;
  disconnectOpenAIOAuth: () => Promise<boolean>;
  startAnthropicOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  completeAnthropicOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  importAnthropicClaudeCredentials: () => Promise<AnyRecord | null>;
  disconnectAnthropicOAuth: () => Promise<boolean>;
  startGeminiOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  completeGeminiOAuth: (payload: AnyRecord) => Promise<AnyRecord | null>;
  disconnectGeminiOAuth: () => Promise<boolean>;
  fetchGitHubAuthStatus: () => Promise<AnyRecord | null>;
  connectGitHub: (payload: AnyRecord) => Promise<AnyRecord | null>;
  disconnectGitHub: () => Promise<boolean>;
  probeProvider: (payload: AnyRecord) => Promise<AnyRecord | null>;
  probeACPTarget: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchSearchProviderStatus: () => Promise<AnyRecord | null>;
  fetchImageGenerationStatus: () => Promise<AnyRecord | null>;
  fetchProjects: () => Promise<AnyRecord[] | null>;
  fetchProjectSummaries: () => Promise<AnyRecord[] | null>;
  fetchProject: (projectId: string) => Promise<AnyRecord | null>;
  fetchTaskByReference: (taskReference: string) => Promise<AnyRecord | null>;
  createProject: (payload: AnyRecord) => Promise<{ project: AnyRecord; repoCloneSucceeded: boolean | null } | null>;
  emergencyStopProject: (projectId: string) => Promise<AnyRecord>;
  updateProject: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchProjectWorkflows: (projectId: string) => Promise<AnyRecord[] | null>;
  createProjectWorkflow: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateProjectWorkflow: (projectId: string, workflowId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProjectWorkflow: (projectId: string, workflowId: string) => Promise<boolean>;
  startProjectWorkflowRun: (projectId: string, workflowId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchProjectWorkflowRuns: (projectId: string) => Promise<AnyRecord[] | null>;
  fetchProjectWorkflowRun: (projectId: string, runId: string) => Promise<AnyRecord | null>;
  fetchProjectWorkflowActions: (projectId: string) => Promise<AnyRecord[] | null>;
  resolveProjectWorkflowAction: (projectId: string, actionId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchSourceControlProviders: () => Promise<AnyRecord[] | null>;
  fetchTaskSyncProviders: () => Promise<AnyRecord[] | null>;
  fetchProjectTaskSync: (projectId: string) => Promise<AnyRecord | null>;
  updateProjectTaskSync: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  discoverProjectTaskSync: (projectId: string, payload?: AnyRecord) => Promise<AnyRecord | null>;
  linkProjectTaskSync: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  unlinkProjectTaskSync: (projectId: string) => Promise<AnyRecord | null>;
  syncProjectTasksNow: (projectId: string) => Promise<AnyRecord | null>;
  fetchProjectTaskSyncToken: (projectId: string, providerId?: string) => Promise<AnyRecord | null>;
  setProjectTaskSyncToken: (projectId: string, payload: AnyRecord, providerId?: string) => Promise<AnyRecord | null>;
  clearProjectTaskSyncToken: (projectId: string, providerId?: string) => Promise<AnyRecord | null>;
  refreshProjectContext: (projectId: string) => Promise<AnyRecord | null>;
  deleteProject: (projectId: string) => Promise<boolean>;
  createProjectChannel: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  linkProjectChannel: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProjectChannel: (projectId: string, channelId: string) => Promise<AnyRecord | null>;
  createProjectTask: (projectId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateProjectTask: (projectId: string, taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteProjectTask: (projectId: string, taskId: string) => Promise<AnyRecord | null>;
  fetchArchivedTasks: (projectId: string) => Promise<AnyRecord[] | null>;
  fetchAgents: (options?: { includeSystem?: boolean }) => Promise<AnyRecord[] | null>;
  fetchAgent: (agentId: string) => Promise<AnyRecord | null>;
  fetchAgentTasks: (agentId: string) => Promise<AnyRecord[] | null>;
  fetchAgentMemories: (agentId: string, query?: AgentMemoryQuery) => Promise<AnyRecord | null>;
  fetchAgentMemoryGraph: (agentId: string, query?: Pick<AgentMemoryQuery, "search" | "filter">) => Promise<AnyRecord | null>;
  fetchProjectMemories: (projectId: string, query?: AgentMemoryQuery) => Promise<AnyRecord | null>;
  fetchProjectMemoryGraph: (projectId: string, query?: Pick<AgentMemoryQuery, "search" | "filter">) => Promise<AnyRecord | null>;
  updateAgentMemory: (agentId: string, memoryId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteAgentMemory: (agentId: string, memoryId: string) => Promise<boolean>;
  createAgent: (payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteAgent: (agentId: string) => Promise<boolean>;
  fetchActorsBoard: () => Promise<AnyRecord | null>;
  updateActorsBoard: (payload: AnyRecord) => Promise<AnyRecord | null>;
  resolveActorRoute: (payload: AnyRecord) => Promise<AnyRecord | null>;
  previewActorDelegationTree: (payload: AnyRecord) => Promise<AnyRecord | null>;
  createActorNode: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorNode: (actorId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorNode: (actorId: string) => Promise<AnyRecord | null>;
  createActorLink: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorLink: (linkId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorLink: (linkId: string) => Promise<AnyRecord | null>;
  createActorTeam: (payload: AnyRecord) => Promise<AnyRecord | null>;
  updateActorTeam: (teamId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteActorTeam: (teamId: string) => Promise<AnyRecord | null>;
  fetchAgentSessions: (
    agentId: string,
    options?: { projectId?: string | null; limit?: number; offset?: number }
  ) => Promise<AnyRecord[] | null>;
  openLongChat: (agentId: string, userId?: string, projectId?: string) => Promise<AnyRecord>;
  fetchLongChat: (agentId: string, sessionId: string) => Promise<AnyRecord>;
  updateLongChatTask: (agentId: string, sessionId: string, taskId: string, action: string, payload?: AnyRecord) => Promise<AnyRecord>;
  cancelLongChatTasks: (agentId: string, sessionId: string) => Promise<void>;
  createAgentSession: (agentId: string, payload?: AnyRecord) => Promise<AnyRecord | null>;
  submitAgentMemoryImport: (agentId: string, sessionId: string, attachments: MemoryImportAttachment[]) => Promise<void>;
  postAgentMemoryCheckpoint: (
    agentId: string,
    sessionId: string,
    payload?: AnyRecord
  ) => Promise<AnyRecord | null>;
  fetchAgentSession: (agentId: string, sessionId: string) => Promise<AnyRecord | null>;
  postAgentSessionMessage: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  answerAgentSessionInputRequest: (
    agentId: string,
    sessionId: string,
    requestId: string,
    payload: AnyRecord
  ) => Promise<AnyRecord | null>;
  postAgentSessionDirectory: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  postAgentSessionControl: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  postAgentSessionEvents: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  subscribeAgentSessionStream: (
    agentId: string,
    sessionId: string,
    handlers?: AgentSessionStreamHandlers
  ) => () => void;
  subscribeDashboardTerminal: (handlers?: DashboardTerminalHandlers) => DashboardTerminalConnection;
  deleteAgentSession: (agentId: string, sessionId: string) => Promise<boolean>;
  fetchAgentConfig: (agentId: string) => Promise<AnyRecord | null>;
  fetchAgentFiles: (agentId: string, path?: string) => Promise<AnyRecord[] | null>;
  fetchAgentFileContent: (agentId: string, path: string) => Promise<AnyRecord | null>;
  updateAgentConfig: (agentId: string, payload: AnyRecord) => Promise<AnyRecord>;
  fetchAgentTokenUsage: (agentId: string) => Promise<AnyRecord | null>;
  fetchAgentToolsCatalog: (agentId: string) => Promise<AnyRecord[] | null>;
  fetchAgentToolsPolicy: (agentId: string) => Promise<AnyRecord | null>;
  updateAgentToolsPolicy: (agentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  invokeAgentTool: (
    agentId: string,
    sessionId: string,
    payload: AnyRecord,
    options?: RequestOptions
  ) => Promise<AnyRecord | null>;
  fetchSkillsRegistry: (search?: string, sort?: string, limit?: number, offset?: number) => Promise<AnyRecord | null>;
  fetchAgentSkills: (agentId: string) => Promise<AnyRecord | null>;
  installAgentSkill: (agentId: string, payload: { owner?: string; repo?: string; localPath?: string }) => Promise<AnyRecord | null>;
  uninstallAgentSkill: (agentId: string, skillId: string) => Promise<boolean>;
  fetchAgentCronTasks: (agentId: string) => Promise<AnyRecord[] | null>;
  createAgentCronTask: (agentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateAgentCronTask: (agentId: string, cronId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteAgentCronTask: (agentId: string, cronId: string) => Promise<boolean>;
  fetchPendingApprovals: (platform?: string) => Promise<AnyRecord[] | null>;
  approvePendingApproval: (approvalId: string, code: string) => Promise<boolean>;
  rejectPendingApproval: (approvalId: string) => Promise<boolean>;
  blockPendingApproval: (approvalId: string) => Promise<boolean>;
  fetchPendingToolApprovals: () => Promise<AnyRecord[] | null>;
  approveToolApproval: (approvalId: string, scope?: "once" | "session") => Promise<AnyRecord | null>;
  rejectToolApproval: (approvalId: string) => Promise<AnyRecord | null>;
  fetchAccessUsers: (platform?: string) => Promise<AnyRecord[] | null>;
  deleteAccessUser: (userId: string) => Promise<boolean>;
  fetchTokenUsage: (query?: { channelId?: string; taskId?: string; from?: string; to?: string }) => Promise<AnyRecord | null>;
  fetchUsageBreakdown: (query?: UsageQuery) => Promise<UsageBreakdown>;
  fetchSemanticDecisionSpending: (query?: { from?: string; to?: string }) => Promise<AnyRecord>;
  fetchChannelModel: (channelId: string) => Promise<AnyRecord | null>;
  updateChannelModel: (channelId: string, model: string) => Promise<AnyRecord | null>;
  clearChannelModel: (channelId: string) => Promise<boolean>;
  fetchTaskDiff: (projectId: string, taskId: string) => Promise<AnyRecord | null>;
  fetchProjectWorkingTreeSourceControl: (projectId: string) => Promise<AnyRecord | null>;
  subscribeProjectChangeStream: (
    projectId: string,
    handlers?: ProjectChangeStreamHandlers
  ) => () => void;
  postProjectSourceControlRestore: (projectId: string, path: string) => Promise<boolean>;
  createProjectSourceControlWorktree: (projectId: string, payload: { taskId: string }) => Promise<AnyRecord | null>;
  approveProjectTask: (projectId: string, taskId: string) => Promise<boolean>;
  rejectProjectTask: (projectId: string, taskId: string, reason?: string) => Promise<boolean>;
  fetchReviewComments: (projectId: string, taskId: string) => Promise<AnyRecord[] | null>;
  addReviewComment: (projectId: string, taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  updateReviewComment: (projectId: string, taskId: string, commentId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteReviewComment: (projectId: string, taskId: string, commentId: string) => Promise<boolean>;
  fetchTaskComments: (projectId: string, taskId: string) => Promise<AnyRecord[] | null>;
  addTaskComment: (projectId: string, taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  deleteTaskComment: (projectId: string, taskId: string, commentId: string) => Promise<boolean>;
  fetchTaskActivities: (projectId: string, taskId: string) => Promise<AnyRecord[] | null>;
  fetchTaskLogs: (projectId: string, taskId: string) => Promise<AnyRecord[] | null>;
  fetchTaskClarifications: (projectId: string, taskId: string) => Promise<AnyRecord[] | null>;
  createTaskClarification: (projectId: string, taskId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  answerTaskClarification: (projectId: string, taskId: string, clarificationId: string, payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchProjectFiles: (projectId: string, path?: string) => Promise<AnyRecord[] | null>;
  searchProjectFiles: (projectId: string, query?: string, limit?: number) => Promise<AnyRecord[] | null>;
  fetchProjectFileContent: (projectId: string, path: string) => Promise<AnyRecord | null>;
  fetchProjectAnalytics: (projectId: string, query?: { window?: string; from?: string; to?: string }) => Promise<AnyRecord | null>;
  fetchUpdateStatus: () => Promise<AnyRecord | null>;
  forceUpdateCheck: () => Promise<AnyRecord | null>;
  generateText: (payload: AnyRecord) => Promise<AnyRecord | null>;
  fetchVisorReady: () => Promise<AnyRecord | null>;
  postVisorChat: (question: string) => Promise<AnyRecord | null>;
  fetchDebugSessionContext: (agentId: string, sessionId: string) => Promise<AnyRecord | null>;
  fetchDebugChannels: () => Promise<AnyRecord | null>;
  fetchDebugPromptTemplates: () => Promise<AnyRecord | null>;
}

export function createCoreApi(): CoreApi {
  return {
    fetchAllAgentSessions: async (options = {}) => {
      const query = new URLSearchParams();
      if (options.query) query.set("query", options.query);
      if (options.includeWorkers) query.set("includeWorkers", "true");
      if (options.limit != null) query.set("limit", String(options.limit));
      const response = await requestJson<AnyRecord[]>({ path: `/v1/agent-sessions?${query}` });
      return response.ok && Array.isArray(response.data) ? response.data : null;
    },
    fetchHealth: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/health"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    sendChannelMessage: async (channelId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/messages`,
        method: "POST",
        body: payload
      });
      return response.data;
    },

    fetchChannelState: async (channelId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/state`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchChannelEvents: async (channelId, query = {}) => {
      const params = new URLSearchParams();
      if (Number.isFinite(query.limit)) {
        params.set("limit", String(query.limit));
      }
      if (typeof query.cursor === "string" && query.cursor.length > 0) {
        params.set("cursor", query.cursor);
      }
      if (typeof query.before === "string" && query.before.length > 0) {
        params.set("before", query.before);
      }
      if (typeof query.after === "string" && query.after.length > 0) {
        params.set("after", query.after);
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/events${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchChannelSessions: async (query = {}) => {
      const params = new URLSearchParams();
      if (typeof query.status === "string" && query.status.length > 0) {
        params.set("status", query.status);
      }
      if (typeof query.agentId === "string" && query.agentId.length > 0) {
        params.set("agentId", query.agentId);
      }
      if (Number.isFinite(query.recentMessagesLimit)) {
        params.set("recentMessagesLimit", String(query.recentMessagesLimit));
      }
      if (Number.isFinite(query.limit)) {
        params.set("limit", String(query.limit));
      }
      if (Number.isFinite(query.offset)) {
        params.set("offset", String(query.offset));
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/channel-sessions${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchChannelSession: async (sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channel-sessions/${encodeURIComponent(sessionId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    answerChannelInputRequest: async (sessionId, requestId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channel-sessions/${encodeURIComponent(sessionId)}/input-requests/${encodeURIComponent(requestId)}/answer`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteChannelSession: async (sessionId) => {
      const response = await requestJson({
        path: `/v1/channel-sessions/${encodeURIComponent(sessionId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    postChannelControl: async (channelId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/control`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchBulletins: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/bulletins"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    fetchChannelSlashCommands: async () => {
      const response = await requestJson<{
        commands: Array<{ name: string; description: string; argument?: string | null }>;
      }>({
        path: "/v1/channel/slash-commands"
      });
      if (!response.ok || !response.data || !Array.isArray(response.data.commands)) {
        return null;
      }
      return response.data;
    },

    fetchAgentChatSlashCommands: async (agentId) => {
      const response = await requestJson<{
        commands: Array<{
          source: string;
          name: string;
          description: string;
          argument?: string | null;
          skillId?: string | null;
        }>;
      }>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/chat-slash-commands`
      });
      if (!response.ok || !response.data || !Array.isArray(response.data.commands)) {
        return null;
      }
      return response.data;
    },

    fetchChannelPlugins: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/plugins"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    installPlugin: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/plugins/install",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    fetchWorkers: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/workers"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    cancelWorker: async (workerId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workers/${encodeURIComponent(workerId)}/cancel`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchMeshState: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/node/mesh"
      });
      if (!response.ok || !response.data) {
        return null;
      }
      return response.data;
    },

    configureMeshNetwork: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/network",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createMeshInvite: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/invites",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteMeshInvite: async (token) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/node/mesh/invites/${encodeURIComponent(token)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    acceptMeshInvite: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/invites/accept",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    joinRemoteMesh: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/remote-joins",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    disconnectManualMeshRelay: async (payload) => {
      const response = await requestJson<AnyRecord, typeof payload>({
        path: "/v1/node/mesh/relay/disconnect",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    fetchMeshNodes: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/node/mesh/nodes"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    registerMeshNode: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/nodes",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteMeshNode: async (nodeId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/node/mesh/nodes/${encodeURIComponent(nodeId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    proxyMeshCoreRequest: async (nodeId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/node/mesh/nodes/${encodeURIComponent(nodeId)}/core`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    fetchMeshSharedProjects: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/node/mesh/shared-projects"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    createMeshSharedProject: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/shared-projects",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteMeshSharedProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/node/mesh/shared-projects/${encodeURIComponent(projectId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    attachMeshSharedProjectMember: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/node/mesh/shared-projects/${encodeURIComponent(projectId)}/members`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchMeshTasks: async (projectId = null) => {
      const params = new URLSearchParams();
      if (projectId) {
        params.set("projectId", projectId);
      }
      const query = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/node/mesh/tasks${query ? `?${query}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    fetchMeshAuditLog: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/node/mesh/audit-log"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return [];
      }
      return response.data;
    },

    createMeshTask: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/node/mesh/tasks",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateMeshTask: async (taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/node/mesh/tasks/${encodeURIComponent(taskId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchArtifacts: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/artifacts"
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!Array.isArray((response.data as AnyRecord)?.artifacts)) {
        return [];
      }
      return (response.data as AnyRecord).artifacts as AnyRecord[];
    },

    fetchWorkspaces: async (options = {}) => {
      const params = new URLSearchParams();
      if (options.projectId) params.set("projectId", options.projectId);
      if (typeof options.archived === "boolean") params.set("archived", String(options.archived));
      if (options.query) params.set("query", options.query);
      const suffix = params.size > 0 ? `?${params.toString()}` : "";
      const response = await requestJson<AnyRecord>({ path: `/v1/workspaces${suffix}` });
      return response.ok && Array.isArray(response.data?.workspaces)
        ? response.data.workspaces as AnyRecord[]
        : [];
    },

    createWorkspace: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/workspaces",
        method: "POST",
        body: payload
      });
      return response.ok ? response.data : null;
    },

    fetchWorkspace: async (workspaceId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}`
      });
      return response.ok ? response.data : null;
    },

    updateWorkspace: async (workspaceId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}`,
        method: "PATCH",
        body: payload
      });
      return response.ok ? response.data : null;
    },

    fetchWorkspaceDocument: async (workspaceId, revision) => {
      const suffix = typeof revision === "number" ? `?revision=${revision}` : "";
      const response = await requestJson<AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}/document${suffix}`
      });
      return response.ok ? response.data : null;
    },

    applyWorkspaceTransaction: async (workspaceId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}/transactions`,
        method: "POST",
        body: payload
      });
      return response.ok ? response.data : null;
    },

    undoWorkspaceTransaction: async (workspaceId, transactionId) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}/transactions/${encodeURIComponent(transactionId)}/undo`,
        method: "POST",
        body: {}
      });
      return response.ok ? response.data : null;
    },

    fetchWorkspaceTemplates: async (visibility) => {
      const suffix = visibility ? `?visibility=${encodeURIComponent(visibility)}` : "";
      const response = await requestJson<AnyRecord>({ path: `/v1/workspace-templates${suffix}` });
      return response.ok && Array.isArray(response.data?.templates)
        ? response.data.templates as AnyRecord[]
        : [];
    },

    applyWorkspaceTemplate: async (workspaceId, templateId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}/templates/${encodeURIComponent(templateId)}/apply`,
        method: "POST",
        body: payload
      });
      return response.ok ? response.data : null;
    },

    createWorkspaceRealtimeTicket: async (workspaceId) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/workspaces/${encodeURIComponent(workspaceId)}/realtime-ticket`,
        method: "POST",
        body: {}
      });
      return response.ok ? response.data : null;
    },

    fetchArtifact: async (id) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/artifacts/${encodeURIComponent(id)}/content`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchArtifactMetadata: async (id) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/artifacts/${encodeURIComponent(id)}`
      });
      const artifact = response.data?.artifact;
      return response.ok && artifact && typeof artifact === "object" ? artifact as AnyRecord : null;
    },

    fetchArtifactFile: async (id, signal) =>
      requestBlob(`/v1/artifacts/${encodeURIComponent(id)}/file`, signal),

    fetchWidgetArtifact: async (id) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/artifacts/${encodeURIComponent(id)}/widget`
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!response.data || typeof response.data.html !== "string") {
        return null;
      }
      return response.data;
    },

    planArtifactWebUrl: (projectId, planName) =>
      buildApiURL(`/v1/projects/${encodeURIComponent(projectId)}/plans/${encodeURIComponent(planName)}/web`),

    fetchPlanArtifact: async (projectId, planName) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/plans/${encodeURIComponent(planName)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjectInitiatives: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives`
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!Array.isArray((response.data as AnyRecord)?.initiatives)) {
        return [];
      }
      return (response.data as AnyRecord).initiatives as AnyRecord[];
    },

    createProjectInitiative: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return ((response.data as AnyRecord)?.initiative as AnyRecord | null) ?? null;
    },

    updateProjectInitiative: async (projectId, initiativeId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives/${encodeURIComponent(initiativeId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return ((response.data as AnyRecord)?.initiative as AnyRecord | null) ?? null;
    },

    fetchInitiativeDecisionPackets: async (projectId, initiativeId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives/${encodeURIComponent(initiativeId)}/decision-packets`
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!Array.isArray((response.data as AnyRecord)?.decisionPackets)) {
        return [];
      }
      return (response.data as AnyRecord).decisionPackets as AnyRecord[];
    },

    updateInitiativeDecisionPacket: async (projectId, initiativeId, packetId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives/${encodeURIComponent(initiativeId)}/decision-packets/${encodeURIComponent(packetId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return ((response.data as AnyRecord)?.decisionPacket as AnyRecord | null) ?? null;
    },

    fetchInitiativeArtifacts: async (projectId, initiativeId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives/${encodeURIComponent(initiativeId)}/artifacts`
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!Array.isArray((response.data as AnyRecord)?.artifacts)) {
        return [];
      }
      return (response.data as AnyRecord).artifacts as AnyRecord[];
    },

    fetchInitiativeActivities: async (projectId, initiativeId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/initiatives/${encodeURIComponent(initiativeId)}/activities`
      });
      if (!response.ok) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      if (!Array.isArray((response.data as AnyRecord)?.activities)) {
        return [];
      }
      return (response.data as AnyRecord).activities as AnyRecord[];
    },

    fetchRuntimeConfig: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/config"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchVoiceConfig: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/voice/config"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchVoiceCapabilities: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/voice/capabilities"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    transcribeVoice: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/voice/transcriptions",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    synthesizeVoice: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/voice/speech",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchDashboardAuthStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/dashboard/auth/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    validateDashboardAuthToken: async (token) => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/dashboard/auth/validate",
        method: "POST",
        headers: {
          Authorization: `Bearer ${token.trim()}`
        }
      });
      if (response.ok) {
        return response.data;
      }
      const identityResponse = await requestJson<AnyRecord>({
        path: "/v1/auth/me",
        headers: {
          Authorization: `Bearer ${token.trim()}`
        }
      });
      if (!identityResponse.ok) {
        return null;
      }
      return identityResponse.data;
    },

    fetchAuthChallenge: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/auth/challenge"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    loginIdentityUser: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/auth/login",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    enableIdentityAuthMode: async () => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/auth/mode",
        method: "POST",
        body: {
          mode: "login_password",
          confirmIrreversible: true
        }
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    bootstrapIdentityAdmin: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/auth/bootstrap",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    resetIdentityPassword: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/auth/password-reset",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchIdentityUsers: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/auth/users"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateIdentityUser: async (login, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/auth/users/${encodeURIComponent(login)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createIdentityInvite: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/auth/invites",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    generateIdentityRecoveryCodes: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/auth/recovery-codes",
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createIdentityPasswordResetToken: async (login) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/auth/users/${encodeURIComponent(login)}/password-reset-token`,
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateRuntimeConfig: async (config) => {
      const challenge = await requestJson<AnyRecord>({ path: "/v1/auth/challenge" });
      if (!challenge.ok || !["token", "login_password"].includes(String(challenge.data?.mode))) {
        throw new Error("Could not determine the authentication mode. Try saving again.");
      }
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/config",
        method: "PUT",
        body: config
      });
      if (!response.ok || response.data == null) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      // Identity sessions are independent of the legacy token in the config.
      if (challenge.data?.mode === "login_password") {
        return response.data;
      }
      const nextUI = (response.data.ui as AnyRecord | undefined) ?? null;
      const nextDashboardAuth = (nextUI?.dashboardAuth as AnyRecord | undefined) ?? null;
      const nextDashboardAuthEnabled = Boolean(nextDashboardAuth?.enabled);
      const nextDashboardAuthToken = String(nextDashboardAuth?.token || "").trim();
      if (nextDashboardAuthEnabled && nextDashboardAuthToken) {
        setDashboardAuthToken(nextDashboardAuthToken, { persist: isDashboardAuthTokenPersisted() });
      } else if (!nextDashboardAuthEnabled || !nextDashboardAuthToken) {
        clearDashboardAuthToken();
      }
      return response.data;
    },

    runWorkspaceGitSync: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/git-sync/run",
        method: "POST"
      });
      return response.data ?? null;
    },

    fetchSystemLogs: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/logs"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchRuntimePerformance: async (limit = 60) => {
      const safeLimit = Math.max(1, Math.min(240, Math.round(limit)));
      const response = await requestJson<AnyRecord>({
        path: `/v1/system/performance?limit=${safeLimit}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createIssueReport: async (payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/support/issue-report",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    selectDirectory: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/system/select-directory",
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    selectDirectories: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/system/select-directories",
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAvailableModels: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/providers/models"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchOpenAIModels: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/openai/models",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchOpenAIProviderStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/openai/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchImageGenerationStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/image-generation/status"
      });
      return response.ok ? response.data : null;
    },

    fetchAnthropicProviderStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/anthropic/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchGeminiProviderStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/gemini/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    startOpenAIOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/openai/oauth/start",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    completeOpenAIOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/openai/oauth/complete",
        method: "POST",
        body: payload
      });
      return response.data;
    },

    importOpenAICodexCredentials: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/openai/oauth/import-codex",
        method: "POST"
      });
      return response.data;
    },

    startOpenAIDeviceCode: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/openai/oauth/device-code/start",
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    pollOpenAIDeviceCode: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/openai/oauth/device-code/poll",
        method: "POST",
        body: payload
      });
      return response.data;
    },

    disconnectOpenAIOAuth: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/openai/oauth/disconnect",
        method: "POST"
      });
      return response.ok;
    },

    startAnthropicOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/anthropic/oauth/start",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    completeAnthropicOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/anthropic/oauth/complete",
        method: "POST",
        body: payload
      });
      return response.data;
    },

    importAnthropicClaudeCredentials: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/anthropic/oauth/import-claude",
        method: "POST"
      });
      return response.data;
    },

    disconnectAnthropicOAuth: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/anthropic/oauth/disconnect",
        method: "POST"
      });
      return response.ok;
    },

    startGeminiOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/gemini/oauth/start",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    completeGeminiOAuth: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/gemini/oauth/complete",
        method: "POST",
        body: payload
      });
      return response.data;
    },

    disconnectGeminiOAuth: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/gemini/oauth/disconnect",
        method: "POST"
      });
      return response.ok;
    },

    fetchGitHubAuthStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/github/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    connectGitHub: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/github/connect",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    disconnectGitHub: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/github/disconnect",
        method: "POST"
      });
      return response.ok;
    },

    probeProvider: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/providers/probe",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    probeACPTarget: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/acp/targets/probe",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchSearchProviderStatus: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/providers/search/status"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjects: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/projects"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchProjectSummaries: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/projects?summary=true"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchTaskByReference: async (taskReference) => {
      const response = await requestJson<AnyRecord>({
        path: `/tasks/${encodeURIComponent(taskReference)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createProject: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/projects",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      const data = response.data;
      if (!data || typeof data !== "object") {
        return null;
      }
      const record = data as AnyRecord;
      if (record.project && typeof record.project === "object") {
        return {
          project: record.project as AnyRecord,
          repoCloneSucceeded: typeof record.repoCloneSucceeded === "boolean" ? record.repoCloneSucceeded : null
        };
      }
      return { project: record, repoCloneSucceeded: null };
    },

    emergencyStopProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/emergency-stop`,
        method: "POST"
      });
      if (!response.ok || !response.data) throw new Error("Emergency stop failed. Check the project and try again.");
      return response.data;
    },

    updateProject: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjectWorkflows: async (projectId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflows`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    createProjectWorkflow: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflows`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    updateProjectWorkflow: async (projectId, workflowId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflows/${encodeURIComponent(workflowId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    deleteProjectWorkflow: async (projectId, workflowId) => {
      const response = await requestJson({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflows/${encodeURIComponent(workflowId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    startProjectWorkflowRun: async (projectId, workflowId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflows/${encodeURIComponent(workflowId)}/runs`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchProjectWorkflowRuns: async (projectId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflow-runs`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    fetchProjectWorkflowRun: async (projectId, runId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflow-runs/${encodeURIComponent(runId)}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchProjectWorkflowActions: async (projectId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflow-actions`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    resolveProjectWorkflowAction: async (projectId, actionId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/workflow-actions/${encodeURIComponent(actionId)}/resolve`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchSourceControlProviders: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/source-control/providers"
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchTaskSyncProviders: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/task-sync/providers"
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    fetchProjectTaskSync: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync`
      });
      if (!response.ok) return null;
      return response.data;
    },

    updateProjectTaskSync: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    discoverProjectTaskSync: async (projectId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/discover`,
        method: "POST",
        body: payload
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    linkProjectTaskSync: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/link`,
        method: "POST",
        body: payload
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    unlinkProjectTaskSync: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/unlink`,
        method: "POST"
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    syncProjectTasksNow: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/sync-now`,
        method: "POST"
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    fetchProjectTaskSyncToken: async (projectId, providerId = "github") => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/token?providerId=${encodeURIComponent(providerId)}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    setProjectTaskSyncToken: async (projectId, payload, providerId = "github") => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/token?providerId=${encodeURIComponent(providerId)}`,
        method: "POST",
        body: payload
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    clearProjectTaskSyncToken: async (projectId, providerId = "github") => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/task-sync/token?providerId=${encodeURIComponent(providerId)}`,
        method: "DELETE"
      });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    refreshProjectContext: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/context/refresh`,
        method: "POST"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteProject: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    createProjectChannel: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/channels`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    linkProjectChannel: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/channel-links`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return response.data || null;
      }
      return response.data;
    },

    deleteProjectChannel: async (projectId, channelId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/channels/${encodeURIComponent(channelId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createProjectTask: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateProjectTask: async (projectId, taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteProjectTask: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchArchivedTasks: async (projectId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/archived`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgents: async (options?: { includeSystem?: boolean }) => {
      const path =
        options?.includeSystem === true ? "/v1/agents" : "/v1/agents?system=false";
      const response = await requestJson<AnyRecord[]>({ path });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgent: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentTasks: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tasks`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchMemories: async (query = {}) => {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(query)) {
        if (value !== undefined && value !== "") params.set(key, String(value));
      }
      const response = await requestJson<MemoryBrowserResponse>({ path: `/v1/memories?${params}` });
      return response.ok ? response.data : null;
    },

    fetchAgentMemories: async (agentId, query = {}) => {
      const params = new URLSearchParams();
      if (typeof query.search === "string" && query.search.trim().length > 0) {
        params.set("search", query.search.trim());
      }
      if (typeof query.filter === "string" && query.filter.trim().length > 0) {
        params.set("filter", query.filter.trim());
      }
      if (Number.isFinite(query.limit)) {
        params.set("limit", String(query.limit));
      }
      if (Number.isFinite(query.offset)) {
        params.set("offset", String(query.offset));
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/memories${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentMemoryGraph: async (agentId, query = {}) => {
      const params = new URLSearchParams();
      if (typeof query.search === "string" && query.search.trim().length > 0) {
        params.set("search", query.search.trim());
      }
      if (typeof query.filter === "string" && query.filter.trim().length > 0) {
        params.set("filter", query.filter.trim());
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/memories/graph${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjectMemories: async (projectId, query = {}) => {
      const params = new URLSearchParams();
      if (typeof query.search === "string" && query.search.trim().length > 0) {
        params.set("search", query.search.trim());
      }
      if (typeof query.filter === "string" && query.filter.trim().length > 0) {
        params.set("filter", query.filter.trim());
      }
      if (Number.isFinite(query.limit)) {
        params.set("limit", String(query.limit));
      }
      if (Number.isFinite(query.offset)) {
        params.set("offset", String(query.offset));
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/memories${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchProjectMemoryGraph: async (projectId, query = {}) => {
      const params = new URLSearchParams();
      if (typeof query.search === "string" && query.search.trim().length > 0) {
        params.set("search", query.search.trim());
      }
      if (typeof query.filter === "string" && query.filter.trim().length > 0) {
        params.set("filter", query.filter.trim());
      }

      const queryString = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/memories/graph${queryString ? `?${queryString}` : ""}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentMemory: async (agentId, memoryId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/memories/${encodeURIComponent(memoryId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteAgentMemory: async (agentId, memoryId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/memories/${encodeURIComponent(memoryId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    createAgent: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/agents",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteAgent: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchActorsBoard: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/actors/board"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorsBoard: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/board",
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    resolveActorRoute: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/route",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    previewActorDelegationTree: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/delegation-tree/preview",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorNode: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/nodes",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorNode: async (actorId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/nodes/${encodeURIComponent(actorId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorNode: async (actorId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/nodes/${encodeURIComponent(actorId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorLink: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/links",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorLink: async (linkId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/links/${encodeURIComponent(linkId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorLink: async (linkId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/links/${encodeURIComponent(linkId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    createActorTeam: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/actors/teams",
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateActorTeam: async (teamId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/actors/teams/${encodeURIComponent(teamId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteActorTeam: async (teamId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/actors/teams/${encodeURIComponent(teamId)}`,
        method: "DELETE"
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentSessions: async (agentId, options = {}) => {
      const projectId =
        typeof options.projectId === "string" && options.projectId.trim().length > 0
          ? options.projectId.trim()
          : "";
      const params = new URLSearchParams();
      if (projectId) {
        params.set("projectId", projectId);
      }
      if (Number.isFinite(options.limit)) {
        params.set("limit", String(options.limit));
      }
      if (Number.isFinite(options.offset)) {
        params.set("offset", String(options.offset));
      }
      const query = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions${query ? `?${query}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    openLongChat: async (agentId, userId = "user", projectId) => {
      const response = await requestJson<AnyRecord>({ path: `/v1/agents/${encodeURIComponent(agentId)}/long-chat`, method: "POST", body: { userId, projectId } });
      if (!response.ok || !response.data) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },
    fetchLongChat: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({ path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/long-chat` });
      if (!response.ok || !response.data) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },
    updateLongChatTask: async (agentId, sessionId, taskId, action, payload = {}) => {
      const response = await requestJson<AnyRecord>({ path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/long-chat/tasks/${encodeURIComponent(taskId)}/${encodeURIComponent(action)}`, method: "POST", body: payload });
      if (!response.ok || !response.data) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },
    cancelLongChatTasks: async (agentId, sessionId) => {
      const response = await requestJson({ path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/long-chat/cancel`, method: "POST", body: {} });
      if (!response.ok) throw new Error(formatHttpError(response.status, response.data));
    },

    createAgentSession: async (agentId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    submitAgentMemoryImport: async (agentId, sessionId, attachments) => {
      await startMemoryImport(agentId, attachments, sessionId);
    },

    postAgentMemoryCheckpoint: async (agentId, sessionId, payload = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/checkpoint`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentSession: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionMessage: async (agentId, sessionId, payload, options = {}) => {
      const messagePayload = { ...payload, sessionReferences: sessionReferencesInText(String(payload.content || "")) };
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/messages`,
        method: "POST",
        body: messagePayload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    answerAgentSessionInputRequest: async (agentId, sessionId, requestId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/input-requests/${encodeURIComponent(requestId)}/answer`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionDirectory: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/directories`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionControl: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/control`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    postAgentSessionEvents: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/events`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    subscribeAgentSessionStream: (agentId, sessionId, handlers = {}) => {
      let socket: WebSocket | null = null;
      let reconnectTimer: number | null = null;
      let disposed = false;

      const connect = () => {
        if (disposed) {
          return;
        }

        socket = new WebSocket(
          buildWebSocketURL(`/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/ws`)
        );

        socket.onopen = () => {
          handlers.onOpen?.();
        };

        socket.onmessage = (event) => {
          if (!event?.data || typeof handlers.onUpdate !== "function") {
            return;
          }

          try {
            const payload = JSON.parse(String(event.data));
            if (payload && typeof payload === "object") {
              handlers.onUpdate(payload as AnyRecord);
            }
          } catch {
            // Ignore malformed chunks and keep the socket open.
          }
        };

        socket.onerror = () => {
          handlers.onError?.();
        };

        socket.onclose = () => {
          socket = null;
          if (disposed) {
            return;
          }
          handlers.onError?.();
          reconnectTimer = window.setTimeout(() => {
            reconnectTimer = null;
            connect();
          }, 500);
        };
      };

      connect();

      return () => {
        disposed = true;
        if (reconnectTimer != null) {
          window.clearTimeout(reconnectTimer);
          reconnectTimer = null;
        }
        if (socket) {
          socket.close();
          socket = null;
        }
      };
    },

    subscribeDashboardTerminal: (handlers = {}) => {
      let socket: WebSocket | null = null;
      let authenticated = false;
      let closedExplicitly = false;
      let auth: DashboardAuthSnapshot | null = null;
      const socketURL = buildWebSocketURL("/v1/dashboard/terminal/ws");

      socket = new WebSocket(socketURL);

      socket.onopen = () => {
        try {
          if (closedExplicitly || socketURL !== buildWebSocketURL("/v1/dashboard/terminal/ws")) return;
          auth = captureDashboardAuth();
          socket?.send(JSON.stringify({
            type: "auth",
            token: auth.token || undefined
          }));
        } catch {
          handlers.onError?.();
        }
      };

      socket.onmessage = (event) => {
        if (!event?.data) {
          return;
        }

        try {
          const payload = JSON.parse(String(event.data));
          if (payload && typeof payload === "object") {
            const normalized = payload as AnyRecord;
            const type = String(normalized.type || "").toLowerCase();
            if (type === "authenticated") {
              authenticated = true;
              handlers.onOpen?.();
              return;
            }
            if (type === "error" && String(normalized.code || "").toLowerCase() === "unauthorized"
              && auth && !closedExplicitly && socketURL === buildWebSocketURL("/v1/dashboard/terminal/ws")) {
              invalidateDashboardAuthToken(auth);
            }
            handlers.onMessage?.(normalized);
          }
        } catch {
          // Ignore malformed terminal frames and keep the socket open.
        }
      };

      socket.onerror = () => {
        handlers.onError?.();
      };

      socket.onclose = (event) => {
        const shouldNotifyClose = !closedExplicitly;
        socket = null;
        if (shouldNotifyClose) {
          handlers.onClose?.({
            code: event.code,
            reason: event.reason || "",
            wasClean: event.wasClean
          });
        }
      };

      return {
        send: (payload) => {
          if (!socket || socket.readyState !== WebSocket.OPEN || !authenticated) {
            return false;
          }
          try {
            socket.send(JSON.stringify(payload));
            return true;
          } catch {
            return false;
          }
        },
        close: () => {
          closedExplicitly = true;
          if (socket) {
            socket.close();
            socket = null;
          }
        }
      };
    },

    deleteAgentSession: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchAgentConfig: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/config`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentFiles: async (agentId, path = "") => {
      const params = new URLSearchParams();
      if (path) {
        params.set("path", path);
      }
      const qs = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/files${qs ? `?${qs}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgentFileContent: async (agentId, path) => {
      const params = new URLSearchParams();
      params.set("path", path);
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/files/content?${params.toString()}`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentConfig: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/config`,
        method: "PUT",
        body: payload
      });
      if (!response.ok || response.data == null) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    fetchAgentTokenUsage: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/token-usage`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchAgentToolsCatalog: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools/catalog`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    fetchAgentToolsPolicy: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentToolsPolicy: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/tools`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    invokeAgentTool: async (agentId, sessionId, payload, options = {}) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/sessions/${encodeURIComponent(sessionId)}/tools/invoke`,
        method: "POST",
        body: payload,
        signal: options.signal
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    fetchSkillsRegistry: async (search, sort = "installs", limit = 20, offset = 0) => {
      const params = new URLSearchParams();
      if (search) params.append("search", search);
      params.append("sort", sort);
      params.append("limit", String(limit));
      params.append("offset", String(offset));
      const path = `/v1/skills/registry?${params.toString()}`;
      console.debug("[skills.registry] request:", { search: search ?? null, sort, limit, offset, path });
      const response = await requestJson<AnyRecord>({
        path
      });
      if (!response.ok) {
        console.debug("[skills.registry] response: ok=false", response);
        return null;
      }
      console.debug("[skills.registry] response:", {
        ok: true,
        total: response.data?.total,
        skillsCount: Array.isArray(response.data?.skills) ? (response.data?.skills as unknown[]).length : 0,
        data: response.data
      });
      return response.data;
    },

    fetchAgentSkills: async (agentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills`
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    installAgentSkill: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    uninstallAgentSkill: async (agentId, skillId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/skills/${encodeURIComponent(skillId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchAgentCronTasks: async (agentId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/cron`
      });
      if (!response.ok || !Array.isArray(response.data)) {
        return null;
      }
      return response.data;
    },

    createAgentCronTask: async (agentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/cron`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    updateAgentCronTask: async (agentId, cronId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/cron/${encodeURIComponent(cronId)}`,
        method: "PUT",
        body: payload
      });
      if (!response.ok) {
        return null;
      }
      return response.data;
    },

    deleteAgentCronTask: async (agentId, cronId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/agents/${encodeURIComponent(agentId)}/cron/${encodeURIComponent(cronId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchPendingApprovals: async (platform) => {
      const params = new URLSearchParams();
      if (platform) params.set("platform", platform);
      const qs = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/channel-approvals/pending${qs ? `?${qs}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    approvePendingApproval: async (approvalId, code) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channel-approvals/${encodeURIComponent(approvalId)}/approve`,
        method: "POST",
        body: { code }
      });
      return response.ok;
    },

    rejectPendingApproval: async (approvalId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channel-approvals/${encodeURIComponent(approvalId)}/reject`,
        method: "POST"
      });
      return response.ok;
    },

    blockPendingApproval: async (approvalId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channel-approvals/${encodeURIComponent(approvalId)}/block`,
        method: "POST"
      });
      return response.ok;
    },

    fetchPendingToolApprovals: async () => {
      const response = await requestJson<AnyRecord[]>({
        path: "/v1/tool-approvals/pending"
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    approveToolApproval: async (approvalId, scope = "once") => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/tool-approvals/${encodeURIComponent(approvalId)}/approve`,
        method: "POST",
        body: { decidedBy: "dashboard", scope }
      });
      if (!response.ok) return null;
      return response.data;
    },

    rejectToolApproval: async (approvalId) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/tool-approvals/${encodeURIComponent(approvalId)}/reject`,
        method: "POST",
        body: { decidedBy: "dashboard" }
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchAccessUsers: async (platform) => {
      const params = new URLSearchParams();
      if (platform) params.set("platform", platform);
      const qs = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/channel-approvals/users${qs ? `?${qs}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    deleteAccessUser: async (userId) => {
      const response = await requestJson({
        path: `/v1/channel-approvals/users/${encodeURIComponent(userId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchTokenUsage: async (query = {}) => {
      const params = new URLSearchParams();
      if (query.channelId) params.set("channelId", query.channelId);
      if (query.taskId) params.set("taskId", query.taskId);
      if (query.from) params.set("from", query.from);
      if (query.to) params.set("to", query.to);
      const qs = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/token-usage${qs ? `?${qs}` : ""}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchUsageBreakdown: async (query = {}) => {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(query)) {
        if (value !== undefined && value !== "") params.set(key, String(value));
      }
      const response = await requestJson<UsageBreakdown>({ path: `/v1/usage/breakdown${params.size ? `?${params.toString()}` : ""}` });
      if (!response.ok || !response.data) throw new Error(formatHttpError(response.status, response.data));
      return response.data;
    },

    fetchSemanticDecisionSpending: async (query = {}) => {
      const params = new URLSearchParams();
      if (query.from) params.set("from", query.from);
      if (query.to) params.set("to", query.to);
      const suffix = params.size > 0 ? `?${params.toString()}` : "";
      const response = await requestJson<AnyRecord>({ path: `/v1/semantic-decisions/spending${suffix}` });
      if (!response.ok || !response.data) {
        throw new Error(formatHttpError(response.status, response.data));
      }
      return response.data;
    },

    fetchChannelModel: async (channelId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/model`
      });
      if (!response.ok) return null;
      return response.data;
    },

    updateChannelModel: async (channelId, model) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/channels/${encodeURIComponent(channelId)}/model`,
        method: "PUT",
        body: { model }
      });
      if (!response.ok) return null;
      return response.data;
    },

    clearChannelModel: async (channelId) => {
      const response = await requestJson({
        path: `/v1/channels/${encodeURIComponent(channelId)}/model`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchTaskDiff: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/diff`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchProjectWorkingTreeSourceControl: async (projectId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/source-control/working-tree`
      });
      if (!response.ok) return null;
      return response.data;
    },

    subscribeProjectChangeStream: (projectId, handlers = {}) => {
      const source = new EventSource(
        buildApiURL(`/v1/projects/${encodeURIComponent(projectId)}/changes/stream`)
      );

      source.onopen = () => {
        handlers.onOpen?.();
      };

      source.addEventListener("change_batch", (event) => {
        if (typeof handlers.onBatch !== "function") return;
        try {
          const payload = JSON.parse(String(event.data || "{}"));
          if (payload && typeof payload === "object") {
            handlers.onBatch(payload as AnyRecord);
          }
        } catch {
          // Ignore malformed change chunks and keep the stream alive.
        }
      });

      source.onerror = () => {
        handlers.onError?.();
      };

      return () => {
        source.close();
      };
    },

    postProjectSourceControlRestore: async (projectId, path) => {
      const response = await requestJson<AnyRecord, { path: string }>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/source-control/restore`,
        method: "POST",
        body: { path }
      });
      return response.ok;
    },

    createProjectSourceControlWorktree: async (projectId, payload) => {
      const response = await requestJson<AnyRecord, { taskId: string }>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/source-control/worktrees`,
        method: "POST",
        body: payload
      });
      if (!response.ok) {
        return {
          ok: false,
          status: response.status,
          error: response.data?.error ?? null,
          message: response.data?.message ?? formatHttpError(response.status, response.data)
        };
      }
      return response.data;
    },

    approveProjectTask: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/approve`,
        method: "POST"
      });
      return response.ok;
    },

    rejectProjectTask: async (projectId, taskId, reason) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/reject`,
        method: "POST",
        body: reason ? { reason } : {}
      });
      return response.ok;
    },

    fetchReviewComments: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/review-comments`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    addReviewComment: async (projectId, taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/review-comments`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    updateReviewComment: async (projectId, taskId, commentId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/review-comments/${encodeURIComponent(commentId)}`,
        method: "PATCH",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    deleteReviewComment: async (projectId, taskId, commentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/review-comments/${encodeURIComponent(commentId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchTaskComments: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/comments`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    addTaskComment: async (projectId, taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/comments`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    deleteTaskComment: async (projectId, taskId, commentId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/comments/${encodeURIComponent(commentId)}`,
        method: "DELETE"
      });
      return response.ok;
    },

    fetchTaskActivities: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/activities`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    fetchTaskLogs: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/logs`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    fetchTaskClarifications: async (projectId, taskId) => {
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/clarifications`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    createTaskClarification: async (projectId, taskId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/clarifications`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data ?? null;
    },

    answerTaskClarification: async (projectId, taskId, clarificationId, payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/clarifications/${encodeURIComponent(clarificationId)}/answer`,
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data ?? null;
    },

    fetchProjectFiles: async (projectId, path = "") => {
      const params = new URLSearchParams();
      if (path) params.set("path", path);
      const qs = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/files${qs ? `?${qs}` : ""}`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    searchProjectFiles: async (projectId, query = "", limit = 50) => {
      const params = new URLSearchParams();
      if (query) params.set("q", query);
      params.set("limit", String(limit));
      const qs = params.toString();
      const response = await requestJson<AnyRecord[]>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/files/search?${qs}`
      });
      if (!response.ok || !Array.isArray(response.data)) return null;
      return response.data;
    },

    fetchProjectFileContent: async (projectId, path) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/files/content?path=${encodeURIComponent(path)}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchProjectAnalytics: async (projectId, query = {}) => {
      const params = new URLSearchParams();
      if (query.window) params.set("window", query.window);
      if (query.from) params.set("from", query.from);
      if (query.to) params.set("to", query.to);
      const qs = params.toString();
      const response = await requestJson<AnyRecord>({
        path: `/v1/projects/${encodeURIComponent(projectId)}/analytics${qs ? `?${qs}` : ""}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchUpdateStatus: async () => {
      const response = await requestJson<AnyRecord>({ path: "/v1/updates/check" });
      if (!response.ok) return null;
      return response.data;
    },

    forceUpdateCheck: async () => {
      const response = await requestJson<AnyRecord>({ path: "/v1/updates/check", method: "POST" });
      if (!response.ok) return null;
      return response.data;
    },

    generateText: async (payload) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/generate",
        method: "POST",
        body: payload
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchVisorReady: async () => {
      const response = await requestJson<AnyRecord>({ path: "/v1/visor/ready" });
      if (!response.ok) return null;
      return response.data;
    },

    postVisorChat: async (question) => {
      const response = await requestJson<AnyRecord, AnyRecord>({
        path: "/v1/visor/chat",
        method: "POST",
        body: { question }
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchDebugSessionContext: async (agentId, sessionId) => {
      const response = await requestJson<AnyRecord>({
        path: `/v1/debug/session-context/${encodeURIComponent(agentId)}/${encodeURIComponent(sessionId)}`
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchDebugChannels: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/debug/channels"
      });
      if (!response.ok) return null;
      return response.data;
    },

    fetchDebugPromptTemplates: async () => {
      const response = await requestJson<AnyRecord>({
        path: "/v1/debug/prompt-templates"
      });
      if (!response.ok) return null;
      return response.data;
    }
  };
}


export interface MemoryImportJob {
  id: string;
  agentId: string;
  sessionId: string;
  status: "queued" | "running" | "completed" | "failed" | "cancelling" | "cancelled";
  totalUnits: number;
  completedUnits: number;
  savedCount: number;
  duplicateCount: number;
  ignoredCount: number;
  parts?: Array<{ id: string; sourceId: string; completed: boolean; disposition?: string; reason?: string; startUTF8: number; endUTF8: number; memoryIds: string[] }>;
  error?: string;
  sources: Array<{ id: string; name: string; sha256: string; completedUnits: number; totalUnits: number }>;
}

const memoryImportsBase = (agentId: string) => `/v1/agents/${encodeURIComponent(agentId)}/memory-imports`;

async function checkedMemoryImport<T>(path: string, method: "GET" | "POST" = "GET", body?: unknown): Promise<T> {
  const response = await requestJson<T>({ path, method, body });
  if (!response.ok || !response.data) {
    const error = response.data as { error?: string; message?: string } | null;
    throw new Error(error?.message || error?.error || `Memory import request failed (${response.status || "connection lost"}).`);
  }
  return response.data;
}

export const startMemoryImport = (agentId: string, attachments: MemoryImportAttachment[], sessionId?: string) =>
  checkedMemoryImport<MemoryImportJob>(memoryImportsBase(agentId), "POST", { attachments, sessionId });
export const fetchMemoryImports = (agentId: string) => checkedMemoryImport<MemoryImportJob[]>(memoryImportsBase(agentId));
export const fetchMemoryImport = (agentId: string, id: string) => checkedMemoryImport<MemoryImportJob>(`${memoryImportsBase(agentId)}/${encodeURIComponent(id)}`);
export const resumeMemoryImport = (agentId: string, id: string) => checkedMemoryImport<MemoryImportJob>(`${memoryImportsBase(agentId)}/${encodeURIComponent(id)}/resume`, "POST");
export const cancelMemoryImport = (agentId: string, id: string) => checkedMemoryImport<MemoryImportJob>(`${memoryImportsBase(agentId)}/${encodeURIComponent(id)}/cancel`, "POST");
export const importSessionAttachments = (agentId: string, sessionId: string) => checkedMemoryImport<MemoryImportJob>(`${memoryImportsBase(agentId)}/from-session/${encodeURIComponent(sessionId)}`, "POST");
export const fetchMemoryImportSource = (agentId: string, id: string, sourceId: string) =>
  checkedMemoryImport<{ name: string; content: string; sha256: string }>(`${memoryImportsBase(agentId)}/${encodeURIComponent(id)}/sources/${encodeURIComponent(sourceId)}`);
export const fetchMemoryImportSourceLocations = (agentId: string, memoryId: string) =>
  checkedMemoryImport<Array<{ jobId: string; sourceId: string; name: string; startUTF8: number; endUTF8: number }>>(`${memoryImportsBase(agentId)}/for-memory/${encodeURIComponent(memoryId)}`);

// Migration readers execute on Core; the macOS client uses the same DTOs for local uploads.
export async function migrationRequest<T>(path: string, body?: unknown, apiBase?: string, token?: string): Promise<T> {
  const response = await requestJson<T>({ path: `/v1/migrations${path}`, method: body === undefined ? "GET" : "POST", body, apiBase, headers: apiBase ? { authorization: token ? `Bearer ${token}` : "" } : undefined });
  if (!response.ok || !response.data) { throw new Error(formatHttpError(response.status, response.data)); }
  return response.data;
}
