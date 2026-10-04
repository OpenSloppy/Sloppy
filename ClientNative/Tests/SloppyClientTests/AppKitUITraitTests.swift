import Testing
import SloppyUITestSupport

@Suite("AppKit test isolation")
struct AppKitUITraitTests {
    @Test("UI scopes exclude peers without blocking the main actor")
    func scopesExcludePeers() async throws {
        let test = try #require(Test.current)
        let probe = ScopeProbe()
        let trait: AppKitUITrait = .appKitUI
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await trait.provideScope(for: test, testCase: nil) {
                        await probe.enter()
                        await MainActor.run {}
                        try await Task.sleep(for: .milliseconds(5))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maximumConcurrent == 1)
        #expect(await probe.completed == 4)
    }

    @Test("a thrown test error releases the UI scope")
    func failureReleasesScope() async throws {
        let test = try #require(Test.current)
        let trait: AppKitUITrait = .appKitUI
        enum ExpectedError: Error { case failure }
        do {
            try await trait.provideScope(for: test, testCase: nil) { throw ExpectedError.failure }
            Issue.record("Expected the test error to propagate")
        } catch ExpectedError.failure {}

        let probe = ScopeProbe()
        try await trait.provideScope(for: test, testCase: nil) {
            await probe.enter()
            await probe.leave()
        }
        #expect(await probe.completed == 1)
    }
}

private actor ScopeProbe {
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var completed = 0

    func enter() {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }
}
