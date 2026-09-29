#if os(macOS)
import Foundation
import Observation
import AppKit
import Darwin

@MainActor @Observable
public final class ClientMigrationController {
    public var sources: [MigrationSource] = []
    public var selectedSources: Set<String> = []
    public var catalog = MigrationCatalog()
    public var selectedItems: Set<String> = []
    public var agentMappings: [String: String] = [:]
    public var projectMappings: [String: String] = [:]
    public var agents: [APIAgentRecord] = []
    public var preview: MigrationPreview?
    public var job: MigrationJob?
    public var history: [MigrationJob] = []
    public var step = 0
    public var busy = false
    public var error: String?
    public var mcpResults: [MigrationMCPStatus] = []
    public let api: SloppyAPIClient
    public let destination: String
    private let uploadFolder: URL
    private var accessURLs: [URL] = []
    public init(endpoint: SloppyInstanceEndpoint, destinationKey: String) {
        api = SloppyAPIClient(endpoint: endpoint)
        destination = endpoint.coordinatorBaseURL.absoluteString + " · " + destinationKey
        uploadFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sloppy/Migrations/" + MigrationDigest.id(destinationKey))
        restoreBookmarks()
        sources = Self.discover()
        selectedSources = Set(sources.map(\.id))
    }
    isolated deinit { for url in accessURLs { url.stopAccessingSecurityScopedResource() } }
    public static func discover() -> [MigrationSource] {
        var granted: [URL] = []
        for data in UserDefaults.standard.array(forKey: "migration.bookmarks") as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() { granted.append(url) }
        }
        defer { for url in granted { url.stopAccessingSecurityScopedResource() } }
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath: String(cString: $0)) } ?? FileManager.default.homeDirectoryForCurrentUser
        return MigrationScanner.discover(home: home)
    }
    public static func newSources(defaults: UserDefaults = .standard) -> [MigrationSource] {
        let seen = Set(defaults.stringArray(forKey: "migration.offeredSources") ?? [])
        let found = discover()
        if !found.isEmpty { return found.filter { !seen.contains($0.id) } }
        let actualHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
        guard let actualHome, actualHome != FileManager.default.homeDirectoryForCurrentUser.path,
              !defaults.bool(forKey: "migration.permissionOfferShown") else { return [] }
        // A sandbox cannot distinguish absent data from denied access. Offer folder authorization once without claiming installations were found.
        return MigrationSourceKind.allCases.map { MigrationSource(kind: $0, path: actualHome + "/" + $0.directoryName, readable: false) }.filter { !seen.contains($0.id) }
    }
    public static func markOffered(_ sources: [MigrationSource], defaults: UserDefaults = .standard) {
        if sources.contains(where: { !$0.readable }) { defaults.set(true, forKey: "migration.permissionOfferShown") }
        let ids = Set(defaults.stringArray(forKey: "migration.offeredSources") ?? []).union(sources.filter(\.readable).map(\.id))
        defaults.set(Array(ids), forKey: "migration.offeredSources")
    }
    public var selection: MigrationSelection {
        .init(items: catalog.items.filter { selectedItems.contains($0.id) }, agentMappings: agentMappings, projectMappings: projectMappings, warnings: catalog.warnings)
    }
    public var profiles: [String] { Array(Set(selection.items.map(\.profileKey))).sorted() }
    public var projectPaths: [String] { Array(Set(selection.items.compactMap(\.projectPath))).sorted() }
    public func loadHistory() async {
        do { agents = try await api.fetchAgents(); history = try await api.fetchMigrations() }
        catch { self.error = error.localizedDescription }
    }
    public func chooseFolder(kind: MigrationSourceKind) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.message = "Choose the \(kind.directoryName) folder. For Codex shared skills and Claude global MCP, choose your home folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var values = UserDefaults.standard.array(forKey: "migration.bookmarks") as? [Data] ?? []; values.append(bookmark)
            UserDefaults.standard.set(values, forKey: "migration.bookmarks")
        }
        let child = url.appendingPathComponent(kind.directoryName)
        let sourceURL = FileManager.default.fileExists(atPath: child.path) ? child : url
        let source = MigrationSource(kind: kind, path: sourceURL.path)
        if !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
        selectedSources.insert(source.id)
    }
    private func restoreBookmarks() {
        for data in UserDefaults.standard.array(forKey: "migration.bookmarks") as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        }
    }
    public func analyze() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let roots = sources.filter { selectedSources.contains($0.id) }
            catalog = try await Task.detached { try MigrationScanner.scan(sources: roots) }.value
            selectedItems = Set(catalog.items.map(\.id)); Self.markOffered(roots); step = 1
        } catch { self.error = error.localizedDescription }
    }
    public func makePreview() async {
        busy = true; error = nil; defer { busy = false }
        do { preview = try await api.previewMigration(selection); step = 3 }
        catch { self.error = error.localizedDescription }
    }
    public func begin() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let data = try MigrationDigest.encoder.encode(selection)
            try FileManager.default.createDirectory(at: uploadFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let digest = MigrationDigest.sha256(data)
            let snapshot = uploadFolder.appendingPathComponent(digest + ".data")
            try data.write(to: snapshot, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            job = try await api.createMigration(.init(destination: destination, totalBytes: data.count, sha256: digest, totalItems: selection.items.count))
            guard let id = job?.id, UUID(uuidString: id) != nil else { throw MigrationError.invalid("Invalid job identity.") }
            try Data(digest.utf8).write(to: uploadFolder.appendingPathComponent(id + ".snapshot"), options: .atomic)
            step = 4
            try await transfer(data)
        } catch { self.error = error.localizedDescription }
    }
    private func transfer(_ data: Data) async throws {
        guard var current = job else { return }
        while current.uploadedBytes < data.count {
            try Task.checkCancellation()
            let offset = current.uploadedBytes; let end = min(data.count, offset + 1024 * 1024)
            current = try await api.uploadMigration(current.id, chunk: .init(offset: offset, data: Data(data[offset..<end]))); job = current
        }
        job = try await api.controlMigration(current.id, action: "start")
    }
    public func resume(_ selectedJob: MigrationJob) async {
        busy = true; error = nil; defer { busy = false }
        do {
            job = try await api.fetchMigration(selectedJob.id); step = 4
            if job?.status == .uploading || (job?.stage == .transfer && (job?.uploadedBytes ?? 0) < (job?.totalBytes ?? 0)) {
                job = try await api.controlMigration(selectedJob.id, action: "resume")
                guard UUID(uuidString: selectedJob.id) != nil else { throw MigrationError.invalid("Invalid job identity.") }
                let digest = try String(contentsOf: uploadFolder.appendingPathComponent(selectedJob.id + ".snapshot"), encoding: .utf8)
                guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw MigrationError.invalid("The upload snapshot is unavailable on this Mac.") }
                let data = try Data(contentsOf: uploadFolder.appendingPathComponent(digest + ".data"))
                guard MigrationDigest.sha256(data) == digest else { throw MigrationError.integrity }
                try await transfer(data)
            } else { job = try await api.controlMigration(selectedJob.id, action: "resume") }
        } catch { self.error = error.localizedDescription }
    }
    public func refresh() async {
        guard let id = job?.id else { return }
        do {
            job = try await api.fetchMigration(id)
            if let status = job?.status, [.completed, .completedWithIssues, .waitingForModel, .cancelled, .failed].contains(status) { step = 5 }
        } catch { self.error = error.localizedDescription }
    }
    public func cancel() async {
        guard let id = job?.id else { return }
        do { job = try await api.controlMigration(id, action: "cancel"); step = 5 }
        catch { self.error = error.localizedDescription }
    }
    public func enableMCP() async {
        guard let job else { return }
        do { mcpResults = try await api.enableMigrationMCP(job.id, ids: job.outcomes.compactMap(\.mcpID)) }
        catch { self.error = error.localizedDescription }
    }
}
#endif
