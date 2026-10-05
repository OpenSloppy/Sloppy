import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
public struct AttentionScreen: View {
    private let inbox: AttentionInbox
    @Environment(\.colorScheme) private var colorScheme
    @State private var showHistory = false

    public init(inbox: AttentionInbox) {
        self.inbox = inbox
    }

    private var background: Color { .fromHex(colorScheme == .dark ? 0x20261e : 0xf5f2e9) }
    private var ink: Color { .fromHex(colorScheme == .dark ? 0xf5f2e9 : 0x242521) }
    private var muted: Color { .fromHex(colorScheme == .dark ? 0xb5bfad : 0x6d7066) }
    private var rule: Color { .fromHex(colorScheme == .dark ? 0x52604a : 0xd5d7ca) }
    private var highlight: Color { .fromHex(colorScheme == .dark ? 0x35432c : 0xc8e2ae) }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Picker("Finding history", selection: $showHistory) {
                        Text("Active").tag(false)
                        Text("All history").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("attention.filter")

                    if let checked = inbox.lastCheckedAt {
                        Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(muted)
                    }
                    if inbox.pendingAnalysisCount > 0 {
                        Label("\(inbox.pendingAnalysisCount) reviews queued", systemImage: "clock")
                            .font(.caption).foregroundStyle(muted)
                    }
                    ForEach(inbox.errors, id: \.self) { error in
                        Text(error).font(.subheadline).foregroundStyle(ink)
                            .accessibilityIdentifier("attention.error")
                    }
                    let findings = inbox.findings.filter { showHistory || $0.isActiveAttention(at: timeline.date) }
                    if !inbox.hasLoaded && inbox.isLoading {
                        ProgressView("Loading attention…").frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if findings.isEmpty && inbox.errors.isEmpty {
                        ContentUnavailableView(
                            showHistory ? "No attention history" : "You're all caught up",
                            systemImage: "checkmark.circle",
                            description: Text("Updates from your agents will appear here when a task or pull request needs your next step.")
                        )
                        .accessibilityIdentifier("attention.empty")
                    }
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(findings) { finding in
                            findingRow(finding, at: timeline.date)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .foregroundStyle(ink)
        .background(background.ignoresSafeArea())
        .refreshable { await inbox.refresh() }
        .task { await inbox.refresh() }
        .navigationTitle("Attention")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.screen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attention").font(.largeTitle.bold()).tracking(-0.8)
                Spacer(minLength: 12)
                Button { Task { await inbox.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(inbox.isLoading)
                .accessibilityIdentifier("attention.refresh")
            }
            Text("Your agents watch for changes that need your next step.")
                .font(.subheadline).foregroundStyle(muted)
        }
    }

    private func findingRow(_ finding: ProactiveFinding, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Label(finding.source.kind == .task ? "Task" : "Pull request",
                          systemImage: finding.source.kind == .task ? "checklist" : "arrow.triangle.branch")
                    Spacer(minLength: 12)
                    Text(inbox.agentNames[finding.agentId] ?? finding.agentId)
                }
                .font(.caption).foregroundStyle(muted)
                Text(finding.source.title).font(.title3.bold()).textSelection(.enabled)
                Text(status(for: finding, at: date))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(highlight, in: Capsule())
            }
            detail("Why it matters", finding.reason)
            detail("What happened", finding.evidence)
            VStack(alignment: .leading, spacing: 8) {
                Label("Next step", systemImage: "arrow.turn.down.right").font(.caption.weight(.semibold))
                Text(finding.nextStep).font(.subheadline).textSelection(.enabled)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlight, in: RoundedRectangle(cornerRadius: 12))
            if let until = finding.snoozedUntil, until > date {
                Label("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption).foregroundStyle(muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceActions(finding); Spacer(minLength: 0); findingActions(finding) }
                VStack(alignment: .leading, spacing: 12) { sourceActions(finding); findingActions(finding) }
            }
            .controlSize(.regular)
            Rectangle().fill(rule).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.finding.\(finding.id)")
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(muted)
            Text(text).font(.subheadline).textSelection(.enabled)
        }
    }

    private func sourceActions(_ finding: ProactiveFinding) -> some View {
        HStack(spacing: 12) {
            if let url = DeepLink.session(agentId: finding.agentId, sessionId: finding.sessionId).url {
                Link(destination: url) { Label("Discuss with agent", systemImage: "bubble") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("attention.discuss.\(finding.id)")
            }
            if let project = finding.source.projectId, let task = finding.source.taskId,
               let url = DeepLink.task(projectId: project, taskId: task).url {
                Link("Open task", destination: url).buttonStyle(.bordered)
            } else if let raw = finding.source.url, let url = URL(string: raw),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link("Open source", destination: url).buttonStyle(.bordered)
            }
        }
        .tint(ink)
    }

    private func findingActions(_ finding: ProactiveFinding) -> some View {
        HStack(spacing: 12) {
            Button(finding.readAt == nil ? "Mark read" : "Read", systemImage: "checkmark") {
                Task { await inbox.act(finding, action: .read) }
            }
            .disabled(finding.readAt != nil)
            .accessibilityIdentifier("attention.read.\(finding.id)")
            Menu {
                Button("Snooze 24h", systemImage: "clock") { Task { await inbox.act(finding, action: .snooze) } }
                Button("Dismiss", systemImage: "xmark") { Task { await inbox.act(finding, action: .dismiss) } }
                    .disabled(finding.dismissedAt != nil)
            } label: { Label("More", systemImage: "ellipsis") }
            .accessibilityIdentifier("attention.actions.\(finding.id)")
        }
        .buttonStyle(.borderless)
        .tint(ink)
        .disabled(inbox.busyFindingIDs.contains(finding.id) || finding.resolvedAt != nil || finding.dismissedAt != nil)
    }

    private func status(for finding: ProactiveFinding, at date: Date) -> String {
        if finding.resolvedAt != nil { return "Resolved" }
        if finding.dismissedAt != nil { return "Dismissed" }
        if let until = finding.snoozedUntil, until > date { return "Snoozed" }
        if finding.readAt != nil { return "Read" }
        return finding.outcome == .needsInput ? "Input needed" : "Suggested action"
    }
}
