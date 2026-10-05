import SloppyClientCore
import SloppyFeatureChat

@MainActor
extension MainViewModel {
    func openSourceFile(_ reference: SourceFileReference, from chat: ChatScreenViewModel) {
        let scope: WorkspaceSourceFileViewModel.Scope
        if let projectID = chat.activeProjectIdForWorkspacePanel {
            scope = .project(projectID)
        } else if let agentID = chat.selectedAgent?.id {
            scope = .agent(agentID)
        } else {
            scope = .unavailable
        }
        workspaceDockState.openSourceFile(reference, apiClient: SloppyAPIClient(endpoint: chat.sessionEndpoint), scope: scope)
    }
}
