import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Service command group

/// Top-level `sloppy service` group.
///
/// Manages the Sloppy server as a persistent background service that starts
/// automatically on user login.
///
/// - On **macOS** a LaunchAgent plist is written to
///   `~/Library/LaunchAgents/com.sloppy.server.plist` and loaded via
///   `launchctl`. `KeepAlive` is enabled so the OS restarts the process if it
///   exits unexpectedly.
/// - On **Linux** a systemd user unit is written to
///   `~/.config/systemd/user/sloppy.service` and enabled via
///   `systemctl --user`. The unit targets `default.target` so it starts after
///   login.
///
/// Usage:
/// ```
/// sloppy service install            # register + start
/// sloppy service install --config-path /path/to/sloppy.json
/// sloppy service uninstall          # stop + remove
/// sloppy service start | stop | restart
/// sloppy service status             # show launchctl / systemctl output
/// sloppy service logs               # tail -f log (macOS) or journalctl (Linux)
/// ```
struct ServiceCommand: AsyncParsableCommand, SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage the Sloppy background service.",
        subcommands: [
            ServiceInstallCommand.self,
            ServiceUninstallCommand.self,
            ServiceStartCommand.self,
            ServiceStopCommand.self,
            ServiceRestartCommand.self,
            ServiceStatusCommand.self,
            ServiceLogsCommand.self,
        ]
    )
}

// MARK: - Platform helpers

/// Compile-time platform tag used to dispatch service management calls.
private enum ServicePlatform {
    case macOS
    case linux
    case unsupported(String)

    static var current: ServicePlatform {
#if os(macOS)
        return .macOS
#elseif os(Linux)
        return .linux
#else
        return .unsupported(ProcessInfo.processInfo.operatingSystemVersionString)
#endif
    }
}

/// Shared constants and helpers for interacting with the host service manager
/// (launchctl on macOS, systemctl on Linux).
enum ServiceManager {
    enum LinuxLingerResult: Equatable {
        case alreadyEnabled
        case enabledNow
        case requiresManualSetup
    }

    /// Reverse-DNS label used as the LaunchAgent label and systemd unit base name.
    static let label = "com.sloppy.server"

    // MARK: macOS

