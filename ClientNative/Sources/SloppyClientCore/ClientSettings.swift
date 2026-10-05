import Foundation
import Observation
import SloppyRemoteProtocol

@Observable
@MainActor
public final class ClientSettings {
    private enum Keys {
        static let serverHost = "client_server_host"
        static let serverPort = "client_server_port"
        static let serverScheme = "client_server_scheme"
        static let accentColorHex = "client_accent_color_hex"
        static let colorScheme = "client_color_scheme"
        static let chatSidebarMode = "client_chat_sidebar_mode"
        static let projectOrderIDs = "client_project_order_ids"
        static let projectModeSections = "client_project_mode_sections"
        static let windowCloseBehavior = "client_window_close_behavior"
        static let lastAgentId = "client_last_agent_id"
        static let lastProjectId = "client_last_project_id"
        static let lastSessionId = "client_last_session_id"
        static let pinnedSessionIds = "client_pinned_session_ids"
        static let archivedSessionIds = "client_archived_session_ids"
        static let viewedSessionResultEvents = "client_viewed_session_result_events"
        static let savedServers = "client_saved_servers"
        static let meshTargetNodeId = "client_mesh_target_node_id"
        static let instanceSelection = "client_instance_selection"
    }

    public var serverHost: String {
        didSet { UserDefaults.standard.set(serverHost, forKey: Keys.serverHost) }
    }

    public var serverPort: Int {
        didSet { UserDefaults.standard.set(serverPort, forKey: Keys.serverPort) }
    }

    public var serverScheme: String {
        didSet { UserDefaults.standard.set(serverScheme, forKey: Keys.serverScheme) }
    }

