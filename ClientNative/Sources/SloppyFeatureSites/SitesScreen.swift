import Observation
import SloppyClientCore
import SloppyClientUI
import SwiftUI

@Observable
@MainActor
public final class SitesViewModel {
    public private(set) var sites: [PublishedSiteRecord] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let apiClient: SloppyAPIClient

    public init(apiClient: SloppyAPIClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await apiClient.fetchPublishedSites()
            sites = try await ClientBackgroundWork.run { fetched.sorted { $0.updatedAt > $1.updatedAt } }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func update(_ site: PublishedSiteRecord, request: PublishedSiteUpdateRequest) async {
        let previous = sites
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            if let title = request.title { sites[index].title = title }
            if let slug = request.slug {
                sites[index].slug = slug
                sites[index].path = "/sites/\(slug)/"
            }
            if let visibility = request.visibility { sites[index].visibility = visibility }
            sites[index].updatedAt = Date()
        }
        do {
            let updated = try await apiClient.updatePublishedSite(id: site.id, request: request)
            replace(updated)
            errorMessage = nil
            await load()
        } catch {
            sites = previous
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ site: PublishedSiteRecord) async {
        let previous = sites
        sites.removeAll { $0.id == site.id }
        do {
            try await apiClient.deletePublishedSite(id: site.id)
            errorMessage = nil
            await load()
        } catch {
            sites = previous
            errorMessage = error.localizedDescription
        }
    }

    public func launchURL(for site: PublishedSiteRecord) async throws -> URL {
        try await apiClient.createPublishedSiteLaunch(id: site.id)
    }

    public func directURL(for site: PublishedSiteRecord) -> URL? {
        URL(string: site.path, relativeTo: apiClient.baseURL)?.absoluteURL
    }

    private func replace(_ site: PublishedSiteRecord) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else {
            sites.insert(site, at: 0)
            return
        }
        sites[index] = site
    }
}

public struct SitesScreen: View {
    fileprivate struct EditDraft: Identifiable {
        var id: String { site.id }
        var site: PublishedSiteRecord
        var title: String
        var slug: String
        var visibility: PublishedSiteVisibility
    }

    @State private var viewModel: SitesViewModel
    @State private var searchText = ""
    @State private var editDraft: EditDraft?
    @State private var sitePendingDeletion: PublishedSiteRecord?
    @Environment(\.openURL) private var openURL

    private let onCreate: @MainActor () -> Void

    public init(apiClient: SloppyAPIClient, onCreate: @escaping @MainActor () -> Void) {
        _viewModel = State(initialValue: SitesViewModel(apiClient: apiClient))
        self.onCreate = onCreate
    }

    private var filteredSites: [PublishedSiteRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.sites }
        return viewModel.sites.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage, !viewModel.sites.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $searchText, prompt: "Search sites")
        .mobileScreenBackground()
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $editDraft) { draft in
            SiteEditSheet(draft: draft) { request in
                editDraft = nil
                Task { await viewModel.update(draft.site, request: request) }
            }
        }
        .confirmationDialog(
            "Delete published site?",
            isPresented: Binding(
                get: { sitePendingDeletion != nil },
                set: { if !$0 { sitePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: sitePendingDeletion
        ) { site in
            Button("Delete \(site.title)", role: .destructive) {
                sitePendingDeletion = nil
                Task { await viewModel.delete(site) }
            }
            Button("Cancel", role: .cancel) { sitePendingDeletion = nil }
        } message: { site in
            Text("The deployed bundle at \(site.path) will be permanently removed.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sites")
                    .font(.largeTitle.weight(.semibold))
                Text("Turn your projects into live static websites")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await viewModel.load() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh sites")
            Button("Create", systemImage: "plus", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.sites.isEmpty {
            LoadingSkeleton("Loading sites…")
        } else if let error = viewModel.errorMessage, viewModel.sites.isEmpty {
            ContentUnavailableView(
                "Sites unavailable",
                systemImage: "globe.badge.chevron.backward",
                description: Text(error)
            )
        } else if filteredSites.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No sites yet" : "No results",
                systemImage: "globe",
                description: Text(searchText.isEmpty
                    ? "Build a web project with an agent, then publish it here."
                    : "Try a different search term.")
            )
        } else {
            List(filteredSites) { site in
                SiteRow(
                    site: site,
                    directURL: viewModel.directURL(for: site),
                    onOpen: { open(site) },
                    onEdit: {
                        editDraft = EditDraft(
                            site: site,
                            title: site.title,
                            slug: site.slug,
                            visibility: site.visibility
                        )
                    },
                    onDelete: { sitePendingDeletion = site }
                )
            }
            .listStyle(.inset)
        }
    }

    private func open(_ site: PublishedSiteRecord) {
        Task {
            do {
                openURL(try await viewModel.launchURL(for: site))
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct SiteRow: View {
    let site: PublishedSiteRecord
    let directURL: URL?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(site.title)
                    .font(.headline)
                    .lineLimit(1)
                Button(action: onOpen) {
                    Label(site.path, systemImage: "arrow.up.right")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text(site.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            Label(
                site.visibility == .private ? "Only you" : "Public",
                systemImage: site.visibility == .private ? "lock" : "globe"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let directURL {
                ShareLink(item: directURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Menu {
                Button("Open in browser", systemImage: "arrow.up.right.square", action: onOpen)
                Button("Edit", systemImage: "pencil", action: onEdit)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }
}

private struct SiteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var slug: String
    @State private var isPublic: Bool
    let onSave: (PublishedSiteUpdateRequest) -> Void

    init(draft: SitesScreen.EditDraft, onSave: @escaping (PublishedSiteUpdateRequest) -> Void) {
        _title = State(initialValue: draft.title)
        _slug = State(initialValue: draft.slug)
        _isPublic = State(initialValue: draft.visibility == .public)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Slug", text: $slug)
                Toggle("Public access", isOn: $isPublic)
            }
            .mobileScreenBackground()
            .navigationTitle("Site settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: { dismiss() })
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(PublishedSiteUpdateRequest(
                            title: title,
                            slug: slug,
                            visibility: isPublic ? .public : .private
                        ))
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }
}
