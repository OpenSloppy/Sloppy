#if os(macOS)
import SloppyClientCore
import SwiftUI

struct SloppyDesktopNotchHeroView: View {
    let state: SloppyDesktopOverlayState
    let showsMascot: Bool
    let petNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if showsMascot {
                    SloppyNotchPetView(
                        agentID: state.mascotAgentID,
                        paletteID: state.mascotPaletteID,
                        presentationScale: 3.4,
                        state: state.mascotState,
                        onClick: { _ = state.openMascotDestination() }
                    )
                        .matchedGeometryEffect(
                            id: "notch-mascot",
                            in: petNamespace
                        )
                        .transition(.identity)
                }
            }
            .frame(width: 82, height: 82)
            .accessibilityElement()
            .accessibilityLabel("Open related activity")
            .help(state.hasMascotDestination ? "Open related activity" : "Move over the mascot")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: accentColor.opacity(0.75), radius: 4)
                    Text(eyebrow)
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if !state.activeAgentRuns.isEmpty {
                        metricChip(
                            title: "\(state.activeAgentRuns.count) agent\(state.activeAgentRuns.count == 1 ? "" : "s")",
                            systemImage: "sparkles"
                        )
                    }
                    if !state.activeTasks.isEmpty {
                        metricChip(
                            title: "\(state.activeTasks.count) task\(state.activeTasks.count == 1 ? "" : "s")",
                            systemImage: "bolt.fill"
                        )
                    }
                    if state.activityCount == 0 && state.toolApproval == nil {
                        metricChip(title: "Ready", systemImage: "checkmark")
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 92)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    private var eyebrow: String {
        switch state.mascotState {
        case .idle: "READY"
        case .working: "WORKING"
        case .thinking: "THINKING"
        case .needsInput: "NEEDS INPUT"
        case .error: "ERROR"
        }
    }

    private var title: String {
        switch state.mascotState {
        case .error:
            return "Something went wrong"
        case .needsInput:
            if state.toolApproval != nil {
                return "Your approval is needed"
            }
            if let task = state.activeTasks.first(where: \.requiresInput) {
                return task.title
            }
            return state.mascotPrimaryRun.map { "\($0.agentName) needs you" } ?? "Input needed"
        case .thinking:
            return state.mascotPrimaryRun.map { "\($0.agentName) is thinking" } ?? "Thinking"
        case .working:
            if let run = state.mascotPrimaryRun {
                return run.agentName
            }
            if state.activeAgentRuns.count > 1 {
                return "\(state.activeAgentRuns.count) agents are working"
            }
            if let task = state.activeTasks.first {
                return task.title
            }
            return "Sloppy is working"
        case .idle:
            return "Sloppy is ready"
        }
    }

    private var subtitle: String {
        switch state.mascotState {
        case .error:
            return state.mascotErrorMessage ?? "The last operation was interrupted."
        case .needsInput:
            return state.mascotNeedsInputMessage ?? "A decision is needed to continue."
        case .thinking, .working:
            if let run = state.mascotPrimaryRun {
                let detail = run.statusDetails?.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail?.isEmpty == false ? detail! : run.statusLabel
            }
            if let task = state.activeTasks.first {
                return "\(task.projectName) · \(task.statusTitle)"
            }
            return "Working through the current task."
        case .idle:
            return "Watching your workspace and ready for the next task."
        }
    }

    private var accentColor: Color {
        switch state.mascotState {
        case .idle: .mint
        case .working, .thinking: .cyan
        case .needsInput: .orange
        case .error: .red
        }
    }

    private func metricChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(.white.opacity(0.06), in: Capsule())
    }
}
#endif
