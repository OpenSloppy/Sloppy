#if os(macOS)
import SwiftUI

@MainActor
struct SloppyUpdateReminderView: View {
    var controller: SloppyUpdateController = .shared

    var body: some View {
        if let version = controller.availableVersion {
            SloppyUpdateBadge(version: version, onCheckForUpdates: controller.checkForUpdates)
        }
    }
}

struct SloppyUpdateBadge: View {
    let version: String
    let onCheckForUpdates: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onCheckForUpdates) {
            HStack(spacing: 0) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)

                if isHovered {
                    Text("Update")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.leading, 2)
                        .padding(.trailing, 10)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .frame(height: 32)
            .background(Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered)
        .help("Review and install Sloppy \(version)")
        .accessibilityIdentifier("sloppy.updateAvailable")
        .accessibilityLabel("Update available: \(version)")
        .accessibilityHint("Opens the update window")
    }
}

#Preview("Update available") {
    SloppyUpdateBadge(version: "2.2.0", onCheckForUpdates: {})
        .padding()
}
#endif
