import Foundation

public struct PromptTemplateLoader {
    public enum LoaderError: Error, Equatable {
        case templateNotFound(String)
        case unreadableTemplate(String)
    }

    public typealias Resolver = @Sendable (_ relativePath: String) throws -> String

    private let resolver: Resolver

    public init(
        basePath: String = "Prompts/en",
        fileManager: FileManager = .default,
        executablePath: String? = CommandLine.arguments.first,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        sourceFilePath: String = #filePath
    ) {
        let searchRoots = Self.searchRoots(
            fileManager: fileManager,
            basePath: basePath,
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath,
            sourceFilePath: sourceFilePath,
            bundledResourcesURL: Bundle.module.resourceURL
        )

        self.resolver = { relativePath in
            guard let url = searchRoots
                .map({ $0.appendingPathComponent(relativePath) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                throw LoaderError.templateNotFound(relativePath)
            }

            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw LoaderError.unreadableTemplate(relativePath)
            }
        }
    }

    public init(resolver: @escaping Resolver) {
        self.resolver = resolver
    }

    public func loadTemplate(for processKind: PromptProcessKind) throws -> String {
        try resolver("\(processKind.templateName).md")
    }

    public func loadPartial(named name: String) throws -> String {
        do {
            return try resolver("partials/\(name).md")
        } catch LoaderError.templateNotFound {
            // SwiftPM bundles can flatten processed resources in release/debug
            // artifacts, so keep a compatibility fallback to the root filename.
            return try resolver("\(name).md")
        }
    }
}

private extension PromptTemplateLoader {
    static func searchRoots(
        fileManager: FileManager,
        basePath: String,
        executablePath: String?,
        currentDirectoryPath: String,
        sourceFilePath: String,
        bundledResourcesURL: URL?
    ) -> [URL] {
        var roots: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL) {
            let normalized = url.standardizedFileURL
            guard seenPaths.insert(normalized.path).inserted else { return }
            roots.append(normalized)
        }

        for directoryURL in executableDirectories(
            fileManager: fileManager,
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        ) {
            append(directoryURL.appendingPathComponent(basePath))
            append(
                directoryURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("share/sloppy")
                    .appendingPathComponent(basePath)
            )
            append(
                directoryURL
                    .appendingPathComponent("Sloppy_SloppyRuntime.bundle")
                    .appendingPathComponent(basePath)
            )
            append(
                directoryURL
                    .appendingPathComponent("Sloppy_SloppyRuntime.resources")
                    .appendingPathComponent(basePath)
            )
        }

        append(
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Sources/SloppyRuntime/Resources")
                .appendingPathComponent(basePath)
        )

        let sourceDirectory = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        append(
            sourceDirectory
                .appendingPathComponent("Resources")
                .appendingPathComponent(basePath)
        )
        append(
            sourceDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent(basePath)
        )

        if let bundledResourcesURL {
            append(bundledResourcesURL.appendingPathComponent(basePath))
        }

        return roots
    }

    static func executableDirectories(
        fileManager: FileManager,
        executablePath: String?,
        currentDirectoryPath: String
    ) -> [URL] {
        guard let executablePath, !executablePath.isEmpty else {
            return []
        }

        let currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        let rawExecutableURL: URL
        if executablePath.hasPrefix("/") {
            rawExecutableURL = URL(fileURLWithPath: executablePath)
        } else {
            rawExecutableURL = URL(fileURLWithPath: executablePath, relativeTo: currentDirectoryURL)
        }

        var directories: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL) {
            let normalized = url.standardizedFileURL.deletingLastPathComponent()
            guard seenPaths.insert(normalized.path).inserted else { return }
            directories.append(normalized)
        }

        append(rawExecutableURL)
        append(rawExecutableURL.resolvingSymlinksInPath())

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: rawExecutableURL.path) {
            let destinationURL: URL
            if destination.hasPrefix("/") {
                destinationURL = URL(fileURLWithPath: destination)
            } else {
                destinationURL = rawExecutableURL.deletingLastPathComponent().appendingPathComponent(destination)
            }
            append(destinationURL)
        }

        return directories
    }
}
