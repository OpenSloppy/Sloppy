import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
struct ChatUsageScreen: View {
    let apiClient: SloppyAPIClient
    let instanceTitle: String
    let onOpenSession: (ChatSessionSummary) -> Void

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    @State private var period: UsagePeriod = .week
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Date()
    @State private var summaries: [ChatUsageSummary] = []
    @State private var sessionsByChannel: [String: ChatSessionSummary] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var catalogWarning: String?
    @State private var searchText = ""
    @State private var refreshID = 0

    private enum UsagePeriod: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days", custom = "Custom"
        var id: Self { self }
    }

    private var totalTokens: Int { summaries.reduce(0) { $0 + $1.totalTokens } }
    private var visibleSummaries: [ChatUsageSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? summaries : summaries.filter {
            title(for: $0).localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                periodControls
                if isLoading {
                    ProgressView("Loading usage…").frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Usage unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { refreshID += 1 }
                    }
                } else {
                    totals
                    Text("Recorded model tokens on this instance. Shares show each chat’s portion of token usage during the period. Subscription quota percentages are unavailable. Routing calls are excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let catalogWarning {
                        Label(catalogWarning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if summaries.isEmpty {
                        ContentUnavailableView("No recorded usage", systemImage: "chart.bar",
                                               description: Text("There are no recorded model calls in this period. Providers that do not report usage cannot be counted."))
                    } else {
                        usageList
                    }
                }
            }
            .padding(idiom == .phone ? 16 : 28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .mobileScreenBackground()
        .navigationTitle("Usage")
        .accessibilityIdentifier("chat-usage.screen")
        .task(id: "\(period.rawValue)|\(startDate)|\(endDate)|\(refreshID)|\(apiClient.endpoint.cacheNamespace)") {
            await load()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chat usage").font(idiom == .phone ? .title3.bold() : .largeTitle.bold())
                Text(instanceTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            #if os(macOS)
            Button { refreshID += 1 } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            #endif
        }
    }

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            if period == .custom {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        datePickers
                    }
                    VStack(alignment: .leading) { datePickers }
                }
            }
        }
    }

    @ViewBuilder private var datePickers: some View {
        DatePicker("From", selection: $startDate, in: ...endDate, displayedComponents: .date)
        DatePicker("Through", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
    }

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading, spacing: 16) {
            metric("Total tokens", value: totalTokens)
            metric("Input", value: summaries.reduce(0) { $0 + $1.inputTokens })
            metric("Output", value: summaries.reduce(0) { $0 + $1.outputTokens })
            metric("Channels", value: summaries.count)
        }
    }

    private func metric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var usageList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("By chat").font(.title3.bold())
                Spacer()
                Text("Largest usage first").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search chats", text: $searchText)
                .textFieldStyle(.roundedBorder)
            LazyVStack(spacing: 0) {
                ForEach(visibleSummaries) { summary in
                    let session = sessionsByChannel[summary.id]
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let session {
                                    Button { onOpenSession(session) } label: {
                                        Text(title(for: summary)).font(.headline).multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open chat")
                                } else {
                                    Text(title(for: summary)).font(.headline)
                                }
                                Text("\(summary.requestCount.formatted()) usage records · \(summary.inputTokens.formatted()) input · \(summary.outputTokens.formatted()) output")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(summary.totalTokens.formatted()).font(.headline).monospacedDigit()
                                Text(share(for: summary).formatted(.percent.precision(.fractionLength(1))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: share(for: summary)).tint(theme.colors.accent)
                        DisclosureGroup("Token details") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cached input: \(summary.cachedTokens.formatted())")
                                Text("Cache creation: \(summary.cacheCreationTokens.formatted())")
                                Text("Reasoning: \(summary.reasoningTokens.formatted())")
                                Text("Cache and reasoning counters are provider details; they are not added again to the total.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 16)
                    Divider()
                }
            }
            if visibleSummaries.isEmpty {
                Text("No matching chats").foregroundStyle(.secondary)
            }
        }
    }

    private func title(for summary: ChatUsageSummary) -> String {
        sessionsByChannel[summary.id]?.title ?? summary.id
    }

    private func share(for summary: ChatUsageSummary) -> Double {
        totalTokens > 0 ? Double(summary.totalTokens) / Double(totalTokens) : 0
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        catalogWarning = nil
        summaries = []
        sessionsByChannel = [:]
        let now = Date()
        let calendar = Calendar.current
        let from: Date
        let to: Date
        if period == .custom {
            from = calendar.startOfDay(for: startDate)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? now
            to = min(now, nextDay.addingTimeInterval(-0.001))
        } else {
            let days = period == .week ? 6 : period == .month ? 29 : 0
            from = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
            to = now
        }
        do {
            let records = try await apiClient.fetchChatUsage(from: from, to: to)
            var catalog: [String: ChatSessionSummary] = [:]
            var warning: String?
            do {
                let agents = try await apiClient.fetchAgents()
                for agent in agents {
                    try Task.checkCancellation()
                    do {
                        let sessions = try await apiClient.fetchAgentSessions(agentId: agent.id)
                        for session in sessions {
                            catalog["agent:\(session.agentId):session:\(session.id)"] = session
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { warning = "Some chat titles could not be loaded. Usage is still shown by channel ID." }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warning = "Chat titles could not be loaded. Usage is still shown by channel ID." }
            try Task.checkCancellation()
            summaries = ChatUsageSummary.grouped(records)
            sessionsByChannel = catalog
            catalogWarning = warning
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
