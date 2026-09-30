import Foundation
import PluginSDK
import Protocols
import AgentRuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Path resolution

extension ToolContext {
    func resolveReadablePath(_ path: String) -> URL? {
        resolveToolPath(
            path,
            workspaceRootURL: workspaceRootURL,
            currentDirectoryURL: currentDirectoryURL,
            extraRoots: extraReadableRoots()
        )
    }

    func resolveWritablePath(_ path: String) -> URL? {
        resolveToolPath(
            path,
            workspaceRootURL: workspaceRootURL,
            currentDirectoryURL: currentDirectoryURL,
            extraRoots: extraWritableRoots()
        )
    }

    func resolveExecCwd(_ path: String) -> URL? {
        resolveToolPath(
            path,
            workspaceRootURL: workspaceRootURL,
            currentDirectoryURL: currentDirectoryURL,
            extraRoots: extraExecRoots()
        )
    }

    private func extraReadableRoots() -> [String] {
        if policy.sandbox.mode == .fullAccess {
            return ["/"] + readOnlyRoots
        }
        return policy.guardrails.allowedWriteRoots + defaultTemporaryToolRoots() + readOnlyRoots
    }

    private func extraWritableRoots() -> [String] {
        if policy.sandbox.mode == .fullAccess {
            return ["/"]
        }
        return policy.guardrails.allowedWriteRoots + defaultTemporaryToolRoots()
    }

    private func extraExecRoots() -> [String] {
        if policy.sandbox.mode == .fullAccess {
            return ["/"]
        }
        return policy.guardrails.allowedExecRoots + defaultTemporaryToolRoots()
    }

    /// True when the path targets an agent's `USER.md` or `MEMORY.md` under `/agents` (including `.system`).
    func isAgentsUserOrMemoryMarkdownFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name == "USER.md" || name == "MEMORY.md" else {
            return false
        }
        let agentsRoot = workspaceRootURL.appendingPathComponent("agents", isDirectory: true).standardizedFileURL
        let systemRoot = agentsRoot.appendingPathComponent(".system", isDirectory: true).standardizedFileURL
        let path = url.standardizedFileURL.path
        let agentsPath = agentsRoot.path
        let systemPath = systemRoot.path
        return path.hasPrefix(agentsPath + "/") || path.hasPrefix(systemPath + "/")
    }
}

func defaultTemporaryToolRoots() -> [String] {
    ["/tmp"]
}

func resolveToolPath(
    _ path: String,
    workspaceRootURL: URL,
    currentDirectoryURL: URL? = nil,
    extraRoots: [String]
) -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let roots = [workspaceRootURL] + extraRoots.map { raw -> URL in
        raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : workspaceRootURL.appendingPathComponent(raw)
    }

    let candidates: [URL]
    if trimmed.hasPrefix("/") {
        candidates = [URL(fileURLWithPath: trimmed)]
    } else {
        let currentDirectoryURL = currentDirectoryURL ?? workspaceRootURL
        var relativeCandidates = [currentDirectoryURL.appendingPathComponent(trimmed)]
        if currentDirectoryURL.standardizedFileURL.path != workspaceRootURL.standardizedFileURL.path {
            relativeCandidates.append(workspaceRootURL.appendingPathComponent(trimmed))
        }
        candidates = relativeCandidates
    }

    for candidate in candidates {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        for root in roots {
            let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
            let rootPath = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
            if resolved.path == rootResolved.path || resolved.path.hasPrefix(rootPath) {
                return resolved
            }
        }
    }
    return nil
}

// MARK: - Command guard

func isCommandAllowed(_ command: String, deniedPrefixes: [String]) -> Bool {
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }
    let basename = URL(fileURLWithPath: normalized).lastPathComponent
    let candidates = [normalized, basename]
    for prefix in deniedPrefixes.map({ $0.lowercased() }) {
        if candidates.contains(where: { $0 == prefix || $0.hasPrefix(prefix + " ") }) {
            return false
        }
    }
    return true
}

// MARK: - Process environment

