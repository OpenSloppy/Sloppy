import SwiftUI
import SloppyClientUI

@MainActor
struct WorkspaceBrowserStartView: View {
    let allowsProjectTools: Bool
    let onOpenTool: (@MainActor (WorkspaceSidePanelItem) -> Void)?
    let onFocusAddress: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let onOpenTool {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Tools")
                                .font(.system(size: 14, weight: .medium))
                            LazyVGrid(columns: Array(
                                repeating: GridItem(.flexible(), spacing: 10),
                                count: geometry.size.width >= 560 ? 2 : 1
                            ), spacing: 8) {
                                ForEach([WorkspaceSidePanelItem.review, .terminal, .files, .sideChat]) { item in
                                    WorkspaceBrowserToolCard(
                                        item: item,
                                        isEnabled: !item.requiresProject || allowsProjectTools,
                                        action: { onOpenTool(item) }
                                    )
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Browse")
                            .font(.system(size: 14, weight: .medium))
                        Button(action: onFocusAddress) {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(theme.colors.textSecondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Open a website")
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.colors.textPrimary)
                                    Text("Enter an address in the URL bar above")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.colors.textMuted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(theme.colors.textMuted)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.colors.surfaceGlow, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace-browser-focus-address")
                    }
                }
                .foregroundStyle(theme.colors.textPrimary)
                .frame(maxWidth: 820)
                .padding(.horizontal, geometry.size.width >= 560 ? 36 : 24)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.colors.surface)
        .accessibilityIdentifier("workspace-browser-start")
    }
}

@MainActor
private struct WorkspaceBrowserToolCard: View {
    let item: WorkspaceSidePanelItem
    let isEnabled: Bool
    let action: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 20)
                Text(item.title).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
                if let hint = item.keyboardHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.colors.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.colors.surfaceRaised, in: Capsule())
                }
            }
            .foregroundStyle(theme.colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(isHovered ? theme.colors.surfaceRaised : theme.colors.surfaceGlow,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 && isEnabled }
        .help(isEnabled ? "Open \(item.title)" : "Open a project to use \(item.title)")
        .accessibilityIdentifier("workspace-browser-tool.\(item.rawValue)")
    }
}