    static var launchAgentsPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var serviceLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sloppy/logs/service.log")
    }

    static let launchAgentFallbackPATHComponents = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func launchAgentPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var components: [String] = []
        var seen = Set<String>()

        let configuredPath = environment["PATH"] ?? ""
        for component in configuredPath.split(separator: ":").map(String.init) + launchAgentFallbackPATHComponents {
            let normalized = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            components.append(normalized)
        }

        return components.joined(separator: ":")
    }

    static func makePlist(
        executablePath: String,
        configPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let configArgs: String
        if let configPath {
            configArgs = """
                <string>--config-path</string>
                        <string>\(xmlEscaped(configPath))</string>
            """
        } else {
            configArgs = ""
        }
        let logPath = xmlEscaped(serviceLogURL.path)
        let launchAgentPath = xmlEscaped(launchAgentPATH(environment: environment))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(launchAgentPath)</string>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(executablePath))</string>
                <string>run</string>
                \(configArgs.isEmpty ? "" : configArgs.trimmingCharacters(in: .whitespacesAndNewlines))
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    static func macOSRestartCommands(plistPath: String) -> [[String]] {
        [
            ["launchctl", "unload", "-w", plistPath],
            ["launchctl", "load", "-w", plistPath],
        ]
    }

    static func startMacOS(
        plistPath: String,
        userID: UInt32 = getuid(),
        shellStatus: ([String]) -> Int32 = ServiceManager.shellStatus
    ) -> Int32 {
        let domain = "gui/\(userID)"
        let target = "\(domain)/\(label)"
        let status = shellStatus(["launchctl", "print", target])
        if status == 0 {
            return shellStatus(["launchctl", "kickstart", target])
        }
        guard status == 113 else { return status }
        return shellStatus(["launchctl", "bootstrap", domain, plistPath])
    }

    static func stopMacOS(
        userID: UInt32 = getuid(),
        shellStatus: ([String]) -> Int32 = ServiceManager.shellStatus,
        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
    ) -> Int32 {
        let target = "gui/\(userID)/\(label)"
        let status = shellStatus(["launchctl", "print", target])
        // launchctl returns 113 when the job is already unloaded.
        if status == 113 { return 0 }
        guard status == 0 else { return status }
        // Remove the job from this login session so KeepAlive cannot respawn it.
        // Leave it enabled for the next login.
        let stopStatus = shellStatus(["launchctl", "bootout", target])
        guard stopStatus == 0 || stopStatus == 113 else { return stopStatus }
        // bootout can return while the job is still SIGTERMed. Starting it in
        // that window can kickstart a job which launchd then removes anyway.
        for _ in 0..<100 {
            let status = shellStatus(["launchctl", "print", target])
            if status == 113 { return 0 }
            guard status == 0 else { return status }
            wait()
        }
        return 1
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: Linux

    static var systemdUserServiceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/systemd/user/sloppy.service")
    }

    static func makeSystemdUnit(executablePath: String, configPath: String?) -> String {
        let execArgs: String
        if let configPath {
            execArgs = "\(executablePath) run --config-path \(configPath)"
        } else {
            execArgs = "\(executablePath) run"
        }
        return """
        [Unit]
        Description=Sloppy AI Agent Runtime
        After=network.target

        [Service]
        ExecStart=\(execArgs)
        Restart=on-failure
        RestartSec=5
        StandardOutput=journal
        StandardError=journal

        [Install]
        WantedBy=default.target
        """
    }

    static func currentUsername(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let user = environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return user
        }

        let fallback = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    static func linuxLingerStatusCommand(username: String) -> [String] {
        ["loginctl", "show-user", username, "-p", "Linger"]
    }

    static func linuxEnableLingerCommand(username: String) -> [String] {
        ["loginctl", "enable-linger", username]
    }

    static func linuxLingerHint(username: String) -> String {
        "To keep sloppy running without an active login session, enable lingering once: sudo loginctl enable-linger \(username)"
    }

    static func isLinuxUserLingerEnabled(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "Linger=yes"
            }
    }

    static func ensureLinuxUserLinger(
        username: String,
        shell: ([String]) throws -> String = ServiceManager.shell,
        shellStatus: ([String]) -> Int32 = ServiceManager.shellStatus
    ) -> LinuxLingerResult {
        if let output = try? shell(linuxLingerStatusCommand(username: username)),
           isLinuxUserLingerEnabled(output) {
            return .alreadyEnabled
        }

        let status = shellStatus(linuxEnableLingerCommand(username: username))
        return status == 0 ? .enabledNow : .requiresManualSetup
    }

    // MARK: Shell helpers

    @discardableResult
    static func shell(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
    }

    static func shellStatus(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - install

/// Writes the platform service file and registers it with the host service
/// manager so the Sloppy server starts on user login and auto-restarts on
/// unexpected exits.
///
/// macOS: writes `~/Library/LaunchAgents/com.sloppy.server.plist` then calls
/// `launchctl load -w`.
/// Linux: writes `~/.config/systemd/user/sloppy.service`, ensures lingering is
/// enabled when possible so the user service survives logout, then calls
/// `systemctl --user enable --now`.
struct ServiceInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install and enable the Sloppy background service."
    )

    @Option(name: .long, help: "Path to sloppy.json config (defaults to ~/.sloppy/sloppy.json)")
    var configPath: String?

    mutating func run() async throws {
        let executablePath: String
        if let url = currentExecutableURL() {
            executablePath = url.path
        } else {
            CLIStyle.error("Cannot determine sloppy executable path.")
            throw ExitCode.failure
        }

        switch ServicePlatform.current {
        case .macOS:
            try installMacOS(executablePath: executablePath)
        case .linux:
            try installLinux(executablePath: executablePath)
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name). Service install is supported on macOS and Linux.")
            throw ExitCode.failure
        }
    }

    private func installMacOS(executablePath: String) throws {
        let plistURL = ServiceManager.launchAgentsPlistURL

        // Ensure log directory exists
        try FileManager.default.createDirectory(
            at: ServiceManager.serviceLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Unload existing agent if present
        if FileManager.default.fileExists(atPath: plistURL.path) {
            print(CLIStyle.dim("  Unloading existing agent…"))
            ServiceManager.shellStatus(["launchctl", "unload", "-w", plistURL.path])
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist = ServiceManager.makePlist(executablePath: executablePath, configPath: configPath)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        print(CLIStyle.dim("  Written: \(plistURL.path)"))

        let status = ServiceManager.shellStatus(["launchctl", "load", "-w", plistURL.path])
        guard status == 0 else {
            CLIStyle.error("launchctl load failed (exit \(status)). Check: launchctl list \(ServiceManager.label)")
            throw ExitCode.failure
        }

        CLIStyle.success("Sloppy service installed; startup requested.")
        print(CLIStyle.dim("  Plist:   \(plistURL.path)"))
        print(CLIStyle.dim("  Logs:    \(ServiceManager.serviceLogURL.path)"))
        print(CLIStyle.dim("  Ready:   sloppy status"))
        print(CLIStyle.dim("  Stop:    sloppy service stop"))
        print(CLIStyle.dim("  Remove:  sloppy service uninstall"))
    }

    private func installLinux(executablePath: String) throws {
        let serviceURL = ServiceManager.systemdUserServiceURL

        try FileManager.default.createDirectory(
            at: serviceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let unit = ServiceManager.makeSystemdUnit(executablePath: executablePath, configPath: configPath)
        try unit.write(to: serviceURL, atomically: true, encoding: .utf8)
        print(CLIStyle.dim("  Written: \(serviceURL.path)"))

        if let username = ServiceManager.currentUsername() {
            switch ServiceManager.ensureLinuxUserLinger(username: username) {
            case .alreadyEnabled:
                print(CLIStyle.dim("  Linger:  enabled for \(username)"))
            case .enabledNow:
                print(CLIStyle.dim("  Linger:  enabled for \(username)"))
            case .requiresManualSetup:
                print("\(CLIStyle.yellow("!")) User lingering is not enabled, so the service may stop after logout.")
                print(CLIStyle.dim("  Fix:     \(ServiceManager.linuxLingerHint(username: username))"))
            }
        }

        ServiceManager.shellStatus(["systemctl", "--user", "daemon-reload"])

        let enableStatus = ServiceManager.shellStatus(["systemctl", "--user", "enable", "--now", "sloppy.service"])
        guard enableStatus == 0 else {
            CLIStyle.error("systemctl enable failed (exit \(enableStatus)).")
            print(CLIStyle.dim("  Try: systemctl --user status sloppy.service"))
            throw ExitCode.failure
        }

        CLIStyle.success("Sloppy service installed and enabled.")
        print(CLIStyle.dim("  Unit:    \(serviceURL.path)"))
        print(CLIStyle.dim("  Logs:    journalctl --user -u sloppy.service -f"))
        print(CLIStyle.dim("  Stop:    sloppy service stop"))
        print(CLIStyle.dim("  Remove:  sloppy service uninstall"))
    }
}

// MARK: - uninstall

/// Unloads the service from the host service manager and removes the service
/// file. On macOS calls `launchctl unload -w` before deleting the plist; on
/// Linux calls `systemctl --user disable --now` before deleting the unit.
struct ServiceUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop and remove the Sloppy background service."
    )

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            try uninstallMacOS()
        case .linux:
            try uninstallLinux()
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }

    private func uninstallMacOS() throws {
        let plistURL = ServiceManager.launchAgentsPlistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            CLIStyle.error("Service is not installed (no plist at \(plistURL.path)).")
            throw ExitCode.failure
        }

        ServiceManager.shellStatus(["launchctl", "unload", "-w", plistURL.path])
        try FileManager.default.removeItem(at: plistURL)
        CLIStyle.success("Sloppy service removed.")
    }

    private func uninstallLinux() throws {
        let serviceURL = ServiceManager.systemdUserServiceURL
        guard FileManager.default.fileExists(atPath: serviceURL.path) else {
            CLIStyle.error("Service is not installed (no unit at \(serviceURL.path)).")
            throw ExitCode.failure
        }

        ServiceManager.shellStatus(["systemctl", "--user", "disable", "--now", "sloppy.service"])
        try FileManager.default.removeItem(at: serviceURL)
        ServiceManager.shellStatus(["systemctl", "--user", "daemon-reload"])
        CLIStyle.success("Sloppy service removed.")
    }
}

