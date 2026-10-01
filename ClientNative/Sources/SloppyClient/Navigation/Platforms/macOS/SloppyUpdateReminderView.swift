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

    var body: some View {
        Button(action: onCheckForUpdates) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                Text("Update available: \(version)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
