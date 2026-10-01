import Foundation

public struct ConsoleSSOSettings: Codable, Equatable, Sendable {
    public var issuer: String
    public var required: Bool
    public init(issuer: String, required: Bool) { self.issuer = issuer; self.required = required }
}

public struct ConsoleTrustSnapshot: Codable, Sendable {
    public var instance: InstanceBinding
    public var devices: [ConsoleDevice]
    public var grants: [DeviceGrant]
    public var policies: [InstanceAccessPolicy]
    public var signedChanges: [SignedAccessProposal]
    public init(instance: InstanceBinding, devices: [ConsoleDevice], grants: [DeviceGrant], policies: [InstanceAccessPolicy], signedChanges: [SignedAccessProposal]) {
        self.instance = instance; self.devices = devices; self.grants = grants; self.policies = policies; self.signedChanges = signedChanges
    }
}


public struct ConsoleAccountMigration: Codable, Sendable {
    public var accountByLocalUserID: [String: UUID]
    public var backupPairingConfirmed: Bool
    public init(accountByLocalUserID: [String: UUID], backupPairingConfirmed: Bool) { self.accountByLocalUserID = accountByLocalUserID; self.backupPairingConfirmed = backupPairingConfirmed }
}
