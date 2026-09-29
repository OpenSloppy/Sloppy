import Foundation
import Testing
import SloppyClientCore
@testable import SloppyDesktopCompanion

@Suite("Companion follows local Sloppy desktop")
struct DesktopLocalSloppyConfigurationTests {
    @Test func usesDesktopDefaultsWithoutIndependentCompanionAddress() throws {
        let configuration = try DesktopLocalSloppyConfiguration(preferences: [
            "companion.core-address": "https://another-core.example"
        ])
        #expect(configuration.baseURL.absoluteString == "http://localhost:25101")
    }

    @Test func preservesDesktopHostPortAgentAndCertificatePin() throws {
        let local = SavedServer(label: "Local Sloppy", scheme: "https", host: "127.0.0.1",
                                port: 25112, tlsFingerprint: "desktop-certificate-pin")
        let configuration = try DesktopLocalSloppyConfiguration(preferences: [
            "client_server_host": local.host,
            "client_server_port": local.port,
            "client_server_scheme": local.scheme,
            "client_last_agent_id": "my-agent",
            "client_saved_servers": try JSONEncoder().encode([local])
        ])
        #expect(configuration.baseURL == local.baseURL)
        #expect(configuration.tlsFingerprint == local.tlsFingerprint)
        #expect(configuration.defaultAgentID == "my-agent")
    }

    @Test func selectsSavedLocalInstanceWhileDesktopUsesRemote() throws {
        let remote = SavedServer(label: "Remote", host: "core.example", port: 443)
        let local = SavedServer(label: "My Mac", host: "localhost", port: 25113)
        let configuration = try DesktopLocalSloppyConfiguration(preferences: [
            "client_server_host": remote.host,
            "client_server_port": remote.port,
            "client_saved_servers": try JSONEncoder().encode([local, remote])
        ])
        #expect(configuration.baseURL == local.baseURL)
        #expect(configuration.defaultAgentID == nil)
    }

    @Test func doesNotSilentlyConnectToAnotherCoreWhenLocalInstanceIsUnknown() {
        #expect(throws: DesktopLocalSloppyError.self) {
            try DesktopLocalSloppyConfiguration(preferences: ["client_server_host": "core.example"])
        }
        #expect(throws: DesktopLocalSloppyError.self) {
            try DesktopLocalSloppyConfiguration(preferences: ["client_server_host": "localhost", "client_server_port": -1])
        }
    }

    @Test func zeroPortUsesTheSameDefaultAsDesktop() throws {
        let configuration = try DesktopLocalSloppyConfiguration(preferences: ["client_server_port": 0])
        #expect(configuration.baseURL.absoluteString == "http://localhost:25101")
    }
}
