import Foundation
import Observation
import SloppyClientCore

@Observable
@MainActor
final class WorkspaceSourceFileViewModel {
    enum Scope: Equatable {
        case project(String)
        case agent(String)
        case unavailable
    }

    let apiClient: SloppyAPIClient
    let scope: Scope
    private(set) var reference: SourceFileReference
    private(set) var content: ProjectFileContentResponse?
    private(set) var lines: [String] = []
    private(set) var errorMessage: String?
    private(set) var navigationRevision = 0

    init(reference: SourceFileReference, apiClient: SloppyAPIClient, scope: Scope) {
        self.reference = reference
        self.apiClient = apiClient
        self.scope = scope
    }

    var title: String { URL(fileURLWithPath: reference.path).lastPathComponent }
    var targetLine: Int { min(max(reference.line ?? 1, 1), max(lines.count, 1)) }
    var isLineOutsideFile: Bool { reference.line.map { $0 > lines.count } ?? false }

    func navigate(to reference: SourceFileReference) {
        guard self.reference.path == reference.path else { return }
        self.reference = reference
        navigationRevision += 1
    }

    func reload() {
        content = nil
        lines = []
        errorMessage = nil
        navigationRevision += 1
    }

    func loadIfNeeded() async {
        guard content == nil else { return }
        let revision = navigationRevision
        errorMessage = nil
        do {
            let response: ProjectFileContentResponse
            switch scope {
            case .project(let id):
                response = try await apiClient.fetchProjectFileContent(projectId: id, path: reference.path)
            case .agent(let id):
                response = try await apiClient.fetchAgentFileContent(agentId: id, path: reference.path)
            case .unavailable:
                errorMessage = "Open this link from a conversation with a project or agent."
                return
            }
            guard !Task.isCancelled, revision == navigationRevision else { return }
            content = response
            lines = response.content.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        } catch {
            guard !Task.isCancelled, revision == navigationRevision else { return }
            errorMessage = "Unable to open this file. It may be unavailable, outside the workspace, binary, or larger than 2 MB."
        }
    }
}
