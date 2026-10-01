import Foundation

public enum ConsoleRole: String, Codable, Sendable { case owner, admin, member }
public enum ConsoleStatus: String, Codable, Sendable { case pending, active, revoked }
public enum InstancePermission: String, Codable, CaseIterable, Sendable {
    case read, write, runAgents = "run_agents", terminal, administer
}

public struct ConsoleAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var issuer: String
    public var subject: String
    public var email: String
    public var name: String
    public var personalSpaceID: UUID
    public init(id: UUID = UUID(), issuer: String, subject: String, email: String, name: String, personalSpaceID: UUID = UUID()) {
        self.id = id; self.issuer = issuer; self.subject = subject; self.email = email; self.name = name; self.personalSpaceID = personalSpaceID
    }
}

public struct ConsoleOrganization: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var ownerID: UUID
    public var authorityPublicKey: Data?
    public var ssoIssuer: String?
    public var ssoRequired: Bool
    public var version: Int
    public init(id: UUID = UUID(), name: String, ownerID: UUID) {
        self.id = id; self.name = name; self.ownerID = ownerID; authorityPublicKey = nil; ssoIssuer = nil; ssoRequired = false; version = 0
    }
}

public struct ConsoleMembership: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var organizationID: UUID
    public var accountID: UUID
    public var role: ConsoleRole
    public var status: ConsoleStatus
    public init(id: UUID = UUID(), organizationID: UUID, accountID: UUID, role: ConsoleRole, status: ConsoleStatus = .active) {
        self.id = id; self.organizationID = organizationID; self.accountID = accountID; self.role = role; self.status = status
    }
}

public struct ConsoleGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var organizationID: UUID
    public var name: String
    public var accountIDs: Set<UUID>
    public var version: Int
    public init(id: UUID = UUID(), organizationID: UUID, name: String) {
        self.id = id; self.organizationID = organizationID; self.name = name; accountIDs = []; version = 0
    }
}

public struct ConsoleDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID
    public var name: String
    public var signingPublicKey: Data
    public var certificateDER: Data
    public var status: ConsoleStatus
    public init(id: UUID = UUID(), accountID: UUID, name: String, signingPublicKey: Data, certificateDER: Data, status: ConsoleStatus = .pending) {
        self.id = id; self.accountID = accountID; self.name = name; self.signingPublicKey = signingPublicKey; self.certificateDER = certificateDER; self.status = status
    }
}

public struct InstanceBinding: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ownerID: UUID
    public var spaceID: UUID
    public var name: String
    public var authorityPublicKey: Data
    public var hostDeviceID: UUID
    public var hostCertificateFingerprint: String
    public var status: ConsoleStatus
    public var version: Int
    public init(id: UUID = UUID(), ownerID: UUID, spaceID: UUID, name: String, authorityPublicKey: Data, hostDeviceID: UUID, hostCertificateFingerprint: String = "", status: ConsoleStatus = .pending, version: Int = 0) {
        self.id = id; self.ownerID = ownerID; self.spaceID = spaceID; self.name = name; self.authorityPublicKey = authorityPublicKey; self.hostDeviceID = hostDeviceID; self.hostCertificateFingerprint = hostCertificateFingerprint; self.status = status; self.version = version
    }
}

public struct DeviceGrant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var instanceID: UUID
    public var deviceID: UUID
    public var accountID: UUID
    public var organizationID: UUID?
    public var signingPublicKey: Data
    public var certificateFingerprint: String
    public var permissions: Set<InstancePermission>
    public var projectIDs: Set<String>
    public var version: Int
    public var status: ConsoleStatus
    public var signedProposal: SignedAccessProposal
    public init(id: UUID, instanceID: UUID, deviceID: UUID, accountID: UUID, organizationID: UUID?, signingPublicKey: Data, certificateFingerprint: String, permissions: Set<InstancePermission>, projectIDs: Set<String>, version: Int, signedProposal: SignedAccessProposal) {
        self.id = id; self.instanceID = instanceID; self.deviceID = deviceID; self.accountID = accountID; self.organizationID = organizationID; self.signingPublicKey = signingPublicKey; self.certificateFingerprint = certificateFingerprint; self.permissions = permissions; self.projectIDs = projectIDs; self.version = version; status = .active; self.signedProposal = signedProposal
    }
}

