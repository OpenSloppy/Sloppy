import Foundation
import Testing
import SloppyRuntime
@testable import Protocols
@testable import sloppy

@Test
func agentSessionStoreCachesListsAndInvalidatesSummarySidecar() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "cache-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Cache Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let session = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Cached session"),
        createdAt: createdAt
    )
    let sessionDirectoryURL = datedSessionDirectoryURL(
        rootURL: rootURL,
        agentID: agentID,
        sessionID: session.id,
        createdAt: createdAt
    )
    let sessionFileURL = sessionDirectoryURL.appendingPathComponent("session.jsonl")
    let summaryURL = rootURL
        .appendingPathComponent(agentID, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("2023", isDirectory: true)
        .appendingPathComponent("11", isDirectory: true)
        .appendingPathComponent("14", isDirectory: true)
        .appendingPathComponent(session.id, isDirectory: true)
        .appendingPathComponent("summary.json")
    #expect(FileManager.default.fileExists(atPath: sessionFileURL.path))
    try? FileManager.default.removeItem(at: summaryURL)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

    let warmed = try store.listSessions(agentID: agentID)
    #expect(warmed.map(\.id) == [session.id])
    #expect(FileManager.default.fileExists(atPath: summaryURL.path))

    let userEvent = AgentSessionEvent(
        agentId: agentID,
        sessionId: session.id,
        type: .message,
        createdAt: Date().addingTimeInterval(60),
        message: AgentSessionMessage(
            role: .user,
            segments: [AgentMessageSegment(kind: .text, text: "Fresh summary text")],
            userId: "tester"
        )
    )
    _ = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [userEvent])
    let afterAppend = try store.listSessions(agentID: agentID)
    #expect(afterAppend.first?.messageCount == 1)
    #expect(afterAppend.first?.lastMessagePreview == "Fresh summary text")

    _ = try store.incrementUserTurnCount(agentID: agentID, sessionID: session.id)
    let afterTurnCount = try store.listSessions(agentID: agentID)
    #expect(afterTurnCount.first?.userTurnCount == 1)

    try store.deleteSession(agentID: agentID, sessionID: session.id)
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
    #expect(try store.listSessions(agentID: agentID).isEmpty)
}

@Test
func agentSessionStorePaginatesCachedSessionList() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-pagination-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "paged-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Paged Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let first = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "First"))
    let second = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Second"))
    let third = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest(title: "Third"))

    for (index, session) in [first, second, third].enumerated() {
        let event = AgentSessionEvent(
            agentId: agentID,
            sessionId: session.id,
            type: .message,
            createdAt: Date().addingTimeInterval(TimeInterval(index + 1) * 60),
            message: AgentSessionMessage(
                role: .user,
                segments: [AgentMessageSegment(kind: .text, text: "message \(index)")],
                userId: "tester"
            )
        )
        _ = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [event])
    }

    let page = try store.listSessions(agentID: agentID, limit: 1, offset: 1)
    #expect(page.count == 1)
    #expect(page.first?.id == second.id)
}

@Test
func agentSessionStoreDeletesExpiredSessionsAndCompanionFiles() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "retention-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Retention Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let freshDate = oldDate.addingTimeInterval(10 * 24 * 60 * 60)
    let oldSession = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Old"),
        createdAt: oldDate
    )
    let freshSession = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Fresh"),
        createdAt: freshDate
    )

    _ = try store.incrementUserTurnCount(agentID: agentID, sessionID: oldSession.id)
    _ = try store.persistAttachments(
        agentID: agentID,
        sessionID: oldSession.id,
        uploads: [
            AgentAttachmentUpload(
                name: "note.txt",
                mimeType: "text/plain",
                sizeBytes: 5,
                contentBase64: "aGVsbG8="
            )
        ]
    )

    let oldSessionDirectoryURL = datedSessionDirectoryURL(
        rootURL: rootURL,
        agentID: agentID,
        sessionID: oldSession.id,
        createdAt: oldDate
    )
    let oldFileURL = oldSessionDirectoryURL.appendingPathComponent("session.jsonl")
    let oldSidecarURL = oldSessionDirectoryURL.appendingPathComponent("sidecar.json")
    let oldAssetsURL = oldSessionDirectoryURL.appendingPathComponent("assets", isDirectory: true)

    let deleted = try store.deleteExpiredSessions(
        agentIDs: [agentID],
        olderThan: oldDate.addingTimeInterval(2 * 24 * 60 * 60)
    )

    #expect(deleted.map(\.id) == [oldSession.id])
    #expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldSidecarURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldAssetsURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldSessionDirectoryURL.path))
    #expect(try store.listSessions(agentID: agentID).map(\.id) == [freshSession.id])
}

