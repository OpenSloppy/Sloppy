import Foundation
import SwiftUI
import SloppyClientCore

@MainActor
struct UsageBreakdownSection: View {
    let apiClient: SloppyAPIClient
    let from: Date
    let to: Date
    let revision: Int
    let sessions: [String: ChatSessionSummary]
    let onOpenSession: (ChatSessionSummary) -> Void
    @State private var provider = ""
    @State private var model = ""
    @State private var serverId = ""
    @State private var grouping = "tool"
    @State private var data: UsageBreakdownResponse?
    @State private var error: String?
    @State private var selected: String?
    @State private var calls: [UsageBreakdownCall] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var detailLoading = false
    @State private var detailError: String?
    @State private var retry = 0

    init(apiClient: SloppyAPIClient, from: Date, to: Date, revision: Int,
         sessions: [String: ChatSessionSummary], onOpenSession: @escaping (ChatSessionSummary) -> Void,
         initialResponse: UsageBreakdownResponse? = nil) {
        self.apiClient = apiClient; self.from = from; self.to = to; self.revision = revision
        self.sessions = sessions; self.onOpenSession = onOpenSession
        _data = State(initialValue: initialResponse)
    }

    private var requestKey: String { "\(from)|\(to)|\(grouping)|\(revision)|\(retry)|\(provider)|\(model)|\(serverId)|\(apiClient.endpoint.cacheNamespace)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("Tools, MCP & skills").font(.title2.bold())
            Picker("Group by", selection: $grouping) {
                Text("Tools").tag("tool")
                Text("MCP").tag("server")
                Text("Skills").tag("skill")
            }
            .pickerStyle(.segmented).frame(maxWidth: 480)
            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Provider identifier", text: $provider)
                    TextField("Exact model identifier", text: $model)
                    TextField("MCP server identifier", text: $serverId)
                }
                .textFieldStyle(.roundedBorder)
            }
            if loading { ProgressView("Loading breakdown…") }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { retry += 1 }
            }
            if let data {
                Text("\(data.providerUsage.total.formatted()) provider reported tokens")
                    .font(.headline).monospacedDigit()
                Text("\(data.providerUsage.prompt.formatted()) input · \(data.providerUsage.completion.formatted()) output · \(data.providerUsage.cachedInput.formatted()) cached · \(data.providerUsage.cacheCreationInput.formatted()) cache creation · \(data.providerUsage.reasoning.formatted()) reasoning")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Usage reported for \(data.reportedRequestCount) of \(data.requestCount) observed requests; full attribution for \(data.completeRequestCount).")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = data.collectionStartedAt {
                    Text("Collection started \(date.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Local counts describe visible payloads; estimates are approximate. Neither is exact billing. Tool and skill views overlap. MCP server internal usage and token savings are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                if data.groups.isEmpty { Text("No measurements in this period.").foregroundStyle(.secondary) }
                ForEach(data.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { selected = selected == group.id ? nil : group.id } label: {
                            HStack(alignment: .top) {
                                Text(group.id).font(.headline).multilineTextAlignment(.leading)
                                Spacer(minLength: 12)
                                Text(group.totalTokens.formatted()).font(.headline).monospacedDigit()
                                Image(systemName: selected == group.id ? "chevron.up" : "chevron.down")
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(group.id), \(group.totalTokens) tokens, details")
                        Text("\(group.calls) \(grouping == "skill" ? "loads" : "calls") · \(group.failures) errors · \(group.countingLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { metrics(group) }
                            VStack(alignment: .leading, spacing: 6) { metrics(group) }
                        }
                        .font(.caption).monospacedDigit()
                        if selected == group.id { callDetails }
                        Divider()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .accessibilityIdentifier("usage-breakdown.section")
        .task(id: requestKey) { await load() }
        .task(id: "\(requestKey)|\(selected ?? "")") { await loadCalls(append: false) }
    }
    @ViewBuilder private func metrics(_ group: UsageBreakdownGroup) -> some View {
        Text("Arguments: \(group.argumentsTokens.formatted())")
        Text("Result input: \(group.resultTokens.formatted())")
        Text("Replay: \(group.replayTokens.formatted())")
        Text(grouping == "skill" ? "Catalog: \(group.catalogTokens.formatted())" : "Schemas: \(group.schemaTokens.formatted())")
        if let average = group.averagePerCall { Text("Average/call: \(average.formatted(.number.precision(.fractionLength(1))))") }
    }
    private var callDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if detailLoading { ProgressView("Loading calls…") }
            if let detailError {
                Text(detailError).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadCalls(append: false) } }
            }
            ForEach(calls, id: \.stableId) { call in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(call.tool) · \(call.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    Text("\(call.argumentsTokens.formatted()) arguments · \(call.resultTokens.formatted()) result · \(call.replayTokens.formatted()) replay")
                        .font(.caption).monospacedDigit()
                    Text(call.tokenizerMeasurements > 0 ? "Local count" : call.estimatedMeasurements > 0 ? "Estimate" : "No data")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(call.ok == true ? "Succeeded" : call.ok == false ? "Failed" : "Outcome unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                    if let session = sessions[call.channelId] {
                        Button("Open chat") { onOpenSession(session) }.font(.caption)
                    } else { Text(call.channelId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            if !detailLoading && detailError == nil && calls.isEmpty {
                Text("No calls generated in this period. Catalog and replay measurements can exist without new calls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if cursor != nil { Button("Load more") { Task { await loadCalls(append: true) } }.disabled(detailLoading) }
        }
        .padding(.vertical, 8)
    }
    private func load() async {
        loading = true; data = nil; error = nil; selected = nil
        do {
            let result = try await apiClient.fetchUsageBreakdown(from: from, to: to, groupBy: grouping, provider: provider, model: model, serverId: serverId)
            try Task.checkCancellation()
            data = result; loading = false
        } catch is CancellationError { return }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; loading = false }
    }
    private func loadCalls(append: Bool) async {
        guard let selected else { calls = []; cursor = nil; detailLoading = false; return }
        let key = requestKey
        if !append { calls = []; cursor = nil }
        detailLoading = true; detailError = nil
        do {
            let result = try await apiClient.fetchUsageBreakdown(from: from, to: to, groupBy: grouping, groupId: selected, cursor: append ? cursor : nil, provider: provider, model: model, serverId: serverId)
            try Task.checkCancellation()
            guard self.selected == selected, requestKey == key else { return }
            let seen = Set(calls.map(\.stableId))
            calls += result.calls.filter { !seen.contains($0.stableId) }; cursor = result.nextCursor; detailLoading = false
        } catch is CancellationError { return }
        catch { guard self.selected == selected, requestKey == key else { return }; detailError = error.localizedDescription; detailLoading = false }
    }
}
