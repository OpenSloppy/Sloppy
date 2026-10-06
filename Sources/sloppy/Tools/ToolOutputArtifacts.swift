import Foundation
import Protocols

struct ToolOutputArtifactStore: Sendable {
    let workspaceRootURL: URL
    let agentID: String
    let sessionID: String

    var root: URL { workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(".sloppy/tool-outputs", isDirectory: true) }
    var directory: URL {
        root.appendingPathComponent(TaskSyncCrypto.sha256Hex(Data(agentID.utf8)), isDirectory: true)
            .appendingPathComponent(TaskSyncCrypto.sha256Hex(Data(sessionID.utf8)), isDirectory: true)
    }

    func permitsRead(_ url: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path == canonicalRoot || path.hasPrefix(canonicalRoot + "/") else { return true }
        guard directory.standardizedFileURL.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        return path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    func isArtifactPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let artifactRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == artifactRoot || path.hasPrefix(artifactRoot + "/")
    }

    func prepare() throws {
        var component = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let names = [".sloppy", "tool-outputs", TaskSyncCrypto.sha256Hex(Data(agentID.utf8)), TaskSyncCrypto.sha256Hex(Data(sessionID.utf8))]
        for name in names {
            component.appendPathComponent(name, isDirectory: true)
            if let values = try? component.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard component.resolvingSymlinksInPath().standardizedFileURL.path == component.standardizedFileURL.path else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        cleanup()
    }

    func cleanup(now: Date = Date()) { cleanup(directory: directory, now: now) }

    private func cleanup(directory: URL, now: Date) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        ) else { return }
        for file in entries where ["json", "log"].contains(file.pathExtension) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func cleanupAllSessions(now: Date = Date()) {
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else { return }
        func scopedDirectories(_ parent: URL) -> [URL] {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { return [] }
            return children.filter { child in
                let name = child.lastPathComponent
                guard name.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        for agent in scopedDirectories(root) {
            for session in scopedDirectories(agent) {
                cleanup(directory: session, now: now)
            }
        }
    }

    func save(_ data: Data) throws -> JSONValue {
        try prepare()
        let url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return .object(["path": .string(url.path), "totalBytes": .number(Double(data.count)), "complete": .bool(true)])
    }

    func capture() throws -> ToolOutputCapture {
        try prepare()
        return try ToolOutputCapture(directory: directory)
    }

    func bound(_ result: ToolInvocationResult, maxBytes: Int) -> ToolInvocationResult {
        guard let object = result.data?.asObject,
              let original = try? JSONEncoder().encode(result.data), original.count > maxBytes else { return result }
        var budget = max(0, maxBytes)
        var changed = false
        func preview(_ value: JSONValue, key: String = "") -> JSONValue {
            switch value {
            case .string(let text) where ["text", "content", "output", "stdout", "stderr", "html", "markdown"].contains(key):
                let bounded = boundedToolText(text, maxBytes: budget)
                budget = max(0, budget - bounded.utf8.count)
                changed = changed || bounded != text
                return .string(bounded)
            case .object(let object):
                // Preserve typed verification and control metadata without rewriting it.
                return .object(object.keys.sorted().reduce(into: [:]) { output, name in
                    guard let value = object[name] else { return }
                    output[name] = name == "verificationEvidence" || name.hasSuffix("Artifact")
                        ? value : preview(value, key: name)
                })
            case .array(let items): return .array(items.map { preview($0, key: key) })
            default: return value
            }
        }
        var data = preview(.object(object)).asObject ?? object
        guard changed else { return result }
        do {
            data["outputArtifact"] = try save(original)
            data["outputTruncated"] = .bool(true)
        } catch {
            data["outputCaptureError"] = .string(error.localizedDescription)
            data["outputTruncated"] = .bool(true)
        }
        var bounded = result
        bounded.data = .object(data)
        return bounded
    }
}

actor ToolOutputArtifactRetention {
    private var lastSweepByRoot: [String: Date] = [:]

    func sweepIfNeeded(workspaceRootURL: URL, now: Date = Date()) {
        let key = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        if let last = lastSweepByRoot[key], now.timeIntervalSince(last) < 3_600 { return }
        lastSweepByRoot[key] = now
        ToolOutputArtifactStore(workspaceRootURL: workspaceRootURL, agentID: "", sessionID: "").cleanupAllSessions(now: now)
    }
}

/// FileHandle is serialized at the process-pipe boundary; the full stream never
/// accumulates in memory. A capture is published only after successful close.
final class ToolOutputCapture: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private var totalBytes = 0
    private var failure: String?
    private var finished: JSONValue?

    init(directory: URL) throws {
        url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".capture")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
        if finished == nil { try? FileManager.default.removeItem(at: url) }
    }

    func append(_ data: Data) {
        totalBytes += data.count
        guard failure == nil else { return }
        do { try handle.write(contentsOf: data) }
        catch { failure = error.localizedDescription }
    }

    func finish() -> JSONValue {
        if let finished { return finished }
        let result = finishOnce()
        finished = result
        return result
    }

    private func finishOnce() -> JSONValue {
        do { try handle.close() }
        catch { failure = failure ?? error.localizedDescription }
        if let failure {
            try? FileManager.default.removeItem(at: url)
            return .object(["complete": .bool(false), "totalBytes": .number(Double(totalBytes)), "error": .string(failure)])
        }
        let destination = url.deletingPathExtension().appendingPathExtension("log")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return .object(["path": .string(destination.path), "totalBytes": .number(Double(totalBytes)), "complete": .bool(true)])
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .object(["complete": .bool(false), "totalBytes": .number(Double(totalBytes)), "error": .string(error.localizedDescription)])
        }
    }
}

func boundedToolText(_ text: String, maxBytes: Int) -> String {
    guard text.utf8.count > maxBytes else { return text }
    var prefix = Data(text.utf8.prefix(max(0, maxBytes)))
    while !prefix.isEmpty {
        if let string = String(data: prefix, encoding: .utf8) { return string }
        prefix.removeLast()
    }
    return ""
}
