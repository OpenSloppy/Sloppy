import Foundation
import Logging
import Protocols

public final class AgentSessionFileStore: @unchecked Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case invalidAgentID
        case invalidSessionID
        case agentNotFound
        case sessionNotFound
        case sessionFileNotFound(agentID: String, sessionID: String, agentsRoot: String)
        case sessionEventsEmpty(agentID: String, sessionID: String, lineCount: Int, filePath: String)
        case invalidPayload

        public var description: String {
            switch self {
            case .invalidAgentID: return "invalidAgentID"
            case .invalidSessionID: return "invalidSessionID"
            case .agentNotFound: return "agentNotFound"
            case .sessionNotFound: return "sessionNotFound"
            case .sessionFileNotFound(let a, let s, let root):
                return "sessionFileNotFound(agent=\(a), session=\(s), agentsRoot=\(root))"
            case .sessionEventsEmpty(let a, let s, let lc, let fp):
                return "sessionEventsEmpty(agent=\(a), session=\(s), lines=\(lc), file=\(fp))"
            case .invalidPayload: return "invalidPayload"
            }
        }
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger
    private static let operationLock = NSRecursiveLock()
    private static let summaryCacheSchemaVersion = 1

    public init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL
        var logger = Logger(label: "sloppy.session.store")
        if ProcessInfo.processInfo.environment["SLOPPY_QUIET_LOGS"] == "1" {
            logger.logLevel = .critical
        }
        self.logger = logger

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func updateAgentsRootURL(_ url: URL) {
        withLock {
            self.agentsRootURL = url
        }
    }

    public func listSessions(
        agentID: String,
        includeHeartbeat: Bool = false,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [AgentSessionSummary] {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let sessionsDirectory = try sessionsDirectoryURL(agentID: normalizedAgentID, createIfMissing: false)

            guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
                return []
            }
            try migrateLegacySessions(in: sessionsDirectory)

            let resolver = try sessionPathResolver(agentID: normalizedAgentID)
            var seenSessionIDs = Set<String>()
            let canonicalFiles = resolver.canonicalSessionFiles()
            let legacyFiles = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }
            let sessionFiles = canonicalFiles + legacyFiles
            var summaries: [AgentSessionSummary] = []
            for file in sessionFiles {
                let sessionID = file.lastPathComponent == "session.jsonl"
                    ? AgentSessionPathResolver.sessionID(fromCanonicalSessionFile: file)
                    : file.deletingPathExtension().lastPathComponent
                guard seenSessionIDs.insert(sessionID).inserted else {
                    continue
                }
                if let summary = try? loadSessionSummary(agentID: normalizedAgentID, sessionID: sessionID, fileURL: file),
                   includeHeartbeat || summary.kind != .heartbeat {
                    summaries.append(summary)
                }
            }

            let sorted = summaries.sorted { $0.updatedAt > $1.updatedAt }
            return Self.paginated(sorted, limit: limit, offset: offset)
        }
    }

    public func createSession(
        agentID: String,
        request: AgentSessionCreateRequest,
        createdAt: Date = Date(),
        importedSessionID: String? = nil
    ) throws -> AgentSessionSummary {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedParentSessionID = try normalizedOptionalSessionID(request.parentSessionId)
            _ = try sessionsDirectoryURL(agentID: normalizedAgentID, createIfMissing: true)
            let resolver = try sessionPathResolver(agentID: normalizedAgentID)

            let sessionID = try importedSessionID.map { try normalizedSessionID($0) } ?? "session-\(UUID().uuidString.lowercased())"
            if importedSessionID != nil, let existing = sessionFileURL(agentID: normalizedAgentID, sessionID: sessionID), fileManager.fileExists(atPath: existing.path) {
                return try loadSession(agentID: normalizedAgentID, sessionID: sessionID).summary
            }
            let trimmedTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            let titleIsAutomatic: Bool
            if let trimmedTitle, !trimmedTitle.isEmpty {
                title = trimmedTitle
                titleIsAutomatic = false
            } else {
                title = AgentSessionTitleGenerator.fallbackTitle
                titleIsAutomatic = true
            }

            let projectIdMeta: String? = {
                guard let raw = request.projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                return raw
            }()
            let taskIdMeta: String? = {
                guard let raw = request.taskId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                return raw
            }()
            let workspaceIdMeta: String? = {
                guard let raw = request.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                return raw
            }()

            let createdEvent = AgentSessionEvent(
                agentId: normalizedAgentID,
                sessionId: sessionID,
                type: .sessionCreated,
                createdAt: createdAt,
                metadata: AgentSessionMetadataEvent(
                    title: title,
                    parentSessionId: normalizedParentSessionID,
                    kind: request.kind,
                    projectId: projectIdMeta,
                    taskId: taskIdMeta,
                    workspaceId: workspaceIdMeta,
                    titleIsAutomatic: titleIsAutomatic
                )
            )

            let location = resolver.canonicalLocation(sessionID: sessionID, createdAt: createdAt)
            try fileManager.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
            let fileURL = location.sessionFileURL
            try append(events: [createdEvent], to: fileURL, createIfMissing: true)
            return try refreshSummaryCache(agentID: normalizedAgentID, sessionID: sessionID, fileURL: fileURL)
        }
    }

    @discardableResult
    public func deleteExpiredSessions(
        agentIDs: [String],
        olderThan cutoffDate: Date
    ) throws -> [AgentSessionSummary] {
        try withLock {
            var deleted: [AgentSessionSummary] = []
            for agentID in agentIDs {
                let normalizedAgentID = try normalizedAgentID(agentID)
                let summaries = try listSessions(agentID: normalizedAgentID, includeHeartbeat: true)
                for summary in summaries where summary.updatedAt < cutoffDate {
                    try deleteSession(agentID: normalizedAgentID, sessionID: summary.id)
                    deleted.append(summary)
                }
            }
            return deleted
        }
    }

    public func loadSession(agentID: String, sessionID: String) throws -> AgentSessionDetail {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)
            let events = try readEvents(agentID: normalizedAgentID, sessionID: normalizedSessionID)
            let summary = summaryForSession(agentID: normalizedAgentID, sessionID: normalizedSessionID, events: events)
            return AgentSessionDetail(summary: summary, events: events)
        }
    }

    public func sessionFilePath(agentID: String, sessionID: String) throws -> String {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)
            guard let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
                  fileManager.fileExists(atPath: fileURL.path) else {
                throw StoreError.sessionNotFound
            }
            return fileURL.standardizedFileURL.path
        }
    }

    @discardableResult
    public func appendEvents(agentID: String, sessionID: String, events: [AgentSessionEvent]) throws -> AgentSessionSummary {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)
            guard !events.isEmpty else {
                throw StoreError.invalidPayload
            }

            guard let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
                  fileManager.fileExists(atPath: fileURL.path) else {
                throw StoreError.sessionNotFound
            }

            try append(events: events, to: fileURL, createIfMissing: false)
            return try refreshSummaryCache(agentID: normalizedAgentID, sessionID: normalizedSessionID, fileURL: fileURL)
        }
    }

    public func deleteSession(agentID: String, sessionID: String) throws {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)

            guard let fileURL = sessionFileURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
                  fileManager.fileExists(atPath: fileURL.path) else {
                throw StoreError.sessionNotFound
            }

            let location = try sessionPathResolver(agentID: normalizedAgentID)
                .existingLocation(sessionID: normalizedSessionID)
            try fileManager.removeItem(at: fileURL)
            removeSummaryCache(agentID: normalizedAgentID, sessionID: normalizedSessionID)

            if location?.isLegacy == false {
                try? fileManager.removeItem(at: location!.directoryURL)
                return
            }

            if let sidecar = sessionSidecarURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
               fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar)
            }

            if let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
               fileManager.fileExists(atPath: assetsDirectory.path) {
                try fileManager.removeItem(at: assetsDirectory)
            }
        }
    }

    public func incrementUserTurnCount(agentID: String, sessionID: String) throws -> Int {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)
            let prior = try readUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID)
            let next = prior + 1
            try writeUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID, count: next)
            return next
        }
    }

    public func resetUserTurnCount(agentID: String, sessionID: String) throws {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)
            try writeUserTurnCount(agentID: normalizedAgentID, sessionID: normalizedSessionID, count: 0)
        }
    }

    private struct AgentSessionSidecar: Codable {
        var userTurnCount: Int
    }

    private func sessionSidecarURL(agentID: String, sessionID: String) -> URL? {
        guard let resolver = try? sessionPathResolver(agentID: agentID) else {
            return nil
        }
        return resolver.existingLocation(sessionID: sessionID)?.sidecarURL
            ?? resolver.legacyLocation(sessionID: sessionID).sidecarURL
    }

    private func readUserTurnCount(agentID: String, sessionID: String) throws -> Int {
        guard let url = sessionSidecarURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let data = try Data(contentsOf: url)
        let sidecar = try JSONDecoder().decode(AgentSessionSidecar.self, from: data)
        return max(0, sidecar.userTurnCount)
    }

    private func writeUserTurnCount(agentID: String, sessionID: String, count: Int) throws {
        guard let url = sessionSidecarURL(agentID: agentID, sessionID: sessionID) else {
            throw StoreError.agentNotFound
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try JSONEncoder().encode(AgentSessionSidecar(userTurnCount: max(0, count)))
        try payload.write(to: url, options: .atomic)
        removeSummaryCache(agentID: agentID, sessionID: sessionID)
    }

    public func persistAttachments(agentID: String, sessionID: String, uploads: [AgentAttachmentUpload]) throws -> [AgentAttachment] {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            let normalizedSessionID = try normalizedSessionID(sessionID)

            if uploads.isEmpty {
                return []
            }

            var attachments: [AgentAttachment] = []
            for upload in uploads {
                let cleanName = sanitizeFilename(upload.name)
                let normalizedName = cleanName.isEmpty ? "attachment.bin" : cleanName
                let mimeType = upload.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachmentID = UUID().uuidString.lowercased()
                let fileName = "\(attachmentID)-\(normalizedName)"

                var relativePath: String?
                if let contentBase64 = upload.contentBase64, !contentBase64.isEmpty {
                    guard let data = Data(base64Encoded: contentBase64, options: [.ignoreUnknownCharacters]) else {
                        throw StoreError.invalidPayload
                    }

                    guard let assetsDirectory = assetsDirectoryURL(agentID: normalizedAgentID, sessionID: normalizedSessionID),
                          let agentDirectory = resolvedAgentDirectoryURL(agentID: normalizedAgentID) else {
                        throw StoreError.agentNotFound
                    }
                    try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

                    let fileURL = assetsDirectory.appendingPathComponent(fileName)
                    try data.write(to: fileURL, options: .atomic)
                    relativePath = AgentSessionPathResolver.relativePath(from: agentDirectory, to: fileURL)
                }

                attachments.append(
                    AgentAttachment(
                        id: attachmentID,
                        name: normalizedName,
                        mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
                        sizeBytes: max(upload.sizeBytes, 0),
                        relativePath: relativePath
                    )
                )
            }

            return attachments
        }
    }

    public func resolveAttachmentFileURL(agentID: String, attachment: AgentAttachment) throws -> URL? {
        try withLock {
            let normalizedAgentID = try normalizedAgentID(agentID)
            guard let relativePath = attachment.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !relativePath.isEmpty,
                  let agentDirectory = resolvedAgentDirectoryURL(agentID: normalizedAgentID) else {
                return nil
            }
            let directURL = agentDirectory.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }

            if let migratedURL = migratedAttachmentURL(agentID: normalizedAgentID, legacyRelativePath: relativePath),
               fileManager.fileExists(atPath: migratedURL.path) {
                return migratedURL
            }
            return directURL
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        return try body()
    }

    private func append(events: [AgentSessionEvent], to fileURL: URL, createIfMissing: Bool) throws {
        if createIfMissing && !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()

        for event in events {
            var payload = try encoder.encode(event)
            payload.append(0x0A)
            try handle.write(contentsOf: payload)
        }
    }

    private func readEvents(agentID: String, sessionID: String) throws -> [AgentSessionEvent] {
        if let sessionsDirectory = try? sessionsDirectoryURL(agentID: agentID, createIfMissing: false),
           fileManager.fileExists(atPath: sessionsDirectory.path) {
            try? migrateLegacySessions(in: sessionsDirectory)
        }

        guard let fileURL = sessionFileURL(agentID: agentID, sessionID: sessionID) else {
            logger.warning(
                "Session file URL resolution failed",
                metadata: [
                    "agent_id": .string(agentID),
                    "session_id": .string(sessionID),
                    "agents_root": .string(agentsRootURL.path)
                ]
            )
            throw StoreError.sessionFileNotFound(
                agentID: agentID,
                sessionID: sessionID,
                agentsRoot: agentsRootURL.path
            )
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.sessionFileNotFound(
                agentID: agentID,
                sessionID: sessionID,
                agentsRoot: agentsRootURL.path
            )
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidPayload
        }

        let lines = content
            .split(whereSeparator: \.isNewline)
            .filter { line in line.contains { !$0.isWhitespace } }

        var events: [AgentSessionEvent] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard let lineData = String(line).data(using: .utf8) else {
                continue
            }
            if let event = try? decoder.decode(AgentSessionEvent.self, from: lineData) {
                events.append(event)
            }
        }

        if events.isEmpty {
            throw StoreError.sessionEventsEmpty(
                agentID: agentID,
                sessionID: sessionID,
                lineCount: lines.count,
                filePath: fileURL.path
            )
        }

        return events.sorted { $0.createdAt < $1.createdAt }
    }

    private struct AgentSessionSummaryCache: Codable {
        var schemaVersion: Int
        var sourceByteCount: Int
        var sourceModifiedAt: TimeInterval
        var summary: AgentSessionSummary
    }

    private func loadSessionSummary(agentID: String, sessionID: String, fileURL: URL) throws -> AgentSessionSummary {
        if let cached = try? readSummaryCache(agentID: agentID, sessionID: sessionID, fileURL: fileURL) {
            return cached
        }
        return try refreshSummaryCache(agentID: agentID, sessionID: sessionID, fileURL: fileURL)
    }

    @discardableResult
    private func refreshSummaryCache(agentID: String, sessionID: String, fileURL: URL) throws -> AgentSessionSummary {
        let events = try readEvents(agentID: agentID, sessionID: sessionID)
        let summary = summaryForSession(agentID: agentID, sessionID: sessionID, events: events)
        try writeSummaryCache(summary, fileURL: fileURL)
        return summary
    }

    private func readSummaryCache(agentID: String, sessionID: String, fileURL: URL) throws -> AgentSessionSummary? {
        guard let cacheURL = sessionSummaryCacheURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: cacheURL)
        let cache = try decoder.decode(AgentSessionSummaryCache.self, from: data)
        guard cache.schemaVersion == Self.summaryCacheSchemaVersion,
              let fingerprint = try sourceFingerprint(fileURL: fileURL),
              cache.sourceByteCount == fingerprint.byteCount,
              cache.sourceModifiedAt == fingerprint.modifiedAt else {
            return nil
        }
        return cache.summary
    }

    private func writeSummaryCache(_ summary: AgentSessionSummary, fileURL: URL) throws {
        guard let cacheURL = sessionSummaryCacheURL(agentID: summary.agentId, sessionID: summary.id),
              let fingerprint = try sourceFingerprint(fileURL: fileURL) else {
            return
        }
        let cache = AgentSessionSummaryCache(
            schemaVersion: Self.summaryCacheSchemaVersion,
            sourceByteCount: fingerprint.byteCount,
            sourceModifiedAt: fingerprint.modifiedAt,
            summary: summary
        )
        let payload = try encoder.encode(cache)
        try payload.write(to: cacheURL, options: .atomic)
    }

    private func removeSummaryCache(agentID: String, sessionID: String) {
        guard let cacheURL = sessionSummaryCacheURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        try? fileManager.removeItem(at: cacheURL)
    }

    private func sessionSummaryCacheURL(agentID: String, sessionID: String) -> URL? {
        guard let resolver = try? sessionPathResolver(agentID: agentID) else {
            return nil
        }
        return resolver.existingLocation(sessionID: sessionID)?.summaryURL
            ?? resolver.legacyLocation(sessionID: sessionID).summaryURL
    }

    private func sourceFingerprint(fileURL: URL) throws -> (byteCount: Int, modifiedAt: TimeInterval)? {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let byteCount = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return nil
        }
        return (byteCount, modifiedAt.timeIntervalSince1970)
    }

    private static func paginated(_ summaries: [AgentSessionSummary], limit: Int?, offset: Int) -> [AgentSessionSummary] {
        let start = min(max(0, offset), summaries.count)
        let tail = summaries[start...]
        guard let limit else {
            return Array(tail)
        }
        return Array(tail.prefix(max(0, limit)))
    }

    private func summaryForSession(agentID: String, sessionID: String, events: [AgentSessionEvent]) -> AgentSessionSummary {
        var title = "Session \(sessionID.prefix(8))"
        var parentSessionID: String?
        var kind: AgentSessionKind = .chat
        var projectID: String?
        var taskID: String?
        var workspaceID: String?
        var titleIsAutomatic = false
        var userMessages: [AgentSessionMessage] = []
        var createdAt = events.first?.createdAt ?? Date()
        var updatedAt = createdAt
        var messageCount = 0
        var lastPreview: String?

        for event in events {
            createdAt = min(createdAt, event.createdAt)
            updatedAt = max(updatedAt, event.createdAt)

            if event.type == .sessionCreated, let metadata = event.metadata {
                title = metadata.title
                parentSessionID = metadata.parentSessionId
                kind = metadata.kind
                projectID = metadata.projectId
                taskID = metadata.taskId
                workspaceID = metadata.workspaceId
                titleIsAutomatic = metadata.titleIsAutomatic
            }

            if let message = event.message {
                if message.role == .user {
                    userMessages.append(message)
                }
                messageCount += 1
                if let preview = previewText(for: message), !preview.isEmpty {
                    lastPreview = preview
                }
            }
        }

        if titleIsAutomatic {
            title = AgentSessionTitleGenerator.title(for: userMessages)
        }

        let userTurnCount = (try? readUserTurnCount(agentID: agentID, sessionID: sessionID)) ?? 0

        return AgentSessionSummary(
            id: sessionID,
            agentId: agentID,
            title: title,
            parentSessionId: parentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messageCount,
            lastMessagePreview: lastPreview,
            kind: kind,
            userTurnCount: userTurnCount,
            projectId: projectID,
            taskId: taskID,
            workspaceId: workspaceID
        )
    }

    private func previewText(for message: AgentSessionMessage) -> String? {
        for segment in message.segments {
            if let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.count > 120 ? String(text.prefix(120)) : text
            }
            if let attachment = segment.attachment {
                return "Attachment: \(attachment.name)"
            }
        }
        return nil
    }

    private func resolvedAgentDirectoryURL(agentID: String) -> URL? {
        let regular = agentsRootURL.appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: regular.path) {
            return regular
        }
        let system = agentsRootURL.appendingPathComponent(".system", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: system.path) {
            return system
        }
        return nil
    }

    private func sessionsDirectoryURL(agentID: String, createIfMissing: Bool) throws -> URL {
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: agentID) else {
            throw StoreError.agentNotFound
        }

        let sessionsDirectory = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        if createIfMissing {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
        return sessionsDirectory
    }

    private func sessionFileURL(agentID: String, sessionID: String) -> URL? {
        guard let resolver = try? sessionPathResolver(agentID: agentID) else {
            return nil
        }
        return resolver.existingLocation(sessionID: sessionID)?.sessionFileURL
    }

    private func assetsDirectoryURL(agentID: String, sessionID: String) -> URL? {
        guard let resolver = try? sessionPathResolver(agentID: agentID) else {
            return nil
        }
        return resolver.existingLocation(sessionID: sessionID)?.assetsURL
    }

    private func sessionPathResolver(agentID: String) throws -> AgentSessionPathResolver {
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: agentID) else {
            throw StoreError.agentNotFound
        }
        return AgentSessionPathResolver(agentDirectoryURL: agentDirectory, fileManager: fileManager)
    }

    private func migrateLegacySessions(in sessionsDirectory: URL) throws {
        let files = try fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }

        let resolver = AgentSessionPathResolver(
            agentDirectoryURL: sessionsDirectory.deletingLastPathComponent(),
            fileManager: fileManager
        )

        for fileURL in files {
            let sessionID = fileURL.deletingPathExtension().lastPathComponent
            guard resolver.existingCanonicalLocation(sessionID: sessionID) == nil else {
                continue
            }

            let createdAt = legacySessionCreatedAt(fileURL: fileURL) ?? legacyFileModifiedAt(fileURL: fileURL) ?? Date()
            let destination = resolver.canonicalLocation(sessionID: sessionID, createdAt: createdAt)
            try fileManager.createDirectory(at: destination.directoryURL, withIntermediateDirectories: true)
            let legacy = resolver.legacyLocation(sessionID: sessionID)

            try moveIfPossible(from: legacy.summaryURL, to: destination.summaryURL)
            try moveIfPossible(from: legacy.sidecarURL, to: destination.sidecarURL)
            try moveIfPossible(from: legacy.acpStateURL, to: destination.acpStateURL)
            try moveIfPossible(from: legacy.assetsURL, to: destination.assetsURL)
            try moveIfPossible(from: legacy.sessionFileURL, to: destination.sessionFileURL)
        }
    }

    private func moveIfPossible(from sourceURL: URL, to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
            return
        }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func legacySessionCreatedAt(fileURL: URL) -> Date? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in content.split(whereSeparator: \.isNewline) {
            guard line.contains(where: { !$0.isWhitespace }),
                  let lineData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(AgentSessionEvent.self, from: lineData),
                  event.type == .sessionCreated else {
                continue
            }
            return event.createdAt
        }
        return nil
    }

    private func legacyFileModifiedAt(fileURL: URL) -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func migratedAttachmentURL(agentID: String, legacyRelativePath: String) -> URL? {
        let prefix = "sessions/"
        guard legacyRelativePath.hasPrefix(prefix) else {
            return nil
        }
        let tail = String(legacyRelativePath.dropFirst(prefix.count))
        guard let assetsRange = tail.range(of: ".assets/") else {
            return nil
        }
        let sessionID = String(tail[..<assetsRange.lowerBound])
        let fileName = String(tail[assetsRange.upperBound...])
        guard !sessionID.isEmpty,
              !fileName.isEmpty,
              let resolver = try? sessionPathResolver(agentID: agentID),
              let location = resolver.existingCanonicalLocation(sessionID: sessionID) else {
            return nil
        }
        return location.assetsURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func normalizedAgentID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidAgentID
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidAgentID
        }

        return trimmed
    }

    private func normalizedSessionID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSessionID
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidSessionID
        }

        return trimmed
    }

    private func normalizedOptionalSessionID(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return try normalizedSessionID(trimmed)
    }

    private static func shortSessionID(_ sessionID: String) -> String {
        let prefix = "session-"
        if sessionID.hasPrefix(prefix) {
            return String(sessionID.dropFirst(prefix.count).prefix(8))
        }
        return String(sessionID.prefix(8))
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        let normalized = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        return normalized
    }
}
