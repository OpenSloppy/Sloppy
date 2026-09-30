import Foundation
import Protocols

protocol LaunchToolService: Sendable {
    func configureLaunch(agentID: String, sessionID: String, request: LaunchConfigurationRequest) async throws -> LaunchSessionState
}

extension CoreService: LaunchToolService {
    func launchContext(agentID: String, sessionID: String) async throws -> ToolContext {
        let detail = try getAgentSession(agentID: agentID, sessionID: sessionID)
        let scope = await toolContextForSession(sessionID: detail.summary.id, sessionTitle: detail.summary.title,
                                               projectID: detail.summary.projectId, taskID: detail.summary.taskId)
        var policy = try await getAgentToolsPolicy(agentID: agentID)
        policy.guardrails.allowedExecRoots += scope.extraRoots
        return toolExecution.makeContext(agentID: detail.summary.agentId, sessionID: detail.summary.id,
                                         policy: policy, currentProjectID: detail.summary.projectId,
                                         currentDirectoryURL: scope.workingDirectory.map { URL(fileURLWithPath: $0) },
                                         environmentOverrides: await toolExecution.sessionEnvironmentOverrides(sessionID))
    }

    func validatedLaunchRequest(_ input: LaunchConfigurationRequest, context: ToolContext) throws -> LaunchConfigurationRequest {
        var request = input
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let root = context.resolveExecCwd(request.checkoutPath) else { throw LaunchRunService.Failure.invalid("Choose an allowed checkout directory and a named target.") }
        request.checkoutPath = root.resolvingSymlinksInPath().path
        guard !request.workingDirectory.hasPrefix("/") else { throw LaunchRunService.Failure.invalid("Working directory must be relative to the checkout.") }
        let cwd = root.appendingPathComponent(request.workingDirectory).resolvingSymlinksInPath().path
        guard cwd == request.checkoutPath || cwd.hasPrefix(request.checkoutPath + "/") else { throw LaunchRunService.Failure.invalid("Working directory escapes the checkout.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw LaunchRunService.Failure.unavailable("Worktree is missing: \(cwd)") }
        for command in request.build + (request.launch.map { [$0] } ?? []) {
            guard isCommandAllowed(command.executable, deniedPrefixes: context.policy.guardrails.deniedCommandPrefixes),
                  !command.executable.contains("\0"), !command.arguments.contains(where: { $0.contains("\0") }) else { throw LaunchRunService.Failure.invalid("A launch command is blocked by the runtime policy.") }
        }
        switch request.platform {
        case .web:
            guard request.launch != nil, let port = request.webPort, (1...65535).contains(port) else { throw LaunchRunService.Failure.invalid("Web launch requires a command and loopback port.") }
            let path = request.webPath ?? "/"
            guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\r"), !path.contains("\n") else { throw LaunchRunService.Failure.invalid("Invalid web preview path.") }
        case .macOS, .iOSSimulator:
            guard !request.build.isEmpty else { throw LaunchRunService.Failure.invalid("Add a build command so Play rebuilds the current checkout before opening the application.") }
            guard let appPath = request.appPath, !appPath.hasPrefix("/"),
                  root.appendingPathComponent(appPath).resolvingSymlinksInPath().path.hasPrefix(request.checkoutPath + "/"),
                  appPath.hasSuffix(".app") else { throw LaunchRunService.Failure.invalid("Application path must point to an .app inside the checkout.") }
            if request.platform == .iOSSimulator {
                guard let bundle = request.bundleID, !bundle.isEmpty else { throw LaunchRunService.Failure.invalid("Simulator launch requires a bundle ID.") }
            }
        }
        return request
    }

    func launchState(agentID: String, sessionID: String) async throws -> LaunchSessionState {
        let detail = try getAgentSession(agentID: agentID, sessionID: sessionID)
        return try await launches.state(agentID: detail.summary.agentId, sessionID: detail.summary.id)
    }

    func configureLaunch(agentID: String, sessionID: String, request: LaunchConfigurationRequest) async throws -> LaunchSessionState {
        let context = try await launchContext(agentID: agentID, sessionID: sessionID)
        let request = try validatedLaunchRequest(request, context: context)
        let state = try await launches.state(agentID: context.agentID, sessionID: context.sessionID)
        let id: String
        if let requested = request.id {
            guard state.configurations.contains(where: { $0.id == requested }) else { throw LaunchRunService.Failure.notFound }
            id = requested
        } else if let existing = state.configurations.first(where: {
            $0.request.checkoutPath == request.checkoutPath && $0.request.workingDirectory == request.workingDirectory
                && $0.request.target == request.target && $0.request.platform == request.platform
        }) { id = existing.id }
        else { id = UUID().uuidString.lowercased() }
        var evidence: [LaunchVerificationEvidence] = []
        if let ids = request.verificationEvidenceIDs, !ids.isEmpty {
            let detail = try getAgentSession(agentID: context.agentID, sessionID: context.sessionID)
            let currentTurn = detail.events.reversed().prefix { $0.message?.role != .user }
            let records = currentTurn.compactMap { event -> JSONValue? in
                guard event.toolResult?.ok == true else { return nil }
                return event.toolResult?.data?.asObject?["verificationEvidence"]
            }
            for id in ids {
                guard let record = records.first(where: { $0.asObject?["id"]?.asString == id }) else {
                    throw LaunchRunService.Failure.invalid("Verification evidence is not from a successful check in this turn: \(id)")
                }
                evidence.append(try JSONDecoder().decode(LaunchVerificationEvidence.self, from: JSONEncoder().encode(record)))
            }
        }
        let configuration = LaunchConfiguration(id: id, agentID: context.agentID, sessionID: context.sessionID,
                                                projectID: context.currentProjectID, hostName: ProcessInfo.processInfo.hostName,
                                                request: request, updatedAt: Date(), verificationEvidence: evidence)
        return try await launches.configure(configuration)
    }

    func selectLaunch(agentID: String, sessionID: String, request: LaunchSelectionRequest) async throws -> LaunchSessionState {
        _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
        if let simulatorID = request.simulatorID {
            guard try await launchSimulators(agentID: agentID, sessionID: sessionID).contains(where: { $0.id == simulatorID }) else { throw LaunchRunService.Failure.invalid("Simulator is not available on this host.") }
        }
        return try await launches.select(agentID: agentID, sessionID: sessionID, request: request)
    }

    func startLaunch(agentID: String, sessionID: String, configurationID: String) async throws -> LaunchRun {
        let context = try await launchContext(agentID: agentID, sessionID: sessionID)
        let state = try await launches.state(agentID: context.agentID, sessionID: context.sessionID)
        guard var configuration = state.configurations.first(where: { $0.id == configurationID }) else { throw LaunchRunService.Failure.notFound }
        configuration.request = try validatedLaunchRequest(configuration.request, context: context)
#if !os(macOS)
        guard configuration.request.platform == .web else { throw LaunchRunService.Failure.unavailable("Apple applications require a Mac execution host.") }
#endif
        if configuration.request.platform == .iOSSimulator {
            guard let id = configuration.request.simulatorID,
                  try await launchSimulators(agentID: agentID, sessionID: sessionID).contains(where: { $0.id == id }) else {
                throw LaunchRunService.Failure.invalid("Choose an available Simulator on the execution host.")
            }
        }
        return try await launches.start(configuration: configuration, environment: context.environmentOverrides,
                                        timeoutMs: context.policy.guardrails.maxExecTimeoutMs,
                                        maxProcesses: context.policy.guardrails.maxProcessesPerSession)
    }

    func stopLaunch(agentID: String, sessionID: String, runID: String) async throws -> LaunchSessionState {
        _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
        return try await launches.stop(agentID: agentID, sessionID: sessionID, runID: runID)
    }

    func removeLaunch(agentID: String, sessionID: String, configurationID: String) async throws -> LaunchSessionState {
        _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
        return try await launches.remove(agentID: agentID, sessionID: sessionID, configurationID: configurationID)
    }

    func archiveLaunch(agentID: String, sessionID: String, isArchived: Bool) async throws -> LaunchSessionState {
        _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
        return try await launches.archive(agentID: agentID, sessionID: sessionID, isArchived: isArchived)
    }

    func launchSimulators(agentID: String, sessionID: String) async throws -> [LaunchSimulator] {
        _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
#if os(macOS)
        let result = try await runForegroundProcess(command: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "available", "--json"], cwd: nil, timeoutMs: 15_000, maxOutputBytes: 256 * 1024)
        guard result.asObject?["exitCode"]?.asInt == 0, let output = result.asObject?["stdout"]?.asString,
              let data = output.data(using: .utf8) else { throw LaunchRunService.Failure.unavailable("Cannot list Simulators on this host.") }
        struct Device: Decodable { var udid: String; var name: String; var state: String }
        struct Devices: Decodable { var devices: [String: [Device]] }
        return try JSONDecoder().decode(Devices.self, from: data).devices.filter { $0.key.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") }.values.flatMap { $0 }.map {
            LaunchSimulator(id: $0.udid, name: $0.name, state: $0.state)
        }.sorted { $0.name < $1.name }
#else
        throw LaunchRunService.Failure.unavailable("iOS Simulator requires a Mac execution host.")
#endif
    }
}
