import Foundation

extension SloppyAPIClient {
    public func fetchChatUsage(from: Date, to: Date) async throws -> [ChatUsageRecord] {
        try await ChatUsageLoader.load(from: from, to: to) { [self] start, end in
            try await fetchChatUsageWindow(from: start, to: end)
        }
    }

    private func fetchChatUsageWindow(from: Date, to: Date) async throws -> [ChatUsageRecord] {
        struct Response: Decodable { var items: [ChatUsageRecord] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = BackendHTTPClient.encodeQueryValue(formatter.string(from: from))
        let end = BackendHTTPClient.encodeQueryValue(formatter.string(from: to))
        let response: Response = try await http.get("/v1/token-usage?from=\(start)&to=\(end)")
        return response.items
    }
}
