import Foundation
import SloppyConsoleProtocol

/// Transfers a host pin from a trusted screen. Access still requires a Console proof.
public struct ConsoleConnectionCode: Equatable, Sendable, Identifiable {
    public let instanceID: UUID
    public let hostDeviceID: UUID
    public let fingerprint: String
    public var id: UUID { instanceID }

    public init?(instance: InstanceBinding) {
        guard instance.status == .active,
              let fingerprint = Self.normalizeFingerprint(instance.hostCertificateFingerprint) else { return nil }
        self.instanceID = instance.id
        self.hostDeviceID = instance.hostDeviceID
        self.fingerprint = fingerprint
    }

    private init(instanceID: UUID, hostDeviceID: UUID, fingerprint: String) {
        self.instanceID = instanceID
        self.hostDeviceID = hostDeviceID
        self.fingerprint = fingerprint
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "sloppy"
        components.host = "console-connect"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "instance", value: instanceID.uuidString),
            URLQueryItem(name: "host", value: hostDeviceID.uuidString),
            URLQueryItem(name: "fingerprint", value: fingerprint),
        ]
        return components.url
    }

    public static func parse(_ url: URL) -> Self? {
        guard url.absoluteString.count <= 1024,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sloppy", components.host == "console-connect",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 4,
              Set(items.map(\.name)) == Set(["v", "instance", "host", "fingerprint"]),
              items.first(where: { $0.name == "v" })?.value == "1",
              let rawInstance = items.first(where: { $0.name == "instance" })?.value,
              let instanceID = UUID(uuidString: rawInstance),
              let rawHost = items.first(where: { $0.name == "host" })?.value,
              let hostDeviceID = UUID(uuidString: rawHost),
              let fingerprint = normalizeFingerprint(items.first(where: { $0.name == "fingerprint" })?.value)
        else { return nil }
        return Self(instanceID: instanceID, hostDeviceID: hostDeviceID, fingerprint: fingerprint)
    }

    public func matches(_ instance: InstanceBinding) -> Bool {
        instance.status == .active && instance.id == instanceID
            && instance.hostDeviceID == hostDeviceID
            && Self.normalizeFingerprint(instance.hostCertificateFingerprint) == fingerprint
    }

    public static func normalizeFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return normalized
    }
}
