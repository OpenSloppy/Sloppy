import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SloppyClientCore

@Suite("Backend updates")
struct BackendUpdateTests {
    static func status(
        current: String = "2.2.0", latest: String? = "v2.3.0", available: Bool = true,
        kind: String = "release", commit: String? = nil
    ) throws -> BackendUpdateStatus {
        var object: [String: Any] = [
            "currentVersion": current, "updateAvailable": available,
            "isReleaseBuild": kind == "release", "deploymentKind": "local", "updateKind": kind,
        ]
        object["latestVersion"] = latest
        object["latestCommit"] = commit
        return try JSONDecoder().decode(BackendUpdateStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Uses backend availability, including source builds and unknown releases")
    func availability() throws {
        #expect(try Self.status(available: false).availableUpdate == nil)
        #expect(try Self.status(latest: nil).availableUpdate == nil)
        #expect(try Self.status().availableUpdate == "v2.3.0")
        #expect(try Self.status(latest: "2.3.0").releaseTag == "v2.3.0")
        let linked = try JSONDecoder().decode(BackendUpdateStatus.self, from: Data(#"{"currentVersion":"2.2.0","latestVersion":"2.3.0","updateAvailable":true,"isReleaseBuild":true,"releaseUrl":"https://github.com/TeamSloppy/Sloppy/releases/tag/2.3.0"}"#.utf8))
        #expect(linked.releaseTag == "2.3.0")
        #expect(try Self.status(latest: nil, kind: "git", commit: "1234567890abcdef").availableUpdate == "12345678")
    }

    @Test("Fetch and forced check use the existing authenticated backend API")
    func apiChecks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendUpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = SloppyAPIClient(
            baseURL: try #require(URL(string: "https://backend.test")), authToken: "backend-token",
            session: session, authSessionStore: AuthSessionStore(persistence: .memory)
        )
        #expect(try await api.fetchBackendUpdateStatus().currentVersion == "GET")
        #expect(try await api.fetchBackendUpdateStatus(force: true).currentVersion == "POST")
    }

    @Test("Checks the selected relay target rather than its coordinator")
    func relayCheck() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendUpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = SloppyAPIClient(
            endpoint: .relay(coordinatorBaseURL: try #require(URL(string: "https://backend.test")), targetNodeID: "home"),
            authToken: "backend-token", session: session, authSessionStore: AuthSessionStore(persistence: .memory)
        )
        #expect(try await api.fetchBackendUpdateStatus(force: true).currentVersion == "relay-target")
    }

    #if os(macOS)
    @Test("Installer resolves the offered release tag before touching the installation")
    func pinsInstallationToOfferedRelease() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendUpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let installer = BackendInstaller(session: session, installationRoot: root)
        do {
            _ = try await installer.install(releaseTag: "v2.3.0") { _ in }
            Issue.record("A release without backend assets must not be installed")
        } catch let error as BackendInstallerError {
            guard case .missingAsset = error else {
                Issue.record("Unexpected installation error: \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test("Restarts only the owned managed process and waits for it to exit")
    @MainActor
    func managedProcessRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let binary = BackendInstaller.installedExecutableURL(installationRoot: root)
        let pidFile = root.appending(path: "pid")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let launcher = LocalBackendLauncher(homeDirectory: root, environment: [:], managedInstallationRoot: root, healthProbe: { _, _ in
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return kill(pid, 0) == 0
        })
        defer {
            launcher.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try #require(URL(string: "http://localhost:25101"))
        guard case .started = await launcher.ensureRunning(at: url) else {
            Issue.record("Test backend did not start")
            return
        }
        let oldPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(launcher.ownsManagedBackend(at: url, processID: oldPID))
        let otherURL = try #require(URL(string: "http://localhost:25102"))
        #expect(!launcher.ownsManagedBackend(at: otherURL, processID: oldPID))
        #expect(!launcher.ownsManagedBackend(at: url, processID: oldPID + 1))
        try await launcher.restartManagedBackend(at: url, processID: oldPID)
        let newPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(newPID != oldPID)
        #expect(launcher.ownsManagedBackend(at: url, processID: newPID))
        #expect(!launcher.ownsManagedBackend(at: url, processID: oldPID))
    }
    #endif

    @Test("Reminder stays dismissed for one version and returns for a newer offer")
    @MainActor
    func dismissal() async throws {
        let source = UpdateFixture(try Self.status())
        let model = BackendUpdateModel(fetch: { _ in await source.read() }, eligibility: { _ in false }, install: { _, _ in })
        await model.check()
        #expect(model.reminderVersion == "v2.3.0")
        model.dismissReminder()
        await model.check(force: true)
        #expect(model.reminderVersion == nil)
        await source.set(try Self.status(latest: "v2.4.0"))
        await model.check()
        #expect(model.reminderVersion == "v2.4.0")
    }

    @Test("A failed check preserves the last known version and supports retry")
    @MainActor
    func retryAfterFailure() async throws {
        let source = UpdateFixture(try Self.status())
        let model = BackendUpdateModel(fetch: { _ in try await source.fetch() }, eligibility: { _ in false }, install: { _, _ in })
        await model.check()
        await source.fail(true)
        await model.check()
        #expect(model.errorMessage != nil)
        #expect(model.reminderVersion == "v2.3.0")
        #expect(!model.isChecking)
        await source.fail(false)
        await model.check()
        #expect(model.errorMessage == nil)
    }

    @Test("Update installs the offered tag and clears the old reminder")
    @MainActor
    func installsOfferedVersion() async throws {
        let source = UpdateFixture(try Self.status())
        var installed: String?
        let model = BackendUpdateModel(fetch: { _ in await source.read() }, eligibility: { _ in true }, install: { tag, progress in
            installed = tag
            progress("Restarting")
            await source.set(try Self.status(current: "2.3.0", available: false))
        })
        await model.check()
        await model.installUpdate()
        #expect(installed == "v2.3.0")
        #expect(model.reminderVersion == nil)
        #expect(!model.isInstalling)
        #expect(model.errorMessage == nil)
    }

    @Test("Losing process ownership prevents installing an unrelated backend")
    @MainActor
    func ownershipRechecked() async throws {
        let status = try Self.status()
        let fixture = InstallationFixture()
        let model = BackendUpdateModel(fetch: { _ in status }, eligibility: { _ in fixture.owned }, install: { _, _ in fixture.installed = true })
        await model.check()
        #expect(model.canInstall)
        fixture.owned = false
        await model.installUpdate()
        #expect(!fixture.installed)
        #expect(model.errorMessage != nil)
    }

    @Test("Installation failures keep the offer visible")
    @MainActor
    func installFailure() async throws {
        let status = try Self.status()
        let model = BackendUpdateModel(fetch: { _ in status }, eligibility: { _ in true }, install: { _, _ in
            throw BackendUpdateError.restartFailed
        })
        await model.check()
        await model.installUpdate()
        #expect(model.errorMessage != nil)
        #expect(!model.isInstalling)
        #expect(model.reminderVersion == "v2.3.0")
    }

    @Test("Polling stops when the view task is cancelled")
    @MainActor
    func pollingCancellation() async throws {
        let source = UpdateFixture(try Self.status())
        let model = BackendUpdateModel(fetch: { force in await source.recordCheck(force: force) }, eligibility: { _ in false }, install: { _, _ in })
        let task = Task { await model.monitor(interval: .seconds(3600)) }
        while await source.checkCount == 0 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(await source.checkCount == 1)
        #expect(await source.lastForce == true)
    }
}

@MainActor
private final class InstallationFixture {
    var owned = true
    var installed = false
}

private actor UpdateFixture {
    var value: BackendUpdateStatus
    var shouldFail = false
    var checkCount = 0
    var lastForce = false
    init(_ value: BackendUpdateStatus) { self.value = value }
    func read() -> BackendUpdateStatus { value }
    func set(_ value: BackendUpdateStatus) { self.value = value }
    func fail(_ fail: Bool) { shouldFail = fail }
    func fetch() throws -> BackendUpdateStatus {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return value
    }
    func recordCheck(force: Bool) -> BackendUpdateStatus {
        checkCount += 1
        lastForce = force
        return value
    }
}

private final class BackendUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try #require(request.url)
            if url.host == "api.github.com" {
                #expect(url.path == "/repos/TeamSloppy/Sloppy/releases/tags/v2.3.0")
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v2.3.0","assets":[]}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer backend-token")
            var version = request.httpMethod ?? ""
            let relay = url.path == "/v1/node/mesh/nodes/home/core"
            if relay {
                #expect(request.httpMethod == "POST")
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var body = Data()
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                    data = body
                }
                let requestBody = try #require(data)
                let object = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
                #expect(object["path"] as? String == "/v1/updates/check")
                #expect(object["method"] as? String == "POST")
                version = "relay-target"
            } else {
                #expect(url.path == "/v1/updates/check")
            }
            var body = try JSONSerialization.data(withJSONObject: [
                "currentVersion": version, "latestVersion": "v2.3.0", "updateAvailable": true,
                "isReleaseBuild": true, "deploymentKind": "local",
            ])
            if relay {
                body = try JSONSerialization.data(withJSONObject: ["status": 200, "contentType": "application/json", "bodyBase64": body.base64EncodedString()])
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
