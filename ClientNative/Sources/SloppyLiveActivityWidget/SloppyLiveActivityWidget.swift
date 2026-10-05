import ActivityKit
import SloppyLiveActivity
import SwiftUI
import WidgetKit

@main
struct SloppyLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        SloppyLiveActivityWidget()
    }
}

struct SloppyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SloppyActivityAttributes.self) { context in
            SloppyLockScreenActivityView(context: context)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Sloppy", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SloppyActivityCounter(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(dynamicIslandTitle(for: context.state))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SloppyExpandedActivityContent(context: context)
                }
            } compactLeading: {
                Image(systemName: compactSymbol(for: context.state))
                    .foregroundStyle(compactColor(for: context.state))
            } compactTrailing: {
                if context.state.activityCount > 0 {
                    Text("\(context.state.activityCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                } else {
                    Image(systemName: "exclamationmark")
                        .foregroundStyle(compactColor(for: context.state))
                }
            } minimal: {
                Image(systemName: compactSymbol(for: context.state))
                    .foregroundStyle(compactColor(for: context.state))
            }
            .keylineTint(.pink)
        }
    }

    private func dynamicIslandTitle(for state: SloppyActivityContentState) -> String {
        if let approval = state.approval {
            return approval.toolName ?? "Approval required"
        }
        if let error = state.error {
            return error.title
        }
        if state.agentRunCount == 1 {
            return "Agent is working"
        }
        return "\(state.activityCount) active items"
    }

    private func compactSymbol(for state: SloppyActivityContentState) -> String {
        if state.approval != nil {
            return "exclamationmark.shield.fill"
        }
        if state.error != nil {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.path.ecg"
    }

    private func compactColor(for state: SloppyActivityContentState) -> Color {
        if state.approval != nil {
            return .orange
        }
        if state.error != nil {
            return .red
        }
        return .green
    }
}

private struct SloppyLockScreenActivityView: View {
    let context: ActivityViewContext<SloppyActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("SloppyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Sloppy")
                    .font(.headline)
                Spacer()
                SloppyActivityCounter(state: context.state)
            }

            SloppyExpandedActivityContent(context: context)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct SloppyExpandedActivityContent: View {
    let context: ActivityViewContext<SloppyActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let approval = context.state.approval {
                approvalContent(approval)
            }
            if let error = context.state.error {
                errorContent(error)
            }
            activityContent
        }
        .invalidatableContent(context.state.approval != nil)
    }

    private func approvalContent(_ approval: SloppyActivityApproval) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(approval.title, systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Text(approval.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button(
                    intent: RejectSloppyToolIntent(
                        approvalID: approval.id,
                        serverURL: context.attributes.serverURL
                    )
                ) {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button(
                    intent: ApproveSloppyToolIntent(
                        approvalID: approval.id,
                        serverURL: context.attributes.serverURL
                    )
                ) {
                    Label("Allow", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .buttonStyle(.borderedProminent)
            .font(.caption.weight(.semibold))
        }
    }

    private func errorContent(_ error: SloppyActivityError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(error.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if let run = context.state.agentRuns.first {
            activityRow(
                symbol: "sparkles",
                tint: .green,
                title: run.sessionTitle,
                subtitle: "\(run.agentName) · \(run.status)"
            )
        }
        if let task = context.state.tasks.first {
            activityRow(
                symbol: "bolt.fill",
                tint: .cyan,
                title: task.title,
                subtitle: "\(task.projectName) · \(task.status.title)"
            )
        }
        let displayedRowCount = (context.state.agentRuns.isEmpty ? 0 : 1)
            + (context.state.tasks.isEmpty ? 0 : 1)
        if context.state.activityCount > displayedRowCount {
            Text("+\(context.state.activityCount - displayedRowCount) more active items")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func activityRow(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SloppyActivityCounter: View {
    let state: SloppyActivityContentState

    var body: some View {
        if state.activityCount > 0 {
            Label("\(state.activityCount)", systemImage: "bolt.fill")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.cyan)
        } else if state.approval != nil {
            Text("Approval")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Text("Error")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}
