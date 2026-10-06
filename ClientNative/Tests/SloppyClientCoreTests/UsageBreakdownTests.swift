import Foundation
import Testing
@testable import SloppyClientCore

@Suite struct UsageBreakdownTests {
    @Test func decodesCountsWithoutAddingCacheOrReasoningAgain() throws {
        let data = Data(#"{"requestCount":2,"reportedRequestCount":1,"completeRequestCount":1,"providerUsage":{"prompt":100,"completion":20,"cachedInput":50,"cacheCreationInput":5,"reasoning":10},"groups":[{"id":"files.read","calls":2,"failures":0,"argumentsTokens":10,"resultTokens":100,"replayTokens":50,"schemaTokens":30,"catalogTokens":0,"tokenizerMeasurements":3,"estimatedMeasurements":0,"unavailableMeasurements":0}],"calls":[]}"#.utf8)
        let response = try JSONDecoder().decode(UsageBreakdownResponse.self,from:data)
        #expect(response.providerUsage.total == 120)
        #expect(response.groups.first?.totalTokens == 190)
        #expect(response.groups.first?.averagePerCall == 55)
        #expect(response.groups.first?.countingLabel == "Local count")
        #expect(response.collectionStartedAt == nil)
    }
    @Test func catalogWithoutCallsHasNoPerCallAverage() throws {
        let data = Data(#"{"id":"mcp.lookup","calls":0,"failures":0,"argumentsTokens":0,"resultTokens":0,"replayTokens":0,"schemaTokens":20,"catalogTokens":0,"tokenizerMeasurements":0,"estimatedMeasurements":1,"unavailableMeasurements":0}"#.utf8)
        let group = try JSONDecoder().decode(UsageBreakdownGroup.self,from:data)
        #expect(group.averagePerCall == nil)
        #expect(group.countingLabel == "Estimate")
    }
}
