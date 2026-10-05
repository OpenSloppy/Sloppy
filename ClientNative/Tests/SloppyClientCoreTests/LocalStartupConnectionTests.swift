#if os(macOS)
import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Local desktop startup")
@MainActor
struct LocalStartupConnectionTests {
    @Test("A previously used remote server does not replace the local workspace")
    func remotePreferenceStartsLocalCore() async throws {
        let remote = try #require(URL(string: "https://relay.example:443"))
        let local = ServerAddress(host: "localhost").baseURL
        var attemptedURL: URL?

        let connectedURL = await LocalStartupConnection.connect(configuredURL: remote) { url in
            attemptedURL = url
            return .alreadyRunning
        }

        #expect(attemptedURL == local)
        #expect(connectedURL == local)
    }

    @Test("An explicitly configured local port and TLS address are retained")
    func retainsConfiguredLoopback() async throws {
        let local = try #require(URL(string: "https://127.0.0.1:25202"))
        var attemptedURL: URL?

        let connectedURL = await LocalStartupConnection.connect(configuredURL: local) { url in
            attemptedURL = url
            return .started(URL(fileURLWithPath: "/test/sloppy"))
        }

        #expect(attemptedURL == local)
        #expect(connectedURL == local)
    }

    @Test("An unavailable local backend does not open a connected workspace",
          arguments: [LocalBackendLauncher.Result.unavailable, .failed("Could not start")])
    func unavailableLocalBackend(result: LocalBackendLauncher.Result) async {
        let connectedURL = await LocalStartupConnection.connect(
            configuredURL: ServerAddress(host: "localhost").baseURL
        ) { _ in result }

        #expect(connectedURL == nil)
    }
}
#endif
