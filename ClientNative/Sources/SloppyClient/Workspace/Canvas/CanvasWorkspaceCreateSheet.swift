import SwiftUI
import SloppyClientUI

@MainActor
struct CanvasWorkspaceCreateSheet: View {
    let viewModel: CanvasWorkspaceViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var title = ""
    @State private var workspaceDescription = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Name", text: $title)
                        .focused($isTitleFocused)
                    TextField("Description", text: $workspaceDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let projectName = viewModel.projectName {
                    Section("Project") {
                        Label(projectName, systemImage: "folder")
                        Text("The new workspace will be linked to this project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Location") {
                        Label(
                            CanvasWorkspaceViewModel.personalWorkspaceName,
                            systemImage: "person.crop.circle"
                        )
                        Text("The new workspace will be kept in your personal workspace.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .mobileScreenBackground()
            .navigationTitle("New Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createWorkspace()
                    }
                    .disabled(normalizedTitle.isEmpty || isCreating)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 330)
        #endif
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            isTitleFocused = true
        }
    }

    private func createWorkspace() {
        guard !normalizedTitle.isEmpty else {
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await viewModel.createWorkspace(
                    title: normalizedTitle,
                    description: workspaceDescription
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
