import Foundation

public struct UsageBreakdownGroup: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var calls: Int
    public var failures: Int
    public var argumentsTokens: Int
    public var resultTokens: Int
    public var replayTokens: Int
    public var schemaTokens: Int
    public var catalogTokens: Int
    public var tokenizerMeasurements: Int
    public var estimatedMeasurements: Int
    public var unavailableMeasurements: Int
    public var totalTokens: Int { argumentsTokens + resultTokens + replayTokens + schemaTokens + catalogTokens }
    public var averagePerCall: Double? { calls > 0 && unavailableMeasurements == 0 ? Double(argumentsTokens + resultTokens) / Double(calls) : nil }
    public var countingLabel: String {
        var labels: [String] = []
        if tokenizerMeasurements > 0 { labels.append("Local count") }
        if estimatedMeasurements > 0 { labels.append("Estimate") }
        if unavailableMeasurements > 0 { labels.append("No data") }
        return labels.isEmpty ? "No data" : labels.joined(separator: " · ")
    }
}

public struct UsageBreakdownCall: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var requestId: String
    public var channelId: String
    public var sessionId: String?
    public var agentId: String?
    public var tool: String
    public var serverId: String?
    public var skillId: String?
    public var ok: Bool?
    public var argumentsTokens: Int
    public var resultTokens: Int
    public var replayTokens: Int
    public var tokenizerMeasurements: Int
    public var estimatedMeasurements: Int
    public var unavailableMeasurements: Int
    public var createdAt: Date
    public var stableId: String { channelId + "|" + id }
}

public struct UsageBreakdownResponse: Codable, Sendable {
    public struct ProviderUsage: Codable, Sendable {
        public var prompt: Int
        public var completion: Int
        public var cachedInput: Int
        public var cacheCreationInput: Int
        public var reasoning: Int
        public var total: Int { prompt + completion }
    }
    public var collectionStartedAt: Date?
    public var requestCount: Int
    public var reportedRequestCount: Int
    public var completeRequestCount: Int
    public var providerUsage: ProviderUsage
    public var groups: [UsageBreakdownGroup]
    public var calls: [UsageBreakdownCall]
    public var nextCursor: String?
}

extension SloppyAPIClient {
    public func fetchUsageBreakdown(from: Date, to: Date, groupBy: String = "tool", groupId: String? = nil,
                                   cursor: String? = nil, provider: String? = nil, model: String? = nil,
                                   serverId: String? = nil) async throws -> UsageBreakdownResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let values: [(String, String?)] = [("from",formatter.string(from:from)),("to",formatter.string(from:to)),
            ("groupBy",groupBy),("groupId",groupId),("cursor",cursor),("provider",provider),("model",model),("serverId",serverId)]
        let query = values.compactMap { key,value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return key + "=" + BackendHTTPClient.encodeQueryValue(value)
        }.joined(separator:"&")
        return try await http.get("/v1/usage/breakdown?" + query)
    }
}
