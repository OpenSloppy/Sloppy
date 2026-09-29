import Foundation

public enum DeepLink: Equatable, Sendable {
    case connect(host: String, port: Int, label: String?)
    case open
    case project(id: String)
    case task(projectId: String, taskId: String)
    case session(agentId: String, sessionId: String)
    case proactivity(agentId: String, findingId: String?)
    case dictationToggle(agentId: String, sessionId: String)

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == "sloppy" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        switch url.host {
        case "connect":
            let items = components.queryItems ?? []
            guard let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty else { return nil }
            let portString = items.first(where: { $0.name == "port" })?.value
            guard let address = ServerAddress.parse(host: host, port: portString) else { return nil }
            let label = items.first(where: { $0.name == "label" })?.value
            return .connect(host: address.host, port: address.port, label: label)
        case "open":
            return .open
        case "project":
            guard let id = components.nonEmptyQueryValue(named: "id") else { return nil }
            return .project(id: id)
        case "task":
            guard let projectId = components.nonEmptyQueryValue(named: "project"),
                  let taskId = components.nonEmptyQueryValue(named: "id") else { return nil }
            return .task(projectId: projectId, taskId: taskId)
        case "session":
            guard let agentId = components.nonEmptyQueryValue(named: "agent"),
                  let sessionId = components.nonEmptyQueryValue(named: "id") else { return nil }
            return .session(agentId: agentId, sessionId: sessionId)
        case "proactivity":
            guard let agentId = components.nonEmptyQueryValue(named: "agent") else { return nil }
            return .proactivity(agentId: agentId, findingId: components.nonEmptyQueryValue(named: "id"))
        case "dictation" where url.path == "/toggle":
            guard let agentId = components.nonEmptyQueryValue(named: "agent"),
                  let sessionId = components.nonEmptyQueryValue(named: "session") else { return nil }
            return .dictationToggle(agentId: agentId, sessionId: sessionId)
        default:
            return nil
        }
    }

    public var serverURL: URL? {
        switch self {
        case .connect(let host, let port, _):
            return ServerAddress(host: host, port: port).baseURL
        case .open, .project, .task, .session, .proactivity, .dictationToggle:
            return nil
        }
    }

    public var savedServer: SavedServer? {
        switch self {
        case .connect(let host, let port, let label):
            return SavedServer(
                label: label ?? "Sloppy @ \(host)",
                host: host,
                port: port,
                isAutoDiscovered: false
            )
        case .open, .project, .task, .session, .proactivity, .dictationToggle:
            return nil
        }
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "sloppy"

        switch self {
        case .connect(let host, let port, let label):
            components.host = "connect"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                label.map { URLQueryItem(name: "label", value: $0) },
            ].compactMap { $0 }
        case .open:
            components.host = "open"
        case .project(let id):
            components.host = "project"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .task(let projectId, let taskId):
            components.host = "task"
            components.queryItems = [
                URLQueryItem(name: "project", value: projectId),
                URLQueryItem(name: "id", value: taskId),
            ]
        case .session(let agentId, let sessionId):
            components.host = "session"
            components.queryItems = [
                URLQueryItem(name: "agent", value: agentId),
                URLQueryItem(name: "id", value: sessionId),
            ]
        case .dictationToggle(let agentId, let sessionId):
            components.host = "dictation"
            components.path = "/toggle"
            components.queryItems = [
                URLQueryItem(name: "agent", value: agentId),
                URLQueryItem(name: "session", value: sessionId),
            ]
        case .proactivity(let agentId, let findingId):
            components.host = "proactivity"
            components.queryItems = [URLQueryItem(name: "agent", value: agentId), findingId.map { URLQueryItem(name: "id", value: $0) }].compactMap { $0 }
        }

        return components.url
    }
}

private extension URLComponents {
    func nonEmptyQueryValue(named name: String) -> String? {
        guard let value = queryItems?.first(where: { $0.name == name })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
