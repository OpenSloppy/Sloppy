import Crypto
import Foundation

public enum ConsoleTrustError: Error, Equatable, Sendable {
    case invalidSignature, expired, wrongContext, staleVersion, forbidden, invalidConfiguration
}

public enum ConsoleTrust {
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func proposalBytes(_ proposal: AccessProposal) throws -> Data {
        Data("sloppy-console-proposal-v1\n".utf8) + (try ConsoleWire.encode(proposal))
    }
    public static func sign(_ proposal: AccessProposal, privateKey: Data) throws -> SignedAccessProposal {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return SignedAccessProposal(proposal: proposal, signingPublicKey: key.publicKey.rawRepresentation, signature: try key.signature(for: proposalBytes(proposal)))
    }
    public static func verify(_ signed: SignedAccessProposal, authority: Data, now: Date = Date()) throws {
        guard signed.proposal.expiresAt > now else { throw ConsoleTrustError.expired }
        guard signed.signingPublicKey == authority,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: authority),
              key.isValidSignature(signed.signature, for: try proposalBytes(signed.proposal)) else { throw ConsoleTrustError.invalidSignature }
    }
    public static func proofBytes(_ proof: InstanceAccessProof) throws -> Data {
        Data("sloppy-console-access-v1\n".utf8) + (try ConsoleWire.encode(proof))
    }
    public static func signProof(_ proof: InstanceAccessProof, privateKey: Data) throws -> SignedInstanceAccessProof {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return SignedInstanceAccessProof(proof: proof, signature: try key.signature(for: proofBytes(proof)))
    }
    public static func verifyProof(_ signed: SignedInstanceAccessProof, consolePublicKey: Data, grant: DeviceGrant, instanceID: UUID, peerCertificate: Data, minimumVersion: Int, now: Date = Date()) throws {
        let proof = signed.proof
        guard proof.issuedAt <= now.addingTimeInterval(30), proof.expiresAt > now,
              proof.expiresAt.timeIntervalSince(proof.issuedAt) > 0,
              proof.expiresAt.timeIntervalSince(proof.issuedAt) <= 300 else { throw ConsoleTrustError.expired }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: consolePublicKey),
              key.isValidSignature(signed.signature, for: try proofBytes(proof)) else { throw ConsoleTrustError.invalidSignature }
        guard grant.status == .active, proof.instanceID == instanceID, grant.instanceID == instanceID,
              proof.deviceID == grant.deviceID, proof.accountID == grant.accountID,
              proof.organizationID == grant.organizationID,
              proof.certificateFingerprint == grant.certificateFingerprint,
              fingerprint(peerCertificate) == grant.certificateFingerprint else { throw ConsoleTrustError.wrongContext }
        guard proof.grantVersion == grant.version, grant.version >= minimumVersion else { throw ConsoleTrustError.staleVersion }
    }
}

/// Created only after the proof, TLS peer and locally pinned grant are verified.
public struct ConsoleAuthorizationContext: Sendable {
    public let accountID: UUID
    public let organizationID: UUID?
    public let instanceID: UUID
    public let deviceID: UUID
    public let permissions: Set<InstancePermission>
    public let projectIDs: Set<String>
    public let expiresAt: Date
    public init(proof: SignedInstanceAccessProof, consolePublicKey: Data, grant: DeviceGrant, instanceAuthority: Data, instanceID: UUID, peerCertificate: Data, minimumVersion: Int, effectivePermissions: Set<InstancePermission>? = nil, effectiveProjectIDs: Set<String>? = nil, now: Date = Date()) throws {
        // Approval expiry bounds issuance, not the life of the persisted grant.
        try ConsoleTrust.verify(grant.signedProposal, authority: instanceAuthority, now: grant.signedProposal.proposal.expiresAt.addingTimeInterval(-1))
        let proposal = grant.signedProposal.proposal
        let request = try ConsoleWire.decode(GrantRequest.self, from: proposal.payload)
        guard proposal.kind == .deviceGrant, proposal.instanceID == instanceID,
              proposal.targetID == grant.id, proposal.version == grant.version,
              request.accountID == grant.accountID, request.signingPublicKey == grant.signingPublicKey,
              request.certificateFingerprint == grant.certificateFingerprint,
              request.deviceID == grant.deviceID, request.organizationID == grant.organizationID,
              request.permissions == grant.permissions, request.projectIDs == grant.projectIDs else { throw ConsoleTrustError.wrongContext }
        try ConsoleTrust.verifyProof(proof, consolePublicKey: consolePublicKey, grant: grant, instanceID: instanceID, peerCertificate: peerCertificate, minimumVersion: minimumVersion, now: now)
        accountID = grant.accountID; organizationID = grant.organizationID; self.instanceID = instanceID; deviceID = grant.deviceID
        if let effectivePermissions, !grant.permissions.contains(.administer), !effectivePermissions.isSubset(of: grant.permissions) { throw ConsoleTrustError.forbidden }
        permissions = effectivePermissions ?? grant.permissions
        if let effectiveProjectIDs { projectIDs = grant.permissions.contains(.administer) ? effectiveProjectIDs : grant.projectIDs.intersection(effectiveProjectIDs) }
        else { projectIDs = grant.projectIDs }
        expiresAt = proof.proof.expiresAt
    }
    public func require(_ permission: InstancePermission, projectID: String? = nil, now: Date = Date()) throws {
        guard expiresAt > now else { throw ConsoleTrustError.expired }
        guard permissions.contains(permission) || permissions.contains(.administer) else { throw ConsoleTrustError.forbidden }
        if !permissions.contains(.administer) {
            guard let projectID, projectIDs.contains(projectID) else { throw ConsoleTrustError.forbidden }
        }
    }
}
