import Foundation
import Protocols
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor SessionProcessRegistry {
    enum RegistryError: Error {
        case processLimitReached
        case processNotFound
        case invalidPayload
        case launchFailed
    }

    private struct ManagedProcess {
        let id: String
        let command: String
        let arguments: [String]
        let cwd: String?
        let process: Process
        let startedAt: Date
        var finishedAt: Date?
        var exitCode: Int32?
        var outputBuffer: ProcessOutputBuffer?
        var outputPipe: Pipe?
        var ownsProcessGroup: Bool
    }

    private var processesBySession: [String: [String: ManagedProcess]] = [:]

    func activeCount(sessionID: String) -> Int {
        let processes = normalizedSessionProcesses(sessionID: sessionID)
        return processes.values.filter(\.process.isRunning).count
    }

    func start(
        sessionID: String,
        command: String,
        arguments: [String],
        cwd: String?,
        maxProcesses: Int,
        environmentOverrides: [String: String] = [:],
        captureOutput: Bool = false
    ) throws -> JSONValue {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RegistryError.invalidPayload
        }

        let current = activeCount(sessionID: sessionID)
        if current >= maxProcesses {
            throw RegistryError.processLimitReached
        }

        let process = Process()
        if command.hasPrefix("/") || command.hasPrefix("./") || command.hasPrefix("../") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            // Use /usr/bin/env to resolve command from PATH
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        let outputBuffer = captureOutput ? ProcessOutputBuffer(maxBytes: 256 * 1024, keepsTail: true) : nil
        let outputPipe = captureOutput ? Pipe() : nil
        if let outputPipe, let outputBuffer {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in outputBuffer.append(handle.availableData) }
            process.standardOutput = outputPipe
            process.standardError = outputPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        process.environment = childProcessEnvironment(overrides: environmentOverrides)

        do {
            try process.run()
        } catch {
            throw RegistryError.launchFailed
        }

        let id = "proc-\(UUID().uuidString.lowercased())"
        let now = Date()
        let managed = ManagedProcess(
            id: id,
            command: command,
            arguments: arguments,
            cwd: cwd,
            process: process,
            startedAt: now,
            finishedAt: nil,
            exitCode: nil,
            outputBuffer: outputBuffer,
            outputPipe: outputPipe,
            ownsProcessGroup: captureOutput && getpgid(process.processIdentifier) == process.processIdentifier
        )
        var sessionProcesses = normalizedSessionProcesses(sessionID: sessionID)
        sessionProcesses[id] = managed
        processesBySession[sessionID] = sessionProcesses

        return .object([
            "processId": .string(id),
            "pid": .number(Double(process.processIdentifier)),
            "running": .bool(true),
            "startedAt": .string(iso8601(now))
        ])
    }

    func output(sessionID: String, processID: String) -> String {
        guard let buffer = processesBySession[sessionID]?[processID]?.outputBuffer else { return "" }
        let snapshot = buffer.snapshot()
        return String(decoding: snapshot.data, as: UTF8.self) + (snapshot.truncated ? "\n[Output truncated]\n" : "")
    }

    func status(sessionID: String, processID: String) throws -> JSONValue {
        var sessionProcesses = normalizedSessionProcesses(sessionID: sessionID)
        guard var process = sessionProcesses[processID] else {
            throw RegistryError.processNotFound
        }

        process = refreshed(process)
        sessionProcesses[processID] = process
        processesBySession[sessionID] = sessionProcesses
        return processPayload(process)
    }

    func stop(sessionID: String, processID: String) async throws -> JSONValue {
        var sessionProcesses = normalizedSessionProcesses(sessionID: sessionID)
        guard var process = sessionProcesses[processID] else {
            throw RegistryError.processNotFound
        }

        if process.ownsProcessGroup {
            // Foundation creates a new process group; confirm ownership before signalling descendants.
            kill(-process.process.processIdentifier, SIGTERM)
        } else if process.process.isRunning && process.outputBuffer != nil {
            await terminateLaunchDescendants(process.process.processIdentifier)
        }
        if process.process.isRunning { await terminateProcess(process.process) }
        if process.ownsProcessGroup { kill(-process.process.processIdentifier, SIGKILL) }
        process = refreshed(process)
        sessionProcesses[processID] = process
        processesBySession[sessionID] = sessionProcesses
        return processPayload(process)
    }

    func list(sessionID: String) -> JSONValue {
        let sessionProcesses = normalizedSessionProcesses(sessionID: sessionID)
        let items = sessionProcesses.values
            .sorted { $0.startedAt > $1.startedAt }

        var refreshedSessionMap: [String: ManagedProcess] = [:]
        for item in items {
            refreshedSessionMap[item.id] = item
        }
        processesBySession[sessionID] = refreshedSessionMap

        return .array(items.map(processPayload))
    }

    func cleanup(sessionID: String) async {
        guard let sessionProcesses = processesBySession[sessionID] else {
            return
        }
        for process in sessionProcesses.values where process.process.isRunning || process.ownsProcessGroup {
            _ = try? await stop(sessionID: sessionID, processID: process.id)
        }
        for process in sessionProcesses.values { process.outputPipe?.fileHandleForReading.readabilityHandler = nil }
        processesBySession.removeValue(forKey: sessionID)
    }

    func shutdown() async {
        for sessionID in processesBySession.keys {
            await cleanup(sessionID: sessionID)
        }
    }

    private func refreshed(_ process: ManagedProcess) -> ManagedProcess {
        guard !process.process.isRunning else {
            return process
        }

        if process.exitCode != nil {
            return process
        }

        var copy = process
        copy.exitCode = process.process.terminationStatus
        copy.finishedAt = Date()
        return copy
    }

    private func normalizedSessionProcesses(sessionID: String) -> [String: ManagedProcess] {
        let sessionProcesses = processesBySession[sessionID] ?? [:]
        let normalized = sessionProcesses.mapValues(refreshed)
        processesBySession[sessionID] = normalized
        return normalized
    }

    private func processPayload(_ process: ManagedProcess) -> JSONValue {
        .object([
            "processId": .string(process.id),
            "command": .string(process.command),
            "arguments": .array(process.arguments.map { .string($0) }),
            "cwd": process.cwd.map(JSONValue.string) ?? .null,
            "running": .bool(process.process.isRunning),
            "startedAt": .string(iso8601(process.startedAt)),
            "finishedAt": process.finishedAt.map { .string(iso8601($0)) } ?? .null,
            "exitCode": process.exitCode.map { .number(Double($0)) } ?? .null
        ])
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Capture child identities before stopping the parent to avoid orphaning shell-launched servers.
private func terminateLaunchDescendants(_ parent: Int32) async {
#if canImport(Darwin) || canImport(Glibc)
    guard let result = try? await runForegroundProcess(command: "/usr/bin/pgrep", arguments: ["-P", String(parent)], cwd: nil, timeoutMs: 2_000, maxOutputBytes: 8192),
          let text = result.asObject?["stdout"]?.asString else { return }
    for child in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
        await terminateLaunchDescendants(child)
        kill(child, SIGTERM)
    }
#endif
}