/// Full environment for spawned processes: the current process environment (shell, launchd `EnvironmentVariables`, CI, etc.) plus optional per-spawn overrides. Overrides replace or add keys; the base dict is never dropped.
func childProcessEnvironment(
    overrides: [String: String] = [:],
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var env = base
    env["PATH"] = augmentedChildProcessPATH(base["PATH"])
    for (key, value) in overrides {
        env[key] = value
    }
    return env
}

private func augmentedChildProcessPATH(_ path: String?) -> String {
    var entries = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)
    let existing = Set(entries)
    for candidate in childProcessPATHCandidates() where !existing.contains(candidate) {
        entries.append(candidate)
    }
    return entries.joined(separator: ":")
}

private func childProcessPATHCandidates() -> [String] {
    [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/homebrew/opt/node/bin",
        "/opt/homebrew/opt/node@24/bin",
        "/opt/homebrew/opt/node@22/bin",
        "/opt/homebrew/opt/node@20/bin",
        "/opt/homebrew/opt/node@18/bin",
    ].filter { FileManager.default.fileExists(atPath: $0) }
}

// MARK: - Process execution

final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int
    private var truncated = false
    private let keepsTail: Bool

    init(maxBytes: Int, keepsTail: Bool = false) {
        self.maxBytes = max(0, maxBytes)
        self.keepsTail = keepsTail
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if keepsTail {
            data.append(chunk)
            if data.count > maxBytes { data = Data(data.suffix(maxBytes)); truncated = true }
            return
        }
        guard data.count < maxBytes else {
            truncated = true
            return
        }

        let remaining = maxBytes - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

func runForegroundProcess(
    command: String,
    arguments: [String],
    cwd: URL?,
    timeoutMs: Int,
    maxOutputBytes: Int,
    environmentOverrides: [String: String] = [:],
    standardInput: Data? = nil
) async throws -> JSONValue {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = try makeProcessInputPipe()
    let stdoutBuffer = ProcessOutputBuffer(maxBytes: maxOutputBytes)
    let stderrBuffer = ProcessOutputBuffer(maxBytes: maxOutputBytes)

    if command.hasPrefix("/") || command.hasPrefix("./") || command.hasPrefix("../") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
    }

    process.environment = childProcessEnvironment(overrides: environmentOverrides)
    process.standardOutput = stdout
    process.standardError = stderr
    if standardInput != nil {
        process.standardInput = stdin
    }
    process.currentDirectoryURL = cwd

    stdout.fileHandleForReading.readabilityHandler = { handle in
        stdoutBuffer.append(handle.availableData)
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
        stderrBuffer.append(handle.availableData)
    }

    try process.run()
    if let standardInput {
        try stdin.fileHandleForWriting.write(contentsOf: standardInput)
        try? stdin.fileHandleForWriting.close()
    }

    let didTimeout = await waitForProcessExitOrTimeout(process: process, timeoutMs: timeoutMs)

    if didTimeout, process.isRunning {
        await terminateProcess(process)
    }

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil

    let stdoutSnapshot = stdoutBuffer.snapshot()
    let stderrSnapshot = stderrBuffer.snapshot()
    let exitCode = process.isRunning ? -1 : Int(process.terminationStatus)

    return .object([
        "command": .string(command),
        "arguments": .array(arguments.map { .string($0) }),
        "exitCode": .number(Double(exitCode)),
        "timedOut": .bool(didTimeout),
        "stdout": .string(String(decoding: stdoutSnapshot.data, as: UTF8.self)),
        "stderr": .string(String(decoding: stderrSnapshot.data, as: UTF8.self)),
        "stdoutTruncated": .bool(stdoutSnapshot.truncated),
        "stderrTruncated": .bool(stderrSnapshot.truncated)
    ])
}

func resolvedExecTimeoutMs(arguments: [String: JSONValue], guardrails: AgentToolsGuardrails) -> Int {
    let requested = arguments["timeoutMs"]?.asInt ?? guardrails.maxExecTimeoutMs
    return min(max(1, requested), max(1, guardrails.maxExecTimeoutMs))
}

