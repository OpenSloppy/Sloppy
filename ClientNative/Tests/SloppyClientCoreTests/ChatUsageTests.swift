import Foundation
import Testing
@testable import SloppyClientCore

struct ChatUsageTests {
    private func record(_ id: String, channel: String = "chat-a", total: Int = 30) -> ChatUsageRecord {
        ChatUsageRecord(id: id, channelId: channel, promptTokens: 20, completionTokens: 10,
                        totalTokens: total, cachedInputTokens: 15, reasoningTokens: 5,
                        createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test func groupsByChannelWithoutDoubleCountingCacheReasoningOrDuplicateRecords() {
        let records = [record("a"), record("a"), record("b"), record("c", channel: "chat-b", total: 80)]
        let summaries = ChatUsageSummary.grouped(records)
        #expect(summaries.map(\.id) == ["chat-b", "chat-a"])
        #expect(summaries[1].totalTokens == 60)
        #expect(summaries[1].inputTokens == 40)
        #expect(summaries[1].outputTokens == 20)
        #expect(summaries[1].cachedTokens == 30)
        #expect(summaries[1].reasoningTokens == 10)
        #expect(summaries[1].requestCount == 2)
    }

    @Test func loadsSaturatedPeriodsWithoutLosingOlderRecordsOrDuplicatingBoundaries() async throws {
        let records = (0..<1_501).map { index in
            ChatUsageRecord(id: "\(index)", channelId: "chat", promptTokens: 1,
                            completionTokens: 1, totalTokens: 2,
                            createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let loaded = try await ChatUsageLoader.load(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_500)) { from, to in
            Array(records.filter { $0.createdAt >= from && $0.createdAt <= to }.suffix(1_000))
        }
        #expect(loaded.count == 1_501)
        #expect(Set(loaded.map(\.id)).count == 1_501)
        #expect(ChatUsageSummary.grouped(loaded).first?.totalTokens == 3_002)
    }

    @Test func refusesToShowTruncatedStatisticsForSaturatedSingleSecond() async {
        let records = (0..<1_000).map { record("\($0)") }
        await #expect(throws: ChatUsageLoader.LoadError.self) {
            try await ChatUsageLoader.load(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 101)) { _, _ in records }
        }
    }

    @Test func oldRecordsMayOmitProviderDetails() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ChatUsageRecord.self, from: Data(#"{"id":"a","channelId":"chat","promptTokens":20,"completionTokens":10,"totalTokens":30,"createdAt":"2026-09-30T10:00:00Z"}"#.utf8))
        #expect(value.cachedInputTokens == nil)
        #expect(ChatUsageSummary.grouped([value]).first?.totalTokens == 30)
    }
}
