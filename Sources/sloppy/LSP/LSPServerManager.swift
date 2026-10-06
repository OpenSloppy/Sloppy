import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Logging
import Protocols

// MARK: - LSPServerError

enum LSPServerError: Error, LocalizedError {
    case serverNotFound(String)
    case serverDisabled(String)
    case invalidCommand(String)
    case initializationFailed(String)
    case noItemsForCallHierarchy
    case fileTooLarge(String)
    case requestTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .requestTimedOut(let method):
            return "LSP request timed out: \(method)"
        case .serverNotFound(let ext):
            return "No LSP server configured for extension '\(ext)'."
        case .serverDisabled(let id):
            return "LSP server '\(id)' is disabled."
        case .invalidCommand(let id):
            return "LSP server '\(id)' has an empty or missing command."
        case .initializationFailed(let message):
            return "LSP server initialization failed: \(message)"
        case .noItemsForCallHierarchy:
            return "No call hierarchy items found at the given position."
        case .fileTooLarge(let path):
            return "File '\(path)' exceeds the maximum size for LSP sync."
        }
    }
}

// MARK: - LSPServerInstance

/// Manages lifecycle and requests for a single LSP server process.
actor LSPServerInstance {
    private let config: CoreConfig.LSP.Server
    private let workspaceRootURL: URL
    private let logger: Logger

    private var connection: JSONRPCConnection?
    private var process: Process?
    private var openedFiles: Set<String> = []
    private var documentVersions: [String: Int] = [:]
    private var syncingPaths: Set<String> = []
    private var syncWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var diagnostics = LSPDiagnosticCache()
    private var initializationTask: Task<JSONRPCConnection, Error>?
    private var isInitialized = false

    private static let maxFileSizeBytes = 10 * 1024 * 1024 // 10 MB

    init(config: CoreConfig.LSP.Server, workspaceRootURL: URL, logger: Logger) {
        self.config = config
        self.workspaceRootURL = workspaceRootURL
        self.logger = logger
    }

    func shutdown() {
        initializationTask?.cancel()
        initializationTask = nil
        connection?.close()
        connection = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        openedFiles = []
        documentVersions = [:]
        diagnostics = LSPDiagnosticCache()
        isInitialized = false
    }

    // MARK: - LSP Operations

    func definition(uri: DocumentURI, position: Position) async throws -> LocationsOrLocationLinksResponse? {
        let conn = try await ensureInitialized()
        let request = DefinitionRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position
        )
        return try await send(request, on: conn)
    }

    func references(uri: DocumentURI, position: Position) async throws -> [Location] {
        let conn = try await ensureInitialized()
        let request = ReferencesRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position,
            context: ReferencesContext(includeDeclaration: true)
        )
        return try await send(request, on: conn) ?? []
    }

    func hover(uri: DocumentURI, position: Position) async throws -> HoverResponse? {
        let conn = try await ensureInitialized()
        let request = HoverRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position
        )
        return try await send(request, on: conn) ?? nil
    }

    func documentSymbol(uri: DocumentURI) async throws -> DocumentSymbolResponse? {
        let conn = try await ensureInitialized()
        let request = DocumentSymbolRequest(textDocument: TextDocumentIdentifier(uri))
        return try await send(request, on: conn) ?? nil
    }

    func workspaceSymbol(query: String) async throws -> [WorkspaceSymbolItem] {
        let conn = try await ensureInitialized()
        let request = WorkspaceSymbolsRequest(query: query)
        return try await send(request, on: conn) ?? []
    }

    func implementation(uri: DocumentURI, position: Position) async throws -> LocationsOrLocationLinksResponse? {
        let conn = try await ensureInitialized()
        let request = ImplementationRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position
        )
        return try await send(request, on: conn) ?? nil
    }

    func prepareCallHierarchy(uri: DocumentURI, position: Position) async throws -> [CallHierarchyItem] {
        let conn = try await ensureInitialized()
        let request = CallHierarchyPrepareRequest(
            textDocument: TextDocumentIdentifier(uri),
            position: position
        )
        return try await send(request, on: conn) ?? []
    }

    func incomingCalls(uri: DocumentURI, position: Position) async throws -> [CallHierarchyIncomingCall] {
        let items = try await prepareCallHierarchy(uri: uri, position: position)
        guard let item = items.first else {
            throw LSPServerError.noItemsForCallHierarchy
        }
        let conn = try await ensureInitialized()
        let request = CallHierarchyIncomingCallsRequest(item: item)
        return try await send(request, on: conn) ?? []
    }

    func outgoingCalls(uri: DocumentURI, position: Position) async throws -> [CallHierarchyOutgoingCall] {
        let items = try await prepareCallHierarchy(uri: uri, position: position)
        guard let item = items.first else {
            throw LSPServerError.noItemsForCallHierarchy
        }
        let conn = try await ensureInitialized()
        let request = CallHierarchyOutgoingCallsRequest(item: item)
        return try await send(request, on: conn) ?? []
    }

    // MARK: - File Sync

    func openFileIfNeeded(uri: DocumentURI, filePath: String) async throws {
        let conn = try await ensureInitialized()
        await acquireDocument(filePath)
        defer { releaseDocument(filePath) }
        try Task.checkCancellation()
        guard !openedFiles.contains(filePath) else { return }
        let fileURL = URL(fileURLWithPath: filePath)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard data.count <= Self.maxFileSizeBytes else {
            throw LSPServerError.fileTooLarge(filePath)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let ext = (filePath as NSString).pathExtension
        let language = Self.language(forExtension: ext)
        let item = TextDocumentItem(uri: uri, language: language, version: 1, text: text)
        documentVersions[filePath] = 1
        await diagnostics.begin(uri: uri, version: 1)
        guard connection === conn, documentVersions[filePath] == 1 else { throw CancellationError() }
        conn.send(DidOpenTextDocumentNotification(textDocument: item))
        openedFiles.insert(filePath)
    }

    func feedbackAfterMutation(path: String, content: String, waitMs: Int = 500) async throws -> JSONValue {
        guard content.utf8.count <= Self.maxFileSizeBytes else { throw LSPServerError.fileTooLarge(path) }
        let conn = try await ensureInitialized()
        await acquireDocument(path)
        do { try Task.checkCancellation() }
        catch { releaseDocument(path); throw error }
        let uri = DocumentURI(URL(fileURLWithPath: path))
        let version = (documentVersions[path] ?? 0) + 1
        documentVersions[path] = version
        let cache = diagnostics
        await cache.begin(uri: uri, version: version)
        guard documentVersions[path] == version, diagnostics === cache, connection === conn else {
            releaseDocument(path)
            return LSPDiagnosticFeedback.payload(status: "pending", path: path, version: version, reason: "A newer document version is being synchronized.")
        }
        if openedFiles.contains(path) {
            conn.send(DidChangeTextDocumentNotification(
                textDocument: VersionedTextDocumentIdentifier(uri, version: version),
                contentChanges: [TextDocumentContentChangeEvent(text: content)]
            ))
        } else {
            let ext = (path as NSString).pathExtension
            conn.send(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
                uri: uri, language: Self.language(forExtension: ext), version: version, text: content
            )))
            openedFiles.insert(path)
        }
        releaseDocument(path)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(0, waitMs)))
        repeat {
            try Task.checkCancellation()
            guard documentVersions[path] == version, diagnostics === cache else {
                return LSPDiagnosticFeedback.payload(status: "pending", path: path, version: version, reason: "Document or server changed while waiting for diagnostics.")
            }
            if let items = await cache.diagnostics(uri: uri, version: version),
               documentVersions[path] == version, diagnostics === cache {
                return LSPDiagnosticFeedback.payload(status: "ready", path: path, version: version, diagnostics: items)
            }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        } while true
        return LSPDiagnosticFeedback.payload(status: "pending", path: path, version: version, reason: "No current versioned diagnostics received within the wait budget.")
    }

    private func acquireDocument(_ path: String) async {
        if syncingPaths.insert(path).inserted { return }
        await withCheckedContinuation { syncWaiters[path, default: []].append($0) }
    }

    private func releaseDocument(_ path: String) {
        if var waiters = syncWaiters[path], !waiters.isEmpty {
            let next = waiters.removeFirst()
            syncWaiters[path] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else { syncingPaths.remove(path) }
    }

    static func language(forExtension ext: String) -> Language {
        let ids = [
            "swift": "swift", "ts": "typescript", "tsx": "typescriptreact",
            "js": "javascript", "jsx": "javascriptreact", "py": "python",
            "rs": "rust", "go": "go", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp",
            "cs": "csharp", "sh": "shellscript", "bash": "shellscript",
            "json": "json", "md": "markdown", "yaml": "yaml", "yml": "yaml",
        ]
        return Language(rawValue: ids[ext.lowercased()] ?? (ext.isEmpty ? "plaintext" : ext))
    }

    // MARK: - Connection lifecycle

    private func ensureInitialized() async throws -> JSONRPCConnection {
        if let connection, isInitialized {
            return connection
        }
        if let initializationTask { return try await initializationTask.value }
        let task = Task { try await self.startAndInitialize() }
        initializationTask = task
        defer { initializationTask = nil }
        return try await task.value
    }

    private func startAndInitialize() async throws -> JSONRPCConnection {
        let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw LSPServerError.invalidCommand(config.id)
        }

        let executableURL: URL
        let arguments: [String]
        if command.hasPrefix("/") || command.hasPrefix(".") {
            executableURL = URL(fileURLWithPath: command)
            arguments = config.arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = [command] + config.arguments
        }

        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let messageRegistry = MessageRegistry(
            requests: builtinRequests,
            notifications: builtinNotifications
        )

        let conn = JSONRPCConnection(
            name: "\(config.id)-lsp",
            protocol: messageRegistry,
            receiveFD: serverToClient.fileHandleForReading,
            sendFD: clientToServer.fileHandleForWriting
        )

        let handler = LSPDiagnosticMessageHandler(cache: diagnostics)
        conn.start(receiveHandler: handler) {
            withExtendedLifetime((clientToServer, serverToClient)) {}
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.standardOutput = serverToClient
        proc.standardInput = clientToServer
        proc.standardError = FileHandle.standardError

        if let cwd = config.cwd.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            proc.currentDirectoryURL = cwd
        }

        proc.environment = childProcessEnvironment()

        let serverID = config.id
        proc.terminationHandler = { [weak self] process in
            let reason: JSONRPCConnection.TerminationReason = process.terminationReason == .exit
                ? .exited(exitCode: process.terminationStatus)
                : .uncaughtSignal
            conn.close()
            Task { await self?.handleTermination(reason: reason, terminatedConnection: conn) }
            _ = serverID
        }

        try proc.run()

        self.connection = conn
        self.process = proc

        do {
            try await initialize(conn: conn)
            try Task.checkCancellation()
            isInitialized = true
            return conn
        } catch {
            conn.close()
            if proc.isRunning { proc.terminate() }
            if connection === conn {
                connection = nil
                process = nil
                isInitialized = false
                openedFiles = []
                documentVersions = [:]
                diagnostics = LSPDiagnosticCache()
            }
            throw error
        }
    }

    private func initialize(conn: JSONRPCConnection) async throws {
        let rootURI = DocumentURI(workspaceRootURL)
        let capabilities = ClientCapabilities(
            workspace: WorkspaceClientCapabilities(),
            textDocument: TextDocumentClientCapabilities(),
            window: nil,
            general: nil,
            experimental: nil
        )
        let request = InitializeRequest(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: InitializeRequest.ClientInfo(name: "sloppy", version: "1.0.0"),
            rootURI: rootURI,
            capabilities: capabilities,
            workspaceFolders: [WorkspaceFolder(uri: rootURI, name: workspaceRootURL.lastPathComponent)]
        )

        _ = try await send(request, on: conn)
        conn.send(InitializedNotification())
    }

    private func handleTermination(reason: JSONRPCConnection.TerminationReason, terminatedConnection: JSONRPCConnection) {
        guard connection === terminatedConnection else { return }
        logger.warning("LSP server '\(config.id)' terminated: \(String(describing: reason))")
        connection = nil
        process = nil
        isInitialized = false
        openedFiles = []
        documentVersions = [:]
        diagnostics = LSPDiagnosticCache()
    }

    // MARK: - Async send helper

    private func send<R: RequestType>(_ request: R, on conn: JSONRPCConnection) async throws -> R.Response {
        let pending = LSPPendingReply<R.Response>()
        conn.send(request) { result in
            Task { await pending.resolve(result.mapError { $0 as Error }) }
        }
        let timeoutMs = max(1, config.timeoutMs)
        let timeout = Task {
            do { try await Task.sleep(for: .milliseconds(timeoutMs)) }
            catch { return }
            await pending.resolve(.failure(LSPServerError.requestTimedOut(R.method)))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await pending.wait()
        } onCancel: {
            Task { await pending.resolve(.failure(CancellationError())) }
        }
    }
}