// MARK: - start

/// Starts the already-installed service immediately without waiting for the
/// next login. Loads or kickstarts the LaunchAgent (macOS), or calls
/// `systemctl --user start sloppy.service` (Linux).
///
/// The service must be installed first (`sloppy service install`).
struct ServiceStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the background service now."
    )

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            let plistURL = ServiceManager.launchAgentsPlistURL
            guard FileManager.default.fileExists(atPath: plistURL.path) else {
                CLIStyle.error("Service is not installed. Run: sloppy service install")
                throw ExitCode.failure
            }
            let status = ServiceManager.startMacOS(plistPath: plistURL.path)
            if status == 0 {
                CLIStyle.success("Sloppy service start requested. Check readiness: sloppy status")
            } else {
                CLIStyle.error("LaunchAgent start failed (exit \(status)). Check: sloppy service status")
                throw ExitCode.failure
            }
        case .linux:
            let status = ServiceManager.shellStatus(["systemctl", "--user", "start", "sloppy.service"])
            if status == 0 {
                CLIStyle.success("Sloppy service started.")
            } else {
                CLIStyle.error("systemctl start failed (exit \(status)). Is the service installed? Run: sloppy service install")
                throw ExitCode.failure
            }
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }
}

// MARK: - stop

/// Stops and unloads the running LaunchAgent. The service remains installed and will
/// start again on the next login (or when `sloppy service start` is called).
/// To prevent it from restarting at all, use `sloppy service uninstall`.
struct ServiceStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the background service."
    )

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            guard FileManager.default.fileExists(atPath: ServiceManager.launchAgentsPlistURL.path) else {
                CLIStyle.error("Service is not installed. Run: sloppy service install")
                throw ExitCode.failure
            }
            let status = ServiceManager.stopMacOS()
            if status == 0 {
                CLIStyle.success("Sloppy service stopped.")
            } else {
                CLIStyle.error("LaunchAgent stop failed (exit \(status)).")
                throw ExitCode.failure
            }
        case .linux:
            let status = ServiceManager.shellStatus(["systemctl", "--user", "stop", "sloppy.service"])
            if status == 0 {
                CLIStyle.success("Sloppy service stopped.")
            } else {
                CLIStyle.error("systemctl stop failed (exit \(status)).")
                throw ExitCode.failure
            }
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }
}

