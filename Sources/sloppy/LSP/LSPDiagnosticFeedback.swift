import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Protocols

actor LSPDiagnosticCache {
    private struct Entry {
        let version: Int
        var diagnostics: [Diagnostic]?
    }
    private var entries: [DocumentURI: Entry] = [:]

    func begin(uri: DocumentURI, version: Int) {
        guard version >= (entries[uri]?.version ?? 0) else { return }
        entries[uri] = Entry(version: version)
    }

    func publish(_ notification: PublishDiagnosticsNotification) {
        guard var entry = entries[notification.uri],
              notification.version == entry.version || (notification.version == nil && entry.version == 1)
        else { return }
        entry.diagnostics = notification.diagnostics
        entries[notification.uri] = entry
    }

    func diagnostics(uri: DocumentURI, version: Int) -> [Diagnostic]? {
        guard entries[uri]?.version == version else { return nil }
        return entries[uri]?.diagnostics
    }

    func clear() { entries.removeAll() }
}

final class LSPDiagnosticMessageHandler: MessageHandler {
    let cache: LSPDiagnosticCache

    init(cache: LSPDiagnosticCache) { self.cache = cache }

    func handle(_ notification: some NotificationType) {
        guard let diagnostics = notification as? PublishDiagnosticsNotification else { return }
        Task { await cache.publish(diagnostics) }
    }

    func handle<R: RequestType>(
        _ request: R, id: RequestID,
        reply: @Sendable @escaping (LSPResult<R.Response>) -> Void
    ) {
        reply(.failure(ResponseError.methodNotFound(R.method)))
    }
}

actor LSPPendingReply<Response: Sendable> {
    private var result: Result<Response, Error>?
    private var continuation: CheckedContinuation<Response, Error>?

    func resolve(_ result: Result<Response, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func wait() async throws -> Response {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

enum LSPDiagnosticFeedback {
    static func payload(status: String, path: String, version: Int? = nil, diagnostics: [Diagnostic] = [], reason: String? = nil) -> JSONValue {
        let items = diagnostics.prefix(30).map { diagnostic -> JSONValue in
            .object([
                "file": .string(path),
                "line": .number(Double(diagnostic.range.lowerBound.line + 1)),
                "character": .number(Double(diagnostic.range.lowerBound.utf16index + 1)),
                "severity": .string(severity(diagnostic.severity)),
                "message": .string(String(diagnostic.message.prefix(2_000))),
            ])
        }
        var result: [String: JSONValue] = [
            "status": .string(status), "items": .array(items),
            "truncated": .bool(diagnostics.count > 30 || diagnostics.contains { $0.message.count > 2_000 }),
        ]
        if let version { result["version"] = .number(Double(version)) }
        if let reason { result["reason"] = .string(reason) }
        return .object(result)
    }

    private static func severity(_ severity: DiagnosticSeverity?) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .information: "information"
        case .hint: "hint"
        case nil: "unknown"
        }
    }
}

extension ToolContext {
    func mutationResult(tool: String, outcome: FileMutationOutcome) async -> ToolInvocationResult {
        var data = outcome.data
        let path = data["path"]?.asString ?? ""
        if let lspManager {
            data["diagnostics"] = await lspManager.feedbackAfterMutation(path: path, content: outcome.content)
        } else {
            data["diagnostics"] = LSPDiagnosticFeedback.payload(status: "unavailable", path: path, reason: "No LSP manager configured.")
        }
        return toolSuccess(tool: tool, data: .object(data))
    }
}
