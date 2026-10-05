import SloppyClientUI
import SwiftUI

@MainActor
struct SidebarNavigationRow: View {
    let icon: MaterialSymbol?
    let title: String
    var trailing: String? = nil
    var badgeCount: Int = 0
    let isSelected: Bool
    var navigationValue: MainSidebarSelection? = nil
    let action: @MainActor () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Group {
            if let navigationValue {
                NavigationLink(value: navigationValue) { content }
                    .simultaneousGesture(TapGesture().onEnded { action() })
            } else {
                Button(action: action) { content }
            }
        }
        .contentShape(Rectangle())
        .buttonStyle(SidebarHoverButtonStyle(isHovered: isHovered, isSelected: isSelected))
        .onHover { isHovered = $0 }
    }

    private var content: some View {
        HStack(spacing: theme.spacing.s) {
            if let icon {
                Icons.symbol(icon, size: theme.typography.body)
                    .foregroundColor(isSelected ? theme.colors.accentCyan : theme.colors.textMuted)
                    .frame(width: 22)
            } else {
                Color.clear.frame(width: 22)
            }
            Text(title)
                .font(.system(size: theme.typography.body))
                .foregroundColor(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.fromHex(0x242521))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.fromHex(0xc8e2ae), in: Capsule())
                    .accessibilityLabel("\(badgeCount) items need attention")
                    .accessibilityIdentifier("sidebar.attention.badge")
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textMuted)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(minHeight: MainSidebarView.rowMinimumHeight)
    }
}

struct SidebarHoverButtonStyle: ButtonStyle {
    let isHovered: Bool
    var isSelected = false

    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? theme.colors.surfaceRaised : .clear)
                if configuration.isPressed || isHovered {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

#Preview("Navigation Row") {
    VStack(alignment: .leading, spacing: 0) {
        SidebarNavigationRow(
            icon: .timer,
            title: "Scheduled",
            trailing: "3",
            isSelected: true,
            navigationValue: .scheduled,
            action: {}
        )

        SidebarNavigationRow(
            icon: .folder,
            title: "Sloppy",
            isSelected: false,
            action: {}
        )

    }
    .frame(width: 320)
    .padding()
}
