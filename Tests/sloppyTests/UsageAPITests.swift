import Foundation
import Testing
import Protocols
@testable import sloppy

@Suite struct UsageAPITests {
    @Test func exposesNewUsageAndRejectsInvalidFilters() async throws {
        let service = CoreService(config:.test,persistenceBuilder:InMemoryCorePersistenceBuilder())
        let router = CoreRouter(service:service)
        let response = await router.handle(method:"GET",path:"/v1/usage/breakdown?groupBy=tool",body:nil)
        #expect(response.status == 200)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(UsageBreakdownResponse.self,from:response.body)
        #expect(result.requestCount == 0)
        #expect(result.groups.isEmpty)
        for query in ["groupBy=wrong","from=invalid","to=invalid","limit=not-a-number","limit=201","from=2026-10-06T00:00:00Z&to=2026-10-05T00:00:00Z"] {
            let rejected = await router.handle(method:"GET",path:"/v1/usage/breakdown?"+query,body:nil)
            #expect(rejected.status == 400)
        }
    }
}
