import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
public struct AgentProactivityScreen: View {
    private let agentID: String
    private let apiClient: SloppyAPIClient
    private let initialFindingID: String?
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var heartbeat = AgentHeartbeatSettings()
    @State private var instructions = ""
    @State private var models: [ChatModelOption] = []
    @State private var projects: [APIProjectRecord] = []
    @State private var providers: [CodeReviewProviderDescriptor] = []
    @State private var inbox = ProactiveInbox()
    @State private var loaded = false
    @State private var saving = false
    @State private var actionID: String?
    @State private var error: String?
    @State private var showHistory = false

    public init(agentID: String, apiClient: SloppyAPIClient, initialFindingID: String? = nil) {
        self.agentID = agentID; self.apiClient = apiClient; self.initialFindingID = initialFindingID
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    if let error { Text(error).foregroundStyle(theme.colors.statusBlocked).accessibilityIdentifier("proactivity.error") }
                    if loaded {
                        if initialFindingID != nil {
                            history
                            DisclosureGroup("Agent checks") { configuration }
                        } else {
                            configuration
                            history
                        }
                    } else if error != nil { Button("Retry") { Task { await load() } } }
                    else { ProgressView("Loading attention…").frame(maxWidth: .infinity) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .task(id: "\(agentID):\(apiClient.baseURL.absoluteString)") {
                await load()
                guard loaded else { return }
                if let initialFindingID {
                    showHistory = true
                    await Task.yield()
                    proxy.scrollTo(initialFindingID, anchor: .center)
                }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if scenePhase == .active { await refreshInbox() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshInbox() } }
            }
        }
        .background(theme.colors.background)
        .mobileScreenBackground()
        .navigationTitle("Proactivity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsGroup("Schedule", icon: "clock") {
                settingRow("Background checks") {
                    Toggle("Background checks", isOn: $heartbeat.enabled)
                        .labelsHidden()
                        .tint(theme.colors.accent)
                        .accessibilityIdentifier("proactivity.enabled")
                }
                rowDivider
                settingRow("Behavior") {
                    Picker("Behavior", selection: $heartbeat.mode) {
                        Text("Checklist").tag(AgentHeartbeatMode.checklist)
                        Text("Proactive attention").tag(AgentHeartbeatMode.proactive)
                    }
                    .labelsHidden()
                    .tint(theme.colors.textPrimary)
                    .onChange(of: heartbeat.mode) { _, mode in
                        heartbeat.intervalMinutes = mode == .proactive ? 30 : 5
                    }
                }
                rowDivider
                settingRow("Check interval") {
                    Stepper("\(heartbeat.intervalMinutes) min", value: $heartbeat.intervalMinutes,
                            in: (heartbeat.mode == .proactive ? 5 : 1)...1_440)
                        .fixedSize()
                        .monospacedDigit()
                }
                if heartbeat.mode == .proactive {
                    rowDivider
                    settingRow("Review model") {
                        Picker("Review model", selection: $heartbeat.proactive.analysisModel) {
                            Text("Choose a model").tag("")
                            ForEach(models) { model in Text(model.title).tag(model.id) }
                        }
                        .labelsHidden()
                        .tint(theme.colors.textPrimary)
                        .accessibilityIdentifier("proactivity.model")
                    }
                }
            }
            if heartbeat.mode == .proactive {
                Text("Your agent reviews changes and suggests a next step. You decide what happens next.")
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 4)
                settingsGroup("Projects to watch", icon: "folder") {
                    if projects.isEmpty { emptySetting("No projects available.") }
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { rowDivider }
                        settingRow(project.name) {
                            Toggle(project.name, isOn: selection(project.id, in: \AgentProactiveSettings.projectIds))
                                .labelsHidden()
                                .tint(theme.colors.accent)
                                .accessibilityIdentifier("proactivity.project.\(project.id)")
                        }
                    }
                }
                settingsGroup("Pull requests", icon: "arrow.triangle.branch") {
                    if providers.isEmpty { emptySetting("Connect a review provider to watch PRs.") }
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { rowDivider }
                        settingRow(provider.displayName) {
                            Toggle(provider.displayName, isOn: selection(provider.id, in: \AgentProactiveSettings.reviewProviderIds))
                                .labelsHidden()
                                .tint(theme.colors.accent)
                        }
                    }
                }
                Text("Your authored PRs and requests for your review.")
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 4)
                settingsGroup("Notification hours", icon: "bell") {
                    settingRow("From") {
                        Picker("From", selection: $heartbeat.proactive.notificationStartHour) {
                            ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }.labelsHidden().tint(theme.colors.textPrimary).monospacedDigit()
                    }
                    rowDivider
                    settingRow("Until") {
                        Picker("Until", selection: $heartbeat.proactive.notificationEndHour) {
                            ForEach(1..<25) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }.labelsHidden().tint(theme.colors.textPrimary).monospacedDigit()
                    }
                    rowDivider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Time zone").font(.subheadline)
                        TextField("Europe/Moscow", text: $heartbeat.proactive.timeZone)
                            .font(.subheadline.monospaced())
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(theme.colors.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.colors.border, lineWidth: 1) }
                            .accessibilityIdentifier("proactivity.timezone")
                    }.padding(16)
                }
                Text("Overnight findings wait until notification hours begin, then arrive together.")
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 4)
            }
            settingsGroup("Instructions", icon: "text.alignleft") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tell your agent what deserves your attention.")
                        .font(.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                    TextEditor(text: $instructions)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 130)
                        .padding(8)
                        .background(theme.colors.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.colors.border, lineWidth: 1) }
                        .accessibilityIdentifier("proactivity.instructions")
                }.padding(16)
            }
            Button { Task { await save() } } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView().controlSize(.small) }
                    Text(saving ? "Saving…" : "Save changes").fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.colors.accent)
            .disabled(saving)
            .accessibilityIdentifier("proactivity.save")
        }
    }

    private func settingsGroup<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.colors.textSecondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.surfaceRaised.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.colors.border.opacity(0.8), lineWidth: 1) }
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text(title).font(.subheadline).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                content().font(.subheadline).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline)
                content().font(.subheadline)
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().overlay(theme.colors.border.opacity(0.6)).padding(.leading, 16)
    }

    private func emptySetting(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(theme.colors.textSecondary).padding(16)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Attention", systemImage: "bell.badge").font(.headline)
                Spacer()
                Button { Task { await refreshInbox() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).accessibilityLabel("Refresh findings")
            }
            if let checked = inbox.lastCheckedAt {
                Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(theme.colors.textSecondary)
            }
            if inbox.pendingAnalysisCount > 0 {
                Label("\(inbox.pendingAnalysisCount) reviews queued", systemImage: "clock").font(.caption)
            }
            ForEach(inbox.sourceErrors.keys.sorted(), id: \.self) { key in
                Text("\(key): \(inbox.sourceErrors[key] ?? "")").font(.caption).foregroundStyle(theme.colors.statusWarning)
            }
            if let error = inbox.lastAnalysisError {
                Text("Review could not finish: \(error)").font(.caption).foregroundStyle(theme.colors.statusWarning)
            }
            Picker("Finding history", selection: $showHistory) {
                Text("Active").tag(false)
                Text("All history").tag(true)
            }.pickerStyle(.segmented)
            let findings = inbox.findings.filter { showHistory || ($0.dismissedAt == nil && $0.resolvedAt == nil) }
            if findings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.title).foregroundStyle(theme.colors.textMuted)
                    Text("Nothing needs your attention.").font(.subheadline).foregroundStyle(theme.colors.textSecondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            ForEach(findings) { finding in findingCard(finding).id(finding.id) }
        }
        .accessibilityIdentifier("proactivity.inbox")
    }

    private func findingCard(_ finding: ProactiveFinding) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label(finding.source.kind == .task ? "Task" : "Pull request",
                      systemImage: finding.source.kind == .task ? "checklist" : "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(theme.colors.textSecondary)
                Text(finding.source.title).font(.headline)
                Text(finding.outcome == .needsInput ? "Your input is needed" : "Suggested action")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.colors.statusWarning)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(theme.colors.statusWarning.opacity(0.1), in: Capsule())
            }
            findingText("Why it matters", finding.reason)
            findingText("What happened", finding.evidence)
            VStack(alignment: .leading, spacing: 6) {
                Label("Next step", systemImage: "arrow.turn.down.right").font(.caption.weight(.semibold))
                Text(finding.nextStep).font(.subheadline).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(theme.colors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            if let until = finding.snoozedUntil {
                Label("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption).foregroundStyle(theme.colors.textSecondary)
            }
            HStack(spacing: 10) {
                if let url = DeepLink.session(agentId: agentID, sessionId: finding.sessionId).url {
                    Link("Discuss", destination: url).buttonStyle(.borderedProminent).tint(theme.colors.accent)
                }
                if let project = finding.source.projectId, let task = finding.source.taskId,
                   let url = DeepLink.task(projectId: project, taskId: task).url {
                    Link("Open task", destination: url).buttonStyle(.bordered)
                } else if let raw = finding.source.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
                    Link("Open source", destination: url).buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Menu { findingActions(finding) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("More finding actions")
            }.controlSize(.regular)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceRaised.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.colors.border.opacity(0.8), lineWidth: 1) }
        .accessibilityIdentifier("proactivity.finding.\(finding.id)")
    }

    private func findingText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(theme.colors.textSecondary)
            Text(text).font(.subheadline).textSelection(.enabled)
        }
    }

    @ViewBuilder private func findingActions(_ finding: ProactiveFinding) -> some View {
        Button { Task { await act(finding, .read) } } label: { Label("Mark read", systemImage: "checkmark") }
            .disabled(finding.readAt != nil || actionID == finding.id)
        Button { Task { await act(finding, .snooze) } } label: { Label("Snooze 24 hours", systemImage: "clock") }
            .disabled(actionID == finding.id)
        Button { Task { await act(finding, .dismiss) } } label: { Label("Dismiss", systemImage: "xmark") }
            .disabled(finding.dismissedAt != nil || actionID == finding.id)
    }

    private func selection(_ id: String, in keyPath: WritableKeyPath<AgentProactiveSettings, [String]>) -> Binding<Bool> {
        Binding(get: { heartbeat.proactive[keyPath: keyPath].contains(id) }, set: { enabled in
            if enabled { if !heartbeat.proactive[keyPath: keyPath].contains(id) { heartbeat.proactive[keyPath: keyPath].append(id) } }
            else { heartbeat.proactive[keyPath: keyPath].removeAll { $0 == id } }
        })
    }

    private func load() async {
        do {
            async let configuration = apiClient.fetchProactiveSettings(agentId: agentID)
            async let projects = apiClient.fetchProjects()
            async let providers = apiClient.fetchCodeReviewProviders()
            async let inbox = apiClient.fetchProactiveInbox(agentId: agentID)
            let values = try await (configuration, projects, providers, inbox)
            heartbeat = values.0.heartbeat; instructions = values.0.heartbeatMarkdown; models = values.0.availableModels
            self.projects = values.1.filter { $0.isArchived != true }; self.providers = values.2; self.inbox = values.3
            error = nil; loaded = true
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    private func refreshInbox() async {
        do { inbox = try await apiClient.fetchProactiveInbox(agentId: agentID); error = nil }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            let result = try await apiClient.updateProactiveSettings(agentId: agentID, request: .init(heartbeat: heartbeat, heartbeatMarkdown: instructions))
            heartbeat = result.heartbeat; instructions = result.heartbeatMarkdown; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ finding: ProactiveFinding, _ action: ProactiveFindingActionRequest.Action) async {
        actionID = finding.id; defer { actionID = nil }
        do { _ = try await apiClient.updateProactiveFinding(agentId: agentID, findingId: finding.id, action: action); await refreshInbox() }
        catch { self.error = error.localizedDescription }
    }
}
