import Foundation
import Observation

/// Status of the selected Core instance, independent of native client updates.
public struct BackendUpdateStatus: Decodable, Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String?
    public let updateAvailable: Bool
    public let releaseUrl: String?
    public let isReleaseBuild: Bool
    public let deploymentKind: String?
    public let latestCommit: String?
    public let updateKind: String?

    public var availableUpdate: String? {
        guard updateAvailable else { return nil }
        if updateKind == "git" { return latestCommit.map { String($0.prefix(8)) } }
        return latestVersion
    }

    public var releaseTag: String? {
        guard let latestVersion else { return nil }
        // Core removes the leading v from its display version. Prefer the original tag in the release link.
        if let url = releaseURL, url.host?.lowercased() == "github.com" {
            let parts = url.pathComponents
            if parts.count == 6, parts[1].lowercased() == "teamsloppy", parts[2].lowercased() == "sloppy",
               parts[3] == "releases", parts[4] == "tag" {
                return parts[5]
            }
        }
        return latestVersion.hasPrefix("v") ? latestVersion : "v" + latestVersion
    }

    public var releaseURL: URL? {
        guard let releaseUrl, let url = URL(string: releaseUrl),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

extension SloppyAPIClient {
    public func fetchBackendUpdateStatus(force: Bool = false) async throws -> BackendUpdateStatus {
        if force {
            return try await http.post("/v1/updates/check", body: [String: String]())
        }
        return try await http.get("/v1/updates/check")
    }

    func backendProcessID() async throws -> Int32 {
        struct Health: Decodable { let pid: Int32 }
        let health: Health = try await http.get("/health")
        return health.pid
    }
}

@MainActor
@Observable
public final class BackendUpdateModel {
    public typealias Fetch = @Sendable (Bool) async throws -> BackendUpdateStatus
    public typealias Eligibility = @MainActor @Sendable (BackendUpdateStatus) async -> Bool
    public typealias Install = @MainActor @Sendable (String, @escaping BackendInstallerProgress) async throws -> Void
    public typealias BackendInstallerProgress = @MainActor @Sendable (String) -> Void

    public private(set) var status: BackendUpdateStatus?
    public private(set) var isChecking = false
    public private(set) var isInstalling = false
    public private(set) var canInstall = false
    public private(set) var errorMessage: String?
    public private(set) var installationDetail: String?
    private var dismissedUpdate: String?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let eligibility: Eligibility
    @ObservationIgnored private let install: Install

    public var reminderVersion: String? {
        guard let update = status?.availableUpdate, update != dismissedUpdate else { return nil }
        return update
    }

    public init(fetch: @escaping Fetch, eligibility: @escaping Eligibility, install: @escaping Install) {
        self.fetch = fetch
        self.eligibility = eligibility
        self.install = install
    }

    public convenience init(endpoint: SloppyInstanceEndpoint) {
        let api = SloppyAPIClient(endpoint: endpoint)
        self.init(
            fetch: { try await api.fetchBackendUpdateStatus(force: $0) },
            eligibility: { status in
                #if os(macOS)
                guard status.isReleaseBuild, status.updateKind != "git", status.deploymentKind == "local",
                      case .direct(let url) = endpoint,
                      let pid = try? await api.backendProcessID() else { return false }
                return LocalBackendLauncher.shared.ownsManagedBackend(at: url, processID: pid)
                #else
                return false
                #endif
            },
            install: { tag, progress in
                #if os(macOS)
                guard case .direct(let url) = endpoint else { throw BackendUpdateError.unmanagedBackend }
                let pid = try await api.backendProcessID()
                guard LocalBackendLauncher.shared.ownsManagedBackend(at: url, processID: pid) else {
                    throw BackendUpdateError.unmanagedBackend
                }
                _ = try await BackendInstaller().install(releaseTag: tag) { update in
                    progress(update.detail)
                }
                progress("Restarting Sloppy backend")
                try await LocalBackendLauncher.shared.restartManagedBackend(at: url, processID: pid)
                let running = try await api.fetchBackendUpdateStatus()
                guard running.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                        == tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) else {
                    throw BackendUpdateError.restartFailed
                }
                #else
                throw BackendUpdateError.unmanagedBackend
                #endif
            }
        )
    }

    public func check(force: Bool = false) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await fetch(force)
            try Task.checkCancellation()
            let eligible = await eligibility(result)
            try Task.checkCancellation()
            status = result
            canInstall = eligible
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Owned by a SwiftUI task: disconnecting or selecting another instance cancels polling.
    public func monitor(interval: Duration = .seconds(3600)) async {
        while !Task.isCancelled {
            await check(force: true)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func dismissReminder() { dismissedUpdate = status?.availableUpdate }

    public func installUpdate() async {
        guard !isInstalling, !isChecking, canInstall,
              let status, status.updateAvailable, let tag = status.releaseTag else { return }
        isInstalling = true
        errorMessage = nil
        installationDetail = "Preparing backend update"
        do {
            // Ownership may have changed since the check or while reviewing the offer.
            canInstall = await eligibility(status)
            guard canInstall else { throw BackendUpdateError.unmanagedBackend }
            try await install(tag) { [weak self] detail in self?.installationDetail = detail }
            installationDetail = "Backend updated to \(tag)"
            self.status = nil
            canInstall = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalling = false
        if errorMessage == nil { await check(force: true) }
    }
}

public enum BackendUpdateError: LocalizedError {
    case unmanagedBackend
    case restartFailed

    public var errorDescription: String? {
        switch self {
        case .unmanagedBackend: "Update this backend on its host using the original installation method."
        case .restartFailed: "The updated backend could not be started. Check the backend log and retry the connection."
        }
    }
}
