import Foundation
import Testing
@testable import Protocols
@testable import sloppy

@Test
func userAgentGetsPetAndSystemAgentDoesNot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let models = [ProviderModelOption(id: "gpt-5.4-mini", title: "gpt-5.4 mini")]

    let user = try store.createAgent(
        AgentCreateRequest(id: "pet-user", displayName: "Pet User", role: "Builder"),
        availableModels: models
    )
    let system = try store.createAgent(
        AgentCreateRequest(id: "pet-system", displayName: "Pet System", role: "Daemon", isSystem: true),
        availableModels: models
    )

    #expect(user.pet != nil)
    #expect(user.pet?.currentStats == user.pet?.baseStats)
    #expect(user.pet?.visual != nil)
    #expect(user.pet?.evolution?.totalXp == 0)
    #expect(user.pet?.stageAssets.count == 3)
    #expect(system.pet == nil)

    let userPetState = root.appendingPathComponent("pet-user", isDirectory: true).appendingPathComponent("pet-state.json")
    let systemPetState = root.appendingPathComponent(".system/pet-system", isDirectory: true).appendingPathComponent("pet-state.json")
    #expect(FileManager.default.fileExists(atPath: userPetState.path))
    #expect(!FileManager.default.fileExists(atPath: systemPetState.path))
}

