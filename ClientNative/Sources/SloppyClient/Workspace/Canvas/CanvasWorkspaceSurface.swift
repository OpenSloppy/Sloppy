import SwiftUI
import SloppyClientUI

extension EnvironmentValues {
    @Entry var canvasWorkspaceToolbarEnabled = true
}

@MainActor
struct CanvasWorkspaceSurface: View {
    let viewModel: CanvasWorkspaceViewModel
    var allowsProjectSelection = true

    var body: some View {
        Group {
            if viewModel.isShowingLibrary {
                CanvasWorkspaceLibraryView(
                    viewModel: viewModel,
                    allowsProjectSelection: allowsProjectSelection
                )
            } else {
                nativeEditor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mobileScreenBackground()
    }

    private var nativeEditor: some View {
        ZStack {
            CanvasWorkspaceEditorView(viewModel: viewModel)

            if viewModel.isLoadingDocument {
                LoadingSkeleton("Loading workspace…", style: .detail)
                    .background(.regularMaterial)
                    .accessibilityLabel("Loading workspace")
            }

            if let error = viewModel.pageError {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text("Workspace unavailable")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    HStack {
                        Button("Back") {
                            returnToLibrary()
                        }
                        Button("Retry") {
                            Task {
                                await viewModel.retry()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: 360)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(radius: 18)
            }
        }
    }

    private func returnToLibrary() {
        viewModel.showLibrary()
        Task {
            await viewModel.refreshLibrary()
        }
    }
}
