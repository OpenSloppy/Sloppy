import ArgumentParser
import Configuration
import Foundation
import Logging
import Protocols
import SloppyNodeCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the Sloppy server."
    )

    static let dashboardPort = 25102

    @Option(name: [.short, .long], help: "Path to JSON config file")
    var configPath: String?

    @Flag(name: .customLong("gui"), inversion: .prefixedNo, help: "Start the bundled dashboard UI alongside the Core API")
    var gui: Bool?

    @Flag(name: .customLong("dashboard"), inversion: .prefixedNo, help: "Alias for --gui / --no-gui")
    var dashboard: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Overrides config and controls the immediate visor bulletin after boot")
    var bootstrapBulletin: Bool?

    @Option(name: .customLong("generate-openapi"), help: "Generate OpenAPI (Swagger) specification and save to the provided path")
    var openapiPath: String?

    @Option(name: .customLong("relay-public-url"), help: "Public HTTPS/WSS URL advertised for the node mesh relay.")
    var relayPublicURL: String?

    @Flag(name: .customLong("relay-only"), help: "Start as a foreground mesh relay/coordinator without the bundled dashboard.")
    var relayOnly: Bool = false

    mutating func run() async throws {
        var runtimeLogger: Logger?

        do {
            let homeDirectory = CoreConfig.resolvedHomeDirectoryPath()
            var explicitConfigPath = normalizedServerConfigPath(configPath)
            var config: CoreConfig

            if #available(macOS 15.0, *) {
                let envConfig = ConfigReader(providers: [EnvironmentVariablesProvider()])
                if let envConfigPath = normalizedServerConfigPath(
                    envConfig.string(forKey: "core.config.path", default: "")
                ) {
                    explicitConfigPath = envConfigPath
                }

                config = try loadServerConfigRecovering(from: explicitConfigPath, currentDirectory: homeDirectory)
                applyServerEnvironmentOverrides(
                    config: &config,
                    envConfig: envConfig,
                    environment: ProcessInfo.processInfo.environment
                )

                if explicitConfigPath == nil {
                    let workspaceConfigPath = CoreConfig.defaultConfigPath(
                        for: config.workspace,
                        currentDirectory: homeDirectory
                    )
                    if CoreConfigFileStore.hasConfigOrBackup(at: workspaceConfigPath) {
                        config = try loadServerConfigRecovering(from: workspaceConfigPath, currentDirectory: homeDirectory)
                        applyServerEnvironmentOverrides(
                            config: &config,
                            envConfig: envConfig,
                            environment: ProcessInfo.processInfo.environment
                        )
                    }
                }
            } else if explicitConfigPath == nil {
                config = try loadServerConfigRecovering(from: explicitConfigPath, currentDirectory: homeDirectory)
                let workspaceConfigPath = CoreConfig.defaultConfigPath(
                    for: config.workspace,
                    currentDirectory: homeDirectory
                )
                if CoreConfigFileStore.hasConfigOrBackup(at: workspaceConfigPath) {
                    config = try loadServerConfigRecovering(from: workspaceConfigPath, currentDirectory: homeDirectory)
                }
            } else {
                config = try loadServerConfigRecovering(from: explicitConfigPath, currentDirectory: homeDirectory)
            }
            applyCoffeeModeEnvironmentOverrides(config: &config)
            try applyRelayStartupOptions(
                config: &config,
                relayPublicURL: relayPublicURL,
                relayOnly: relayOnly
            )

            let workspaceRoot = try prepareServerWorkspace(config: &config, currentDirectory: homeDirectory)
            let systemLogFileURL = defaultServerLogFileURL(in: workspaceRoot)
            await ServerLoggingBootstrapper.shared.bootstrapIfNeeded(logFileURL: systemLogFileURL)
            let logger = Logger.sloppy(label: "sloppy.core.main")
            runtimeLogger = logger
            await CoreObservability.shared.start(logger: logger)
            await ServerFatalSignalLogger.shared.installIfNeeded()
            logger.info("Workspace prepared at \(workspaceRoot.path)")
            logger.info("System logs are persisted at \(systemLogFileURL.path)")

            let resolvedConfigPath = explicitConfigPath ??
                workspaceRoot.appendingPathComponent(CoreConfig.defaultConfigFileName).path
            try ensureServerConfigFileExists(path: resolvedConfigPath, config: config, logger: logger)

            if let error = CorePersistenceFactory.prepareSQLiteDatabaseIfNeeded(config: config) {
                logger.warning("SQLite initialization failed at \(config.sqlitePath): \(error); runtime will use fallback persistence if needed")
            }

            let service = CoreService(config: config, configPath: resolvedConfigPath, currentDirectory: homeDirectory)
            let router = CoreRouter(service: service)
            let server = CoreHTTPServer(
                host: config.listen.host,
                port: config.listen.port,
                router: router,
                logger: logger
            )

            if let openapiPath = openapiPath {
                let data = try await router.generateOpenAPISpec()
                try data.write(to: URL(fileURLWithPath: openapiPath))
                logger.info("OpenAPI specification generated at \(openapiPath)")

                let docsPublicURL = serverRepoRootURL()
                    .appendingPathComponent("docs/public/swagger.json")
                try FileManager.default.createDirectory(
                    at: docsPublicURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: docsPublicURL, options: .atomic)
                logger.info("OpenAPI specification copied to \(docsPublicURL.path)")
                return
            }

            let coffeeModeHandle = CoffeeModeController(logger: logger).start(config: config.coffeeMode)
            defer {
                coffeeModeHandle?.end()
            }

            if config.coffeeMode.privilegedLidModeRequired {
                do {
                    let status = try CoffeeSystemService().status(
                        config: config.coffeeMode,
                        workspaceRoot: workspaceRoot
                    )
                    if !status.privilegedLidModeActive {
                        logger.warning("Coffee Mode privileged lid mode is required but not active. Run `sudo sloppy coffee apply --allow-unsupported-lid-mode --config-path \(resolvedConfigPath)` to enable the experimental system setting.")
                    }
                } catch {
                    logger.warning("Coffee Mode privileged lid mode status could not be inspected: \(String(describing: error))")
                }
            }

            logger.info("sloppy initialized")

            await service.bootstrapChannelPlugins()

            try server.start()
            logger.info("sloppy HTTP server listening on \(config.listen.host):\(config.listen.port)")

            let guiEnabled = shouldStartDashboard(guiOverride: gui, dashboardOverride: dashboard, relayOnly: relayOnly)
            let lanIPv4 = NetworkAddressResolver.resolvePrimaryLANIPv4()
            let endpoints = NetworkAddressResolver.makeDisplayEndpoints(
                bindHost: config.listen.host,
                apiPort: config.listen.port,
                dashboardPort: guiEnabled ? Self.dashboardPort : nil,
                lanIPv4: lanIPv4
            )

            var dashboardServer: DashboardHTTPServer?
            var dashboardURL: String?
            if guiEnabled {
                let launch = startDashboardServerIfAvailable(
                    config: config,
                    logger: logger,
                    apiBase: endpoints.dashboardAPIBase,
                    publicDashboardURL: endpoints.preferredDashboardURL,
                    overridePath: dashboardOverridePath()
                )
                dashboardServer = launch?.server
                dashboardURL = launch?.publicURL
            }

            printServerStartupBanner(config: config, endpoints: endpoints, dashboardURL: dashboardURL)

            if shouldBootstrapVisorBulletin(cliOverride: bootstrapBulletin, config: config) {
                let bulletin = await service.triggerVisorBulletin()
                logger.info("Visor bulletin generated: \(bulletin.headline)")
            }

            logger.info("sloppy foreground server mode is active")
            defer {
                try? dashboardServer?.shutdown()
                try? server.shutdown()
                Task { await service.shutdownChannelPlugins() }
            }
            try server.waitUntilClosed()
            await CoreObservability.shared.shutdown()
        } catch {
            await CoreObservability.shared.shutdown()
            if let runtimeLogger {
                runtimeLogger.critical("sloppy is exiting because of an unrecoverable error: \(String(describing: error))")
            } else {
                emitServerBootstrapWarning("sloppy is exiting because of an unrecoverable error: \(String(describing: error))")
            }
            throw error
        }
    }
}

