import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct PullRequestsScreen: View {
    let apiClient: SloppyAPIClient
    let onOpenChat: @MainActor (CodeReviewDetail) -> Void
    let onAddToSideChat: @MainActor (String) -> Void
    let onResolveOpenIssues: @MainActor (String) -> Void
    private let filterStore: CodeReviewFilterStore

    @State private var response = CodeReviewInboxResponse(items: [], providers: [])
    @State private var filters: CodeReviewInboxFilters
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var recoveryMessage: String?
    @State private var selectedReviewID: String?
    @State private var isShowingArcadiaCredential = false

#if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    init(
        apiClient: SloppyAPIClient,
        onOpenChat: @escaping @MainActor (CodeReviewDetail) -> Void,
        onAddToSideChat: @escaping @MainActor (String) -> Void,
        onResolveOpenIssues: @escaping @MainActor (String) -> Void,
        filterStore: CodeReviewFilterStore = CodeReviewFilterStore()
    ) {
        self.apiClient = apiClient
        self.onOpenChat = onOpenChat
        self.onAddToSideChat = onAddToSideChat
        self.onResolveOpenIssues = onResolveOpenIssues
        self.filterStore = filterStore
        _filters = State(initialValue: filterStore.load(endpoint: apiClient.endpoint))
    }

    var body: some View {
        reviewLayout
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mobileScreenBackground()
            .navigationTitle("Pull Requests")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task(id: requestKey) { await load() }
            .refreshable { await load() }
            .onChange(of: filters) { _, filters in
                filterStore.save(filters, endpoint: apiClient.endpoint)
            }
            .sheet(isPresented: $isShowingArcadiaCredential) {
                ArcadiaCredentialSheet(apiClient: apiClient)
            }
    }

    @ViewBuilder
    private var reviewLayout: some View {
#if os(macOS)
        HSplitView {
            inboxPane
                .frame(minWidth: 330, idealWidth: 410, maxWidth: 520)
            detailPane(showsBackButton: false)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
#else
        if horizontalSizeClass == .compact {
            if selectedItem != nil {
                detailPane(showsBackButton: true)
            } else {
                inboxPane
            }
        } else {
            HStack(spacing: 0) {
                inboxPane
                    .frame(minWidth: 310, idealWidth: 370, maxWidth: 440)
                Divider()
                detailPane(showsBackButton: false)
            }
        }
#endif
    }

    private var inboxPane: some View {
        VStack(spacing: 0) {
            filterControls
            Divider()
            content
        }
    }

    @ViewBuilder
    private func detailPane(showsBackButton: Bool) -> some View {
        if let selectedItem {
            PullRequestDetailView(
                apiClient: apiClient,
                item: selectedItem,
                showsBackButton: showsBackButton,
                onBack: { selectedReviewID = nil },
                onOpenChat: onOpenChat,
                onAddToSideChat: onAddToSideChat,
                onResolveOpenIssues: onResolveOpenIssues
            )
            .id(selectedItem.id)
        } else {
            ContentUnavailableView(
                "Select a Pull Request",
                systemImage: "arrow.triangle.branch",
                description: Text("Review comments and code changes will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedItem: CodeReviewItem? {
        response.items.first { $0.id == selectedReviewID }
    }

    private var filteredItems: [CodeReviewItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return response.items }
        return response.items.filter { item in
            [item.title, item.repository, item.author, item.providerName]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var requestKey: String {
        [filters.state.rawValue, filters.role.rawValue, filters.providerID ?? "all"].joined(separator: ":")
    }

    private var filterControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("Role", selection: $filters.role) {
                    ForEach(CodeReviewInboxRoleFilter.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search pull requests", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

                Menu {
                    Picker("State", selection: $filters.state) {
                        ForEach(CodeReviewState.allCases) { state in
                            Text(state.title).tag(state)
                        }
                    }
                    if response.providers.count > 1 {
                        Divider()
                        Picker("Provider", selection: $filters.providerID) {
                            Text("All providers").tag(String?.none)
                            ForEach(response.providers) { provider in
                                Text(provider.displayName).tag(Optional(provider.id))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Filter pull requests")

                if response.providers.contains(where: { $0.id == "arcadia-code-review" }) {
                    Button {
                        isShowingArcadiaCredential = true
                    } label: {
                        Image(systemName: "key")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Configure Arcadia token")
                }

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .accessibilityLabel("Refresh pull requests")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && response.items.isEmpty {
            LoadingSkeleton("Loading pull requests…")
        } else if let errorMessage, response.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Pull Requests", systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .textSelection(.enabled)
                    if let recoveryMessage {
                        Text(recoveryMessage)
                            .foregroundStyle(.secondary)
                    }
                    Text("Server: \(apiClient.baseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .disabled(isLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isLoading, response.providers.isEmpty {
            ContentUnavailableView(
                "No Pull Request Providers",
                systemImage: "puzzlepiece.extension",
                description: Text("Connect GitHub or install a code-review plugin.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isLoading, filteredItems.isEmpty {
            ContentUnavailableView(
                "No Pull Requests",
                systemImage: "arrow.triangle.branch",
                description: Text(
                    searchText.isEmpty
                        ? "Nothing matches the selected state, role, and provider."
                        : "Nothing matches your search."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedReviewID) {
                if !response.failures.isEmpty {
                    Section("Provider issues") {
                        ForEach(response.failures.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(providerName(for: entry.key))
                                        .font(.headline)
                                    Text(entry.value)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section {
                    ForEach(filteredItems) { item in
                        PullRequestRow(item: item)
                            .tag(item.id)
                    }
                } header: {
                    Text("\(filteredItems.count) pull requests")
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func providerName(for id: String) -> String {
        response.providers.first(where: { $0.id == id })?.displayName ?? id
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            response = try await apiClient.fetchCodeReviews(
                state: filters.state,
                roles: filters.role.roles,
                providerIDs: filters.providerID.map { [$0] } ?? []
            )
            errorMessage = nil
            recoveryMessage = nil
            if let selectedProviderID = filters.providerID,
               !response.providers.contains(where: { $0.id == selectedProviderID }) {
                filters.providerID = nil
            }
            if let selectedReviewID,
               !response.items.contains(where: { $0.id == selectedReviewID }) {
                self.selectedReviewID = nil
            }
#if os(macOS)
            if selectedReviewID == nil {
                selectedReviewID = response.items.first?.id
            }
#endif
        } catch {
            errorMessage = error.localizedDescription
            recoveryMessage = recoverySuggestion(for: error)
        }
    }

    private func recoverySuggestion(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "Check that Sloppy Core is running and reachable, then try again."
        }
        switch apiError {
        case .httpError(statusCode: 404, _):
            return "The connected Sloppy Core does not expose the Pull Requests API. Update or restart Core so it matches this client."
        case .httpError(statusCode: 401, _), .httpError(statusCode: 403, _):
            return "The server rejected this session. Reconnect the client and verify the code-review account permissions."
        case .decodingFailed:
            return "The client and Core use incompatible response formats. Update or restart both components."
        case .invalidResponse, .httpError:
            return "Check the Core status and server logs, then try again."
        }
    }
}

@MainActor
private struct ArcadiaCredentialSheet: View {
    private let providerID = "arcadia-code-review"

    let apiClient: SloppyAPIClient

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTokenFocused: Bool
    @State private var token = ""
    @State private var status: CodeReviewCredentialStatus?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Arcadia access")
                    .font(.title3.weight(.semibold))
                Text("Your token is stored only in the local macOS Keychain. It is not saved in the plugin configuration.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("Arc OAuth token", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($isTokenFocused)

            if status?.isConfigured == true {
                Label("A token is saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            HStack {
                if status?.isConfigured == true {
                    Button("Remove", role: .destructive) { Task { await remove() } }
                        .disabled(isWorking)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 460, height: 300)
        .mobileScreenBackground()
        .task {
            await load()
            isTokenFocused = true
        }
    }

    private func load() async {
        do {
            status = try await apiClient.fetchCodeReviewCredentialStatus(providerID: providerID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await apiClient.saveCodeReviewCredential(providerID: providerID, token: token)
            token = ""
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await apiClient.deleteCodeReviewCredential(providerID: providerID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct PullRequestRow: View {
    let item: CodeReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isDraft ? "circle.dashed" : stateImage)
                .foregroundStyle(stateColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if let updatedAt = item.updatedAt {
                        Text(updatedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 5) {
                    Text(repositoryLabel)
                    Text("·")
                    Text(item.providerName)
                    if let author = item.author {
                        Text("·")
                        Text(author)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if item.isDraft || item.reviewDecision?.isEmpty == false || !item.labels.isEmpty {
                    HStack(spacing: 5) {
                        if item.isDraft {
                            badge("Draft", color: .secondary)
                        }
                        if let decision = item.reviewDecision, !decision.isEmpty {
                            badge(decision.replacingOccurrences(of: "_", with: " ").capitalized, color: .blue)
                        }
                        ForEach(item.labels.prefix(2), id: \.self) { label in
                            badge(label, color: .secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var stateImage: String {
        switch item.state {
        case .open, .all: "arrow.triangle.branch"
        case .closed: "xmark.circle"
        case .merged: "arrow.triangle.merge"
        }
    }

    private var repositoryLabel: String {
        guard let number = item.number else { return item.repository }
        return "\(item.repository) #\(number)"
    }

    private var stateColor: Color {
        switch item.state {
        case .open, .all: .green
        case .closed: .red
        case .merged: .purple
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
