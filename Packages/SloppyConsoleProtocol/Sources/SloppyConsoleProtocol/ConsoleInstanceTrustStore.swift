import Crypto
import Foundation

public struct ConsoleLocalIdentity: Codable, Sendable {
    public var instanceID: UUID
    public var deviceID: UUID
    public var signingPublicKey: Data
    public var signingPrivateKey: Data
}

private struct LocalConsoleState: Codable, Sendable {
    var identity: ConsoleLocalIdentity
    var consolePublicKey: Data?
    var binding: InstanceBinding?
    var grants: [DeviceGrant] = []
    var policies: [InstanceAccessPolicy] = []
    var groups: [String: Set<UUID>] = [:]
    var groupVersions: [String: Int] = [:]
    var minimumVersions: [String: Int] = [:]
    var accountByLocalUserID: [String: UUID] = [:]
    var passwordMigrationConfirmed = false
    var environment: ConsoleEnvironment = .production
    init(identity: ConsoleLocalIdentity) { self.identity = identity }
    private enum CodingKeys: String, CodingKey { case identity, consolePublicKey, binding, grants, policies, groups, groupVersions, minimumVersions, accountByLocalUserID, passwordMigrationConfirmed, environment }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ConsoleLocalIdentity.self, forKey: .identity)
        consolePublicKey = try c.decodeIfPresent(Data.self, forKey: .consolePublicKey)
        binding = try c.decodeIfPresent(InstanceBinding.self, forKey: .binding)
        grants = try c.decodeIfPresent([DeviceGrant].self, forKey: .grants) ?? []
        policies = try c.decodeIfPresent([InstanceAccessPolicy].self, forKey: .policies) ?? []
        groups = try c.decodeIfPresent([String: Set<UUID>].self, forKey: .groups) ?? [:]
        groupVersions = try c.decodeIfPresent([String: Int].self, forKey: .groupVersions) ?? [:]
        minimumVersions = try c.decodeIfPresent([String: Int].self, forKey: .minimumVersions) ?? [:]
        accountByLocalUserID = try c.decodeIfPresent([String: UUID].self, forKey: .accountByLocalUserID) ?? [:]
        passwordMigrationConfirmed = try c.decodeIfPresent(Bool.self, forKey: .passwordMigrationConfirmed) ?? false
        environment = try c.decodeIfPresent(ConsoleEnvironment.self, forKey: .environment) ?? .production
    }
}

