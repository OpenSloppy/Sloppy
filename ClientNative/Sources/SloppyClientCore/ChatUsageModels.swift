import Foundation

public struct ChatUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var channelId: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cachedInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var reasoningTokens: Int?
    public var createdAt: Date

    public init(id: String, channelId: String, promptTokens: Int, completionTokens: Int,
                totalTokens: Int, cachedInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil,
                reasoningTokens: Int? = nil, createdAt: Date) {
        self.id = id
        self.channelId = channelId
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.reasoningTokens = reasoningTokens
        self.createdAt = createdAt
    }
}

public struct ChatUsageSummary: Sendable, Identifiable {
    public var id: String
    public var requestCount = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var totalTokens = 0
    public var cachedTokens = 0
    public var cacheCreationTokens = 0
    public var reasoningTokens = 0

    public static func grouped(_ records: [ChatUsageRecord]) -> [ChatUsageSummary] {
        var summaries: [String: ChatUsageSummary] = [:]
        var seen: Set<String> = []
        for record in records where seen.insert(record.id).inserted {
            var summary = summaries[record.channelId] ?? ChatUsageSummary(id: record.channelId)
            summary.requestCount += 1
            summary.inputTokens += record.promptTokens
            summary.outputTokens += record.completionTokens
            summary.totalTokens += record.totalTokens
            summary.cachedTokens += record.cachedInputTokens ?? 0
            summary.cacheCreationTokens += record.cacheCreationInputTokens ?? 0
            summary.reasoningTokens += record.reasoningTokens ?? 0
            summaries[record.channelId] = summary
        }
        return summaries.values.sorted {
            $0.totalTokens == $1.totalTokens ? $0.id < $1.id : $0.totalTokens > $1.totalTokens
        }
    }
}

/// The existing endpoint returns at most 1,000 records. Split saturated time windows
/// and deduplicate their inclusive boundaries rather than silently understating usage.
public enum ChatUsageLoader {
    public enum LoadError: LocalizedError {
        case saturatedWindow

        public var errorDescription: String? {
            "The server returned too many usage records in a single second. Complete statistics require a server update."
        }
    }

    public static func load(
        from: Date, to: Date,
        fetch: @Sendable (Date, Date) async throws -> [ChatUsageRecord]
    ) async throws -> [ChatUsageRecord] {
        try Task.checkCancellation()
        let records = try await fetch(from, to)
        guard records.count >= 1_000 else { return records }
        guard to.timeIntervalSince(from) > 1 else { throw LoadError.saturatedWindow }
        let midpoint = Date(timeIntervalSince1970: ((from.timeIntervalSince1970 + to.timeIntervalSince1970) / 2).rounded(.down))
        let earlier = try await load(from: from, to: midpoint, fetch: fetch)
        let later = try await load(from: midpoint, to: to, fetch: fetch)
        var seen: Set<String> = []
        return (earlier + later).filter { seen.insert($0.id).inserted }
    }
}