@Test
func agentSessionStorePersistsAttachmentsInDatedAssetsDirectoryAndResolvesLegacyPaths() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-attachments-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "attachment-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Attachment Agent", role: "Testing"),
        availableModels: []
    )

    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let session = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Attachments"),
        createdAt: createdAt
    )

    let attachments = try store.persistAttachments(
        agentID: agentID,
        sessionID: session.id,
        uploads: [
            AgentAttachmentUpload(
                name: "note.txt",
                mimeType: "text/plain",
                sizeBytes: 5,
                contentBase64: "aGVsbG8="
            )
        ]
    )

    let attachment = try #require(attachments.first)
    #expect(attachment.relativePath?.contains("/\(session.id)/assets/") == true)
    let fileURL = try #require(try store.resolveAttachmentFileURL(agentID: agentID, attachment: attachment))
    #expect(fileURL.path.contains("/sessions/2023/11/14/\(session.id)/assets/"))
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let legacyAssetsURL = rootURL
        .appendingPathComponent(agentID, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("\(session.id).assets", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyAssetsURL, withIntermediateDirectories: true)
    let legacyFileURL = legacyAssetsURL.appendingPathComponent("legacy.txt")
    try Data("legacy".utf8).write(to: legacyFileURL)

    let legacyAttachment = AgentAttachment(
        id: "legacy",
        name: "legacy.txt",
        mimeType: "text/plain",
        sizeBytes: 6,
        relativePath: "sessions/\(session.id).assets/legacy.txt"
    )
    #expect(try store.resolveAttachmentFileURL(agentID: agentID, attachment: legacyAttachment)?.path == legacyFileURL.path)
}

