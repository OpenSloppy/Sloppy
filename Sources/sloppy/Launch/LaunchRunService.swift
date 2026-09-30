import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
import Darwin
#endif
import Protocols
import NIOCore
import NIOPosix

/// Owns launch configuration selection, execution and durable history independently of agent turns.
actor LaunchRunService {
    enum Failure: Error, LocalizedError {
        case invalid(String), notFound, alreadyRunning, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let message), .unavailable(let message): message
            case .notFound: "Launch configuration or run not found."
            case .alreadyRunning: "This target is already running. Use Restart."
            }
        }
    }

    private var store: any PersistenceStore
    private let processes: SessionProcessRegistry
    private var sessions: [String: LaunchSessionState] = [:]
    private var loaded = false
    private var persistenceTail: Task<Void, Error>?
    private var deletingSessions: Set<String> = []
    private var simulatorOwners: [String: String] = [:]
    private var simulatorLaunchAttempts: Set<String> = []
    private var jobs: [String: Task<Void, Never>] = [:]
    private var processIDs: [String: String] = [:]
#if canImport(AppKit)
    private var nativeApplications: [String: NSRunningApplication] = [:]
#endif

    init(store: any PersistenceStore, processes: SessionProcessRegistry) {
        self.store = store; self.processes = processes
    }

    private func key(_ agent: String, _ session: String) -> String { agent + ":" + session }

    private func hydrate() async throws {
        guard !loaded else { return }
        let records = try await store.loadLaunchSessions()
        guard !loaded else { return }
        var recovered: [LaunchSessionState] = []
        for var record in records {
            var changed = false
            for index in record.runs.indices where record.runs[index].status.isActive {
                record.runs[index].status = .failed
                record.runs[index].error = "Core restarted; this launch is no longer managed. Start it again."
                record.runs[index].finishedAt = Date()
                changed = true
            }
            sessions[key(record.agentID, record.sessionID)] = record
            if changed { recovered.append(record) }
        }
        loaded = true
        for record in recovered where sessions[key(record.agentID, record.sessionID)] == record {
            try await writeSnapshot(record)
        }
    }

    func updateStore(_ store: any PersistenceStore, reset: Bool = false) async throws {
        if reset {
            await shutdown()
            self.store = store; sessions = [:]; loaded = false
            try await hydrate()
        } else {
            self.store = store
            for id in Array(sessions.keys) {
                if let state = sessions[id] { try await writeSnapshot(state) }
            }
        }
    }

    func state(agentID: String, sessionID: String) async throws -> LaunchSessionState {
        try await hydrate()
        return sessions[key(agentID, sessionID)] ?? LaunchSessionState(agentID: agentID, sessionID: sessionID)
    }

    private func writeSnapshot(_ state: LaunchSessionState) async throws {
        // Actor methods may reenter while awaiting SQLite. Chain writes so an older snapshot cannot
        // overwrite a newer explicit selection or run status in durable storage.
        let previous = persistenceTail
        let destination = store
        let write = Task {
            _ = try? await previous?.value
            try await destination.saveLaunchSession(state)
        }
        persistenceTail = write
        try await write.value
    }

    private func save(_ state: LaunchSessionState) async throws {
        // The actor's copy changes before yielding to persistence, so concurrent UI requests see it.
        let id = key(state.agentID, state.sessionID)
        let previous = sessions[id]
        sessions[id] = state
        do { try await writeSnapshot(state) }
        catch {
            if sessions[id] == state { sessions[id] = previous }
            throw error
        }
    }

    func configure(_ configuration: LaunchConfiguration) async throws -> LaunchSessionState {
        guard !deletingSessions.contains(key(configuration.agentID, configuration.sessionID)) else { throw Failure.unavailable("This chat is being deleted.") }
        var state = try await state(agentID: configuration.agentID, sessionID: configuration.sessionID)
        if state.runs.contains(where: { $0.configurationID == configuration.id && $0.status.isActive }) {
            throw Failure.alreadyRunning
        }
        state.configurations.removeAll { $0.id == configuration.id }
        state.configurations.append(configuration)
        state.recommendedConfigurationID = configuration.id
        if !state.selectionIsExplicit { state.selectedConfigurationID = configuration.id }
        try await save(state)
        return state
    }

    func select(agentID: String, sessionID: String, request: LaunchSelectionRequest) async throws -> LaunchSessionState {
        var state = try await state(agentID: agentID, sessionID: sessionID)
        guard let index = state.configurations.firstIndex(where: { $0.id == request.configurationID }) else { throw Failure.notFound }
        if let simulatorID = request.simulatorID {
            guard !state.runs.contains(where: { $0.configurationID == request.configurationID && $0.status.isActive }) else {
                throw Failure.alreadyRunning
            }
            state.configurations[index].request.simulatorID = simulatorID
        }
        state.selectedConfigurationID = request.configurationID
        state.selectionIsExplicit = true
        try await save(state)
        return state
    }

    func remove(agentID: String, sessionID: String, configurationID: String) async throws -> LaunchSessionState {
        let state = try await state(agentID: agentID, sessionID: sessionID)
        for run in state.runs where run.configurationID == configurationID && run.status.isActive {
            _ = try await stop(agentID: agentID, sessionID: sessionID, runID: run.id)
        }
        var next = try await self.state(agentID: agentID, sessionID: sessionID)
        next.configurations.removeAll { $0.id == configurationID }
        if next.selectedConfigurationID == configurationID {
            next.selectedConfigurationID = nil; next.selectionIsExplicit = false
        }
        if next.recommendedConfigurationID == configurationID { next.recommendedConfigurationID = next.configurations.last?.id }
        try await save(next)
        return next
    }

    func retainsCheckout(_ path: String) async throws -> Bool {
        try await hydrate()
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return sessions.values.contains { state in
            (!state.isArchived && state.configurations.contains { $0.request.checkoutPath == root })
                || state.runs.contains { $0.status.isActive && $0.configuration.request.checkoutPath == root }
        }
    }

    func archive(agentID: String, sessionID: String, isArchived: Bool) async throws -> LaunchSessionState {
        let current = try await state(agentID: agentID, sessionID: sessionID)
        if isArchived {
            for run in current.runs where run.status.isActive { _ = try await stop(agentID: agentID, sessionID: sessionID, runID: run.id) }
        }
        var next = try await state(agentID: agentID, sessionID: sessionID)
        next.isArchived = isArchived
        try await save(next)
        return next
    }

    func deleteSession(agentID: String, sessionID: String) async throws {
        let id = key(agentID, sessionID)
        deletingSessions.insert(id)
        defer { deletingSessions.remove(id) }
        let state = try await state(agentID: agentID, sessionID: sessionID)
        for run in state.runs where run.status.isActive { _ = try await stop(agentID: agentID, sessionID: sessionID, runID: run.id) }
        sessions.removeValue(forKey: key(agentID, sessionID))
        _ = try? await persistenceTail?.value
        try await store.deleteLaunchSession(agentID: agentID, sessionID: sessionID)
    }

    func start(configuration: LaunchConfiguration, environment: [String: String], timeoutMs: Int, maxProcesses: Int) async throws -> LaunchRun {
        var state = try await state(agentID: configuration.agentID, sessionID: configuration.sessionID)
        guard !deletingSessions.contains(key(configuration.agentID, configuration.sessionID)) else { throw Failure.unavailable("This chat is being deleted.") }
        guard state.configurations.contains(where: { $0.id == configuration.id && $0.request == configuration.request }) else { throw Failure.unavailable("Launch configuration changed or was removed. Select the target again.") }
        guard !state.isArchived else { throw Failure.unavailable("Unarchive this chat before starting Play.") }
        guard !state.runs.contains(where: { $0.configurationID == configuration.id && $0.status.isActive }) else { throw Failure.alreadyRunning }
        let simulatorKey = simulatorTargetKey(configuration.request)
        if let simulatorKey, simulatorOwners[simulatorKey] != nil {
            throw Failure.unavailable("This application is already managed on that Simulator by another launch. Stop that run or choose another Simulator.")
        }
        let run = LaunchRun(id: UUID().uuidString.lowercased(), configurationID: configuration.id,
                            configuration: configuration, status: .preparing, buildSucceeded: false,
                            launchSucceeded: false, logs: "", startedAt: Date())
        state.runs.insert(run, at: 0)
        let active = state.runs.filter { $0.status.isActive }
        state.runs = active + Array(state.runs.filter { !$0.status.isActive }.prefix(20))
        if let simulatorKey { simulatorOwners[simulatorKey] = run.id }
        do { try await save(state) }
        catch {
            if let simulatorKey, simulatorOwners[simulatorKey] == run.id { simulatorOwners[simulatorKey] = nil }
            throw error
        }
        guard let current = sessions[key(configuration.agentID, configuration.sessionID)]?.runs.first(where: { $0.id == run.id }) else {
            if let simulatorKey, simulatorOwners[simulatorKey] == run.id { simulatorOwners[simulatorKey] = nil }
            throw Failure.notFound
        }
        guard current.status.isActive, !deletingSessions.contains(key(configuration.agentID, configuration.sessionID)) else {
            if let simulatorKey, simulatorOwners[simulatorKey] == run.id { simulatorOwners[simulatorKey] = nil }
            return current
        }
        jobs[run.id] = Task {
            await self.execute(run, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
        }
        return run
    }

    private func change(_ run: LaunchRun, _ body: (inout LaunchRun) -> Void) async throws {
        guard var state = sessions[key(run.configuration.agentID, run.configuration.sessionID)],
              let index = state.runs.firstIndex(where: { $0.id == run.id }) else { throw Failure.notFound }
        let previous = state.runs[index]
        body(&state.runs[index])
        guard state.runs[index] != previous else { return }
        do { try await save(state) }
        catch {
            // Preserve runtime truth even if disk writes fail. Configuration edits still roll back,
            // but a stopped/failed process must never be advertised as running in the current Core.
            let id = key(state.agentID, state.sessionID)
            if var latest = sessions[id], let position = latest.runs.firstIndex(where: { $0.id == run.id }),
               latest.runs[position].status.isActive || !state.runs[index].status.isActive {
                latest.runs[position] = state.runs[index]
                latest.runs[position].error = latest.runs[position].error ?? "Launch state could not be saved: \(error.localizedDescription)"
                sessions[id] = latest
            }
            throw error
        }
    }

    private func log(_ run: LaunchRun, _ text: String) async throws {
        try await change(run) { $0.logs = String(($0.logs + text).suffix(256 * 1024)) }
    }

    private func execute(_ run: LaunchRun, environment: [String: String], timeoutMs: Int, maxProcesses: Int) async {
        defer {
            jobs.removeValue(forKey: run.id)
            processIDs.removeValue(forKey: run.id)
            simulatorLaunchAttempts.remove(run.id)
            if let key = simulatorTargetKey(run.configuration.request), simulatorOwners[key] == run.id {
                simulatorOwners[key] = nil
            }
        }
        do {
            let request = run.configuration.request
            let cwd = URL(fileURLWithPath: request.checkoutPath).appendingPathComponent(request.workingDirectory).path
            guard FileManager.default.fileExists(atPath: cwd) else { throw Failure.unavailable("Worktree is missing: \(cwd)") }
            try Task.checkCancellation()
            try await change(run) { $0.status = .building }
            for command in request.build {
                _ = try await commandRun(command, run: run, cwd: cwd, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
            }
            try Task.checkCancellation()
            try await change(run) { $0.buildSucceeded = true; $0.status = .launching }
            switch request.platform {
            case .web:
                guard let command = request.launch, let port = request.webPort else { throw Failure.invalid("Web launch requires a command and loopback port.") }
                if let existing = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.seconds(1)).connect(host: "127.0.0.1", port: port).get() {
                    try? await existing.close().get()
                    throw Failure.unavailable("Preview port \(port) is already in use. Stop its owner or choose another port.")
                }
                let process = try await startProcess(command, run: run, cwd: cwd, environment: environment, maxProcesses: maxProcesses)
                guard let url = URL(string: "http://127.0.0.1:\(port)\(request.webPath ?? "/")") else { throw Failure.invalid("Invalid preview URL.") }
                let deadline = Date().addingTimeInterval(30)
                var ready = false
                while Date() < deadline && !ready {
                    try Task.checkCancellation()
                    let status = try await processes.status(sessionID: processSession(run), processID: process)
                    guard status.asObject?["running"]?.asBool == true else { throw Failure.unavailable("Web server exited before the preview became available.") }
                    var probe = URLRequest(url: url); probe.timeoutInterval = 1
                    if let (_, response) = try? await URLSession.shared.data(for: probe), let response = response as? HTTPURLResponse {
                        ready = (200..<400).contains(response.statusCode)
                    }
                    if !ready { try await Task.sleep(for: .milliseconds(200)) }
                }
                guard ready else { throw Failure.unavailable("Web preview did not become ready within 30 seconds.") }
                try await change(run) { $0.previewURL = url.absoluteString; $0.launchSucceeded = true; $0.status = .running }
                try await monitor(process, run: run)
            case .macOS:
#if canImport(AppKit)
                let app = try appURL(request)
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.environment = childProcessEnvironment(overrides: environment)
                let application = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
                nativeApplications[run.id] = application
                try await change(run) { $0.processID = Int(application.processIdentifier); $0.launchSucceeded = true; $0.status = .running }
                while !application.isTerminated { try await Task.sleep(for: .milliseconds(200)) }
#else
                throw Failure.unavailable("macOS applications require a Mac execution host.")
#endif
            case .iOSSimulator:
#if os(macOS)
                guard let device = request.simulatorID, let bundle = request.bundleID else { throw Failure.invalid("Choose a Simulator before launching.") }
                let app = try appURL(request)
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")),
                      info["CFBundleIdentifier"] as? String == bundle else {
                    throw Failure.invalid("Built application bundle ID does not match the Simulator launch configuration.")
                }
                let xcrun: ([String]) -> LaunchCommand = { LaunchCommand(executable: "/usr/bin/xcrun", arguments: $0) }
                // bootstatus boots a shutdown device and waits for it to become ready.
                _ = try await commandRun(xcrun(["simctl", "bootstatus", device, "-b"]), run: run, cwd: cwd, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
                _ = try await commandRun(LaunchCommand(executable: "/usr/bin/open", arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device]), run: run, cwd: cwd, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
                // Simulator apps have one instance per bundle/device. Play replaces the selected
                // app after building; other managed launches must release this namespace first.
                _ = try? await runForegroundProcess(command: "/usr/bin/xcrun", arguments: ["simctl", "terminate", device, bundle], cwd: nil, timeoutMs: 5_000, maxOutputBytes: 4096)
                try Task.checkCancellation()
                _ = try await commandRun(xcrun(["simctl", "install", device, app.path]), run: run, cwd: cwd, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
                // Record ownership before invoking simctl: cancellation or storage failure may
                // occur after the app starts but before its PID can be published.
                simulatorLaunchAttempts.insert(run.id)
                let output = try await commandRun(xcrun(["simctl", "launch", device, bundle]), run: run, cwd: cwd, environment: environment, timeoutMs: timeoutMs, maxProcesses: maxProcesses)
                let line = output.split(separator: "\n").first { $0.hasPrefix(bundle + ":") }
                let pid = line.flatMap { Int($0.dropFirst(bundle.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard let pid else { throw Failure.unavailable("Simulator did not return an application PID.") }
                try await change(run) { $0.processID = pid; $0.launchSucceeded = true; $0.status = .running }
                while kill(Int32(pid), 0) == 0 { try await Task.sleep(for: .milliseconds(300)) }
#else
                throw Failure.unavailable("iOS Simulator requires a Mac execution host.")
#endif
            }
            try Task.checkCancellation()
            try await change(run) { $0.status = .completed; $0.finishedAt = Date() }
        } catch {
            if let process = processIDs[run.id] { _ = try? await processes.stop(sessionID: processSession(run), processID: process) }
            // Cleanup gets an uncancelled task so platform termination can finish after Stop.
            await Task { await self.terminateNativeApplication(run) }.value
            if !Task.isCancelled {
                try? await change(run) { $0.status = .failed; $0.error = error.localizedDescription; $0.finishedAt = Date() }
            }
        }
        await processes.cleanup(sessionID: processSession(run))
#if canImport(AppKit)
        if nativeApplications[run.id]?.isTerminated == true { nativeApplications[run.id] = nil }
#endif
    }

    private func appURL(_ request: LaunchConfigurationRequest) throws -> URL {
        guard let path = request.appPath else { throw Failure.invalid("Application path is missing.") }
        let url = URL(fileURLWithPath: request.checkoutPath).appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(request.checkoutPath + "/"), url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.unavailable("Built application is missing or outside this checkout: \(path)")
        }
        return url
    }

    private func simulatorTargetKey(_ request: LaunchConfigurationRequest) -> String? {
        guard request.platform == .iOSSimulator, let device = request.simulatorID, let bundle = request.bundleID else { return nil }
        return device + ":" + bundle
    }

    private func processSession(_ run: LaunchRun) -> String { "launch-" + run.id }

    private func startProcess(_ command: LaunchCommand, run: LaunchRun, cwd: String, environment: [String: String], maxProcesses: Int) async throws -> String {
        try Task.checkCancellation()
        try await log(run, "$ \(command.executable) \(command.arguments.joined(separator: " "))\n")
        let result = try await processes.start(sessionID: processSession(run), command: command.executable,
                                               arguments: command.arguments, cwd: cwd, maxProcesses: maxProcesses,
                                               environmentOverrides: environment, captureOutput: true)
        guard let id = result.asObject?["processId"]?.asString else { throw Failure.unavailable("Process failed to start.") }
        processIDs[run.id] = id
        if let pid = result.asObject?["pid"]?.asInt { try await change(run) { $0.processID = pid } }
        // A cancellation can arrive while the registry is starting the child.
        if Task.isCancelled { _ = try? await processes.stop(sessionID: processSession(run), processID: id); throw CancellationError() }
        return id
    }

    private func commandRun(_ command: LaunchCommand, run: LaunchRun, cwd: String, environment: [String: String], timeoutMs: Int, maxProcesses: Int) async throws -> String {
        let process = try await startProcess(command, run: run, cwd: cwd, environment: environment, maxProcesses: maxProcesses)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let prefix = sessions[key(run.configuration.agentID, run.configuration.sessionID)]?.runs.first(where: { $0.id == run.id })?.logs ?? ""
        while true {
            try Task.checkCancellation()
            let status = try await processes.status(sessionID: processSession(run), processID: process)
            let output = await processes.output(sessionID: processSession(run), processID: process)
            try await change(run) { $0.logs = String((prefix + output).suffix(256 * 1024)) }
            if status.asObject?["running"]?.asBool == false {
                // Drain the last pipe callbacks before returning the output.
                try await Task.sleep(for: .milliseconds(50))
                let final = await processes.output(sessionID: processSession(run), processID: process)
                try await change(run) { $0.logs = String((prefix + final).suffix(256 * 1024)) }
                guard status.asObject?["exitCode"]?.asInt == 0 else { throw Failure.unavailable("Command failed (exit \(status.asObject?["exitCode"]?.asInt ?? -1)): \(command.executable)") }
                await processes.cleanup(sessionID: processSession(run))
                processIDs[run.id] = nil
                return final
            }
            guard Date() < deadline else { throw Failure.unavailable("Build command timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func monitor(_ process: String, run: LaunchRun) async throws {
        let prefix = sessions[key(run.configuration.agentID, run.configuration.sessionID)]?.runs.first(where: { $0.id == run.id })?.logs ?? ""
        while true {
            try Task.checkCancellation()
            let status = try await processes.status(sessionID: processSession(run), processID: process)
            let output = await processes.output(sessionID: processSession(run), processID: process)
            try await change(run) { $0.logs = String((prefix + output).suffix(256 * 1024)) }
            if status.asObject?["running"]?.asBool == false {
                guard status.asObject?["exitCode"]?.asInt == 0 else { throw Failure.unavailable("Application process exited with an error.") }
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    func stop(agentID: String, sessionID: String, runID: String) async throws -> LaunchSessionState {
        let state = try await state(agentID: agentID, sessionID: sessionID)
        guard let run = state.runs.first(where: { $0.id == runID }) else { throw Failure.notFound }
        guard run.status.isActive else { return state }
        jobs[runID]?.cancel()
        if let process = processIDs[runID] { _ = try? await processes.stop(sessionID: processSession(run), processID: process) }
        if let job = jobs[runID] { await job.value }
        await terminateNativeApplication(run)
        await processes.cleanup(sessionID: processSession(run))
        try await change(run) { $0.status = .stopped; $0.finishedAt = Date() }
        return try await self.state(agentID: agentID, sessionID: sessionID)
    }

    private func terminateNativeApplication(_ run: LaunchRun) async {
        guard let current = sessions[key(run.configuration.agentID, run.configuration.sessionID)]?.runs.first(where: { $0.id == run.id }) else { return }
#if canImport(AppKit)
        guard current.launchSucceeded || nativeApplications[run.id] != nil || simulatorLaunchAttempts.contains(run.id) else { return }
#else
        guard current.launchSucceeded || simulatorLaunchAttempts.contains(run.id) else { return }
#endif
#if canImport(AppKit)
        if current.configuration.request.platform == .macOS, let application = nativeApplications[run.id] {
            // Keep the specific NSRunningApplication object, rather than assuming a persisted PID is owned.
            application.terminate()
            for _ in 0..<20 {
                if application.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !application.isTerminated { application.forceTerminate() }
            for _ in 0..<10 {
                if application.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if application.isTerminated { nativeApplications[run.id] = nil }
        }
#endif
#if os(macOS)
        if current.configuration.request.platform == .iOSSimulator,
           let device = current.configuration.request.simulatorID, let bundle = current.configuration.request.bundleID {
            _ = try? await runForegroundProcess(command: "/usr/bin/xcrun", arguments: ["simctl", "terminate", device, bundle], cwd: nil, timeoutMs: 5_000, maxOutputBytes: 4096)
        }
#endif
    }

    func shutdown() async {
        let active = sessions.values.flatMap(\.runs).filter { $0.status.isActive }
        for run in active { _ = try? await stop(agentID: run.configuration.agentID, sessionID: run.configuration.sessionID, runID: run.id) }
    }

    func previewPort(agentID: String, sessionID: String, runID: String) async throws -> Int {
        let state = try await state(agentID: agentID, sessionID: sessionID)
        guard let run = state.runs.first(where: { $0.id == runID }), run.status == .running,
              run.configuration.request.platform == .web, let port = run.configuration.request.webPort else { throw Failure.notFound }
        return port
    }
}
