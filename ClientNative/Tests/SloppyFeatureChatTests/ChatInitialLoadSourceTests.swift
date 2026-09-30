import Foundation
import Testing

@Suite("Chat initial load source")
struct ChatInitialLoadSourceTests {
    private var source: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    @Test("initial load selects from the resolved agent list, including cache fallback")
    func initialLoadSelectsFromResolvedAgentList() throws {
        let source = try source

        #expect(source.contains("restoreInitialAgentContext(using: agents"))
        #expect(source.contains("using availableAgents: [APIAgentRecord]"))
        #expect(source.contains("let agent = availableAgents.first(where:"))
        #expect(source.contains("?? availableAgents.first"))
    }

    @Test("global session catalog loads every agent with per-agent cache fallback")
    func globalSessionCatalogLoadsEveryAgent() throws {
        let source = try source

        #expect(source.contains("for agent in agents"))
        #expect(source.contains("apiClient.fetchAgentSessions(agentId: agent.id)"))
        #expect(source.contains("cacheStore.loadSessions(agentId: result.agentId)"))
        #expect(source.contains("ChatSessionCatalog.merge(batches)"))
    }

    @Test("initial chat bootstrap releases the UI from cache before network revalidation")
    func initialBootstrapIsCacheFirst() throws {
        let source = try source

        let cacheRestore = try #require(source.range(of: "await restoreInitialDataFromCache()"))
        let contentReady = try #require(source.range(of: "didLoadInitialData = true"))
        let revalidation = try #require(source.range(of: "await revalidateInitialData()"))

        #expect(cacheRestore.lowerBound < contentReady.lowerBound)
        #expect(contentReady.lowerBound < revalidation.lowerBound)
    }

    @Test("initial load restores only a persisted project that is still available")
    func initialLoadRestoresPersistedAvailableProject() throws {
        let source = try source
        let restoreProject = try #require(source.range(of: "restoreLastProjectContextIfAvailable()"))
        let restoreAgent = try #require(source.range(of: "restoreInitialAgentContext(using: agents"))

        #expect(restoreProject.lowerBound < restoreAgent.lowerBound)
        #expect(source.contains("let projectId = settings.lastProjectId"))
        #expect(source.contains("projects.first(where: { $0.id == projectId })"))
        #expect(source.contains("settings.lastProjectId = projectId"))
        #expect(!source.contains("settings.lastProjectId = projects.first"))
    }

    @Test("session lists and transcripts render cached snapshots before remote fetches")
    func sessionsAndTranscriptsAreCacheFirst() throws {
        let source = try source

        let cachedSessions = try #require(source.range(
            of: "let cached = await cacheStore.loadSessions(agentId: agent.id, projectId: projectId)"
        ))
        let remoteSessions = try #require(source.range(
            of: "let fetched = try await apiClient.fetchAgentSessions(agentId: agent.id, projectId: projectId)"
        ))
        let cachedDetail = try #require(source.range(
            of: "if let cached = await cacheStore.loadSessionDetail(agentId: agentId, sessionId: sessionId)"
        ))
        let socketConnection = try #require(source.range(of: "let socket = SessionSocketManager("))

        #expect(cachedSessions.lowerBound < remoteSessions.lowerBound)
        #expect(cachedDetail.lowerBound < socketConnection.lowerBound)
    }
}
