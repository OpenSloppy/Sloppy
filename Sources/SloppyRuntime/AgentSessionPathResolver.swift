import Foundation

public struct AgentSessionPathResolver {
    public struct Location {
        public let sessionID: String
        public let directoryURL: URL
        public let sessionFileURL: URL
        public let summaryURL: URL
        public let sidecarURL: URL
        public let acpStateURL: URL
        public let assetsURL: URL
        public let isLegacy: Bool
    }

    public let agentDirectoryURL: URL
    public let fileManager: FileManager

    public init(agentDirectoryURL: URL, fileManager: FileManager = .default) {
        self.agentDirectoryURL = agentDirectoryURL
        self.fileManager = fileManager
    }

    public var sessionsDirectoryURL: URL {
        agentDirectoryURL.appendingPathComponent("sessions", isDirectory: true)
    }

    public func canonicalLocation(sessionID: String, createdAt: Date) -> Location {
        let date = Self.datePathComponents(for: createdAt)
        let directory = sessionsDirectoryURL
            .appendingPathComponent(date.year, isDirectory: true)
            .appendingPathComponent(date.month, isDirectory: true)
            .appendingPathComponent(date.day, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        return canonicalLocation(sessionID: sessionID, directoryURL: directory)
    }

    public func canonicalLocation(sessionID: String, directoryURL: URL) -> Location {
        Location(
            sessionID: sessionID,
            directoryURL: directoryURL,
            sessionFileURL: directoryURL.appendingPathComponent("session.jsonl", isDirectory: false),
            summaryURL: directoryURL.appendingPathComponent("summary.json", isDirectory: false),
            sidecarURL: directoryURL.appendingPathComponent("sidecar.json", isDirectory: false),
            acpStateURL: directoryURL.appendingPathComponent("acp-state.json", isDirectory: false),
            assetsURL: directoryURL.appendingPathComponent("assets", isDirectory: true),
            isLegacy: false
        )
    }

    public func legacyLocation(sessionID: String) -> Location {
        Location(
            sessionID: sessionID,
            directoryURL: sessionsDirectoryURL,
            sessionFileURL: sessionsDirectoryURL.appendingPathComponent("\(sessionID).jsonl", isDirectory: false),
            summaryURL: sessionsDirectoryURL.appendingPathComponent("\(sessionID).summary.json", isDirectory: false),
            sidecarURL: sessionsDirectoryURL.appendingPathComponent("\(sessionID).sidecar.json", isDirectory: false),
            acpStateURL: sessionsDirectoryURL.appendingPathComponent("\(sessionID).acp-state.json", isDirectory: false),
            assetsURL: sessionsDirectoryURL.appendingPathComponent("\(sessionID).assets", isDirectory: true),
            isLegacy: true
        )
    }

    public func existingLocation(sessionID: String) -> Location? {
        if let canonical = existingCanonicalLocation(sessionID: sessionID) {
            return canonical
        }
        let legacy = legacyLocation(sessionID: sessionID)
        if fileManager.fileExists(atPath: legacy.sessionFileURL.path) {
            return legacy
        }
        return nil
    }

    public func existingCanonicalLocation(sessionID: String) -> Location? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "session.jsonl",
                  fileURL.deletingLastPathComponent().lastPathComponent == sessionID,
                  fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            return canonicalLocation(sessionID: sessionID, directoryURL: fileURL.deletingLastPathComponent())
        }
        return nil
    }

    public func canonicalSessionFiles() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "session.jsonl" {
            files.append(fileURL)
        }
        return files
    }

    public static func sessionID(fromCanonicalSessionFile fileURL: URL) -> String {
        fileURL.deletingLastPathComponent().lastPathComponent
    }

    public static func relativePath(from baseURL: URL, to fileURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(basePath.count + 1))
    }

    private static func datePathComponents(for date: Date) -> (year: String, month: String, day: String) {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        return (
            String(format: "%04d", components.year ?? 1970),
            String(format: "%02d", components.month ?? 1),
            String(format: "%02d", components.day ?? 1)
        )
    }
}
