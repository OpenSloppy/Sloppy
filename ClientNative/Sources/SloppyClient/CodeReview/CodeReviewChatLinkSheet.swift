import SloppyClientCore
import SwiftUI

@MainActor
struct CodeReviewChatLinkSheet: View {
    let apiClient: SloppyAPIClient
    let onLink: @MainActor (ChatSessionSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sessions: [ChatSessionSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Link working chat").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            TextField("Search chats or agent IDs", text: $query).textFieldStyle(.roundedBorder)
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            if isLoading { ProgressView() }
            List(sessions) { session in
                Button {
                    onLink(session)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                        Text([session.agentId, session.taskId].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 500, minHeight: 380)
        .task(id: query) {
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await apiClient.fetchSessionMentions(query: query)
                guard !Task.isCancelled else { return }
                sessions = result
                errorMessage = nil
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