public struct InstanceAccessPolicy: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var instanceID: UUID
    public var organizationID: UUID
    public var groupID: UUID
    public var organizationAuthorityPublicKey: Data
    public var permissions: Set<InstancePermission>
    public var projectIDs: Set<String>
    public var version: Int
    public var signedProposal: SignedAccessProposal
    public init(id: UUID, instanceID: UUID, organizationID: UUID, groupID: UUID, organizationAuthorityPublicKey: Data, permissions: Set<InstancePermission>, projectIDs: Set<String>, version: Int, signedProposal: SignedAccessProposal) {
        self.id = id; self.instanceID = instanceID; self.organizationID = organizationID; self.groupID = groupID; self.organizationAuthorityPublicKey = organizationAuthorityPublicKey; self.permissions = permissions; self.projectIDs = projectIDs; self.version = version; self.signedProposal = signedProposal
    }
}

/// The entire mutation is signed; no unsigned routing field may widen it.
public struct AccessProposal: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case bindInstance = "bind_instance", deviceGrant = "device_grant", groupMembers = "group_members", policy, organizationAuthority = "organization_authority", sso
    }
    public var id: UUID
    public var kind: Kind
    public var actorAccountID: UUID
    public var instanceID: UUID?
    public var organizationID: UUID?
    public var targetID: UUID
    public var version: Int
    public var expiresAt: Date
    public var payload: Data
    public init(id: UUID = UUID(), kind: Kind, actorAccountID: UUID, instanceID: UUID? = nil, organizationID: UUID? = nil, targetID: UUID, version: Int, expiresAt: Date, payload: Data) {
        self.id = id; self.kind = kind; self.actorAccountID = actorAccountID; self.instanceID = instanceID; self.organizationID = organizationID; self.targetID = targetID; self.version = version; self.expiresAt = Date(timeIntervalSince1970: floor(expiresAt.timeIntervalSince1970)); self.payload = payload
    }
}

public struct SignedAccessProposal: Codable, Equatable, Sendable {
    public var proposal: AccessProposal
    public var signingPublicKey: Data
    public var signature: Data
    public init(proposal: AccessProposal, signingPublicKey: Data, signature: Data) {
        self.proposal = proposal; self.signingPublicKey = signingPublicKey; self.signature = signature
    }
}

public struct GrantRequest: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var accountID: UUID
    public var signingPublicKey: Data
    public var certificateFingerprint: String
    public var organizationID: UUID?
    public var permissions: Set<InstancePermission>
    public var projectIDs: Set<String>
    public init(deviceID: UUID, accountID: UUID, signingPublicKey: Data, certificateFingerprint: String, organizationID: UUID? = nil, permissions: Set<InstancePermission>, projectIDs: Set<String> = []) {
        self.deviceID = deviceID; self.accountID = accountID; self.signingPublicKey = signingPublicKey; self.certificateFingerprint = certificateFingerprint; self.organizationID = organizationID; self.permissions = permissions; self.projectIDs = projectIDs
    }
}

public struct PolicyRequest: Codable, Equatable, Sendable {
    public var groupID: UUID
    public var organizationID: UUID
    public var organizationAuthorityPublicKey: Data
    public var permissions: Set<InstancePermission>
    public var projectIDs: Set<String>
    public init(groupID: UUID, organizationID: UUID, organizationAuthorityPublicKey: Data, permissions: Set<InstancePermission>, projectIDs: Set<String> = []) {
        self.groupID = groupID; self.organizationID = organizationID; self.organizationAuthorityPublicKey = organizationAuthorityPublicKey; self.permissions = permissions; self.projectIDs = projectIDs
    }
}

public struct InstanceAccessProof: Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var instanceID: UUID
    public var deviceID: UUID
    public var organizationID: UUID?
    public var certificateFingerprint: String
    public var grantVersion: Int
    public var issuedAt: Date
    public var expiresAt: Date
    public init(id: UUID = UUID(), accountID: UUID, instanceID: UUID, deviceID: UUID, organizationID: UUID?, certificateFingerprint: String, grantVersion: Int, issuedAt: Date = Date(), expiresAt: Date) {
        self.id = id; self.accountID = accountID; self.instanceID = instanceID; self.deviceID = deviceID; self.organizationID = organizationID; self.certificateFingerprint = certificateFingerprint; self.grantVersion = grantVersion; self.issuedAt = Date(timeIntervalSince1970: floor(issuedAt.timeIntervalSince1970)); self.expiresAt = Date(timeIntervalSince1970: floor(expiresAt.timeIntervalSince1970))
    }
}

public struct SignedInstanceAccessProof: Codable, Sendable {
    public var proof: InstanceAccessProof
    public var signature: Data
    public init(proof: InstanceAccessProof, signature: Data) { self.proof = proof; self.signature = signature }
}

public struct ConsoleEntitlement: Codable, Sendable {
    public var plus: Bool = false
    public var maximumInstances: Int = 5
    public var maximumDevices: Int = 10
    public var monthlyRelayBytes: Int64 = 10 * 1024 * 1024 * 1024
    public init() {}
}

public enum ConsoleWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
