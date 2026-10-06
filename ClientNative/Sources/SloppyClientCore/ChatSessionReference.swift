import Foundation

public struct ChatSessionReference: Codable, Sendable, Equatable, Hashable {
    public var agentId: String
    public var sessionId: String

    public init(agentId: String, sessionId: String) {
        self.agentId = agentId
        self.sessionId = sessionId
    }

    public func markdown(title: String) -> String {
        let label = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
        return "[@\(label)](\(DeepLink.session(agentId: agentId, sessionId: sessionId).url?.absoluteString ?? ""))"
    }

    public static func parseLinks(in text: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"sloppy://session\?[^\s<>\)\]]+"#) else { return [] }
        var seen = Set<Self>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                  case .session(let agentId, let sessionId) = DeepLink.parse(url) else { return nil }
            let reference = Self(agentId: agentId, sessionId: sessionId)
            return seen.insert(reference).inserted ? reference : nil
        }
    }
}

public struct ChatSessionPeerOrigin: Codable, Sendable, Equatable {
    public var agentId: String
    public var sessionId: String
    public var chainId: String
    public var depth: Int
}

extension SloppyAPIClient {
    public func fetchSessionMentions(query: String) async throws -> [ChatSessionSummary] {
        try await http.get("/v1/agent-sessions?includeWorkers=true&limit=50&query=\(BackendHTTPClient.encodeQueryValue(query))")
    }
}
