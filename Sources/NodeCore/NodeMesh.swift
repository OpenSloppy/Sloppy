import Foundation
import Protocols

public enum MeshMessageType: String, Codable, Sendable, Equatable {
    case authChallenge = "auth.challenge"
    case authResponse = "auth.response"
    case nodeHello = "node.hello"
    case nodeHeartbeat = "node.heartbeat"
    case nodeRegistryUpdate = "node.registry.update"
    case eventPublish = "event.publish"
    case eventAck = "event.ack"
    case eventSubscribe = "event.subscribe"
    case rpcRequest = "rpc.request"
    case rpcResponse = "rpc.response"
    case streamOpen = "stream.open"
    case streamChunk = "stream.chunk"
    case streamClose = "stream.close"
    case taskDispatch = "task.dispatch"
    case taskStatusUpdate = "task.status.update"
    case projectSyncEvent = "project.sync"
    case userDirectorySnapshot = "user.directory.snapshot"
    case userDirectoryDelta = "user.directory.delta"
    case userDirectoryRevocation = "user.directory.revocation"
}

public struct MeshDirectoryUserRecord: Codable, Sendable, Equatable {
    public var userId: String
    public var displayName: String
    public var role: String

    public init(userId: String, displayName: String, role: String) {
        self.userId = userId
        self.displayName = displayName
        self.role = role
    }
}

public struct MeshDirectorySnapshotPayload: Codable, Sendable, Equatable {
    public var users: [MeshDirectoryUserRecord]

    public init(users: [MeshDirectoryUserRecord] = []) {
        self.users = users
    }
}

public struct MeshDirectoryDeltaPayload: Codable, Sendable, Equatable {
    public var upsertedUsers: [MeshDirectoryUserRecord]
    public var revokedUserIds: [String]

    public init(upsertedUsers: [MeshDirectoryUserRecord] = [], revokedUserIds: [String] = []) {
        self.upsertedUsers = upsertedUsers
        self.revokedUserIds = revokedUserIds
    }
}

public struct MeshDirectoryRevocationPayload: Codable, Sendable, Equatable {
    public var userIds: [String]

    public init(userIds: [String] = []) {
        self.userIds = userIds
    }
}

public struct MeshEnvelope: Codable, Sendable, Equatable {
    public var id: String
    public var type: MeshMessageType
    public var from: String
    public var to: String?
    public var scope: String?
    public var timestamp: Date
    public var payload: JSONValue
    public var signature: String?

    public init(
        id: String = UUID().uuidString,
        type: MeshMessageType,
        from: String,
        to: String? = nil,
        scope: String? = nil,
        timestamp: Date = Date(),
        payload: JSONValue = .object([:]),
        signature: String? = nil
    ) {
        self.id = id
        self.type = type
        self.from = from
        self.to = to
        self.scope = scope
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
    }
}

public struct MeshAuthChallengePayload: Codable, Sendable, Equatable {
    public var nonce: String
    public var nodeId: String
    public var publicKey: String
    public var issuedAt: Date

    public init(
        nonce: String,
        nodeId: String,
        publicKey: String,
        issuedAt: Date = Date()
    ) {
        self.nonce = nonce
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.issuedAt = issuedAt
    }
}

public struct MeshAuthResponsePayload: Codable, Sendable, Equatable {
    public var nonce: String
    public var nodeId: String
    public var publicKey: String
    public var signature: String

    public init(
        nonce: String,
        nodeId: String,
        publicKey: String,
        signature: String
    ) {
        self.nonce = nonce
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.signature = signature
    }
}

public enum MeshTaskStatus: String, Codable, Sendable, Equatable {
    case queued
    case dispatched
    case claimed
    case started
    case progress
    case blocked
    case readyForReview = "ready_for_review"
    case failed
}

public struct MeshTaskRecord: Codable, Sendable, Equatable {
    public var id: String
    public var projectId: String
    public var title: String
    public var assignedNodeId: String
    public var status: MeshTaskStatus
    public var branch: String?
    public var commit: String?
    public var summary: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "mesh_task_" + UUID().uuidString,
        projectId: String,
        title: String,
        assignedNodeId: String,
        status: MeshTaskStatus = .queued,
        branch: String? = nil,
        commit: String? = nil,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.assignedNodeId = assignedNodeId
        self.status = status
        self.branch = branch
        self.commit = commit
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MeshTaskCreateRequest: Codable, Sendable, Equatable {
    public var projectId: String
    public var title: String
    public var assignedNodeId: String

    public init(projectId: String, title: String, assignedNodeId: String) {
        self.projectId = projectId
        self.title = title
        self.assignedNodeId = assignedNodeId
    }
}

public struct MeshTaskUpdateRequest: Codable, Sendable, Equatable {
    public var projectId: String?
    public var status: MeshTaskStatus
    public var branch: String?
    public var commit: String?
    public var summary: String?

    public init(
        projectId: String? = nil,
        status: MeshTaskStatus,
        branch: String? = nil,
        commit: String? = nil,
        summary: String? = nil
    ) {
        self.projectId = projectId
        self.status = status
        self.branch = branch
        self.commit = commit
        self.summary = summary
    }
}

public enum MeshNodeStatus: String, Codable, Sendable, Equatable {
    case online
    case offline
    case degraded
}

public struct MeshNodeRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var publicKey: String
    public var roles: [String]
    public var endpoint: String?
    public var status: MeshNodeStatus
    public var lastSeenAt: Date
    public var capabilities: [String]
    public var encryptionPublicKey: String?
    public var encryptionKeySignature: String?

    public init(
        id: String,
        name: String,
        publicKey: String,
        roles: [String],
        endpoint: String? = nil,
        status: MeshNodeStatus = .offline,
        lastSeenAt: Date = Date(),
        capabilities: [String],
        encryptionPublicKey: String? = nil,
        encryptionKeySignature: String? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.roles = roles
        self.endpoint = endpoint
        self.status = status
        self.lastSeenAt = lastSeenAt
        self.capabilities = capabilities
        self.encryptionPublicKey = encryptionPublicKey
        self.encryptionKeySignature = encryptionKeySignature
    }
}

public struct MeshLocalNodeRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var publicKey: String
    public var roles: [String]
    public var capabilities: [String]
    public var encryptionPublicKey: String?
    public var encryptionKeySignature: String?
    public var relayURL: String?
    public var networkId: String?
    public var networkName: String?

    public init(
        id: String,
        name: String,
        publicKey: String,
        roles: [String],
        capabilities: [String],
        encryptionPublicKey: String? = nil,
        encryptionKeySignature: String? = nil,
        relayURL: String? = nil,
        networkId: String? = nil,
        networkName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.roles = roles
        self.capabilities = capabilities
        self.encryptionPublicKey = encryptionPublicKey
        self.encryptionKeySignature = encryptionKeySignature
        self.relayURL = relayURL
        self.networkId = networkId
        self.networkName = networkName
    }
}

public struct MeshRelayDisconnectRequest: Codable, Sendable, Equatable {
    public var nodeId: String
    public var relayURL: String

    public init(nodeId: String, relayURL: String) {
        self.nodeId = nodeId
        self.relayURL = relayURL
    }
}

public struct MeshNetworkUpdateRequest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

public struct MeshInviteCreateRequest: Codable, Sendable, Equatable {
    public var networkId: String
    public var name: String?
    public var roles: [String]
    public var capabilities: [String]
    public var ttlSeconds: TimeInterval
    public var relayURL: String?
    public var nodeId: String?
    public var publicKey: String?

    public init(
        networkId: String,
        name: String? = nil,
        roles: [String] = ["worker"],
        capabilities: [String] = ["run_agent", "git"],
        ttlSeconds: TimeInterval = 86400,
        relayURL: String? = nil,
        nodeId: String? = nil,
        publicKey: String? = nil
    ) {
        self.networkId = networkId
        self.name = name
        self.roles = roles
        self.capabilities = capabilities
        self.ttlSeconds = ttlSeconds
        self.relayURL = relayURL
        self.nodeId = nodeId
        self.publicKey = publicKey
    }
}

