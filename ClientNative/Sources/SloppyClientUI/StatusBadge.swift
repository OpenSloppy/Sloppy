import Foundation
import SwiftUI

public struct StatusBadge: View {
    let label: String
    let color: Color

    @Environment(\.theme) private var theme

    public init(_ label: String, color: Color) {
        self.label = label
        self.color = color
    }

    public var body: some View {
        let sp = theme.spacing
        let ty = theme.typography

        return HStack(spacing: sp.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(label.uppercased())
                .font(.system(size: ty.micro))
                .foregroundColor(color)
        }
        .padding(.horizontal, sp.s)
        .padding(.vertical, sp.xs)
        .backportGlassEffect(.regular.tint(color.opacity(0.08 as Float)), in: .rect(cornerRadius: 999))
    }

    public static func forTaskStatus(_ status: String) -> StatusBadge {
        let c = Theme.sloppyDark.colors
        switch status {
        case "in_progress":
            return StatusBadge("Active", color: c.statusActive)
        case "ready":
            return StatusBadge("Ready", color: c.statusReady)
        case "needs_review":
            return StatusBadge("Review", color: c.statusWarning)
        case "done":
            return StatusBadge("Done", color: c.statusDone)
        case "blocked":
            return StatusBadge("Blocked", color: c.statusBlocked)
        case "cancelled":
            return StatusBadge("Off", color: c.statusNeutral)
        case "backlog":
            return StatusBadge("Backlog", color: c.statusNeutral)
        case "pending_approval":
            return StatusBadge("Pending", color: c.statusWarning)
        default:
            return StatusBadge(status, color: c.statusNeutral)
        }
    }
}