// MARK: - restart

/// Restarts the service. On macOS this reloads the LaunchAgent plist so
/// launchd refreshes the executable metadata before starting it again.
struct ServiceRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the background service."
    )

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            try restartMacOS()
        case .linux:
            let status = ServiceManager.shellStatus(["systemctl", "--user", "restart", "sloppy.service"])
            if status == 0 {
                CLIStyle.success("Sloppy service restarted.")
            } else {
                CLIStyle.error("systemctl restart failed (exit \(status)). Is the service installed? Run: sloppy service install")
                throw ExitCode.failure
            }
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }

    private func restartMacOS() throws {
        let plistURL = ServiceManager.launchAgentsPlistURL
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            CLIStyle.error("Service is not installed (no plist at \(plistURL.path)). Run: sloppy service install")
            throw ExitCode.failure
        }

        let commands = ServiceManager.macOSRestartCommands(plistPath: plistURL.path)
        _ = ServiceManager.shellStatus(commands[0])

        let status = ServiceManager.shellStatus(commands[1])
        guard status == 0 else {
            CLIStyle.error("launchctl load failed (exit \(status)). Check: sloppy service status")
            throw ExitCode.failure
        }

        CLIStyle.success("Sloppy service restart requested. Check readiness: sloppy status")
    }
}

// MARK: - status