public struct MeshInviteAcceptRequest: Codable, Sendable, Equatable {
    public var token: String
    public var endpoint: String?
    public var allowRemote: Bool
    public var nodeId: String?
    public var name: String?
    public var publicKey: String?
    public var roles: [String]?
    public var capabilities: [String]?
    public var encryptionPublicKey: String?
    public var encryptionKeySignature: String?

    public init(
        token: String,
        endpoint: String? = nil,
        allowRemote: Bool = true,
        nodeId: String? = nil,
        name: String? = nil,
        publicKey: String? = nil,
        roles: [String]? = nil,
        capabilities: [String]? = nil,
        encryptionPublicKey: String? = nil,
        encryptionKeySignature: String? = nil
    ) {
        self.token = token
        self.endpoint = endpoint
        self.allowRemote = allowRemote
        self.nodeId = nodeId
        self.name = name
        self.publicKey = publicKey
        self.roles = roles
        self.capabilities = capabilities
        self.encryptionPublicKey = encryptionPublicKey
        self.encryptionKeySignature = encryptionKeySignature
    }

    enum CodingKeys: String, CodingKey {
        case token
        case endpoint
        case allowRemote
        case nodeId
        case name
        case publicKey
        case roles
        case capabilities
        case encryptionPublicKey
        case encryptionKeySignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        self.allowRemote = try container.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? true
        self.nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        self.roles = try container.decodeIfPresent([String].self, forKey: .roles)
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
        self.encryptionPublicKey = try container.decodeIfPresent(String.self, forKey: .encryptionPublicKey)
        self.encryptionKeySignature = try container.decodeIfPresent(String.self, forKey: .encryptionKeySignature)
    }
}

public struct MeshRemoteJoinRequest: Codable, Sendable, Equatable {
    public var token: String
    public var name: String?
    public var force: Bool

    public init(token: String, name: String? = nil, force: Bool = false) {
        self.token = token
        self.name = name
        self.force = force
    }
}

public struct MeshRemoteJoinResult: Codable, Sendable, Equatable {
    public var node: MeshNodeRecord
    public var relayURL: String
    public var coordinatorAcceptURL: String
    public var networkId: String?
    public var networkName: String?

    public init(
        node: MeshNodeRecord,
        relayURL: String,
        coordinatorAcceptURL: String,
        networkId: String? = nil,
        networkName: String? = nil
    ) {
        self.node = node
        self.relayURL = relayURL
        self.coordinatorAcceptURL = coordinatorAcceptURL
        self.networkId = networkId
        self.networkName = networkName
    }
}

public enum MeshRemoteJoinError: LocalizedError, Equatable {
    case invalidInvite(String)
    case identityMismatch(expectedPublicKey: String, actualPublicKey: String)
    case coordinatorUnreachable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInvite(message):
            "Remote mesh invite is invalid: \(message)"
        case .identityMismatch:
            "This invite is bound to another node identity. Create a new invite for this machine or use force to replace local identity."
        case let .coordinatorUnreachable(url):
            "Could not reach relay coordinator at \(url)."
        }
    }
}

public struct MeshNodeRegisterRequest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var publicKey: String
    public var roles: [String]
    public var endpoint: String?
    public var capabilities: [String]

    public init(
        id: String,
        name: String,
        publicKey: String,
        roles: [String],
        endpoint: String? = nil,
        capabilities: [String]
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.roles = roles
        self.endpoint = endpoint
        self.capabilities = capabilities
    }
}

public struct MeshInvite: Codable, Sendable, Equatable {
    public var token: String
    public var networkId: String
    public var name: String?
    public var roles: [String]
    public var capabilities: [String]
    public var relayURL: String?
    public var networkName: String?
    public var nodeId: String?
    public var publicKey: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var consumedAt: Date?
    public var consumedByNodeId: String?

    public init(
        token: String,
        networkId: String,
        name: String? = nil,
        roles: [String],
        capabilities: [String],
        relayURL: String? = nil,
        networkName: String? = nil,
        nodeId: String? = nil,
        publicKey: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date,
        consumedAt: Date? = nil,
        consumedByNodeId: String? = nil
    ) {
        self.token = token
        self.networkId = networkId
        self.name = name
        self.roles = roles
        self.capabilities = capabilities
        self.relayURL = relayURL
        self.networkName = networkName
        self.nodeId = nodeId
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.consumedByNodeId = consumedByNodeId
    }

    public var isConsumed: Bool { consumedAt != nil }

    public var bundleToken: String? {
        guard let relayURL else { return nil }
        return try? MeshInviteBundle(
            inviteToken: token,
            relayURL: relayURL,
            networkId: networkId,
            networkName: networkName,
            nodeId: nodeId,
            publicKey: publicKey
        ).tokenString()
    }

    enum CodingKeys: String, CodingKey {
        case token
        case networkId
        case name
        case roles
        case capabilities
        case relayURL
        case networkName
        case nodeId
        case publicKey
        case createdAt
        case expiresAt
        case consumedAt
        case consumedByNodeId
        case bundleToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        networkId = try container.decode(String.self, forKey: .networkId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        roles = try container.decode([String].self, forKey: .roles)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL)
        networkName = try container.decodeIfPresent(String.self, forKey: .networkName)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        consumedAt = try container.decodeIfPresent(Date.self, forKey: .consumedAt)
        consumedByNodeId = try container.decodeIfPresent(String.self, forKey: .consumedByNodeId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(networkId, forKey: .networkId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(roles, forKey: .roles)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(relayURL, forKey: .relayURL)
        try container.encodeIfPresent(networkName, forKey: .networkName)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(publicKey, forKey: .publicKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(consumedAt, forKey: .consumedAt)
        try container.encodeIfPresent(consumedByNodeId, forKey: .consumedByNodeId)
        try container.encodeIfPresent(bundleToken, forKey: .bundleToken)
    }
}

public enum MeshInviteBundleError: LocalizedError, Equatable {
    case invalidToken
    case invalidPayload
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Mesh invite bundle token is invalid."
        case .invalidPayload:
            "Mesh invite bundle payload is invalid."
        case let .unsupportedVersion(version):
            "Mesh invite bundle version \(version) is not supported."
        }
    }
}

public struct MeshInviteBundle: Codable, Sendable, Equatable {
    public static let prefix = "slp_mesh_"

    public var version: Int
    public var inviteToken: String
    public var relayURL: String
    public var networkId: String?
    public var networkName: String?
    public var nodeId: String?
    public var publicKey: String?

    public init(
        version: Int = 1,
        inviteToken: String,
        relayURL: String,
        networkId: String? = nil,
        networkName: String? = nil,
        nodeId: String? = nil,
        publicKey: String? = nil
    ) {
        self.version = version
        self.inviteToken = inviteToken
        self.relayURL = relayURL
        self.networkId = networkId
        self.networkName = networkName
        self.nodeId = nodeId
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case inviteToken
        case relayURL
        case networkId
        case networkName
        case nodeId
        case publicKey
    }

    public func tokenString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return Self.prefix + Self.base64URLEncode(data)
    }

    public static func parse(_ token: String) throws -> MeshInviteBundle {
        guard token.hasPrefix(prefix) else {
            throw MeshInviteBundleError.invalidToken
        }
        let encodedPayload = String(token.dropFirst(prefix.count))
        guard let data = base64URLDecode(encodedPayload) else {
            throw MeshInviteBundleError.invalidPayload
        }
        let bundle = try JSONDecoder().decode(MeshInviteBundle.self, from: data)
        guard bundle.version == 1 else {
            throw MeshInviteBundleError.unsupportedVersion(bundle.version)
        }
        guard !bundle.inviteToken.isEmpty, !bundle.relayURL.isEmpty else {
            throw MeshInviteBundleError.invalidPayload
        }
        return bundle
    }