@Test
func agentSessionStoreMigratesFlatSessionFilesToDatedDirectory() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "migration-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Migration Agent", role: "Testing"),
        availableModels: []
    )

    let sessionID = "session-11111111-2222-4333-8444-555555555555"
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionsURL = rootURL
        .appendingPathComponent(agentID, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)

    let event = AgentSessionEvent(
        agentId: agentID,
        sessionId: sessionID,
        type: .sessionCreated,
        createdAt: createdAt,
        metadata: AgentSessionMetadataEvent(title: "Migrated", kind: .chat)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var payload = try encoder.encode(event)
    payload.append(0x0A)
    try payload.write(to: sessionsURL.appendingPathComponent("\(sessionID).jsonl"))
    try Data(#"{"schemaVersion":1}"#.utf8).write(to: sessionsURL.appendingPathComponent("\(sessionID).summary.json"))
    try Data(#"{"userTurnCount":3}"#.utf8).write(to: sessionsURL.appendingPathComponent("\(sessionID).sidecar.json"))
    try Data(#"{"targetId":"local"}"#.utf8).write(to: sessionsURL.appendingPathComponent("\(sessionID).acp-state.json"))
    let legacyAssetsURL = sessionsURL.appendingPathComponent("\(sessionID).assets", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyAssetsURL, withIntermediateDirectories: true)
    try Data("asset".utf8).write(to: legacyAssetsURL.appendingPathComponent("note.txt"))

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let sessions = try store.listSessions(agentID: agentID)
    #expect(sessions.map(\.id) == [sessionID])

    let sessionDirectoryURL = datedSessionDirectoryURL(
        rootURL: rootURL,
        agentID: agentID,
        sessionID: sessionID,
        createdAt: createdAt
    )
    #expect(FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("session.jsonl").path))
    #expect(FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("summary.json").path))
    #expect(FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("sidecar.json").path))
    #expect(FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("acp-state.json").path))
    #expect(FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("assets/note.txt").path))
    #expect(!FileManager.default.fileExists(atPath: sessionsURL.appendingPathComponent("\(sessionID).jsonl").path))
}

@Test
func agentSessionStoreSerializesConcurrentAppends() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-concurrent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "concurrent-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Concurrent Agent", role: "Testing"),
        availableModels: []
    )

    let primaryStore = AgentSessionFileStore(agentsRootURL: rootURL)
    let secondaryStore = AgentSessionFileStore(agentsRootURL: rootURL)
    let session = try primaryStore.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Concurrent session")
    )

    let errorCollector = ErrorCollector()
    let iterations = 80
    DispatchQueue.concurrentPerform(iterations: iterations) { index in
        do {
            let event = AgentSessionEvent(
                agentId: agentID,
                sessionId: session.id,
                type: .message,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                message: AgentSessionMessage(
                    role: .user,
                    segments: [AgentMessageSegment(kind: .text, text: "message \(index)")],
                    userId: "tester"
                )
            )
            let store = index.isMultiple(of: 2) ? primaryStore : secondaryStore
            _ = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [event])
        } catch {
            errorCollector.append(error)
        }
    }

    #expect(errorCollector.errors.isEmpty)
    if let firstError = errorCollector.errors.first {
        throw firstError
    }

    let detail = try primaryStore.loadSession(agentID: agentID, sessionID: session.id)
    let userMessageCount = detail.events.filter { $0.message?.role == .user }.count
    #expect(userMessageCount == iterations)
    #expect(try secondaryStore.listSessions(agentID: agentID).first?.messageCount == iterations)
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any Error] = []

    var errors: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        values.append(error)
    }
}

private func datedSessionDirectoryURL(rootURL: URL, agentID: String, sessionID: String, createdAt: Date) -> URL {
    let components = Calendar(identifier: .gregorian)
        .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: createdAt)
    return rootURL
        .appendingPathComponent(agentID, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(String(format: "%04d", components.year ?? 1970), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", components.month ?? 1), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", components.day ?? 1), isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
}

@Test
func agentSessionStoreDerivesAutomaticTitleFromUserContext() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-auto-title-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "auto-title-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Title Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let session = try store.createSession(agentID: agentID, request: AgentSessionCreateRequest())
    #expect(session.title == "New session")

    let event = AgentSessionEvent(
        agentId: agentID,
        sessionId: session.id,
        type: .message,
        message: AgentSessionMessage(
            role: .user,
            segments: [AgentMessageSegment(
                kind: .text,
                text: "Есть проблема\nЗаголовки сессий не отражают содержание работы"
            )],
            userId: "tester"
        )
    )
    let updated = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [event])

    #expect(updated.title == "Есть проблема — Заголовки сессий не отражают содержание работы")
}

@Test
func agentSessionStorePreservesExplicitTitle() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-session-explicit-title-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let agentID = "explicit-title-agent"
    let catalog = AgentCatalogFileStore(agentsRootURL: rootURL)
    _ = try catalog.createAgent(
        AgentCreateRequest(id: agentID, displayName: "Title Agent", role: "Testing"),
        availableModels: []
    )

    let store = AgentSessionFileStore(agentsRootURL: rootURL)
    let session = try store.createSession(
        agentID: agentID,
        request: AgentSessionCreateRequest(title: "Manual session title")
    )
    let event = AgentSessionEvent(
        agentId: agentID,
        sessionId: session.id,
        type: .message,
        message: AgentSessionMessage(
            role: .user,
            segments: [AgentMessageSegment(kind: .text, text: "Другой контекст")],
            userId: "tester"
        )
    )
    let updated = try store.appendEvents(agentID: agentID, sessionID: session.id, events: [event])

    #expect(updated.title == "Manual session title")
}
