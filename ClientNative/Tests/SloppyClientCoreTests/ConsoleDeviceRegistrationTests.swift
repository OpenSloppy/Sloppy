import Crypto
import Foundation
import SloppyRemoteProtocol
import Testing
@testable import SloppyClientCore

private actor DeviceRegistrationServer {
    var snapshot: ConsoleAccountClient.Snapshot
    var registrations = 0
    var recoveryRequests = 0
    var recoveryNeedsMFA = false
    var failNextRegistration: Bool

    init(devices: [ConsoleDevice] = [], account: ConsoleAccount, failNextRegistration: Bool = false) {
        snapshot = .init(account: account, organizations: [], devices: devices, instances: [], grants: [], proposals: [], entitlement: .init())
        self.failNextRegistration = failNextRegistration
    }

    func requireMFAForRecovery() { recoveryNeedsMFA = true }

    func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session")
        var status = 200
        let data: Data
        if request.url?.path == "/v1/me" {
            data = try ConsoleWire.encode(snapshot)
        } else if request.url?.path.hasSuffix("/request-access") == true {
            let device = try #require(snapshot.devices.first)
            #expect(request.url?.path == "/v1/devices/\(device.id)/request-access")
            #expect(request.httpMethod == "POST")
            recoveryRequests += 1
            if recoveryNeedsMFA {
                status = 403
                data = Data("{\"error\":\"identityVerificationRequired\"}".utf8)
            } else {
                snapshot.devices[0].status = .pending
                status = 202
                data = try ConsoleWire.encode(snapshot.devices[0])
            }
        } else {
            #expect(request.url?.path == "/v1/devices")
            #expect(request.httpMethod == "POST")
            registrations += 1
            if failNextRegistration {
                failNextRegistration = false
                status = 503
                data = Data()
            } else {
                var device = try ConsoleWire.decode(ConsoleDevice.self, from: #require(request.httpBody))
                if let previous = snapshot.devices.first(where: { $0.id == device.id }) { device.status = previous.status }
                snapshot.devices.removeAll { $0.id == device.id }
                snapshot.devices.append(device)
                status = 201
                data = try ConsoleWire.encode(device)
            }
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

@Suite("Console device registration")
struct ConsoleDeviceRegistrationTests {
    private func credential() throws -> ConsoleDeviceCredential {
        let key = Curve25519.Signing.PrivateKey(), id = UUID()
        return ConsoleDeviceCredential(deviceID: id, privateKey: key.rawRepresentation, tls: try RemoteTLSIdentity(signingPrivateKey: key.rawRepresentation, deviceID: id))
    }
    private let account = ConsoleAccount(issuer: "https://auth.test", subject: "test-user", email: "test@example.test", name: "Test")

    @Test("A saved login recovers failed enrollment on refresh without signing in again")
    func restoresMissingDeviceAfterFailure() async throws {
        let credential = try credential()
        let server = DeviceRegistrationServer(account: account, failNextRegistration: true)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        await #expect(throws: ConsoleAccountError.unavailable) { try await client.snapshot() }
        #expect(await client.isSignedIn())
        let snapshot = try await client.snapshot()
        let device = try #require(snapshot.devices.first)
        #expect(device.id == credential.deviceID)
        #expect(device.name == "Sloppy iOS")
        #expect(device.status == .pending)
        #expect(device.certificateDER == credential.tls.certificateDER)
        _ = try await client.snapshot()
        #expect(await server.registrations == 2)
    }

    @Test("Concurrent workspace loads share one enrollment")
    func coalescesWorkspaceLoads() async throws {
        let credential = try credential()
        let server = DeviceRegistrationServer(account: account)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        async let first = client.snapshot()
        async let second = client.snapshot()
        let values = try await [first, second]
        #expect(values.allSatisfy { $0.devices.count == 1 })
        #expect(await server.registrations == 1)
    }

    @Test("Generic names migrate while active status and credentials stay intact")
    func migratesGenericName() async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "Sloppy Client", signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER, status: .active)
        let server = DeviceRegistrationServer(devices: [device], account: account)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy macOS · Test Mac", credential: credential, transport: { try await server.respond($0) })
        let snapshot = try await client.snapshot()
        var expected = device; expected.name = "Sloppy macOS · Test Mac"
        #expect(snapshot.devices == [expected])
    }

    @Test("An unavailable name migration does not block an already registered device")
    func failedRenameKeepsWorkspaceAccessible() async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "Sloppy Client", signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER, status: .active)
        let server = DeviceRegistrationServer(devices: [device], account: account, failNextRegistration: true)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        #expect(try await client.snapshot().devices == [device])
        #expect(try await client.snapshot().devices.first?.name == "Sloppy iOS")
    }

    @Test("Custom names stay unchanged and revocation cannot trigger reenrollment", arguments: [ConsoleStatus.active, .revoked])
    func preservesCustomNameAndRevocation(status: ConsoleStatus) async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "My device", signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER, status: status)
        let server = DeviceRegistrationServer(devices: [device], account: account)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        #expect(try await client.snapshot().devices == [device])
        #expect(await client.isSignedIn())
        #expect(await server.registrations == 0)
    }

    @Test("Explicit recovery keeps the device identity and returns to pending approval")
    func requestsNewAccessAfterRevocation() async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "My device", signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER, status: .revoked)
        let server = DeviceRegistrationServer(devices: [device], account: account)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        #expect(try await client.snapshot().devices == [device])
        #expect(await server.recoveryRequests == 0)
        try await client.requestDeviceAccessAgain()
        var pending = device; pending.status = .pending
        #expect(try await client.snapshot().devices == [pending])
        #expect(await server.recoveryRequests == 1)
        #expect(await server.registrations == 0)
    }

    @Test("Recovery exposes MFA requirements without resetting identity or clearing the account")
    func recoveryRequiresVerification() async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "My device", signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER, status: .revoked)
        let server = DeviceRegistrationServer(devices: [device], account: account)
        await server.requireMFAForRecovery()
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        await #expect(throws: ConsoleAccountError.identityVerificationRequired) { try await client.requestDeviceAccessAgain() }
        #expect(try await client.snapshot().devices == [device])
        #expect(await client.isSignedIn())
        #expect(await server.registrations == 0)
    }

    @Test("Directory credentials cannot replace the local identity")
    func rejectsChangedCertificate() async throws {
        let credential = try credential()
        let device = ConsoleDevice(id: credential.deviceID, accountID: account.id, name: "Sloppy Client", signingPublicKey: credential.tls.signingPublicKey, certificateDER: Data([99]), status: .active)
        let server = DeviceRegistrationServer(devices: [device], account: account)
        let client = ConsoleAccountClient(token: "test-session", deviceName: "Sloppy iOS", credential: credential, transport: { try await server.respond($0) })
        await #expect(throws: ConsoleAccountError.accessDenied) { try await client.snapshot() }
        #expect(await server.registrations == 0)
    }

    @Test("Default names identify the client platform")
    func platformName() {
        #if os(iOS)
        #expect(ConsoleAccountClient.currentDeviceName == "Sloppy iOS")
        #elseif os(macOS)
        #expect(ConsoleAccountClient.currentDeviceName.hasPrefix("Sloppy macOS · "))
        #endif
    }
}