    public static func inviteToken(from token: String) -> String {
        (try? parse(token).inviteToken) ?? token
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}

public struct SharedProjectPolicies: Codable, Sendable, Equatable {
    public var branchPerTask: Bool
    public var directPushToMain: Bool
    public var requireCleanWorktree: Bool
    public var requireTestsBeforeReady: Bool

    public init(
        branchPerTask: Bool = true,
        directPushToMain: Bool = false,
        requireCleanWorktree: Bool = true,
        requireTestsBeforeReady: Bool = true
    ) {
        self.branchPerTask = branchPerTask
        self.directPushToMain = directPushToMain
        self.requireCleanWorktree = requireCleanWorktree
        self.requireTestsBeforeReady = requireTestsBeforeReady
    }
}

public enum MeshPermission: String, Codable, CaseIterable, Sendable, Equatable {
    case projectRead = "project.read"
    case projectWrite = "project.write"
    case taskCreate = "task.create"
    case taskAssign = "task.assign"
    case taskUpdate = "task.update"
    case nodeRPC = "node.rpc"
    case nodeShell = "node.shell"
    case nodeAgentSpawn = "node.agent.spawn"
    case nodeFilesRead = "node.files.read"
    case nodeFilesWrite = "node.files.write"
    case nodeRelay = "node.relay"

    public static let workerDefaults: [MeshPermission] = [
        .projectRead,
        .taskUpdate,
        .nodeRPC,
    ]
}

public extension [MeshPermission] {
    var rawValues: [String] {
        map(\.rawValue)
    }
}

public struct SharedProjectMember: Codable, Sendable, Equatable {
    public var nodeId: String
    public var actorId: String?
    public var localRepoPath: String
    public var role: String
    public var permissions: [String]

    public init(
        nodeId: String,
        actorId: String? = nil,
        localRepoPath: String,
        role: String,
        permissions: [String]
    ) {
        self.nodeId = nodeId
        self.actorId = actorId
        self.localRepoPath = localRepoPath
        self.role = role
        self.permissions = permissions
    }
}

public struct SharedProjectRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var repoUrl: String
    public var defaultBranch: String
    public var members: [SharedProjectMember]
    public var eventScope: String
    public var policies: SharedProjectPolicies
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        repoUrl: String,
        defaultBranch: String = "main",
        members: [SharedProjectMember] = [],
        eventScope: String? = nil,
        policies: SharedProjectPolicies = SharedProjectPolicies(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repoUrl = repoUrl
        self.defaultBranch = defaultBranch
        self.members = members
        self.eventScope = eventScope ?? "sharedProject:\(id)"
        self.policies = policies
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MeshSharedProjectCreateRequest: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    public var repoUrl: String
    public var defaultBranch: String

    public init(id: String? = nil, name: String, repoUrl: String, defaultBranch: String = "main") {
        self.id = id
        self.name = name
        self.repoUrl = repoUrl
        self.defaultBranch = defaultBranch
    }
}

public struct MeshSharedProjectMemberRequest: Codable, Sendable, Equatable {
    public var nodeId: String
    public var actorId: String?
    public var localRepoPath: String
    public var role: String
    public var permissions: [String]

    public init(
        nodeId: String,
        actorId: String? = nil,
        localRepoPath: String,
        role: String,
        permissions: [String]
    ) {
        self.nodeId = nodeId
        self.actorId = actorId
        self.localRepoPath = localRepoPath
        self.role = role
        self.permissions = permissions
    }
}

public struct MeshSharedProjectUpdateRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var repoUrl: String?
    public var defaultBranch: String?
    public var policies: SharedProjectPolicies?

    public init(
        name: String? = nil,
        repoUrl: String? = nil,
        defaultBranch: String? = nil,
        policies: SharedProjectPolicies? = nil
    ) {
        self.name = name
        self.repoUrl = repoUrl
        self.defaultBranch = defaultBranch
        self.policies = policies
    }
}

public struct MeshAuditLogEntry: Codable, Sendable, Equatable {
    public var id: String
    public var time: Date
    public var actor: String
    public var target: String?
    public var action: String
    public var project: String?
    public var task: String?
    public var allowed: Bool
    public var message: String?

    public init(
        id: String = UUID().uuidString,
        time: Date = Date(),
        actor: String,
        target: String? = nil,
        action: String,
        project: String? = nil,
        task: String? = nil,
        allowed: Bool,
        message: String? = nil
    ) {
        self.id = id
        self.time = time
        self.actor = actor
        self.target = target
        self.action = action
        self.project = project
        self.task = task
        self.allowed = allowed
        self.message = message
    }
}

public struct MeshState: Codable, Sendable, Equatable {
    public var networkId: String
    public var networkName: String
    public var localNode: MeshLocalNodeRecord?
    public var nodes: [MeshNodeRecord]
    public var invites: [MeshInvite]
    public var userDirectory: [MeshDirectoryUserRecord]
    public var sharedProjects: [SharedProjectRecord]
    public var tasks: [MeshTaskRecord]
    public var envelopes: [MeshEnvelope]
    public var auditLog: [MeshAuditLogEntry]
    public var events: [SignedMeshEvent]
    public var eventCursors: [String: String]
    public var processedEnvelopeIDs: [String]

    public init(
        networkId: String = "personal",
        networkName: String = "personal",
        localNode: MeshLocalNodeRecord? = nil,
        nodes: [MeshNodeRecord] = [],
        invites: [MeshInvite] = [],
        userDirectory: [MeshDirectoryUserRecord] = [],
        sharedProjects: [SharedProjectRecord] = [],
        tasks: [MeshTaskRecord] = [],
        envelopes: [MeshEnvelope] = [],
        auditLog: [MeshAuditLogEntry] = [],
        events: [SignedMeshEvent] = [],
        eventCursors: [String: String] = [:],
        processedEnvelopeIDs: [String] = []
    ) {
        self.networkId = networkId
        self.networkName = networkName
        self.localNode = localNode
        self.nodes = nodes
        self.invites = invites
        self.userDirectory = userDirectory
        self.sharedProjects = sharedProjects
        self.tasks = tasks
        self.envelopes = envelopes
        self.auditLog = auditLog
        self.events = events
        self.eventCursors = eventCursors
        self.processedEnvelopeIDs = processedEnvelopeIDs
    }

    enum CodingKeys: String, CodingKey {
        case networkId
        case networkName
        case localNode
        case nodes
        case invites
        case userDirectory
        case sharedProjects
        case tasks
        case envelopes
        case auditLog
        case events
        case eventCursors
        case processedEnvelopeIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkId = try container.decodeIfPresent(String.self, forKey: .networkId) ?? "personal"
        networkName = try container.decodeIfPresent(String.self, forKey: .networkName) ?? "personal"
        localNode = try container.decodeIfPresent(MeshLocalNodeRecord.self, forKey: .localNode)
        nodes = try container.decodeIfPresent([MeshNodeRecord].self, forKey: .nodes) ?? []
        invites = try container.decodeIfPresent([MeshInvite].self, forKey: .invites) ?? []
        userDirectory = try container.decodeIfPresent([MeshDirectoryUserRecord].self, forKey: .userDirectory) ?? []
        sharedProjects = try container.decodeIfPresent([SharedProjectRecord].self, forKey: .sharedProjects) ?? []
        tasks = try container.decodeIfPresent([MeshTaskRecord].self, forKey: .tasks) ?? []
        envelopes = try container.decodeIfPresent([MeshEnvelope].self, forKey: .envelopes) ?? []
        auditLog = try container.decodeIfPresent([MeshAuditLogEntry].self, forKey: .auditLog) ?? []
        events = try container.decodeIfPresent([SignedMeshEvent].self, forKey: .events) ?? []
        eventCursors = try container.decodeIfPresent([String: String].self, forKey: .eventCursors) ?? [:]
        processedEnvelopeIDs = try container.decodeIfPresent([String].self, forKey: .processedEnvelopeIDs) ?? []
    }
}

