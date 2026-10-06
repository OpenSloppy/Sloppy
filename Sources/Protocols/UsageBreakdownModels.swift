import Foundation

public enum UsageCountingMethod: String, Codable, Sendable, CaseIterable {
    case tokenizer, estimate, unavailable
}

public enum UsageComponentKind: String, Codable, Sendable {
    case argumentsOutput, argumentsInput, resultInput, toolSchema, skillCatalog
}

/// Metadata and counts only; request and tool payloads are never persisted here.
public struct UsageComponentRecord: Codable, Sendable, Equatable {
    public var id: String
    public var requestId: String
    public var toolCallId: String?
    public var tool: String?
    public var serverId: String?
    public var skillId: String?
    public var kind: UsageComponentKind
    public var tokens: Int?
    public var method: UsageCountingMethod
    public var encoding: String?
    public var repeated: Bool = false

    public init(id: String = UUID().uuidString, requestId: String, toolCallId: String? = nil,
                tool: String? = nil, serverId: String? = nil, skillId: String? = nil,
                kind: UsageComponentKind, tokens: Int?, method: UsageCountingMethod, encoding: String? = nil) {
        self.id = id; self.requestId = requestId; self.toolCallId = toolCallId
        self.tool = tool; self.serverId = serverId; self.skillId = skillId; self.kind = kind
        self.tokens = tokens; self.method = method; self.encoding = encoding
    }
}

public struct UsageToolCallRecord: Codable, Sendable, Equatable {
    public var id: String
    public var requestId: String
    public var channelId: String
    public var sessionId: String?
    public var agentId: String?
    public var tool: String
    public var serverId: String?
    public var skillId: String?
    public var ok: Bool?
    public var generated: Bool
    public var argumentsTokens: Int = 0
    public var resultTokens: Int = 0
    public var replayTokens: Int = 0
    public var tokenizerMeasurements: Int = 0
    public var estimatedMeasurements: Int = 0
    public var unavailableMeasurements: Int = 0
    public var createdAt: Date
    public init(id: String, requestId: String, channelId: String, sessionId: String? = nil,
                agentId: String? = nil, tool: String, serverId: String? = nil, skillId: String? = nil,
                ok: Bool? = nil, generated: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.requestId = requestId; self.channelId = channelId
        self.sessionId = sessionId; self.agentId = agentId; self.tool = tool
        self.serverId = serverId; self.skillId = skillId; self.ok = ok; self.generated = generated; self.createdAt = createdAt
    }
}

public struct UsageRequestRecord: Codable, Sendable, Equatable {
    public var id: String
    public var channelId: String
    public var sessionId: String?
    public var agentId: String?
    public var provider: String
    public var model: String
    public var createdAt: Date
    public var usage: TokenUsage?
    public var failed: Bool
    public var complete: Bool
    public var components: [UsageComponentRecord]
    public var calls: [UsageToolCallRecord]
    public init(id: String = UUID().uuidString, channelId: String, sessionId: String? = nil,
                agentId: String? = nil, provider: String, model: String, createdAt: Date = Date(),
                usage: TokenUsage? = nil, failed: Bool = false, complete: Bool = true,
                components: [UsageComponentRecord] = [], calls: [UsageToolCallRecord] = []) {
        self.id = id; self.channelId = channelId; self.sessionId = sessionId; self.agentId = agentId
        self.provider = provider; self.model = model; self.createdAt = createdAt; self.usage = usage
        self.failed = failed; self.complete = complete; self.components = components; self.calls = calls
    }
}

public struct UsageBreakdownQuery: Sendable {
    public var from: Date?
    public var to: Date?
    public var channelId: String?
    public var sessionId: String?
    public var provider: String?
    public var model: String?
    public var serverId: String?
    public var groupBy: String
    public var groupId: String?
    public var cursor: String?
    public var limit: Int
    public init(from: Date? = nil, to: Date? = nil, channelId: String? = nil, sessionId: String? = nil,
                provider: String? = nil, model: String? = nil, serverId: String? = nil,
                groupBy: String = "tool", groupId: String? = nil, cursor: String? = nil, limit: Int = 50) {
        self.from = from; self.to = to; self.channelId = channelId; self.sessionId = sessionId
        self.provider = provider; self.model = model; self.serverId = serverId
        self.groupBy = groupBy; self.groupId = groupId; self.cursor = cursor; self.limit = min(200, max(1, limit))
    }
}

public struct UsageBreakdownGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var calls = 0
    public var failures = 0
    public var argumentsTokens = 0
    public var resultTokens = 0
    public var replayTokens = 0
    public var schemaTokens = 0
    public var catalogTokens = 0
    public var tokenizerMeasurements = 0
    public var estimatedMeasurements = 0
    public var unavailableMeasurements = 0
    public var totalTokens: Int { argumentsTokens + resultTokens + replayTokens + schemaTokens + catalogTokens }
    public var averagePerCall: Double? { calls > 0 && unavailableMeasurements == 0 ? Double(argumentsTokens + resultTokens) / Double(calls) : nil }
    public init(id: String) { self.id = id }
}

public struct UsageBreakdownResponse: Codable, Sendable {
    public var collectionStartedAt: Date?
    public var requestCount: Int
    public var reportedRequestCount: Int
    public var completeRequestCount: Int
    public var providerUsage: TokenUsage
    public var groups: [UsageBreakdownGroup]
    public var calls: [UsageToolCallRecord]
    public var nextCursor: String?
    public init(collectionStartedAt: Date?, requestCount: Int, reportedRequestCount: Int,
                completeRequestCount: Int, providerUsage: TokenUsage, groups: [UsageBreakdownGroup],
                calls: [UsageToolCallRecord], nextCursor: String? = nil) {
        self.collectionStartedAt = collectionStartedAt; self.requestCount = requestCount
        self.reportedRequestCount = reportedRequestCount; self.completeRequestCount = completeRequestCount
        self.providerUsage = providerUsage; self.groups = groups; self.calls = calls; self.nextCursor = nextCursor
    }
}
