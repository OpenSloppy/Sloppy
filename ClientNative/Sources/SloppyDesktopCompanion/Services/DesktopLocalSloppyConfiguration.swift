import Foundation
import SloppyClientCore

struct DesktopLocalSloppyConfiguration: Equatable, Sendable {
    static let desktopBundleID = "team.sloppy.client"
    let baseURL: URL
    let tlsFingerprint: String?
    let defaultAgentID: String?

    static func load() throws -> Self {
        let keys = ["client_server_host", "client_server_port", "client_server_scheme",
                    "client_saved_servers", "client_last_agent_id"]
        let domain = desktopBundleID as CFString
        // Refresh the other application's persisted settings, without writing to its domain.
        CFPreferencesAppSynchronize(domain)
        let preferences = CFPreferencesCopyMultiple(keys as CFArray, domain,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        return try Self(preferences: preferences)
    }

    init(preferences: [String: Any]) throws {
        let savedServers = (preferences["client_saved_servers"] as? Data)
            .flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
        let host = preferences["client_server_host"] as? String ?? "localhost"
        let savedPort = preferences["client_server_port"] as? Int ?? 25101
        let port = savedPort == 0 ? 25101 : savedPort
        let scheme = preferences["client_server_scheme"] as? String ?? "http"
        if ServerAddress.isLoopbackHost(host), (1...65535).contains(port) {
            let url = ServerAddress(scheme: scheme, host: host, port: port).baseURL
            baseURL = url
            tlsFingerprint = savedServers.first { $0.baseURL == url }?.tlsFingerprint
            defaultAgentID = preferences["client_last_agent_id"] as? String
        } else if let local = savedServers.last(where: {
            ServerAddress.isLoopbackHost($0.host) && (1...65535).contains($0.port)
        }) {
            baseURL = local.baseURL
            tlsFingerprint = local.tlsFingerprint
            defaultAgentID = nil
        } else {
            throw DesktopLocalSloppyError.noLocalInstance
        }
    }
}

enum DesktopLocalSloppyError: LocalizedError {
    case noLocalInstance

    var errorDescription: String? {
        "Select a local instance in the Sloppy desktop app, then reconnect here."
    }
}
