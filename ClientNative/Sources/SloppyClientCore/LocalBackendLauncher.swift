#if os(macOS)
import Foundation

public enum LocalBackendExecutableLocator {
    public static func installedExecutableURL(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedInstallationRoot: URL = BackendInstaller.managedInstallationRoot()
    ) -> URL? {
        var candidates = [BackendInstaller.installedExecutableURL(installationRoot: managedInstallationRoot)]
        candidates.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "sloppy") })
        candidates.append(contentsOf: [
            homeDirectory.appending(path: ".local/bin/sloppy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/sloppy"),
            URL(fileURLWithPath: "/usr/local/bin/sloppy"),
        ])

        var visited = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard visited.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }
    }
}

@MainActor
public final class LocalBackendLauncher {
    public enum Result: Equatable, Sendable {
        case alreadyRunning
        case started(URL)
        case unavailable
        case failed(String)
    }

    public static let shared = LocalBackendLauncher()

    public typealias HealthProbe = @Sendable (URL, TimeInterval) async -> Bool

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let environment: [String: String]
    private let managedInstallationRoot: URL
    private let healthProbe: HealthProbe
    private var process: Process?
    private var outputHandle: FileHandle?

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedInstallationRoot: URL = BackendInstaller.managedInstallationRoot(),
        healthProbe: @escaping HealthProbe = { baseURL, timeout in
            await HealthService(baseURL: baseURL).isHealthy(timeout: timeout)
        }
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.managedInstallationRoot = managedInstallationRoot
        self.healthProbe = healthProbe
    }

    public func ensureRunning(
        at baseURL: URL,
        startupTimeout: Duration = .seconds(8)
    ) async -> Result {
        guard ServerAddress.isLoopbackHost(baseURL.host) else { return .unavailable }

        if await healthProbe(baseURL, 0.35) {
            return .alreadyRunning
        }

        if process?.isRunning != true {
            finishExitedProcess()
            guard let executableURL = LocalBackendExecutableLocator.installedExecutableURL(
                fileManager: fileManager,
                homeDirectory: homeDirectory,
                environment: environment,
                managedInstallationRoot: managedInstallationRoot
            ) else {
                return .unavailable
            }

            do {
                try launch(executableURL)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        while clock.now < deadline {
            if Task.isCancelled { return .failed(CancellationError().localizedDescription) }
            if await healthProbe(baseURL, 0.35) {
                return .started(process?.executableURL ?? baseURL)
            }
            if process?.isRunning == false {
                let status = process?.terminationStatus
                finishExitedProcess()
                return .failed(status.map { "Sloppy exited with status \($0)." } ?? "Sloppy exited before it became ready.")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        return .failed("Sloppy did not become ready in time.")
    }

    public func ownsManagedBackend(at baseURL: URL, processID: Int32) -> Bool {
        // The launcher runs the default Core port. A different loopback service is not ours.
        guard ServerAddress.isLoopbackHost(baseURL.host), baseURL.scheme == "http",
              baseURL.port == 25101, let process, process.isRunning,
              process.processIdentifier == processID else { return false }
        return process.executableURL?.standardizedFileURL
            == BackendInstaller.installedExecutableURL(installationRoot: managedInstallationRoot).standardizedFileURL
    }

    public func restartManagedBackend(at baseURL: URL, processID: Int32) async throws {
        guard ownsManagedBackend(at: baseURL, processID: processID), let running = process else {
            throw BackendUpdateError.unmanagedBackend
        }
        running.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while running.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !running.isRunning else { throw BackendUpdateError.restartFailed }
        finishExitedProcess()
        guard case .started = await ensureRunning(at: baseURL) else {
            throw BackendUpdateError.restartFailed
        }
    }

    public func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        try? outputHandle?.close()
        outputHandle = nil
    }

    private func launch(_ executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["run", "--no-gui"]
        process.currentDirectoryURL = homeDirectory
        process.environment = environment

        if let handle = try makeOutputHandle() {
            process.standardOutput = handle
            process.standardError = handle
            outputHandle = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        self.process = process
    }

    private func makeOutputHandle() throws -> FileHandle? {
        let directory = homeDirectory.appending(path: "Library/Logs/Sloppy", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appending(path: "client-backend.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            guard fileManager.createFile(atPath: logURL.path, contents: nil) else { return nil }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    private func finishExitedProcess() {
        guard process?.isRunning != true else { return }
        process = nil
        try? outputHandle?.close()
        outputHandle = nil
    }
}
#endif