// MARK: - LSPServerManager

/// Routes LSP requests to the appropriate server based on file extension.
actor LSPServerManager {
    private var config: CoreConfig.LSP
    private var workspaceRootURL: URL
    private let logger: Logger
    private var instances: [String: LSPServerInstance] = [:]

    init(
        config: CoreConfig.LSP,
        workspaceRootURL: URL,
        logger: Logger = Logger.sloppy(label: "sloppy.lsp")
    ) {
        self.config = config
        self.workspaceRootURL = workspaceRootURL
        self.logger = logger
    }

    func feedbackAfterMutation(path: String, content: String) async -> JSONValue {
        do {
            // A later writer may have replaced this mutation before diagnostics start.
            guard (try? String(contentsOfFile: path, encoding: .utf8)) == content else {
                return LSPDiagnosticFeedback.payload(status: "pending", path: path, reason: "File changed after the mutation.")
            }
            let server = try instance(for: path)
            let feedback = try await server.feedbackAfterMutation(path: path, content: content)
            guard (try? String(contentsOfFile: path, encoding: .utf8)) == content else {
                return LSPDiagnosticFeedback.payload(status: "pending", path: path, reason: "File changed while waiting for diagnostics.")
            }
            return feedback
        } catch {
            return LSPDiagnosticFeedback.payload(status: "unavailable", path: path, reason: error.localizedDescription)
        }
    }

    func updateConfig(_ config: CoreConfig.LSP, workspaceRootURL: URL) async {
        let nextIDs = Set(config.servers.map(\.id))
        let obsolete = instances.keys.filter { !nextIDs.contains($0) }
        for id in obsolete {
            await instances[id]?.shutdown()
            instances.removeValue(forKey: id)
        }
        self.config = config
        self.workspaceRootURL = workspaceRootURL
    }

    func shutdown() async {
        for instance in instances.values {
            await instance.shutdown()
        }
        instances.removeAll()
    }

    func instance(for filePath: String) throws -> LSPServerInstance {
        let ext = "." + (filePath as NSString).pathExtension
        guard let serverConfig = config.servers.first(where: {
            $0.enabled && $0.extensions.contains(ext)
        }) else {
            throw LSPServerError.serverNotFound(ext)
        }
        if let existing = instances[serverConfig.id] {
            return existing
        }
        let instance = LSPServerInstance(
            config: serverConfig,
            workspaceRootURL: workspaceRootURL,
            logger: Logger.sloppy(label: "sloppy.lsp.\(serverConfig.id)")
        )
        instances[serverConfig.id] = instance
        return instance
    }
}
