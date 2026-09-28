import Foundation
import Protocols

public struct PromptRenderContext: Sendable {
    var processKind: PromptProcessKind
    var agentID: String
    var sessionID: String?
    var bootstrapMarker: String?
    var documents: AgentDocumentBundle?
    var installedSkills: [InstalledSkill]
    var agentDirectoryPath: String?
    var sharedMemoryEnabled: Bool

    public static func agentSessionBootstrap(
        agentID: String,
        sessionID: String,
        bootstrapMarker: String,
        documents: AgentDocumentBundle,
        installedSkills: [InstalledSkill],
        agentDirectoryPath: String?,
        sharedMemoryEnabled: Bool = true
    ) -> PromptRenderContext {
        PromptRenderContext(
            processKind: .agentSessionBootstrap,
            agentID: agentID,
            sessionID: sessionID,
            bootstrapMarker: bootstrapMarker,
            documents: documents,
            installedSkills: installedSkills,
            agentDirectoryPath: agentDirectoryPath,
            sharedMemoryEnabled: sharedMemoryEnabled
        )
    }
}