public enum NodeMeshStoreError: LocalizedError, Equatable {
    case inviteMissing
    case inviteWrongCoordinator(String)
    case inviteExpired
    case inviteConsumed
    case projectMissing(String)
    case nodeMissing(String)
    case permissionDenied(String)
    case taskAmbiguous(String)
    case taskMissing(String)

    public var errorDescription: String? {
        switch self {
        case .inviteMissing:
            "Invite token was not found."
        case let .inviteWrongCoordinator(relayURL):
            "Invite token was not found in this coordinator state. This bundled token points to relay \(relayURL). Switch the dashboard API base to that relay and accept it there."
        case .inviteExpired:
            "Invite token has expired."
        case .inviteConsumed:
            "Invite token has already been consumed."
        case let .projectMissing(projectId):
            "Shared project '\(projectId)' was not found."
        case let .nodeMissing(nodeId):
            "Node '\(nodeId)' was not found."
        case let .permissionDenied(permission):
            "Permission denied: \(permission)."
        case let .taskAmbiguous(taskId):
            "Mesh task '\(taskId)' exists in multiple projects. Provide a project id or name."
        case let .taskMissing(taskId):
            "Mesh task '\(taskId)' was not found."
        }
    }
}

public struct NodeMeshStore: Sendable {
    public var stateURL: URL

    public init(stateURL: URL = NodeMeshStore.defaultStateURL()) {
        self.stateURL = stateURL
    }