/// Prints whether the service file is installed and forwards the raw output of
/// `launchctl list com.sloppy.server` (macOS) or
/// `systemctl --user status sloppy.service` (Linux) so you can see the current
/// PID, last exit code, and run state at a glance.
struct ServiceStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show background service status."
    )

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            printMacOSStatus()
        case .linux:
            printLinuxStatus()
        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }

    private func printMacOSStatus() {
        let plistURL = ServiceManager.launchAgentsPlistURL
        let installed = FileManager.default.fileExists(atPath: plistURL.path)

        print(CLIStyle.bold("Sloppy service (macOS LaunchAgent)"))
        print("  \(CLIStyle.dim("Label:"))     \(ServiceManager.label)")
        print("  \(CLIStyle.dim("Installed:")) \(installed ? CLIStyle.green("yes") : CLIStyle.red("no"))")
        if installed {
            print("  \(CLIStyle.dim("Plist:"))     \(plistURL.path)")
        }
        print("  \(CLIStyle.dim("Logs:"))      \(ServiceManager.serviceLogURL.path)")
        print("")

        let output = (try? ServiceManager.shell(["launchctl", "list", ServiceManager.label])) ?? ""
        if output.isEmpty || output.contains("Could not find") {
            print("  \(CLIStyle.dim("launchctl:")) \(CLIStyle.yellow("not loaded"))")
        } else {
            print("  \(CLIStyle.dim("launchctl list output:"))")
            for line in output.split(separator: "\n") {
                print("    \(CLIStyle.dim(String(line)))")
            }
        }
    }

    private func printLinuxStatus() {
        let serviceURL = ServiceManager.systemdUserServiceURL
        let installed = FileManager.default.fileExists(atPath: serviceURL.path)

        print(CLIStyle.bold("Sloppy service (systemd user unit)"))
        print("  \(CLIStyle.dim("Unit:"))      sloppy.service")
        print("  \(CLIStyle.dim("Installed:")) \(installed ? CLIStyle.green("yes") : CLIStyle.red("no"))")
        if installed {
            print("  \(CLIStyle.dim("File:"))      \(serviceURL.path)")
        }
        print("")

        let output = (try? ServiceManager.shell(["systemctl", "--user", "status", "sloppy.service"])) ?? ""
        if output.isEmpty {
            print("  \(CLIStyle.dim("systemctl:")) \(CLIStyle.yellow("not found"))")
        } else {
            for line in output.split(separator: "\n").prefix(12) {
                print("  \(CLIStyle.dim(String(line)))")
            }
        }
    }
}

// MARK: - logs

/// Follows the live service log. On macOS this tails
/// `~/.sloppy/logs/service.log` (the file the LaunchAgent writes stdout/stderr
/// to). On Linux it runs `journalctl --user -u sloppy.service -f`.
///
/// The command replaces the current process via `execvp` so that Ctrl-C
/// terminates `tail` / `journalctl` directly rather than leaving them
/// orphaned.
struct ServiceLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Tail the background service log."
    )

    @Option(name: [.short, .long], help: "Number of last lines to show before following")
    var lines: Int = 50

    mutating func run() async throws {
        switch ServicePlatform.current {
        case .macOS:
            let logPath = ServiceManager.serviceLogURL.path
            guard FileManager.default.fileExists(atPath: logPath) else {
                CLIStyle.error("No log file at \(logPath). Has the service been installed and run?")
                throw ExitCode.failure
            }
            // exec tail so signals (Ctrl-C) work naturally
            let args = ["tail", "-n", "\(lines)", "-f", logPath]
            var cargs = args.map { strdup($0) }
            cargs.append(nil)
            execvp("tail", &cargs)
            CLIStyle.error("Failed to exec tail.")
            throw ExitCode.failure

        case .linux:
            let args = ["journalctl", "--user", "-u", "sloppy.service", "-n", "\(lines)", "-f"]
            var cargs = args.map { strdup($0) }
            cargs.append(nil)
            execvp("journalctl", &cargs)
            CLIStyle.error("Failed to exec journalctl.")
            throw ExitCode.failure

        case .unsupported(let name):
            CLIStyle.error("Unsupported platform: \(name).")
            throw ExitCode.failure
        }
    }
}
