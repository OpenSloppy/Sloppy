import Foundation
import Protocols

// MARK: - ToolRegistry

/// Maps tool IDs to their CoreTool implementations.
/// Used by ToolExecutionService to dispatch invocations without a switch/case.
struct ToolRegistry: Sendable {
    private let tools: [String: any CoreTool]

    var allTools: [any CoreTool] {
        var seen = Set<String>()
        return tools.values.filter { seen.insert($0.toolID).inserted }
    }

    init(tools: [any CoreTool]) {
        var map: [String: any CoreTool] = [:]
        for tool in tools {
            map[tool.toolID] = tool
            // Some tools handle multiple IDs (e.g. sessions.send + messages.send)
            for alias in tool.toolAliases {
                map[alias] = tool
            }
        }
        self.tools = map
    }

    func invoke(request: ToolInvocationRequest, context: ToolContext) async -> ToolInvocationResult? {
        let toolID = request.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tool = tools[toolID] else { return nil }
        let startedAt = Date()
        let result = await tool.invoke(arguments: request.arguments, context: context)
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        return ToolInvocationResult(
            tool: result.tool,
            ok: result.ok,
            data: result.data,
            error: result.error,
            durationMs: durationMs
        )
    }

    var catalogEntries: [AgentToolCatalogEntry] {
        var seen = Set<String>()
        return tools.values.compactMap { tool in
            guard seen.insert(tool.toolID).inserted else { return nil }
            return AgentToolCatalogEntry(
                id: tool.toolID,
                domain: tool.domain,
                title: tool.title,
                status: tool.status,
                description: tool.description
            )
        }.sorted { $0.id < $1.id }
    }

    var knownToolIDs: Set<String> {
        Set(tools.keys)
    }

    /// Builds a ToolRegistry containing all built-in Sloppy tools.
    static func makeDefault() -> ToolRegistry {
        ToolRegistry(tools: [
            FilesReadTool(),
            FilesListTool(),
            FilesGrepTool(),
            FilesEditTool(),
            FilesWriteTool(),
            ImagesGenerateTool(),
            WidgetArtifactGenerateTool(),
            WebArtifactCreateTool(),
            SitesListTool(),
            SitesPublishTool(),
            SitesUpdateTool(),
            SitesDeleteTool(),
            WorkspacesListTool(),
            WorkspacesCreateTool(),
            WorkspaceGetTool(),
            WorkspaceUpdateTool(),
            WorkspaceElementsQueryTool(),
            WorkspaceTransactionApplyTool(),
            WorkspaceTemplateListTool(),
            WorkspaceTemplateApplyTool(),
            WorkspaceTemplateSaveTool(),
            WorkspaceArtifactPlaceTool(),
            RuntimeExecTool(),
            RuntimeProcessTool(),
            ComputerClickTool(),
            ComputerTypeTool(),
            ComputerKeyTool(),
            ComputerScreenshotTool(),
            BrowserOpenTool(),
            BrowserNavigateTool(),
            BrowserClickTool(),
            BrowserTypeTool(),
            BrowserScreenshotTool(),
            BrowserStatusTool(),
            BrowserReadTool(),
            BrowserScrollTool(),
            BrowserCloseTool(),
            SleepTool(),
            SessionCompleteTool(),
            PlanningSelectRouteTool(),
            PlanningRequestInputTool(),
            PlanningProgressUpdateTool(),
            DebugReadLogsTool(),
            WebSearchTool(),
            WebFetchTool(),
            WebRequestTool(),
            BranchesSpawnTool(),
            WorkersSpawnTool(),
            AgentsDelegateTaskTool(),
            AgentDelegateFinishTool(),
            WorkersRouteTool(),
            SessionsSpawnTool(),
            SessionsListTool(),
            SessionsHistoryTool(),
            SessionsStatusTool(),
            SessionsSendTool(),
            MemoryGetTool(),
            MemorySaveTool(),
            MemoryImportTool(),
            MemorySourceTool(),
            MemorySearchTool(),
            MCPListServersTool(),
            MCPListToolsTool(),
            MCPCallToolTool(),
            MCPListResourcesTool(),
            MCPReadResourceTool(),
            MCPListPromptsTool(),
            MCPGetPromptTool(),
            MCPSaveServerTool(),
            MCPRemoveServerTool(),
            MCPInstallServerTool(),
            MCPUninstallServerTool(),
            AgentsListTool(),
            ChannelHistoryTool(),
            SystemListToolsTool(),
            CronTool(),
            HeartbeatReportTool(),
            ProjectListTool(),
            ProjectCurrentTool(),
            ProjectCreateTool(),
            ProjectUpdateTool(),
            ProjectChannelLinkTool(),
            ProjectDeleteTool(),
            ProjectTaskListTool(),
            ProjectTaskCreateTool(),
            ProjectTaskGetTool(),
            ProjectTaskUpdateTool(),
            ProjectTaskCancelTool(),
            ProjectTaskDeleteTool(),
            TaskClarificationCreateTool(),
            WorkflowTool(),
            ProjectEscalateTool(),
            ActorDiscussTool(),
            ActorConcludeDiscussionTool(),
            SkillsSearchTool(),
            SkillsListTool(),
            SkillsInstallTool(),
            SkillsManageTool(),
            SkillsUninstallTool(),
            LSPTool(),
            VisorStatusTool(),
            AgentDocumentsSetUserMarkdownTool(),
            AgentDocumentsSetMemoryMarkdownTool(),
            ProjectMetaMemoryTool(),
        ] + SafariBridgeToolFactory.makeTools())
    }
}