    public var accentColorHex: String {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: Keys.accentColorHex) }
    }

    public var colorScheme: ClientColorScheme {
        didSet { UserDefaults.standard.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }

    public var chatSidebarMode: ChatSidebarListMode {
        didSet { UserDefaults.standard.set(chatSidebarMode.rawValue, forKey: Keys.chatSidebarMode) }
    }

    public var projectOrderIDs: [String] {
        didSet { UserDefaults.standard.set(projectOrderIDs, forKey: Keys.projectOrderIDs) }
    }

    public var hiddenSidebarItems: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenSidebarItems).sorted(), forKey: "client_hidden_sidebar_items") }
    }

    public var projectColors: [String: String] {
        didSet { UserDefaults.standard.set(projectColors, forKey: "client_project_colors") }
    }

    public var chatColors: [String: String] {
        didSet { UserDefaults.standard.set(chatColors, forKey: "client_chat_colors") }
    }

    public var projectModeSections: [String: String] {
        didSet { UserDefaults.standard.set(projectModeSections, forKey: Keys.projectModeSections) }
    }

    public var windowCloseBehavior: ClientWindowCloseBehavior {
        didSet { UserDefaults.standard.set(windowCloseBehavior.rawValue, forKey: Keys.windowCloseBehavior) }
    }

    public var lastAgentId: String? {
        didSet { UserDefaults.standard.set(lastAgentId, forKey: Keys.lastAgentId) }
    }

    public var lastProjectId: String? {
        didSet { UserDefaults.standard.set(lastProjectId, forKey: Keys.lastProjectId) }
    }

    public var lastSessionId: String? {
        didSet { UserDefaults.standard.set(lastSessionId, forKey: Keys.lastSessionId) }
    }

    public var pinnedSessionIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(pinnedSessionIds).sorted(), forKey: Keys.pinnedSessionIds)
        }
    }

    public var archivedSessionIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(archivedSessionIds).sorted(), forKey: Keys.archivedSessionIds)
        }
    }

    public var viewedSessionResultEvents: [String: String] {
        didSet { UserDefaults.standard.set(viewedSessionResultEvents, forKey: Keys.viewedSessionResultEvents) }
    }

    public var meshTargetNodeId: String? {
        didSet {
            UserDefaults.standard.set(meshTargetNodeId, forKey: Keys.meshTargetNodeId)
        }
    }

    public var savedServers: [SavedServer] {
        didSet {
            if let data = try? JSONEncoder().encode(savedServers) {
                UserDefaults.standard.set(data, forKey: Keys.savedServers)
            }
        }
    }

    public var instanceSelection: SloppyInstanceSelection {
        didSet {
            if let data = try? JSONEncoder().encode(instanceSelection) {
                UserDefaults.standard.set(data, forKey: Keys.instanceSelection)
            }
        }
    }

    public var discoveredInstances: [SloppyInstance] = []
    public var unverifiedConsoleHostIDs: Set<UUID> = []

    public var baseURL: URL {
        ServerAddress(scheme: serverScheme, host: serverHost, port: serverPort).baseURL
    }

    public var activeServer: SavedServer? {
        savedServers.first {
            $0.scheme == serverScheme && $0.host == serverHost && $0.port == serverPort
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        serverHost = defaults.string(forKey: Keys.serverHost) ?? "localhost"
        serverPort = defaults.integer(forKey: Keys.serverPort).nonZero ?? 25101
        serverScheme = defaults.string(forKey: Keys.serverScheme) == "https" ? "https" : "http"
        accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? "#FF2D6F"
        colorScheme = defaults
            .string(forKey: Keys.colorScheme)
            .flatMap(ClientColorScheme.init(rawValue:)) ?? .dark
        chatSidebarMode = defaults
            .string(forKey: Keys.chatSidebarMode)
            .flatMap(ChatSidebarListMode.init(rawValue:)) ?? .allChats
        hiddenSidebarItems = Set(defaults.stringArray(forKey: "client_hidden_sidebar_items") ?? [])
        projectColors = defaults.dictionary(forKey: "client_project_colors") as? [String: String] ?? [:]
        chatColors = defaults.dictionary(forKey: "client_chat_colors") as? [String: String] ?? [:]
        projectOrderIDs = defaults.stringArray(forKey: Keys.projectOrderIDs) ?? []
        projectModeSections = defaults.dictionary(forKey: Keys.projectModeSections) as? [String: String] ?? [:]
        windowCloseBehavior = defaults
            .string(forKey: Keys.windowCloseBehavior)
            .flatMap(ClientWindowCloseBehavior.init(rawValue:)) ?? .keepProcess
        lastAgentId = defaults.string(forKey: Keys.lastAgentId)
        lastProjectId = defaults.string(forKey: Keys.lastProjectId)
        lastSessionId = defaults.string(forKey: Keys.lastSessionId)
        pinnedSessionIds = Set(defaults.stringArray(forKey: Keys.pinnedSessionIds) ?? [])
        archivedSessionIds = Set(defaults.stringArray(forKey: Keys.archivedSessionIds) ?? [])
        viewedSessionResultEvents = defaults.dictionary(forKey: Keys.viewedSessionResultEvents) as? [String: String] ?? [:]

        if let data = defaults.data(forKey: Keys.savedServers),
           let servers = try? JSONDecoder().decode([SavedServer].self, from: data) {
            savedServers = servers
        } else {
            savedServers = []
        }

        meshTargetNodeId = defaults.string(forKey: Keys.meshTargetNodeId)
        if let data = defaults.data(forKey: Keys.instanceSelection),
           let selection = try? JSONDecoder().decode(SloppyInstanceSelection.self, from: data) {
            instanceSelection = selection
        } else {
            instanceSelection = .all
        }
    }

    public func useServer(_ server: SavedServer) {
        serverScheme = server.scheme
        serverHost = server.host
        serverPort = server.port
        ClientTLSFingerprintStore.set(server.tlsFingerprint, for: server.baseURL)
        if !savedServers.contains(where: { $0.id == server.id }) {
            savedServers.append(server)
        }
    }

    public func installMeshTopology(_ topology: ClientMeshTopology, coordinatorBaseURL: URL) {
        discoveredInstances = topology.instances(coordinatorBaseURL: coordinatorBaseURL)
        if case .instance(let selectedID) = instanceSelection,
           !discoveredInstances.contains(where: { $0.id == selectedID }) {
            instanceSelection = .all
        }
    }

    public func installLocalInstance(baseURL: URL, name: String? = nil) {
        let instance = SloppyInstance(
            id: "local:\(baseURL.absoluteString)",
            name: name ?? baseURL.host ?? "Local Sloppy",
            endpoint: .direct(baseURL: baseURL),
            status: .online,
            isLocal: true
        )
        discoveredInstances = [instance]
    }

    public func installManagedHosts(_ hosts: [RemoteDevice], relayURL: URL) {
        let existing = discoveredInstances.filter {
            if case .managed = $0.endpoint { return false }
            return true
        }
        let managed = hosts.filter { $0.kind == .host && $0.status == .active }
            .map { host in
                SloppyInstance(
                    id: "managed:\(host.spaceID):\(host.id)",
                    name: host.name,
                    endpoint: .managed(relayURL: relayURL, targetDeviceID: host.id),
                    status: host.online == true ? .online : .offline,
                    isLocal: false
                )
            }
        discoveredInstances = existing + managed
        if selectedInstance == nil, !existing.contains(where: \.isLocal),
           let first = managed.first {
            instanceSelection = .instance(first.id)
        }
    }

    public func installConsoleInstances(_ instances: [InstanceBinding], unverifiedHostIDs: Set<UUID>, relayURL: URL) {
        unverifiedConsoleHostIDs = unverifiedHostIDs
        let hosts = CloudServerSelection.activeInstances(instances).map { instance in
            RemoteDevice(id: instance.hostDeviceID, spaceID: instance.spaceID, principalID: instance.ownerID,
                         kind: .host, name: instance.name, signingPublicKey: instance.authorityPublicKey,
                         encryptionPublicKey: Data(), encryptionKeySignature: Data(),
                         capabilities: ["console.remote.v2"], online: true)
        }
        let selection = instanceSelection
        installManagedHosts(hosts, relayURL: relayURL)
        if selection == .all {
            instanceSelection = .all
        } else if case .instance(let id) = selection,
                  !discoveredInstances.contains(where: { $0.id == id }) {
            instanceSelection = .all
        }
    }

    public func requiresConsoleVerification(_ instance: SloppyInstance) -> Bool {
        guard case .managed(_, let hostID) = instance.endpoint else { return false }
        return unverifiedConsoleHostIDs.contains(hostID)
    }

    public var selectedInstance: SloppyInstance? {
        guard case .instance(let id) = instanceSelection else { return nil }
        return discoveredInstances.first { $0.id == id }
    }

    public var activeInstanceEndpoint: SloppyInstanceEndpoint {
        selectedInstance?.endpoint
            ?? discoveredInstances.first(where: \.isLocal)?.endpoint
            ?? discoveredInstances.first(where: { !requiresConsoleVerification($0) })?.endpoint
            ?? .direct(baseURL: baseURL)
    }

    public var instanceDirectoryKey: String {
        instanceSelection.instanceID ?? "all"
    }

    public func isSessionPinned(_ sessionId: String) -> Bool {
        pinnedSessionIds.contains(sessionId)
    }

    public func setSessionPinned(_ sessionId: String, isPinned: Bool) {
        if isPinned {
            pinnedSessionIds.insert(sessionId)
        } else {
            pinnedSessionIds.remove(sessionId)
        }
    }

    public func isSessionArchived(_ sessionId: String) -> Bool {
        archivedSessionIds.contains(sessionId)
    }

    public func setSessionArchived(_ sessionId: String, isArchived: Bool) {
        if isArchived {
            archivedSessionIds.insert(sessionId)
            pinnedSessionIds.remove(sessionId)
        } else {
            archivedSessionIds.remove(sessionId)
        }
    }
}

public enum ClientColorScheme: String, Codable, Sendable, Equatable, CaseIterable {
    case light
    case dark
}

public enum ClientWindowCloseBehavior: String, Codable, Sendable, Equatable, CaseIterable {
    case keepProcess = "keep_process"
    case quitOnLastWindow = "quit_on_last_window"
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