// MARK: - Server helpers (previously file-level private in SloppyApp.swift)

func shouldStartDashboard(guiOverride: Bool?, dashboardOverride: Bool?) -> Bool {
    shouldStartDashboard(guiOverride: guiOverride, dashboardOverride: dashboardOverride, relayOnly: false)
}

func shouldStartDashboard(guiOverride: Bool?, dashboardOverride: Bool?, relayOnly: Bool) -> Bool {
    if let guiOverride {
        return guiOverride
    }
    if let dashboardOverride {
        return dashboardOverride
    }
    return !relayOnly
}

struct RelayStartupMetadata: Equatable, Sendable {
    var publicURL: String
    var publicWebSocketURL: String
}

func applyRelayStartupOptions(
    config: inout CoreConfig,
    relayPublicURL: String?,
    relayOnly: Bool
) throws {
    if let publicURL = normalizedServerConfigPath(relayPublicURL) {
        _ = try relayPublicWebSocketURL(from: publicURL)
        config.nodeMeshPublicURL = publicURL
    } else if relayOnly, let configuredURL = normalizedServerConfigPath(config.nodeMeshPublicURL) {
        _ = try relayPublicWebSocketURL(from: configuredURL)
        config.nodeMeshPublicURL = configuredURL
    }
}

func relayStartupMetadata(config: CoreConfig) -> RelayStartupMetadata? {
    guard let publicURL = normalizedServerConfigPath(config.nodeMeshPublicURL),
          let publicWebSocketURL = try? relayPublicWebSocketURL(from: publicURL)
    else {
        return nil
    }
    return RelayStartupMetadata(publicURL: publicURL, publicWebSocketURL: publicWebSocketURL)
}