func waitForProcessExitOrTimeout(process: Process, timeoutMs: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(max(1, timeoutMs)) / 1000.0)
    while process.isRunning {
        if Task.isCancelled {
            return true
        }
        if Date() >= deadline {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

func terminateProcess(_ process: Process) async {
    process.terminate()
    if await waitForProcessToStop(process, graceMs: 2_000) {
        return
    }
    forceKill(process)
    _ = await waitForProcessToStop(process, graceMs: 2_000)
}

private func waitForProcessToStop(_ process: Process, graceMs: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(max(1, graceMs)) / 1000.0)
    while process.isRunning {
        if Date() >= deadline {
            return false
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

private func forceKill(_ process: Process) {
    #if canImport(Darwin) || canImport(Glibc)
    kill(process.processIdentifier, SIGKILL)
    #else
    process.interrupt()
    #endif
}

// MARK: - String / argument utilities

func sessionChannelID(agentID: String, sessionID: String) -> String {
    "agent:\(agentID):session:\(sessionID)"
}

func trimmedArg(_ key: String, from arguments: [String: JSONValue]) -> String? {
    let s = arguments[key]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.isEmpty ? nil : s
}

func optionalLabel(_ value: String?) -> String {
    let s = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.isEmpty ? "(none)" : s
}

func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: [], range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

// MARK: - JSON encoding

func encodeJSONValue<T: Encodable>(_ value: T) -> JSONValue {
    do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        return .null
    }
}

func stableJSONString(_ value: JSONValue) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

// MARK: - Session status

func statusFrom(events: [AgentSessionEvent]) -> String {
    for event in events.reversed() where event.type == .runStatus {
        if let stage = event.runStatus?.stage.rawValue {
            return stage
        }
    }
    return "idle"
}

// MARK: - Memory scope

func parseMemoryScope(from arguments: [String: JSONValue]) -> MemoryScope? {
    if let scopeObj = arguments["scope"]?.asObject {
        let scopeType = scopeObj["type"]?.asString?.lowercased()
        let scopeID = scopeObj["id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let scopeType, let type = MemoryScopeType(rawValue: scopeType), !scopeID.isEmpty else {
            return nil
        }
        return MemoryScope(
            type: type,
            id: scopeID,
            channelId: scopeObj["channel_id"]?.asString,
            projectId: scopeObj["project_id"]?.asString,
            agentId: scopeObj["agent_id"]?.asString
        )
    }

    let scopeType = arguments["scope_type"]?.asString?.lowercased()
    let scopeID = arguments["scope_id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let scopeType, let type = MemoryScopeType(rawValue: scopeType), !scopeID.isEmpty else {
        return nil
    }
    return MemoryScope(type: type, id: scopeID)
}

func isSharedMemoryScope(_ scope: MemoryScope?) -> Bool {
    guard let scope else { return false }
    return scope.type == .global && scope.id == "shared"
}

func sharedMemoryDisabledFailure(tool: String) -> ToolInvocationResult {
    toolFailure(
        tool: tool,
        code: "shared_memory_disabled",
        message: "Shared memory is disabled for this agent. Use an agent, channel, or project scope instead.",
        retryable: false
    )
}

func rejectDisabledSharedMemory(scope: MemoryScope?, context: ToolContext, tool: String) -> ToolInvocationResult? {
    guard isSharedMemoryScope(scope), !context.sharedMemoryEnabled else {
        return nil
    }
    return sharedMemoryDisabledFailure(tool: tool)
}

// MARK: - Project helpers (pure functions)

func trimmedStringArgument(_ arguments: [String: JSONValue], _ key: String) -> String? {
    guard let raw = arguments[key]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else {
        return nil
    }
    return raw
}

func stringArgument(_ arguments: [String: JSONValue], _ key: String, default defaultValue: String) -> String {
    trimmedStringArgument(arguments, key) ?? defaultValue
}

func findProjectForChannel(store: any PersistenceStore, channelId: String, topicId: String?) async -> ProjectRecord? {
    let projects = await store.listProjects()
    let scoped = ChannelGatewayScope.parse(channelId)
    let effectiveChannelId = ChannelGatewayScope.scopedChannelId(
        baseChannelId: scoped.baseChannelId,
        topicKey: scoped.topicKey ?? topicId
    )
    let ordered = projects.sorted(by: { $0.createdAt < $1.createdAt })
    if let exact = ordered.first(where: { project in
        project.channels.contains { $0.channelId == effectiveChannelId }
    }) {
        return exact
    }
    return ordered.first(where: { project in
        project.channels.contains { binding in
            ChannelGatewayScope.sessionMatchesBinding(sessionChannelId: effectiveChannelId, bindingChannelId: binding.channelId)
        }
    })
}

func normalizeTaskRef(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let token = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard t.rangeOfCharacter(from: allowed.inverted) == nil, t.count <= 180 else { return nil }
    return t
}

func taskReferences(from arguments: [String: JSONValue]) -> (references: [String], invalid: [String]) {
    var rawReferences: [String] = []
    var invalid: [String] = []

    func appendSingle(_ key: String) {
        guard let value = arguments[key] else { return }
        if let raw = value.asString {
            rawReferences.append(raw)
        } else {
            invalid.append(key)
        }
    }

    func appendArray(_ key: String) {
        guard let value = arguments[key] else { return }
        guard let array = value.asArray else {
            invalid.append(key)
            return
        }
        for item in array {
            if let raw = item.asString {
                rawReferences.append(raw)
            } else {
                invalid.append(key)
            }
        }
    }

    appendSingle("taskId")
    appendSingle("reference")
    appendArray("taskIds")
    appendArray("references")

    var seen = Set<String>()
    let normalized = rawReferences.compactMap { raw -> String? in
        guard let ref = normalizeTaskRef(raw) else {
            invalid.append(raw)
            return nil
        }
        let key = ref.lowercased()
        guard seen.insert(key).inserted else {
            return nil
        }
        return ref
    }
    return (normalized, invalid)
}

func findTask(reference: String, in project: ProjectRecord) throws -> ProjectTask {
    let lower = reference.lowercased()
    guard let task = project.tasks.first(where: { $0.id == reference || $0.id.lowercased() == lower }) else {
        throw CoreService.ProjectError.notFound
    }
    return task
}

func taskJSONValue(_ task: ProjectTask) -> JSONValue {
    .object([
        "id": .string(task.id),
        "title": .string(task.title),
        "description": .string(task.description),
        "priority": .string(task.priority),
        "status": .string(task.status),
        "kind": task.kind.map { .string($0.rawValue) } ?? .null,
        "loopModeOverride": task.loopModeOverride.map { .string($0.rawValue) } ?? .null,
        "actorId": task.actorId.map { .string($0) } ?? .null,
        "teamId": task.teamId.map { .string($0) } ?? .null,
        "claimedActorId": task.claimedActorId.map { .string($0) } ?? .null,
        "claimedAgentId": task.claimedAgentId.map { .string($0) } ?? .null,
        "parentTaskId": task.parentTaskId.map { .string($0) } ?? .null,
        "createdBy": task.createdBy.map { .string($0) } ?? .null,
        "dependsOnTaskIds": .array(task.dependsOnTaskIds.map { .string($0) }),
        "swarmId": task.swarmId.map { .string($0) } ?? .null,
        "swarmTaskId": task.swarmTaskId.map { .string($0) } ?? .null,
        "swarmParentTaskId": task.swarmParentTaskId.map { .string($0) } ?? .null,
        "swarmDependencyIds": task.swarmDependencyIds.map { .array($0.map { .string($0) }) } ?? .null,
        "swarmDepth": task.swarmDepth.map { .number(Double($0)) } ?? .null,
        "swarmActorPath": task.swarmActorPath.map { .array($0.map { .string($0) }) } ?? .null,
        "selectedModel": task.selectedModel.map { .string($0) } ?? .null,
        "tags": .array(task.tags.map { .string($0) }),
        "isArchived": .bool(task.isArchived),
        "createdAt": .string(ISO8601DateFormatter().string(from: task.createdAt)),
        "updatedAt": .string(ISO8601DateFormatter().string(from: task.updatedAt))
    ])
}