@Test
func legacyAgentGetsBackfilledPetOnRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let agentDirectory = root.appendingPathComponent("legacy-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

    let legacy = AgentSummary(
        id: "legacy-agent",
        displayName: "Legacy Agent",
        role: "Support",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        isSystem: false,
        runtime: .init()
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try (encoder.encode(legacy) + Data("\n".utf8)).write(
        to: agentDirectory.appendingPathComponent("agent.json"),
        options: .atomic
    )

    let hydrated = try store.getAgent(id: "legacy-agent")
    #expect(hydrated.pet != nil)
    #expect(hydrated.pet?.currentStats == hydrated.pet?.baseStats)
    #expect(hydrated.pet?.visual != nil)
    #expect(FileManager.default.fileExists(atPath: agentDirectory.appendingPathComponent("pet-state.json").path))
}

@Test
func petIdentityMatchesTheNativeAndDashboardCatalog() {
    for (id, shape) in [("a", "circle"), ("b", "triangle"), ("c", "diamond"), ("d", "square"), ("研究", "circle")] {
        let pet = AgentPetFactory.makePet(agentID: id)
        #expect(pet.summary.parts.bodyId == shape)
        #expect(pet.summary.parts.legsId == "none")
        #expect(pet.summary.stageAssets.allSatisfy { $0.spriteSheetPath == "/pets/bots/bot-\(shape).png" })
    }
}

@Test
func legacyArtworkMigrationPreservesIdentityStatsAndXP() {
    let generated = AgentPetFactory.makePet(genome: 42)
    var legacy = generated.summary
    legacy.parts = .init(headId: "head-visor", bodyId: "body-puff", legsId: "legs-bouncer")
    legacy.visual = .init(speciesId: "aurora-bun", displayName: "Old Pet", source: "model", assetBaseURL: "/pets/presets/aurora-bun", currentStage: 1, stageCount: 3, terminalFaceSet: .init(idle: "(o_o)", happy: "(^_^)", sad: "(._.)", sleep: "(-_-)"))
    var state = generated.state
    state.totalXp = 200
    state.currentStats.wisdom = 65
    let migrated = AgentPetFactory.summary(legacy, applying: state, agentID: "b")
    #expect(migrated.petId == legacy.petId)
    #expect(migrated.genomeHex == legacy.genomeHex)
    #expect(migrated.baseStats == legacy.baseStats)
    #expect(migrated.currentStats == state.currentStats)
    #expect(migrated.evolution?.totalXp == 200)
    #expect(migrated.visual?.currentStage == 2)
    #expect(migrated.visual?.speciesId == "triangle")
    #expect(migrated.visual?.source == "bundled_png")
    #expect(AgentPetFactory.summary(migrated, applying: state, agentID: "b") == migrated)
}

@Test
func petPaletteIsIndependentOfShapeAndSurvivesPersistence() throws {
    for (index, palette) in AgentPetFactory.paletteIDs.enumerated() {
        let pet = AgentPetFactory.makePet(genome: UInt64(index) << 8, agentID: "a")
        #expect(pet.summary.parts.bodyId == "circle")
        #expect(pet.summary.visual?.paletteId == palette)
        let updated = AgentPetFactory.summary(pet.summary, applying: pet.state, agentID: "a")
        #expect(updated.visual?.paletteId == palette)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let created = try store.createAgent(.init(id: "random-color", displayName: "Random", role: "Builder"), availableModels: [])
    let palette = try #require(created.pet?.visual?.paletteId)
    #expect(AgentPetFactory.paletteIDs.contains(palette))
    #expect(try store.getAgent(id: "random-color").pet?.visual?.paletteId == palette)
    #expect(try store.getAgent(id: "random-color").pet?.visual?.paletteId == palette)
}

@Test
func retiredPetGenerationReturnsGoneAndAdvertisesUnavailable() async {
    let service = CoreService(config: .test)
    let router = CoreRouter(service: service)
    let response = await router.handle(method: "POST", path: "/v1/pets/generate", body: Data("{}".utf8))
    #expect(response.status == 410)
    let status = await service.petImageGenerationStatus()
    #expect(!status.available)
    #expect(status.providers.isEmpty)
}

@Test
func retiredDraftCannotCreateAnAgentOrLeaveAnEmptyDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentCatalogFileStore(agentsRootURL: root)
    #expect(throws: AgentCatalogFileStore.StoreError.invalidPayload) {
        try store.createAgent(.init(id: "old-draft", displayName: "Old", role: "Builder", petDraftId: "draft_old"), availableModels: [])
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old-draft").path))
}

@Test
func petEvolutionStageThresholdsMatchPlan() {
    #expect(AgentPetFactory.stage(for: 0) == 1)
    #expect(AgentPetFactory.stage(for: 119) == 1)
    #expect(AgentPetFactory.stage(for: 120) == 2)
    #expect(AgentPetFactory.stage(for: 319) == 2)
    #expect(AgentPetFactory.stage(for: 320) == 3)
}

@Test
func petProgressKeepsSmallPositiveActivityGains() {
    let baseStats = AgentPetStats(wisdom: 20, debugging: 20, patience: 20, snark: 20, chaos: 20)
    var state = AgentPetProgressState(currentStats: baseStats)

    AgentPetProgressionEngine.apply(
        state: &state,
        input: AgentPetProgressionInput(
            sourceKind: .agentSession,
            eventKind: .toolCall,
            channelId: "agent:pet-small-gain:session:s1",
            sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: "files.read"
        ),
        baseStats: baseStats
    )

    #expect(state.totalXp > 0)
    #expect(state.currentStats.debugging > baseStats.debugging)
}

@Test
func petProgressCombinesSourcesAndCapsRepeatedShortMessages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = AgentCatalogFileStore(agentsRootURL: root)
    let agent = try store.createAgent(
        AgentCreateRequest(id: "progress-agent", displayName: "Progress Agent", role: "Debugger"),
        availableModels: [ProviderModelOption(id: "gpt-5.4-mini", title: "gpt-5.4 mini")]
    )
    let baseStats = try #require(agent.pet?.baseStats)

    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .agentSession,
            eventKind: .userMessage,
            channelId: "agent:progress-agent:session:s1",
            sessionId: "s1",
            content: "Please debug this Swift build failure and explain the stack trace."
        )
    )
    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .externalChannel,
            eventKind: .toolFailure,
            channelId: "discord-debug"
        )
    )
    _ = try store.recordPetInteraction(
        agentID: "progress-agent",
        input: AgentPetProgressionInput(
            sourceKind: .externalChannel,
            eventKind: .runCompleted,
            channelId: "discord-debug",
            content: "Issue resolved."
        )
    )

    for _ in 0..<40 {
        _ = try store.recordPetInteraction(
            agentID: "progress-agent",
            input: AgentPetProgressionInput(
                sourceKind: .externalChannel,
                eventKind: .userMessage,
                channelId: "discord-debug",
                content: "panic!!!"
            )
        )
    }

    let updated = try store.getAgent(id: "progress-agent")
    let currentStats = try #require(updated.pet?.currentStats)

    #expect(currentStats.wisdom >= baseStats.wisdom)
    #expect(currentStats.debugging >= baseStats.debugging)
    #expect(currentStats.chaos >= baseStats.chaos)
    #expect(currentStats.snark - baseStats.snark <= 10)
    #expect(currentStats.chaos - baseStats.chaos <= 12)
    #expect((updated.pet?.evolution?.totalXp ?? 0) > 0)
}

@Test
func petProgressTracksCoreServiceToolInvocationEvents() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    let agentID = "pet-tool-events-\(UUID().uuidString)"
    _ = try await service.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Pet Tool Events", role: "Debugger")
    )
    let session = try await service.createAgentSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Tool progress")
    )

    let before = try #require(try await service.getAgent(id: agentID).pet)
    let result = await service.invokeToolFromRuntime(
        agentID: agentID,
        sessionID: session.id,
        request: ToolInvocationRequest(tool: "system.list_tools")
    )

    #expect(result.ok)

    let updated = try await service.getAgent(id: agentID)
    let updatedPet = try #require(updated.pet)
    #expect((updatedPet.evolution?.totalXp ?? 0) > (before.evolution?.totalXp ?? 0))
    #expect(updatedPet.currentStats.debugging > before.currentStats.debugging)
}
