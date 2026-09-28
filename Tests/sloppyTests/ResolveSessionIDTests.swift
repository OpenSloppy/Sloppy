import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("resolveSessionID")
struct ResolveSessionIDTests {
    private let realSessionID = "session-abc-123"

    private var context: ToolContext {
        let tmpURL = FileManager.default.temporaryDirectory
        return ToolContext(
            agentID: "test-agent",
            sessionID: realSessionID,
            policy: AgentToolsPolicy(),
            workspaceRootURL: tmpURL,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: AgentSessionFileStore(agentsRootURL: tmpURL),
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: tmpURL),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: tmpURL),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: .sloppy(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    @Test("nil falls back to context sessionID")
    func nilFallback() {
        #expect(resolveSessionID(nil, context: context) == realSessionID)
    }

    @Test("empty string falls back to context sessionID")
    func emptyFallback() {
        #expect(resolveSessionID("", context: context) == realSessionID)
    }

    @Test("'current' resolves to context sessionID")
    func currentPlaceholder() {
        #expect(resolveSessionID("current", context: context) == realSessionID)
    }

    @Test("'Current' resolves to context sessionID (case-insensitive)")
    func currentPlaceholderUppercase() {
        #expect(resolveSessionID("Current", context: context) == realSessionID)
    }

    @Test("'self' resolves to context sessionID")
    func selfPlaceholder() {
        #expect(resolveSessionID("self", context: context) == realSessionID)
    }

    @Test("'this' resolves to context sessionID")
    func thisPlaceholder() {
        #expect(resolveSessionID("this", context: context) == realSessionID)
    }

    @Test("whitespace-only falls back to context sessionID")
    func whitespaceFallback() {
        #expect(resolveSessionID("  ", context: context) == realSessionID)
    }

    @Test("explicit session ID is preserved")
    func explicitSessionID() {
        let explicit = "session-other-456"
        #expect(resolveSessionID(explicit, context: context) == explicit)
    }
}