    public static func defaultStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sloppy/mesh.json")
    }

    public func load() throws -> MeshState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return MeshState()
        }
        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshState.self, from: data)
    }

    public func save(_ state: MeshState) throws {
        let directoryURL = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
        #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        #endif
    }

    public func projectedState() throws -> MeshState {
        let state = try load()
        let trustedEventIDs = Set(state.events.map(\.event.id))
        var projected = try NodeMeshProjection.project(
            events: state.events,
            base: state,
            trustedEventIDs: trustedEventIDs
        )
        projected.events = state.events
        projected.eventCursors = state.eventCursors
        projected.invites = state.invites
        projected.envelopes = state.envelopes
        projected.auditLog = state.auditLog
        return projected
    }

    @discardableResult
    public func createInvite(
        networkId: String,
        name: String?,
        roles: [String],
        capabilities: [String],
        ttlSeconds: TimeInterval = 86400,
        relayURL: String? = nil,
        nodeId: String? = nil,
        publicKey: String? = nil
    ) throws -> MeshInvite {
        var state = try load()
        state.networkId = networkId
        state.networkName = state.networkName.isEmpty ? networkId : state.networkName
        let invite = MeshInvite(
            token: "slp_invite_" + NodeIdentityGenerator.randomToken(byteCount: 18),
            networkId: networkId,
            name: name,
            roles: roles,
            capabilities: capabilities,
            relayURL: relayURL,
            networkName: state.networkName,
            nodeId: nodeId,
            publicKey: publicKey,
            expiresAt: Date().addingTimeInterval(max(1, ttlSeconds))
        )
        state.invites.append(invite)
        state.auditLog.append(MeshAuditLogEntry(actor: "local", action: "node.invite.create", allowed: true, message: invite.token))
        try save(state)
        return invite
    }

    public func revokeInvite(token: String, actor: String = "local") throws {
        var state = try load()
        let bundle = try? MeshInviteBundle.parse(token)
        let inviteToken = bundle?.inviteToken ?? token
        guard let index = state.invites.firstIndex(where: { $0.token == inviteToken }) else {
            throw NodeMeshStoreError.inviteMissing
        }

        let invite = state.invites[index]
        state.invites.remove(at: index)
        state.auditLog.append(MeshAuditLogEntry(actor: actor, action: "node.invite.revoke", allowed: true, message: invite.token))
        try save(state)
    }

    public func exportCoordinatorDirectorySnapshot() throws -> MeshDirectorySnapshotPayload {
        let state = try load()
        return MeshDirectorySnapshotPayload(users: state.userDirectory)
    }

    public func applyUserDirectorySnapshot(_ snapshot: MeshDirectorySnapshotPayload, actor: String = "api") throws {
        var state = try load()
        state.userDirectory = snapshot.users
        state.auditLog.append(MeshAuditLogEntry(
            actor: actor,
            action: "user_directory.apply_snapshot",
            allowed: true,
            message: "users:\(snapshot.users.count)"
        ))
        try save(state)
    }

    public func applyUserDirectoryDelta(_ delta: MeshDirectoryDeltaPayload, actor: String = "api") throws {
        var state = try load()
        for user in delta.upsertedUsers {
            if let index = state.userDirectory.firstIndex(where: { $0.userId == user.userId }) {
                state.userDirectory[index] = user
            } else {
                state.userDirectory.append(user)
            }
        }
        for revokedUserId in delta.revokedUserIds {
            state.userDirectory.removeAll { $0.userId == revokedUserId }
        }
        state.auditLog.append(MeshAuditLogEntry(
            actor: actor,
            action: "user_directory.apply_delta",
            allowed: true,
            message: "upserted:\(delta.upsertedUsers.count), revoked:\(delta.revokedUserIds.count)"
        ))
        try save(state)
    }

    public func applyUserDirectoryRevocation(_ revocation: MeshDirectoryRevocationPayload, actor: String = "api") throws {
        var state = try load()
        if !revocation.userIds.isEmpty {
            state.userDirectory.removeAll { user in
                revocation.userIds.contains(user.userId)
            }
        }
        state.auditLog.append(MeshAuditLogEntry(
            actor: actor,
            action: "user_directory.apply_revocation",
            allowed: true,
            message: "revoked:\(revocation.userIds.count)"
        ))
        try save(state)
    }

    @discardableResult
    public func acceptInvite(token: String, endpoint: String? = nil) throws -> MeshNodeRecord {
        var state = try load()
        let bundle = try? MeshInviteBundle.parse(token)
        let inviteToken = bundle?.inviteToken ?? token
        guard let index = state.invites.firstIndex(where: { $0.token == inviteToken }) else {
            throw NodeMeshStoreError.inviteMissing
        }
        let invite = state.invites[index]
        guard invite.consumedAt == nil else { throw NodeMeshStoreError.inviteConsumed }
        guard invite.expiresAt > Date() else { throw NodeMeshStoreError.inviteExpired }
        guard let nodeId = bundle?.nodeId ?? invite.nodeId, !nodeId.isEmpty,
              let publicKey = bundle?.publicKey ?? invite.publicKey, !publicKey.isEmpty
        else {
            throw NodeMeshStoreError.permissionDenied("invite.identity")
        }

        state.invites[index].consumedAt = Date()
        state.invites[index].consumedByNodeId = nodeId
        state.networkId = invite.networkId
        let record = MeshNodeRecord(
            id: nodeId,
            name: invite.name ?? nodeId,
            publicKey: publicKey,
            roles: invite.roles,
            endpoint: endpoint ?? bundle?.relayURL ?? invite.relayURL,
            status: .offline,
            lastSeenAt: Date(),
            capabilities: invite.capabilities
        )
        upsert(record, in: &state.nodes)
        state.auditLog.append(MeshAuditLogEntry(actor: nodeId, action: "node.invite.accept", allowed: true, message: invite.token))
        try save(state)
        return record
    }

    @discardableResult
    public func consumeInvite(token: String, identity: NodeIdentity, endpoint: String?) throws -> MeshNodeRecord {
        var state = try load()
        let bundle = try? MeshInviteBundle.parse(token)
        let inviteToken = bundle?.inviteToken ?? token
        guard let index = state.invites.firstIndex(where: { $0.token == inviteToken }) else {
            throw NodeMeshStoreError.inviteMissing
        }
        let invite = state.invites[index]
        guard invite.consumedAt == nil else { throw NodeMeshStoreError.inviteConsumed }
        guard invite.expiresAt > Date() else { throw NodeMeshStoreError.inviteExpired }
        if let expectedPublicKey = bundle?.publicKey ?? invite.publicKey,
           expectedPublicKey != identity.publicKey {
            throw NodeMeshStoreError.permissionDenied("invite.public_key")
        }

        state.invites[index].consumedAt = Date()
        state.invites[index].consumedByNodeId = identity.nodeId
        state.networkId = invite.networkId
        let record = MeshNodeRecord(
            id: identity.nodeId,
            name: identity.name,
            publicKey: identity.publicKey,
            roles: identity.roles,
            endpoint: endpoint ?? bundle?.relayURL ?? invite.relayURL,
            status: .online,
            lastSeenAt: Date(),
            capabilities: identity.capabilities,
            encryptionPublicKey: identity.encryptionPublicKey,
            encryptionKeySignature: identity.encryptionKeySignature
        )
        upsert(record, in: &state.nodes)
        state.auditLog.append(MeshAuditLogEntry(actor: identity.nodeId, action: "node.join", allowed: true, message: invite.token))
        try save(state)
        return record
    }

    @discardableResult
    public func registerNode(_ identity: NodeIdentity, endpoint: String? = nil, status: MeshNodeStatus = .online) throws -> MeshNodeRecord {
        var state = try load()
        let record = MeshNodeRecord(
            id: identity.nodeId,
            name: identity.name,
            publicKey: identity.publicKey,
            roles: identity.roles,
            endpoint: endpoint,
            status: status,
            lastSeenAt: Date(),
            capabilities: identity.capabilities
        )
        upsert(record, in: &state.nodes)
        state.auditLog.append(MeshAuditLogEntry(actor: identity.nodeId, action: "node.register", allowed: true))
        try save(state)
        return record
    }

    @discardableResult
    public func upsertNodeRecord(_ record: MeshNodeRecord, auditAction: String = "node.register") throws -> MeshNodeRecord {
        var state = try load()
        upsert(record, in: &state.nodes)
        state.auditLog.append(MeshAuditLogEntry(actor: record.id, action: auditAction, allowed: true))
        try save(state)
        return record
    }

    public func removeNodeRecord(nodeId: String, actor: String = "local") throws {
        var state = try load()
        guard let index = state.nodes.firstIndex(where: { $0.id == nodeId }) else {
            throw NodeMeshStoreError.nodeMissing(nodeId)
        }

        state.nodes.remove(at: index)
        for projectIndex in state.sharedProjects.indices {
            state.sharedProjects[projectIndex].members.removeAll { $0.nodeId == nodeId }
            state.sharedProjects[projectIndex].updatedAt = Date()
        }
        state.auditLog.append(MeshAuditLogEntry(actor: actor, target: nodeId, action: "node.delete.api", allowed: true))
        try save(state)
    }

    @discardableResult
    public func updateNodeStatus(nodeId: String, status: MeshNodeStatus, auditAction: String) throws -> MeshNodeRecord {
        var state = try load()
        guard let index = state.nodes.firstIndex(where: { $0.id == nodeId }) else {
            throw NodeMeshStoreError.nodeMissing(nodeId)
        }
        state.nodes[index].status = status
        state.nodes[index].lastSeenAt = Date()
        let record = state.nodes[index]
        state.auditLog.append(MeshAuditLogEntry(actor: nodeId, action: auditAction, allowed: true))
        try save(state)
        return record
    }

    @discardableResult
    public func createSharedProject(id: String? = nil, name: String, repoUrl: String, defaultBranch: String = "main") throws -> SharedProjectRecord {
        var state = try load()
        let projectId = id?.isEmpty == false ? id! : makeSharedProjectId(name)
        let project = SharedProjectRecord(
            id: projectId,
            name: name,
            repoUrl: repoUrl,
            defaultBranch: defaultBranch.isEmpty ? "main" : defaultBranch
        )
        if let existingIndex = state.sharedProjects.firstIndex(where: { $0.id == project.id || $0.name == name }) {
            state.sharedProjects[existingIndex] = project
        } else {
            state.sharedProjects.append(project)
        }
        appendProjectSyncEvent(
            project,
            action: "shared_project.create",
            actor: "local",
            in: &state
        )
        state.auditLog.append(MeshAuditLogEntry(actor: "local", action: "shared_project.create", project: project.id, allowed: true))
        try save(state)
        return project
    }

    public func removeSharedProject(projectIdOrName: String, actor: String = "local") throws {
        var state = try load()
        guard let projectIndex = state.sharedProjects.firstIndex(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }

        let project = state.sharedProjects.remove(at: projectIndex)
        appendProjectSyncEvent(
            project,
            action: "shared_project.remove",
            actor: actor,
            in: &state
        )
        state.auditLog.append(MeshAuditLogEntry(actor: actor, action: "shared_project.remove", project: project.id, allowed: true))
        try save(state)
    }

    @discardableResult
    public func attachMember(
        projectIdOrName: String,
        nodeId: String,
        localRepoPath: String,
        role: String,
        actorId: String? = nil,
        permissions: [String]
    ) throws -> SharedProjectRecord {
        var state = try load()
        guard let projectIndex = state.sharedProjects.firstIndex(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }
        let member = SharedProjectMember(
            nodeId: nodeId,
            actorId: actorId,
            localRepoPath: localRepoPath,
            role: role,
            permissions: permissions
        )
        if let memberIndex = state.sharedProjects[projectIndex].members.firstIndex(where: { $0.nodeId == nodeId }) {
            state.sharedProjects[projectIndex].members[memberIndex] = member
        } else {
            state.sharedProjects[projectIndex].members.append(member)
        }
        state.sharedProjects[projectIndex].updatedAt = Date()
        let project = state.sharedProjects[projectIndex]
        appendProjectSyncEvent(
            project,
            action: "shared_project.attach",
            actor: "local",
            targetNodeId: nodeId,
            in: &state
        )
        state.auditLog.append(MeshAuditLogEntry(actor: "local", target: nodeId, action: "shared_project.attach", project: project.id, allowed: true))
        try save(state)
        return project
    }

    @discardableResult
    public func updateSharedProject(
        projectIdOrName: String,
        name: String? = nil,
        repoUrl: String? = nil,
        defaultBranch: String? = nil,
        policies: SharedProjectPolicies? = nil,
        actor: String = "local"
    ) throws -> SharedProjectRecord {
        var state = try load()
        guard let projectIndex = state.sharedProjects.firstIndex(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }

        if let name, !name.isEmpty { state.sharedProjects[projectIndex].name = name }
        if let repoUrl, !repoUrl.isEmpty { state.sharedProjects[projectIndex].repoUrl = repoUrl }
        if let defaultBranch, !defaultBranch.isEmpty { state.sharedProjects[projectIndex].defaultBranch = defaultBranch }
        if let policies { state.sharedProjects[projectIndex].policies = policies }
        state.sharedProjects[projectIndex].updatedAt = Date()

        let project = state.sharedProjects[projectIndex]
        appendProjectSyncEvent(
            project,
            action: "shared_project.update",
            actor: actor,
            in: &state
        )
        state.auditLog.append(MeshAuditLogEntry(actor: actor, action: "shared_project.update", project: project.id, allowed: true))
        try save(state)
        return project
    }

    @discardableResult
    public func removeSharedProjectMember(
        projectIdOrName: String,
        nodeId: String,
        actor: String = "local"
    ) throws -> SharedProjectRecord {
        var state = try load()
        guard let projectIndex = state.sharedProjects.firstIndex(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }

        state.sharedProjects[projectIndex].members.removeAll { $0.nodeId == nodeId }
        state.sharedProjects[projectIndex].updatedAt = Date()
        let project = state.sharedProjects[projectIndex]
        appendProjectSyncEvent(
            project,
            action: "shared_project.member.remove",
            actor: actor,
            targetNodeId: nodeId,
            in: &state
        )
        state.auditLog.append(MeshAuditLogEntry(actor: actor, target: nodeId, action: "shared_project.member.remove", project: project.id, allowed: true))
        try save(state)
        return project
    }

    @discardableResult
    public func createNetwork(id: String, name: String? = nil) throws -> MeshState {
        var state = try load()
        state.networkId = id
        state.networkName = name?.isEmpty == false ? name! : id
        state.auditLog.append(MeshAuditLogEntry(actor: "local", action: "network.create", allowed: true, message: state.networkName))
        try save(state)
        return state
    }

    public func listNodes() throws -> [MeshNodeRecord] {
        let state = try load()
        return try mergedNodes(from: state).sorted { $0.name < $1.name }
    }

    public func listSharedProjects() throws -> [SharedProjectRecord] {
        let state = try load()
        return try mergedSharedProjects(from: state).sorted { $0.name < $1.name }
    }

    public func listTasks(projectIdOrName: String? = nil) throws -> [MeshTaskRecord] {
        let state = try load()
        let projects = try mergedSharedProjects(from: state)
        let tasks = try mergedTasks(from: state)
        guard let projectIdOrName, !projectIdOrName.isEmpty else {
            return tasks.sorted { $0.updatedAt > $1.updatedAt }
        }
        let projectId = project(matchingID: projectIdOrName, in: projects)?
            .id ?? project(matchingName: projectIdOrName, in: projects)?
            .id ?? projectIdOrName
        return tasks.filter { $0.projectId == projectId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func appendEvent(
        _ signed: SignedMeshEvent,
        expectedActorPublicKey: String
    ) throws -> SignedMeshEvent {
        var state = try load()
        guard try MeshEventSigner.verify(signed, publicKey: expectedActorPublicKey) else {
            state.auditLog.append(MeshAuditLogEntry(
                actor: signed.event.actorNodeId,
                action: "event.append",
                project: signed.event.projectId,
                allowed: false,
                message: "invalid_signature"
            ))
            try save(state)
            throw MeshEventVerificationError.invalidSignature
        }
        if let existing = state.events.first(where: { $0.event.id == signed.event.id }) {
            guard try NodeMeshProjection.isSameSignedEvent(existing, signed) else {
                state.auditLog.append(MeshAuditLogEntry(
                    actor: signed.event.actorNodeId,
                    target: signed.event.targetNodeId,
                    action: "event.append",
                    project: signed.event.projectId,
                    allowed: false,
                    message: "event_conflict"
                ))
                try save(state)
                throw MeshEventVerificationError.eventConflict(signed.event.id)
            }
            return signed
        }
        try validateAppendOrder([signed], after: state.events)
        let trustedEventIDs = Set(state.events.map(\.event.id))
        _ = try NodeMeshProjection.project(
            events: state.events + [signed],
            base: state,
            trustedEventIDs: trustedEventIDs
        )
        state.events.append(signed)
        state.eventCursors[signed.event.actorNodeId] = signed.event.id
        state.auditLog.append(MeshAuditLogEntry(
            actor: signed.event.actorNodeId,
            target: signed.event.targetNodeId,
            action: "event.append",
            project: signed.event.projectId,
            allowed: true,
            message: signed.event.type.rawValue
        ))
        try save(state)
        return signed
    }

    @discardableResult
    func appendEvents(
        _ signedEvents: [SignedMeshEvent],
        expectedActorPublicKey: String
    ) throws -> [SignedMeshEvent] {
        guard !signedEvents.isEmpty else {
            return []
        }
        var state = try load()
        var pending: [SignedMeshEvent] = []
        for signed in signedEvents {
            guard try MeshEventSigner.verify(signed, publicKey: expectedActorPublicKey) else {
                throw MeshEventVerificationError.invalidSignature
            }
            if let existing = state.events.first(where: { $0.event.id == signed.event.id }) {
                guard try NodeMeshProjection.isSameSignedEvent(existing, signed) else {
                    throw MeshEventVerificationError.eventConflict(signed.event.id)
                }
                continue
            }
            if let existing = pending.first(where: { $0.event.id == signed.event.id }) {
                guard try NodeMeshProjection.isSameSignedEvent(existing, signed) else {
                    throw MeshEventVerificationError.eventConflict(signed.event.id)
                }
                continue
            }
            pending.append(signed)
        }

        guard !pending.isEmpty else {
            return signedEvents
        }

        try validateAppendOrder(pending, after: state.events)
        let trustedEventIDs = Set(state.events.map(\.event.id))
        _ = try NodeMeshProjection.project(
            events: state.events + pending,
            base: state,
            trustedEventIDs: trustedEventIDs
        )
        state.events.append(contentsOf: pending)
        for signed in pending {
            state.eventCursors[signed.event.actorNodeId] = signed.event.id
            state.auditLog.append(MeshAuditLogEntry(
                actor: signed.event.actorNodeId,
                target: signed.event.targetNodeId,
                action: "event.append",
                project: signed.event.projectId,
                allowed: true,
                message: signed.event.type.rawValue
            ))
        }
        try save(state)
        return signedEvents
    }

    public func listEvents(after cursor: String? = nil, limit: Int = 100) throws -> [SignedMeshEvent] {
        guard limit > 0 else {
            return []
        }
        let events = try load().events
        let startIndex: Int
        if let cursor, let index = events.firstIndex(where: { $0.event.id == cursor }) {
            startIndex = events.index(after: index)
        } else {
            startIndex = events.startIndex
        }
        guard startIndex < events.endIndex else {
            return []
        }
        return Array(events[startIndex...].prefix(limit))
    }

    @discardableResult
    public func routeEnvelope(_ envelope: MeshEnvelope) throws -> MeshEnvelope {
        var state = try load()
        let nodes = try mergedNodes(from: state)
        if let target = envelope.to, !nodes.contains(where: { $0.id == target }) {
            state.auditLog.append(MeshAuditLogEntry(actor: envelope.from, target: target, action: envelope.type.rawValue, allowed: false, message: "unknown target node"))
            try save(state)
            throw NodeMeshStoreError.nodeMissing(target)
        }
        state.envelopes.append(envelope)
        state.auditLog.append(MeshAuditLogEntry(actor: envelope.from, target: envelope.to, action: envelope.type.rawValue, project: projectFromScope(envelope.scope), allowed: true))
        try save(state)
        return envelope
    }

    public func ackEnvelope(id: String, acknowledgedBy nodeId: String) throws {
        var state = try load()
        guard let index = state.envelopes.firstIndex(where: { $0.id == id }) else {
            state.auditLog.append(MeshAuditLogEntry(
                actor: nodeId,
                action: MeshMessageType.eventAck.rawValue,
                allowed: true,
                message: "already acknowledged: \(id)"
            ))
            try save(state)
            return
        }
        let envelope = state.envelopes[index]
        guard envelope.to == nodeId else {
            state.auditLog.append(MeshAuditLogEntry(
                actor: nodeId,
                target: envelope.to,
                action: MeshMessageType.eventAck.rawValue,
                allowed: false,
                message: "acknowledging node is not the envelope target: \(id)"
            ))
            try save(state)
            throw NodeMeshStoreError.permissionDenied("event.ack")
        }
        state.envelopes.remove(at: index)
        state.auditLog.append(MeshAuditLogEntry(
            actor: nodeId,
            target: envelope.from,
            action: MeshMessageType.eventAck.rawValue,
            allowed: true,
            message: id
        ))
        try save(state)
    }

    @discardableResult
    public func recordProcessedEnvelope(id: String, processedBy nodeId: String) throws -> Bool {
        var state = try load()
        if state.processedEnvelopeIDs.contains(id) {
            state.auditLog.append(MeshAuditLogEntry(
                actor: nodeId,
                action: "event.processed",
                allowed: true,
                message: "duplicate: \(id)"
            ))
            try save(state)
            return false
        }
        state.processedEnvelopeIDs.append(id)
        state.auditLog.append(MeshAuditLogEntry(
            actor: nodeId,
            action: "event.processed",
            allowed: true,
            message: id
        ))
        try save(state)
        return true
    }

    public func recordRouteFailure(_ envelope: MeshEnvelope, target: String, message: String) throws {
        var state = try load()
        state.auditLog.append(MeshAuditLogEntry(
            actor: envelope.from,
            target: target,
            action: envelope.type.rawValue,
            project: projectFromScope(envelope.scope),
            allowed: false,
            message: message
        ))
        try save(state)
    }

    @discardableResult
    public func rpcRequest(from: String, to: String, method: String, params: JSONValue = .object([:])) throws -> MeshEnvelope {
        try routeEnvelope(MeshEnvelope(
            type: .rpcRequest,
            from: from,
            to: to,
            payload: .object([
                "method": .string(method),
                "params": params,
            ])
        ))
    }

    @discardableResult
    public func dispatchTask(projectIdOrName: String, title: String, assignedNodeId: String, actor: String = "local") throws -> MeshTaskRecord {
        var state = try load()
        guard let project = state.sharedProjects.first(where: { $0.id == projectIdOrName || $0.name == projectIdOrName }) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }
        guard state.nodes.contains(where: { $0.id == assignedNodeId }) else {
            throw NodeMeshStoreError.nodeMissing(assignedNodeId)
        }
        guard let member = project.members.first(where: { $0.nodeId == assignedNodeId }), member.permissions.contains("task.update") || member.permissions.contains("task.assign") else {
            state.auditLog.append(MeshAuditLogEntry(actor: actor, target: assignedNodeId, action: "task.dispatch", project: project.id, allowed: false, message: "missing task.update/task.assign permission"))
            try save(state)
            throw NodeMeshStoreError.permissionDenied("task.dispatch")
        }
        let task = MeshTaskRecord(projectId: project.id, title: title, assignedNodeId: assignedNodeId, status: .dispatched)
        state.tasks.append(task)
        state.envelopes.append(MeshEnvelope(
            type: .taskDispatch,
            from: actor,
            to: assignedNodeId,
            scope: project.eventScope,
            payload: .object([
                "taskId": .string(task.id),
                "projectId": .string(project.id),
                "title": .string(title),
            ])
        ))
        state.auditLog.append(MeshAuditLogEntry(actor: actor, target: assignedNodeId, action: "task.dispatch", project: project.id, task: task.id, allowed: true))
        try save(state)
        return task
    }

    @discardableResult
    public func dispatchTask(
        projectIdOrName: String,
        title: String,
        assignedNodeId: String,
        actorIdentity: NodeIdentity
    ) throws -> MeshTaskRecord {
        let storedState = try load()
        let projected = try projectedState()
        guard let project = sharedProject(
            projectIdOrName: projectIdOrName,
            storedState: storedState,
            projectedState: projected
        ) else {
            throw NodeMeshStoreError.projectMissing(projectIdOrName)
        }
        guard let actorMember = project.members.first(where: { $0.nodeId == actorIdentity.nodeId }),
              actorMember.permissions.contains(MeshPermission.taskCreate.rawValue),
              actorMember.permissions.contains(MeshPermission.taskAssign.rawValue)
        else {
            throw NodeMeshStoreError.permissionDenied("task.dispatch")
        }
        guard storedState.nodes.contains(where: { $0.id == assignedNodeId }) || projected.nodes.contains(where: { $0.id == assignedNodeId }) else {
            throw NodeMeshStoreError.nodeMissing(assignedNodeId)
        }
        guard let assignedMember = project.members.first(where: { $0.nodeId == assignedNodeId }),
              assignedMember.permissions.contains(MeshPermission.taskUpdate.rawValue) || assignedMember.permissions.contains(MeshPermission.taskAssign.rawValue)
        else {
            throw NodeMeshStoreError.permissionDenied("task.dispatch")
        }

        let taskId = "mesh_task_" + UUID().uuidString
        let created = MeshEvent(
            type: .taskCreated,
            actorNodeId: actorIdentity.nodeId,
            projectId: project.id,
            logicalTime: nextLogicalTime(from: storedState),
            payload: .object([
                "taskId": .string(taskId),
                "title": .string(title),
            ])
        )
        let assigned = MeshEvent(
            type: .taskAssigned,
            actorNodeId: actorIdentity.nodeId,
            targetNodeId: assignedNodeId,
            projectId: project.id,
            logicalTime: created.logicalTime + 1,
            causalParents: [created.id],
            payload: .object([
                "taskId": .string(taskId),
                "assignedNodeId": .string(assignedNodeId),
            ])
        )

        _ = try appendEvents([
            MeshEventSigner.sign(created, identity: actorIdentity),
            MeshEventSigner.sign(assigned, identity: actorIdentity),
        ], expectedActorPublicKey: actorIdentity.publicKey)

        guard let task = try projectedState().tasks.first(where: { $0.id == taskId }) else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        return task
    }

    @discardableResult
    public func updateTaskStatus(
        taskId: String,
        projectIdOrName: String? = nil,
        status: MeshTaskStatus,
        actor: String,
        branch: String? = nil,
        commit: String? = nil,
        summary: String? = nil
    ) throws -> MeshTaskRecord {
        var state = try load()
        let index = try resolveTaskIndex(taskId: taskId, projectIdOrName: projectIdOrName, in: state)
        state.tasks[index].status = status
        if let branch { state.tasks[index].branch = branch }
        if let commit { state.tasks[index].commit = commit }
        if let summary { state.tasks[index].summary = summary }
        state.tasks[index].updatedAt = Date()
        let task = state.tasks[index]
        let project = state.sharedProjects.first(where: { $0.id == task.projectId })
        state.envelopes.append(MeshEnvelope(
            type: .taskStatusUpdate,
            from: actor,
            scope: project?.eventScope ?? "sharedProject:\(task.projectId)",
            payload: .object([
                "taskId": .string(task.id),
                "status": .string(status.rawValue),
                "branch": branch.map(JSONValue.string) ?? .null,
                "commit": commit.map(JSONValue.string) ?? .null,
                "summary": summary.map(JSONValue.string) ?? .null,
            ])
        ))
        state.auditLog.append(MeshAuditLogEntry(actor: actor, action: "task.status.update", project: task.projectId, task: task.id, allowed: true, message: status.rawValue))
        try save(state)
        return task
    }

    @discardableResult
    public func updateTaskStatus(
        taskId: String,
        projectIdOrName: String? = nil,
        status: MeshTaskStatus,
        actorIdentity: NodeIdentity,
        branch: String? = nil,
        commit: String? = nil,
        summary: String? = nil
    ) throws -> MeshTaskRecord {
        let storedState = try load()
        let projected = try projectedState()
        var taskResolutionState = storedState
        taskResolutionState.sharedProjects = mergeById(
            stored: storedState.sharedProjects,
            projected: projected.sharedProjects,
            id: \.id
        )
        taskResolutionState.tasks = mergeTasks(stored: storedState.tasks, projected: projected.tasks)
        let task = try resolveTask(taskId: taskId, projectIdOrName: projectIdOrName, in: taskResolutionState)
        guard let project = sharedProject(
            projectIdOrName: task.projectId,
            storedState: storedState,
            projectedState: projected
        ),
        let actorMember = project.members.first(where: { $0.nodeId == actorIdentity.nodeId }),
        actorMember.permissions.contains(MeshPermission.taskUpdate.rawValue)
        else {
            throw NodeMeshStoreError.permissionDenied("task.status.update")
        }
        let ownsTask = task.assignedNodeId == actorIdentity.nodeId
        let hasElevatedTaskPermission = actorMember.permissions.contains(MeshPermission.taskAssign.rawValue)
            || actorMember.permissions.contains(MeshPermission.taskCreate.rawValue)
        guard ownsTask || hasElevatedTaskPermission else {
            throw NodeMeshStoreError.permissionDenied("task.status.update")
        }

        let event = MeshEvent(
            type: .taskStatusUpdated,
            actorNodeId: actorIdentity.nodeId,
            projectId: task.projectId,
            logicalTime: nextLogicalTime(from: storedState),
            payload: .object([
                "taskId": .string(task.id),
                "status": .string(status.rawValue),
                "branch": branch.map(JSONValue.string) ?? .null,
                "commit": commit.map(JSONValue.string) ?? .null,
                "summary": summary.map(JSONValue.string) ?? .null,
            ])
        )

        _ = try appendEvent(
            MeshEventSigner.sign(event, identity: actorIdentity),
            expectedActorPublicKey: actorIdentity.publicKey
        )

        guard let updated = try projectedState().tasks.first(where: { $0.id == taskId && $0.projectId == task.projectId }) else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        return updated
    }

    public func recordTaskDispatchDelivery(taskId: String, target: String, delivered: Bool, message: String? = nil) throws {
        var state = try load()
        let projectId = state.tasks.first(where: { $0.id == taskId })?.projectId
        state.auditLog.append(MeshAuditLogEntry(
            actor: "relay",
            target: target,
            action: "task.dispatch.delivery",
            project: projectId,
            task: taskId,
            allowed: delivered,
            message: message ?? (delivered ? "delivered" : "not delivered")
        ))
        try save(state)
    }

    private func sharedProject(
        projectIdOrName: String,
        storedState: MeshState,
        projectedState: MeshState
    ) -> SharedProjectRecord? {
        if let project = project(matchingID: projectIdOrName, in: projectedState.sharedProjects)
            ?? project(matchingID: projectIdOrName, in: storedState.sharedProjects)
            ?? project(matchingName: projectIdOrName, in: projectedState.sharedProjects)
            ?? project(matchingName: projectIdOrName, in: storedState.sharedProjects) {
            return project
        }
        return nil
    }

    private func mergedNodes(from state: MeshState) throws -> [MeshNodeRecord] {
        guard !state.events.isEmpty else {
            return state.nodes
        }
        let projected = try projectedState()
        return mergeById(stored: state.nodes, projected: projected.nodes, id: \.id)
    }

    private func mergedSharedProjects(from state: MeshState) throws -> [SharedProjectRecord] {
        guard !state.events.isEmpty else {
            return state.sharedProjects
        }
        let projected = try projectedState()
        return mergeById(stored: state.sharedProjects, projected: projected.sharedProjects, id: \.id)
    }

    private func mergedTasks(from state: MeshState) throws -> [MeshTaskRecord] {
        guard !state.events.isEmpty else {
            return state.tasks
        }
        let projected = try projectedState()
        return mergeTasks(stored: state.tasks, projected: projected.tasks)
    }

    private func mergeById<Value>(
        stored: [Value],
        projected: [Value],
        id: KeyPath<Value, String>
    ) -> [Value] {
        var merged = stored
        for projectedValue in projected {
            if let index = merged.firstIndex(where: { $0[keyPath: id] == projectedValue[keyPath: id] }) {
                merged[index] = projectedValue
            } else {
                merged.append(projectedValue)
            }
        }
        return merged
    }

    private func mergeTasks(
        stored: [MeshTaskRecord],
        projected: [MeshTaskRecord]
    ) -> [MeshTaskRecord] {
        var merged = stored
        for projectedTask in projected {
            if let index = merged.firstIndex(where: { $0.id == projectedTask.id && $0.projectId == projectedTask.projectId }) {
                merged[index] = projectedTask
            } else {
                merged.append(projectedTask)
            }
        }
        return merged
    }

    private func resolveTaskIndex(
        taskId: String,
        projectIdOrName: String?,
        in state: MeshState
    ) throws -> Int {
        let indexes = state.tasks.indices.filter { state.tasks[$0].id == taskId }
        guard !indexes.isEmpty else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        guard let projectIdOrName else {
            guard indexes.count == 1 else {
                throw NodeMeshStoreError.taskAmbiguous(taskId)
            }
            return indexes[0]
        }
        let matching = indexes.filter {
            task(state.tasks[$0], matchesProject: projectIdOrName, projects: state.sharedProjects)
        }
        guard let index = matching.first else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        guard matching.count == 1 else {
            throw NodeMeshStoreError.taskAmbiguous(taskId)
        }
        return index
    }

    private func resolveTask(
        taskId: String,
        projectIdOrName: String?,
        in state: MeshState
    ) throws -> MeshTaskRecord {
        let tasks = state.tasks.filter { $0.id == taskId }
        guard !tasks.isEmpty else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        guard let projectIdOrName else {
            guard tasks.count == 1 else {
                throw NodeMeshStoreError.taskAmbiguous(taskId)
            }
            return tasks[0]
        }
        let matching = tasks.filter {
            task($0, matchesProject: projectIdOrName, projects: state.sharedProjects)
        }
        guard let task = matching.first else {
            throw NodeMeshStoreError.taskMissing(taskId)
        }
        guard matching.count == 1 else {
            throw NodeMeshStoreError.taskAmbiguous(taskId)
        }
        return task
    }

    private func task(
        _ task: MeshTaskRecord,
        matchesProject projectIdOrName: String,
        projects: [SharedProjectRecord]
    ) -> Bool {
        task.projectId == projectIdOrName
            || projects.contains(where: { $0.id == task.projectId && $0.name == projectIdOrName })
    }

    private func project(matchingID projectID: String, in projects: [SharedProjectRecord]) -> SharedProjectRecord? {
        projects.first(where: { $0.id == projectID })
    }

    private func project(matchingName projectName: String, in projects: [SharedProjectRecord]) -> SharedProjectRecord? {
        projects.first(where: { $0.name == projectName })
    }

    private func nextLogicalTime(from state: MeshState) -> UInt64 {
        (state.events.map(\.event.logicalTime).max() ?? 0) + 1
    }

    private func validateAppendOrder(
        _ pending: [SignedMeshEvent],
        after accepted: [SignedMeshEvent]
    ) throws {
        var lastLogicalTime = accepted.map(\.event.logicalTime).max() ?? 0
        for signed in pending {
            guard signed.event.logicalTime > lastLogicalTime else {
                throw MeshEventVerificationError.unauthorized("event.append")
            }
            lastLogicalTime = signed.event.logicalTime
        }
    }

    private func projectFromScope(_ scope: String?) -> String? {
        guard let scope, scope.hasPrefix("sharedProject:") else { return nil }
        return String(scope.dropFirst("sharedProject:".count))
    }

    private func appendProjectSyncEvent(
        _ project: SharedProjectRecord,
        action: String,
        actor: String,
        targetNodeId: String? = nil,
        in state: inout MeshState
    ) {
        let memberNodeIds = Set(project.members.map(\.nodeId))
        for nodeId in memberNodeIds {
            state.envelopes.append(MeshEnvelope(
                type: .projectSyncEvent,
                from: actor,
                to: nodeId,
                scope: project.eventScope,
                payload: .object([
                    "action": .string(action),
                    "projectId": .string(project.id),
                    "targetNodeId": targetNodeId.map(JSONValue.string) ?? .null,
                    "project": (try? JSONValueCoder.encode(project)) ?? .object([:]),
                ])
            ))
        }
    }

    private func upsert(_ node: MeshNodeRecord, in nodes: inout [MeshNodeRecord]) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
    }

    private func makeSharedProjectId(_ name: String) -> String {
        let slug = name
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-")
            .joined(separator: "-")
        return "sp_\(slug.isEmpty ? NodeIdentityGenerator.randomToken(byteCount: 4) : slug)"
    }
}
