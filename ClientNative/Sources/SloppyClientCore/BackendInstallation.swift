import Foundation

#if os(macOS)
import CryptoKit
import Darwin

public struct SloppyRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public let tagName: String
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

public enum BackendInstallationPhase: Equatable, Sendable {
    case resolvingRelease
    case downloadingChecksum
    case downloadingArchive
    case verifyingArchive
    case extractingArchive
    case installingFiles
    case creatingCommandLinks
    case verifyingInstallation
}

public struct BackendInstallationProgress: Equatable, Sendable {
    public let phase: BackendInstallationPhase
    public let phaseFraction: Double
    public let detail: String
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?

    public init(
        phase: BackendInstallationPhase,
        phaseFraction: Double,
        detail: String,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.phase = phase
        self.phaseFraction = min(max(phaseFraction, 0), 1)
        self.detail = detail
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

public enum BackendInstallerError: LocalizedError, Equatable {
    case unsupportedArchitecture(String)
    case invalidResponse
    case missingAsset(String)
    case missingChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case invalidArchive
    case commandFailed(command: String, output: String)
    case installationVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "Sloppy does not publish a macOS build for \(architecture)."
        case .invalidResponse:
            return "GitHub returned an invalid release response."
        case .missingAsset(let name):
            return "The latest release does not contain \(name)."
        case .missingChecksum(let name):
            return "SHA256SUMS.txt does not contain a checksum for \(name)."
        case .checksumMismatch:
            return "The downloaded archive failed SHA-256 verification."
        case .invalidArchive:
            return "The release archive does not contain the expected Sloppy files."
        case .commandFailed(let command, let output):
            return "\(command) failed: \(output)"
        case .installationVerificationFailed:
            return "The installed Sloppy executable could not be verified."
        }
    }
}