private func relayPublicWebSocketURL(from publicURL: String) throws -> String {
    try NodeMeshClient.resolveRelayWebSocketURL(publicURL).absoluteString
}

func shouldBootstrapVisorBulletin(cliOverride: Bool?, config: CoreConfig) -> Bool {
    cliOverride ?? config.visor.bootstrapBulletin
}

func applyCoffeeModeEnvironmentOverrides(
    config: inout CoreConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment
) {
    if let enabled = parseCoffeeModeEnvironmentBool(environment["SLOPPY_COFFEE_MODE"]) {
        config.coffeeMode.enabled = enabled
    }
    if let preventDisplaySleep = parseCoffeeModeEnvironmentBool(environment["SLOPPY_COFFEE_PREVENT_DISPLAY_SLEEP"]) {
        config.coffeeMode.preventDisplaySleep = preventDisplaySleep
    }
    if let privilegedLidModeRequired = parseCoffeeModeEnvironmentBool(environment["SLOPPY_COFFEE_REQUIRE_PRIVILEGED_LID_MODE"]) {
        config.coffeeMode.privilegedLidModeRequired = privilegedLidModeRequired
    }
}

private func parseCoffeeModeEnvironmentBool(_ rawValue: String?) -> Bool? {
    guard let rawValue else { return nil }
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return nil
    }
}