/// Trust lives at the instance. Personal owner grants may also be signed by the
/// Console key pinned during local binding; unsigned directory keys are rejected.
public actor ConsoleInstanceTrustStore {
    private let url: URL
    private var state: LocalConsoleState
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try ConsoleWire.decode(LocalConsoleState.self, from: Data(contentsOf: url))
        } else {
            let key = Curve25519.Signing.PrivateKey()
            state = LocalConsoleState(identity: ConsoleLocalIdentity(instanceID: UUID(), deviceID: UUID(), signingPublicKey: key.publicKey.rawRepresentation, signingPrivateKey: key.rawRepresentation))
            try Self.persist(state, at: url)
        }
    }
    public func identity() -> ConsoleLocalIdentity { state.identity }
    public func consolePublicKey() -> Data? { state.consolePublicKey }
    public func binding() -> InstanceBinding? { state.binding }
    public func environment() -> ConsoleEnvironment { state.environment }
    public func migrationConfirmed() -> Bool { state.passwordMigrationConfirmed }
    public func localUserID(accountID: UUID) -> String? { state.accountByLocalUserID.first { $0.value == accountID }?.key }
    public func confirmMigration(_ migration: ConsoleAccountMigration, activeLocalUserIDs: Set<String>) throws {
        guard migration.backupPairingConfirmed, Set(migration.accountByLocalUserID.keys) == activeLocalUserIDs,
              Set(migration.accountByLocalUserID.values).count == migration.accountByLocalUserID.count,
              let binding = state.binding, binding.status == .active else { throw ConsoleTrustError.invalidConfiguration }
        let accounts = Set(state.grants.filter { $0.status == .active }.map(\.accountID)).union([binding.ownerID])
        guard Set(migration.accountByLocalUserID.values).isSubset(of: accounts) else { throw ConsoleTrustError.forbidden }
        var next = state; next.accountByLocalUserID = migration.accountByLocalUserID; next.passwordMigrationConfirmed = true
        try Self.persist(next, at: url); state = next
    }
    public func sign(_ proposal: AccessProposal) throws -> SignedAccessProposal {
        guard proposal.expiresAt > Date() else { throw ConsoleTrustError.expired }
        if proposal.kind == .bindInstance {
            let binding = try ConsoleWire.decode(InstanceBinding.self, from: proposal.payload)
            guard binding.id == state.identity.instanceID, binding.hostDeviceID == state.identity.deviceID,
                  binding.authorityPublicKey == state.identity.signingPublicKey,
                  proposal.instanceID == binding.id, proposal.targetID == binding.id,
                  state.binding == nil || state.binding?.ownerID == binding.ownerID else { throw ConsoleTrustError.wrongContext }
        } else if proposal.instanceID != nil {
            guard proposal.instanceID == state.identity.instanceID else { throw ConsoleTrustError.wrongContext }
        } else if proposal.kind == .organizationAuthority {
            guard proposal.payload == state.identity.signingPublicKey else { throw ConsoleTrustError.wrongContext }
        }
        return try ConsoleTrust.sign(proposal, privateKey: state.identity.signingPrivateKey)
    }
    public func installBinding(_ signed: SignedAccessProposal, consolePublicKey: Data, environment: ConsoleEnvironment = .production) throws {
        guard consolePublicKey.count == 32, signed.proposal.kind == .bindInstance else { throw ConsoleTrustError.invalidConfiguration }
        try ConsoleTrust.verify(signed, authority: state.identity.signingPublicKey)
        var binding = try ConsoleWire.decode(InstanceBinding.self, from: signed.proposal.payload)
        guard binding.id == state.identity.instanceID, binding.hostDeviceID == state.identity.deviceID, binding.authorityPublicKey == state.identity.signingPublicKey else { throw ConsoleTrustError.wrongContext }
        if let existing = state.consolePublicKey, existing != consolePublicKey { throw ConsoleTrustError.invalidConfiguration }
        if state.binding != nil, state.environment != environment { throw ConsoleTrustError.wrongContext }
        binding.status = .active; binding.version = signed.proposal.version
        var next = state; next.binding = binding; next.consolePublicKey = consolePublicKey; next.environment = environment
        try Self.persist(next, at: url); state = next
    }
    public func synchronize(_ snapshot: ConsoleTrustSnapshot) throws {
        guard let binding = state.binding, snapshot.instance.id == binding.id, snapshot.instance.authorityPublicKey == state.identity.signingPublicKey else { throw ConsoleTrustError.wrongContext }
        var next = state
        for grant in snapshot.grants {
            guard grant.instanceID == binding.id else { throw ConsoleTrustError.wrongContext }
            let minimum = next.minimumVersions[grant.id.uuidString] ?? 0
            guard grant.version >= minimum else { throw ConsoleTrustError.staleVersion }
            if grant.status == .active {
                try ConsoleTrust.verifyDeviceGrant(grant.signedProposal, instanceAuthority: state.identity.signingPublicKey, consolePublicKey: state.consolePublicKey, instanceOwnerID: binding.ownerID, now: grant.signedProposal.proposal.expiresAt.addingTimeInterval(-1))
                let request = try ConsoleWire.decode(GrantRequest.self, from: grant.signedProposal.proposal.payload)
                guard grant.signedProposal.proposal.kind == .deviceGrant, grant.signedProposal.proposal.instanceID == binding.id,
                      grant.signedProposal.proposal.targetID == grant.id, grant.signedProposal.proposal.version == grant.version,
                      request.deviceID == grant.deviceID, request.accountID == grant.accountID,
                      request.signingPublicKey == grant.signingPublicKey, request.certificateFingerprint == grant.certificateFingerprint,
                      request.organizationID == grant.organizationID, request.permissions == grant.permissions, request.projectIDs == grant.projectIDs else { throw ConsoleTrustError.wrongContext }
            }
            next.minimumVersions[grant.id.uuidString] = grant.version
            next.grants.removeAll { $0.id == grant.id }; next.grants.append(grant)
        }
        for policy in snapshot.policies {
            guard policy.instanceID == binding.id else { throw ConsoleTrustError.wrongContext }
            try ConsoleTrust.verify(policy.signedProposal, authority: state.identity.signingPublicKey, now: policy.signedProposal.proposal.expiresAt.addingTimeInterval(-1))
            let request = try ConsoleWire.decode(PolicyRequest.self, from: policy.signedProposal.proposal.payload)
            guard policy.signedProposal.proposal.kind == .policy, policy.signedProposal.proposal.targetID == policy.id,
                  policy.signedProposal.proposal.instanceID == binding.id, policy.signedProposal.proposal.organizationID == policy.organizationID,
                  policy.signedProposal.proposal.version == policy.version,
                  request.groupID == policy.groupID, request.organizationID == policy.organizationID,
                  request.organizationAuthorityPublicKey == policy.organizationAuthorityPublicKey,
                  request.permissions == policy.permissions, request.projectIDs == policy.projectIDs else { throw ConsoleTrustError.wrongContext }
            let previous = next.policies.first { $0.id == policy.id }
            guard policy.version >= (previous?.version ?? 0) else { throw ConsoleTrustError.staleVersion }
            next.policies.removeAll { $0.id == policy.id }; next.policies.append(policy)
        }
        for signed in snapshot.signedChanges.filter({ $0.proposal.kind == .groupMembers }).sorted(by: { $0.proposal.version < $1.proposal.version }) {
            guard let orgID = signed.proposal.organizationID,
                  let policy = next.policies.first(where: { $0.organizationID == orgID && $0.groupID == signed.proposal.targetID }) else { continue }
            try ConsoleTrust.verify(signed, authority: policy.organizationAuthorityPublicKey, now: signed.proposal.expiresAt.addingTimeInterval(-1))
            let key = signed.proposal.targetID.uuidString
            guard signed.proposal.version >= (next.groupVersions[key] ?? 0) else { continue }
            next.groups[key] = Set(try ConsoleWire.decode([UUID].self, from: signed.proposal.payload)); next.groupVersions[key] = signed.proposal.version
        }
        if snapshot.instance.status == .revoked { next.binding?.status = .revoked }
        try Self.persist(next, at: url); state = next
    }
    public func authorize(_ proof: SignedInstanceAccessProof, peerCertificate: Data, now: Date = Date()) throws -> ConsoleAuthorizationContext {
        guard let binding = state.binding, binding.status == .active, let consoleKey = state.consolePublicKey,
              let grant = state.grants.first(where: { $0.instanceID == binding.id && $0.deviceID == proof.proof.deviceID && $0.organizationID == proof.proof.organizationID && $0.status == .active }) else { throw ConsoleTrustError.forbidden }
        var permissions: Set<InstancePermission>? = nil, projects: Set<String>? = nil
        if let organizationID = grant.organizationID {
            let policies = state.policies.filter { $0.organizationID == organizationID && (state.groups[$0.groupID.uuidString]?.contains(grant.accountID) ?? false) }
            let allowed = policies.reduce(into: Set<InstancePermission>()) { $0.formUnion($1.permissions) }
            permissions = grant.permissions.contains(.administer) ? allowed : grant.permissions.intersection(allowed)
            projects = policies.reduce(into: Set<String>()) { $0.formUnion($1.projectIDs) }
            guard !policies.isEmpty, permissions?.isEmpty == false else { throw ConsoleTrustError.forbidden }
        }
        return try ConsoleAuthorizationContext(proof: proof, consolePublicKey: consoleKey, grant: grant, instanceAuthority: state.identity.signingPublicKey, instanceID: binding.id, peerCertificate: peerCertificate, minimumVersion: state.minimumVersions[grant.id.uuidString] ?? 0, instanceOwnerID: binding.ownerID, effectivePermissions: permissions, effectiveProjectIDs: projects, now: now)
    }
    public func revoke(grantID: UUID) throws {
        var next = state
        guard let index = next.grants.firstIndex(where: { $0.id == grantID }) else { throw ConsoleTrustError.forbidden }
        next.grants[index].status = .revoked; next.grants[index].version += 1; next.minimumVersions[grantID.uuidString] = next.grants[index].version
        try Self.persist(next, at: url); state = next
    }
    public func unbind() throws {
        var next = state; next.binding?.status = .revoked
        for index in next.grants.indices { next.grants[index].status = .revoked; next.minimumVersions[next.grants[index].id.uuidString] = next.grants[index].version + 1 }
        try Self.persist(next, at: url); state = next
    }
    private static func persist(_ value: LocalConsoleState, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConsoleWire.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
