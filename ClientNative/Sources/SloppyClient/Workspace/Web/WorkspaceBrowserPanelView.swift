import SwiftUI
import SloppyClientUI

@MainActor
struct WorkspaceBrowserPanelView: View {
    @Bindable var viewModel: WorkspaceWebViewModel
    @Environment(\.theme) private var theme
    var onOpenTool: (@MainActor (WorkspaceSidePanelItem) -> Void)? = nil
    var allowsProjectTools = false
    @FocusState private var isAddressFocused: Bool

    var body: some View {
#if os(macOS)
        desktopBrowser
#else
        compactBrowser
#endif
    }

    private var desktopBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    navigationButton("arrow.left", title: "Back", enabled: viewModel.canGoBack, action: viewModel.goBack)
                    navigationButton("arrow.right", title: "Forward", enabled: viewModel.canGoForward, action: viewModel.goForward)
                    Rectangle().fill(theme.colors.borderBold).frame(width: 1, height: 16).padding(.horizontal, 3)
                    navigationButton("arrow.clockwise", title: "Reload", action: viewModel.reload)
                }
                .padding(.horizontal, 4)
                .background(theme.colors.surfaceRaised, in: Capsule())

                TextField("Enter a URL", text: $viewModel.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.colors.textPrimary)
                    .focused($isAddressFocused)
                    .onSubmit {
                        viewModel.openAddress()
                        isAddressFocused = false
                    }
                    .padding(.horizontal, 16)
                    .frame(minWidth: 60, minHeight: 36)
                    .background(theme.colors.surfaceRaised, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(isAddressFocused ? theme.colors.borderBold : theme.colors.border, lineWidth: 1)
                    }
                    .accessibilityLabel("Browser address")
                    .accessibilityIdentifier("workspace-browser-address")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.colors.border).frame(height: 1)
            }

            if viewModel.isLoading {
                ProgressView().controlSize(.small).padding(.vertical, 6)
            }
            if let error = viewModel.lastError {
                Text(error).font(.caption).foregroundStyle(theme.colors.statusBlocked)
                    .textSelection(.enabled).padding(10)
            }
            WorkspaceWebView(viewModel: viewModel)
                .id(ObjectIdentifier(viewModel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-browser-page")
                .overlay {
                    if !viewModel.isLoading && (viewModel.currentURL == nil || viewModel.currentURL?.absoluteString == "about:blank") {
                        WorkspaceBrowserStartView(
                            allowsProjectTools: allowsProjectTools,
                            onOpenTool: onOpenTool,
                            onFocusAddress: { isAddressFocused = true }
                        )
                    }
                }
        }
        .background(theme.colors.surface)
    }

    private func navigationButton(
        _ symbol: String,
        title: String,
        enabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? theme.colors.textSecondary : theme.colors.textMuted.opacity(0.45))
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var compactBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: viewModel.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!viewModel.canGoBack)
                    .accessibilityLabel("Back")
                Button(action: viewModel.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!viewModel.canGoForward)
                    .accessibilityLabel("Forward")
                Button(action: viewModel.reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
                TextField("Open URL", text: $viewModel.addressText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(viewModel.openAddress)
                    .accessibilityIdentifier("workspace-browser-address")
            }
            .buttonStyle(.plain)
            .padding(10)
            if viewModel.isLoading { ProgressView().controlSize(.small) }
            if let error = viewModel.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Divider()
            WorkspaceWebView(viewModel: viewModel)
                .id(ObjectIdentifier(viewModel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-browser-page")
                .overlay {
                    if !viewModel.isLoading && (viewModel.currentURL == nil || viewModel.currentURL?.absoluteString == "about:blank") {
                        theme.colors.surface
                            .overlay {
                                VStack(spacing: 12) {
                                    Image(systemName: "globe").font(.system(size: 28, weight: .light))
                                    Text("Enter a URL above").font(.callout)
                                }
                                .foregroundStyle(theme.colors.textMuted)
                            }
                            .allowsHitTesting(false)
                    }
                }
        }
        .background(theme.colors.surface)
    }
}