@available(macOS 15.0, *)
func applyServerEnvironmentOverrides(
    config: inout CoreConfig,
    envConfig: ConfigReader,
    environment: [String: String] = ProcessInfo.processInfo.environment
) {
    config.listen.host = envConfig.string(forKey: "core.listen.host", default: config.listen.host)
    config.listen.port = envConfig.int(forKey: "core.listen.port", default: config.listen.port)
    config.workspace.name = envConfig.string(forKey: "core.workspace.name", default: config.workspace.name)
    let workspaceBasePath = envConfig.string(
        forKey: "core.workspace.base_path",
        default: config.workspace.basePath
    )
    config.workspace.basePath = envConfig.string(
        forKey: "core.workspace.basePath",
        default: workspaceBasePath
    )
    let explicitAuthToken = envConfig
        .string(forKey: "core.auth.token", default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let sloppyToken = environment["SLOPPY_TOKEN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !explicitAuthToken.isEmpty {
        config.auth.token = explicitAuthToken
    } else if !sloppyToken.isEmpty {
        config.auth.token = sloppyToken
    }

    let explicitDashboardAuthToken = envConfig
        .string(forKey: "core.ui.dashboard_auth.token", default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let explicitDashboardAuthTokenCamel = envConfig
        .string(forKey: "core.ui.dashboardAuth.token", default: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let dashboardAuthTokenOverride = !explicitDashboardAuthToken.isEmpty
        ? explicitDashboardAuthToken
        : explicitDashboardAuthTokenCamel
    if !dashboardAuthTokenOverride.isEmpty {
        config.ui.dashboardAuth.token = dashboardAuthTokenOverride
    } else if config.ui.dashboardAuth.enabled,
              config.ui.dashboardAuth.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sloppyToken.isEmpty {
        config.ui.dashboardAuth.token = sloppyToken
    }
    let publicURLOverride = [
        environment["SLOPPY_NODE_MESH_PUBLIC_URL"],
        envConfig.string(forKey: "core.node_mesh.public_url", default: ""),
        envConfig.string(forKey: "core.nodeMesh.publicURL", default: ""),
    ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    if let publicURLOverride {
        config.nodeMeshPublicURL = publicURLOverride
    }
    let clientPublicURLOverride = [
        environment["SLOPPY_CLIENT_PUBLIC_URL"],
        envConfig.string(forKey: "core.client.public_url", default: ""),
        envConfig.string(forKey: "core.clientPublicURL", default: ""),
    ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    if let clientPublicURLOverride {
        config.clientPublicURL = clientPublicURLOverride
    }
    if let fingerprint = environment["SLOPPY_CLIENT_TLS_FINGERPRINT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty {
        config.clientTLSFingerprint = fingerprint
    }
    config.sqlitePath = envConfig.string(forKey: "core.sqlite.path", default: config.sqlitePath)
}

func dashboardOverridePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    normalizedServerConfigPath(
        environment["CORE_DASHBOARD_PATH"]
            ?? environment["SLOPPY_DASHBOARD_PATH"]
            ?? environment["core.dashboard.path"]
    )
}

func serverRepoRootURL(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

struct DashboardSearchAttempt: Equatable, Sendable {
    let source: String
    let checkedPath: String
}

struct DashboardBundleLocation: Equatable, Sendable {
    let source: String
    let supportRootURL: URL
    let distRootURL: URL
    let templateConfigURL: URL?
}

struct DashboardBundleResolution: Equatable, Sendable {
    let location: DashboardBundleLocation?
    let attempts: [DashboardSearchAttempt]
}

func defaultInstalledDashboardRootURL(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectoryURL
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("sloppy", isDirectory: true)
        .appendingPathComponent("dashboard", isDirectory: true)
}

func currentExecutableURL() -> URL? {
#if os(Linux)
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = readlink("/proc/self/exe", &buffer, buffer.count - 1)
    guard length > 0 else {
        return nil
    }
    buffer[Int(length)] = 0
    return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
#else
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        return nil
    }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL
#endif
}

func repoRootDerivedFromExecutable(
    executableURL: URL,
    fileManager: FileManager = .default
) -> URL? {
    var candidatePath = executableURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .deletingLastPathComponent()
        .path

    while true {
        let packagePath = (candidatePath as NSString).appendingPathComponent("Package.swift")
        let dashboardPath = (candidatePath as NSString).appendingPathComponent("Dashboard")
        if fileManager.fileExists(atPath: packagePath),
           fileManager.fileExists(atPath: dashboardPath)
        {
            return URL(fileURLWithPath: candidatePath, isDirectory: true)
        }

        let parentPath = (candidatePath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, parentPath != candidatePath else {
            break
        }
        candidatePath = parentPath
    }

    return nil
}

func resolveDashboardBundle(
    overridePath: String?,
    executableURL: URL?,
    sourceRepoRootURL: URL = serverRepoRootURL(),
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
) -> DashboardBundleResolution {
    var attempts: [DashboardSearchAttempt] = []
    var seenRoots = Set<String>()

    func resolvedLocation(source: String, candidateRootURL: URL) -> DashboardBundleLocation? {
        let standardized = candidateRootURL.standardizedFileURL
        var variants: [(supportRootURL: URL, distRootURL: URL)] = []

        if standardized.lastPathComponent == "dist" {
            variants.append((
                supportRootURL: standardized.deletingLastPathComponent(),
                distRootURL: standardized
            ))
        }
        variants.append((
            supportRootURL: standardized,
            distRootURL: standardized.appendingPathComponent("dist", isDirectory: true)
        ))

        var seenVariants = Set<String>()
        for variant in variants {
            guard seenVariants.insert(variant.distRootURL.path).inserted else {
                continue
            }

            attempts.append(.init(source: source, checkedPath: variant.distRootURL.path))

            let indexURL = variant.distRootURL.appendingPathComponent("index.html")
            let assetsURL = variant.distRootURL.appendingPathComponent("assets", isDirectory: true)
            var isAssetsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: indexURL.path),
                  fileManager.fileExists(atPath: assetsURL.path, isDirectory: &isAssetsDirectory),
                  isAssetsDirectory.boolValue
            else {
                continue
            }

            let configURL = variant.supportRootURL.appendingPathComponent("config.json")
            let templateConfigURL = fileManager.fileExists(atPath: configURL.path) ? configURL : nil
            return DashboardBundleLocation(
                source: source,
                supportRootURL: variant.supportRootURL,
                distRootURL: variant.distRootURL,
                templateConfigURL: templateConfigURL
            )
        }

        return nil
    }

    let candidates: [(String, URL?)] = [
        ("override", overridePath.map { URL(fileURLWithPath: $0, isDirectory: true) }),
        ("installed bundle", defaultInstalledDashboardRootURL(homeDirectoryURL: homeDirectoryURL)),
        ("executable checkout", executableURL.flatMap { repoRootDerivedFromExecutable(executableURL: $0, fileManager: fileManager) }?.appendingPathComponent("Dashboard", isDirectory: true)),
        ("source fallback", sourceRepoRootURL.appendingPathComponent("Dashboard", isDirectory: true))
    ]

    for (source, candidateURL) in candidates {
        guard let candidateURL else {
            continue
        }

        let key = "\(source)|\(candidateURL.standardizedFileURL.path)"
        guard seenRoots.insert(key).inserted else {
            continue
        }

        if let location = resolvedLocation(source: source, candidateRootURL: candidateURL) {
            return DashboardBundleResolution(location: location, attempts: attempts)
        }
    }

    return DashboardBundleResolution(location: nil, attempts: attempts)
}

func dashboardBundleSearchSummary(_ attempts: [DashboardSearchAttempt]) -> String {
    attempts.map { "\($0.source): \($0.checkedPath)" }.joined(separator: "; ")
}

func normalizedServerConfigPath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
}

func loadServerConfigRecovering(from path: String?, currentDirectory: String) throws -> CoreConfig {
    let resolvedPath = path ?? CoreConfig.defaultConfigPath(currentDirectory: currentDirectory)
    let result = try CoreConfigFileStore.loadRecovering(path: resolvedPath, currentDirectory: currentDirectory)
    if result.restoredFromBackup {
        emitServerBootstrapWarning(
            "Restored config at \(result.path) from backup \(result.backupPath)."
        )
    }
    return result.config
}

func ensureServerConfigFileExists(path: String, config: CoreConfig, logger: Logger) throws {
    let fileManager = FileManager.default
    let configURL = URL(fileURLWithPath: path)
    if fileManager.fileExists(atPath: configURL.path) { return }

    let parentDirectory = configURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = try encoder.encode(config) + Data("\n".utf8)
    try payload.write(to: configURL, options: .atomic)
    logger.info("Config initialized at \(configURL.path)")
}

func prepareServerWorkspace(config: inout CoreConfig, currentDirectory: String) throws -> URL {
    let workspaceRoot = config.resolvedWorkspaceRootURL(currentDirectory: currentDirectory)

    do {
        try createServerWorkspaceDirectories(at: workspaceRoot)
        try verifyWorkspaceWritable(at: workspaceRoot)
        config.sqlitePath = resolveServerSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: workspaceRoot)
        return workspaceRoot
    } catch {
        let fallbackBasePath = "/tmp/sloppy"
        let fallbackRoot = URL(fileURLWithPath: fallbackBasePath, isDirectory: true)
            .appendingPathComponent(config.workspace.name, isDirectory: true)

        emitServerBootstrapWarning(
            "Failed to create workspace at \(workspaceRoot.path), falling back to \(fallbackRoot.path): \(error)"
        )

        try createServerWorkspaceDirectories(at: fallbackRoot)
        config.workspace.basePath = fallbackBasePath
        config.sqlitePath = resolveServerSQLitePath(sqlitePath: config.sqlitePath, workspaceRoot: fallbackRoot)
        return fallbackRoot
    }
}

func createServerWorkspaceDirectories(at workspaceRoot: URL) throws {
    let fileManager = FileManager.default
    let directories = [
        workspaceRoot,
        workspaceRoot.appendingPathComponent("agents", isDirectory: true),
        workspaceRoot.appendingPathComponent("actors", isDirectory: true),
        workspaceRoot.appendingPathComponent("sessions", isDirectory: true),
        workspaceRoot.appendingPathComponent("memory", isDirectory: true),
        workspaceRoot.appendingPathComponent("logs", isDirectory: true),
        workspaceRoot.appendingPathComponent("tui", isDirectory: true),
        workspaceRoot.appendingPathComponent("tui", isDirectory: true).appendingPathComponent("themes", isDirectory: true),
        workspaceRoot.appendingPathComponent("worktrees", isDirectory: true),
        workspaceRoot.appendingPathComponent("plugins", isDirectory: true),
        workspaceRoot.appendingPathComponent("plugin-cache", isDirectory: true),
        workspaceRoot.appendingPathComponent("tmp", isDirectory: true)
    ]

    for directory in directories {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try SloppyTUIThemeStore(workspaceRoot: workspaceRoot, fileManager: fileManager).ensureSeedThemes()
}

func verifyWorkspaceWritable(at workspaceRoot: URL) throws {
    let probeURL = workspaceRoot.appendingPathComponent(".write_probe")
    try Data([0]).write(to: probeURL)
    try? FileManager.default.removeItem(at: probeURL)
}

func resolveServerSQLitePath(sqlitePath: String, workspaceRoot: URL) -> String {
    if sqlitePath.hasPrefix("/") { return sqlitePath }
    return workspaceRoot.appendingPathComponent(sqlitePath).path
}

func defaultServerLogFileURL(in workspaceRoot: URL, now: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let suffix = formatter.string(from: now)
    return workspaceRoot
        .appendingPathComponent("logs", isDirectory: true)
        .appendingPathComponent("core-\(suffix).log")
}

func emitServerBootstrapWarning(_ message: String) {
    let payload = "[warning] \(message)\n"
    payload.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }
}

private struct DashboardLaunch {
    let server: DashboardHTTPServer
    let publicURL: String
}

private func startDashboardServerIfAvailable(
    config: CoreConfig,
    logger: Logger,
    apiBase: String,
    publicDashboardURL: String?,
    overridePath: String?
) -> DashboardLaunch? {
    let resolution = resolveDashboardBundle(
        overridePath: overridePath,
        executableURL: currentExecutableURL()
    )

    guard let location = resolution.location else {
        logger.warning(
            "Dashboard UI is unavailable. Checked \(dashboardBundleSearchSummary(resolution.attempts)). Build/install it with `scripts/install.sh --bundle` or `scripts/dev.sh setup`, set CORE_DASHBOARD_PATH to a dashboard bundle, or rerun `sloppy run --no-gui`."
        )
        return nil
    }

    logger.info("Using dashboard bundle from \(location.source) at \(location.distRootURL.path)")
    let resolver = DashboardContentResolver(
        rootURL: location.distRootURL,
        templateConfigURL: location.templateConfigURL,
        apiBase: apiBase
    )
    let server = DashboardHTTPServer(
        host: config.listen.host,
        port: RunCommand.dashboardPort,
        responder: resolver,
        logger: logger
    )

    do {
        try server.start()
        logger.info("sloppy dashboard listening on \(config.listen.host):\(RunCommand.dashboardPort)")
        return publicDashboardURL.map { DashboardLaunch(server: server, publicURL: $0) }
    } catch {
        logger.warning(
            "Dashboard UI failed to start on \(config.listen.host):\(RunCommand.dashboardPort): \(String(describing: error)). Build it with `cd Dashboard && npm run build` if needed, or rerun `sloppy run --no-gui`."
        )
        try? server.shutdown()
        return nil
    }
}

func printServerStartupBanner(
    config: CoreConfig,
    endpoints: ServerDisplayEndpoints,
    dashboardURL: String?
) {
    let isColor: Bool = {
        if let term = ProcessInfo.processInfo.environment["TERM"], !term.isEmpty, term != "dumb" {
            return true
        }
        return ProcessInfo.processInfo.environment["COLORTERM"] != nil
            || ProcessInfo.processInfo.environment["FORCE_COLOR"] != nil
    }()

    let cyan  = isColor ? "\u{1B}[36m" : ""
    let green = isColor ? "\u{1B}[32m" : ""
    let dim   = isColor ? "\u{1B}[2m"  : ""
    let bold  = isColor ? "\u{1B}[1m"  : ""
    let reset = isColor ? "\u{1B}[0m"  : ""

    let authStatus = config.auth.token.isEmpty ? "none" : "ready"

    var rows: [(String, String)] = [
        ("Bind", endpoints.bindAddress),
    ]
    if let localAPIURL = endpoints.localAPIURL {
        rows.append(("Local API", localAPIURL))
    }
    if let lanAPIURL = endpoints.lanAPIURL {
        rows.append(("LAN API", lanAPIURL))
    }
    if let dashboardURL {
        rows.append(("Dashboard", dashboardURL))
    }
    if let relay = relayStartupMetadata(config: config) {
        rows.append(("Relay WS", relay.publicWebSocketURL))
    }
    rows.append(contentsOf: [
        ("Health", "\(endpoints.preferredAPIBase)/health"),
        ("Auth", authStatus),
        ("Memory", config.memory.backend),
        ("Workspace", config.workspace.name),
    ])

    var info = ""
    for (label, value) in rows {
        let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
        info += "\(dim)\(padded)\(reset)\(green)\(value)\(reset)\n"
    }

    let logo = sloppyRunLogoLines()
        .map { "\(cyan)\(bold)\($0)\(reset)" }
        .joined(separator: "\n")

    let banner = """

    \(logo)

    \(cyan)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\(reset)
    \(info)
    """

    let data = Array(banner.utf8)
    data.withUnsafeBufferPointer { buf in
        _ = write(STDERR_FILENO, buf.baseAddress, buf.count)
    }
}

private func sloppyRunLogoLines() -> [String] {
    [
        "███████╗██╗      ██████╗ ██████╗ ██████╗ ██╗   ██╗",
        "██╔════╝██║     ██╔═══██╗██╔══██╗██╔══██╗╚██╗ ██╔╝",
        "███████╗██║     ██║   ██║██████╔╝██████╔╝ ╚████╔╝ ",
        "╚════██║██║     ██║   ██║██╔═══╝ ██╔═══╝   ╚██╔╝  ",
        "███████║███████╗╚██████╔╝██║     ██║        ██║   ",
        "╚══════╝╚══════╝ ╚═════╝ ╚═╝     ╚═╝        ╚═╝   ",
    ]
}

private func signalNameForCode(_ code: Int32) -> String {
    switch code {
    case SIGABRT: return "SIGABRT"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGFPE: return "SIGFPE"
    default: return "UNKNOWN"
    }
}

private func coreFatalSignalHandler(_ signalCode: Int32) {
    let signalName = signalNameForCode(signalCode)
    let text = "sloppy fatal signal \(signalCode) (\(signalName)). Process will exit.\n"
    text.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }

    _ = signal(signalCode, SIG_DFL)
    _ = raise(signalCode)
}

actor ServerLoggingBootstrapper {
    static let shared = ServerLoggingBootstrapper()

    private var isBootstrapped = false

    func bootstrapIfNeeded(logFileURL: URL) {
        guard !isBootstrapped else { return }
        SystemJSONLLogHandler.configure(fileURL: logFileURL)
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                ColoredLogHandler.standardError(label: label),
                SystemJSONLLogHandler(label: label)
            ])
        }
        isBootstrapped = true
    }
}

actor ServerFatalSignalLogger {
    static let shared = ServerFatalSignalLogger()

    private var isInstalled = false
    private let trackedSignals: [Int32] = [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE]

    func installIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true
        for code in trackedSignals {
            _ = signal(code, coreFatalSignalHandler)
        }
    }
}