public actor BackendInstaller {
    public typealias ProgressHandler = @MainActor @Sendable (BackendInstallationProgress) -> Void

    public static let releaseAPI = URL(string: "https://api.github.com/repos/TeamSloppy/Sloppy/releases/latest")!

    private let session: URLSession
    private let fileManager: FileManager
    private let installationRoot: URL

    public init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        installationRoot: URL = BackendInstaller.managedInstallationRoot()
    ) {
        self.session = session
        self.fileManager = fileManager
        self.installationRoot = installationRoot
    }

    public nonisolated static func managedInstallationRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return applicationSupport.appending(path: "Sloppy/Backend/current", directoryHint: .isDirectory)
    }

    public nonisolated static func installedExecutableURL(
        installationRoot: URL = BackendInstaller.managedInstallationRoot()
    ) -> URL {
        installationRoot.appending(path: "bin/sloppy")
    }

    public nonisolated static func isInstalled(
        fileManager: FileManager = .default,
        installationRoot: URL = BackendInstaller.managedInstallationRoot()
    ) -> Bool {
        fileManager.isExecutableFile(atPath: installedExecutableURL(installationRoot: installationRoot).path)
    }

    public func install(releaseTag: String? = nil, progress: ProgressHandler) async throws -> String {
        await progress(.init(phase: .resolvingRelease, phaseFraction: 0, detail: "Contacting GitHub Releases"))
        let release = try await fetchRelease(tag: releaseTag)
        let archiveName = try Self.archiveName()
        guard let archiveAsset = release.assets.first(where: { $0.name == archiveName }) else {
            throw BackendInstallerError.missingAsset(archiveName)
        }
        guard let checksumAsset = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else {
            throw BackendInstallerError.missingAsset("SHA256SUMS.txt")
        }
        await progress(.init(phase: .resolvingRelease, phaseFraction: 1, detail: "Found Sloppy \(release.tagName)"))

        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "sloppy-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let checksumURL = temporaryDirectory.appending(path: "SHA256SUMS.txt")
        await progress(.init(phase: .downloadingChecksum, phaseFraction: 0, detail: "Downloading SHA256SUMS.txt"))
        try await download(checksumAsset, to: checksumURL, phase: .downloadingChecksum, progress: progress)

        let archiveURL = temporaryDirectory.appending(path: archiveName)
        await progress(.init(phase: .downloadingArchive, phaseFraction: 0, detail: "Downloading \(archiveName)"))
        try await download(archiveAsset, to: archiveURL, phase: .downloadingArchive, progress: progress)

        await progress(.init(phase: .verifyingArchive, phaseFraction: 0, detail: "Calculating archive SHA-256"))
        let sums = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expectedChecksum = Self.checksum(for: archiveName, in: sums) else {
            throw BackendInstallerError.missingChecksum(archiveName)
        }
        let actualChecksum = try Self.sha256(of: archiveURL)
        guard expectedChecksum.caseInsensitiveCompare(actualChecksum) == .orderedSame else {
            throw BackendInstallerError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }
        await progress(.init(phase: .verifyingArchive, phaseFraction: 1, detail: "SHA-256 checksum verified"))

        let extractedURL = temporaryDirectory.appending(path: "extracted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        await progress(.init(phase: .extractingArchive, phaseFraction: 0, detail: "Extracting release archive"))
        try await run("/usr/bin/tar", arguments: ["-xzf", archiveURL.path, "-C", extractedURL.path])
        let stagedBinary = extractedURL.appending(path: "bin/sloppy")
        let stagedShare = extractedURL.appending(path: "share/sloppy", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: stagedBinary.path), fileManager.fileExists(atPath: stagedShare.path) else {
            throw BackendInstallerError.invalidArchive
        }
        await progress(.init(phase: .extractingArchive, phaseFraction: 1, detail: "Archive extracted"))

        try Task.checkCancellation()
        let binaryDirectory = installationRoot.appending(path: "bin", directoryHint: .isDirectory)
        let shareDirectory = installationRoot.appending(path: "share/sloppy", directoryHint: .isDirectory)
        await progress(.init(phase: .installingFiles, phaseFraction: 0, detail: "Installing the app-managed backend executable"))
        try fileManager.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try replaceItem(at: binaryDirectory.appending(path: "sloppy"), with: stagedBinary)
        await progress(.init(phase: .installingFiles, phaseFraction: 0.5, detail: "Installing Dashboard and runtime resources"))
        try fileManager.createDirectory(at: shareDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replaceItem(at: shareDirectory, with: stagedShare)
        await progress(.init(phase: .installingFiles, phaseFraction: 1, detail: "Sloppy files installed"))

        await progress(.init(phase: .creatingCommandLinks, phaseFraction: 0, detail: "Creating the slop command link"))
        let shortCommand = binaryDirectory.appending(path: "slop")
        if fileManager.fileExists(atPath: shortCommand.path) || (try? shortCommand.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: shortCommand)
        }
        try fileManager.createSymbolicLink(at: shortCommand, withDestinationURL: binaryDirectory.appending(path: "sloppy"))
        await progress(.init(phase: .creatingCommandLinks, phaseFraction: 1, detail: "Command links created"))

        await progress(.init(phase: .verifyingInstallation, phaseFraction: 0, detail: "Running sloppy --version"))
        guard fileManager.isExecutableFile(atPath: Self.installedExecutableURL(installationRoot: installationRoot).path) else {
            throw BackendInstallerError.installationVerificationFailed
        }
        let version = try await run(Self.installedExecutableURL(installationRoot: installationRoot).path, arguments: ["--version"])
        await progress(.init(phase: .verifyingInstallation, phaseFraction: 1, detail: version.isEmpty ? "Installation verified" : version))
        return release.tagName
    }

    public nonisolated static func checksum(for filename: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }
            let listedName = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if listedName == filename { return String(fields[0]) }
        }
        return nil
    }

    private nonisolated static func archiveName() throws -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let architecture = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        switch architecture {
        case "arm64": return "Sloppy-macos-arm64.tar.gz"
        case "x86_64": return "Sloppy-macos-x86_64.tar.gz"
        default: throw BackendInstallerError.unsupportedArchitecture(architecture)
        }
    }

    private func fetchRelease(tag: String?) async throws -> SloppyRelease {
        let url = tag.map { Self.releaseAPI.deletingLastPathComponent().appending(path: "tags").appending(component: $0) }
            ?? Self.releaseAPI
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SloppyClient", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw BackendInstallerError.invalidResponse
        }
        return try JSONDecoder().decode(SloppyRelease.self, from: data)
    }

    private func download(
        _ asset: SloppyRelease.Asset,
        to destination: URL,
        phase: BackendInstallationPhase,
        progress: ProgressHandler
    ) async throws {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("SloppyClient", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw BackendInstallerError.invalidResponse
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : asset.size
        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                let fraction = expected > 0 ? Double(received) / Double(expected) : 0
                await progress(.init(
                    phase: phase,
                    phaseFraction: fraction,
                    detail: "Downloading \(asset.name)",
                    downloadedBytes: received,
                    totalBytes: expected > 0 ? expected : nil
                ))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        await progress(.init(
            phase: phase,
            phaseFraction: 1,
            detail: "Downloaded \(asset.name)",
            downloadedBytes: received,
            totalBytes: expected > 0 ? expected : received
        ))
    }

    private nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        let staged = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).install-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staged)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: BackendInstallerError.commandFailed(command: executable, output: text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
