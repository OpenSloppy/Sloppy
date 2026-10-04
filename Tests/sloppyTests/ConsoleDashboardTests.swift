import Foundation
import Crypto
import Testing
import SloppyConsoleProtocol
@testable import sloppy
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor DashboardCloudFixture {
    var paths: [String] = []
    var responseStatus = 200
    var responseBody = Data()
    let account = ConsoleAccount(issuer: "https://auth-test.sloppy.team/", subject: "dashboard-owner", email: "owner@example.invalid", name: "Owner")
    var device: ConsoleDevice?
    var proposal: AccessProposal?
    func configure(device: ConsoleDevice, proposal: AccessProposal) { self.device = device; self.proposal = proposal }
    func fail(_ status: Int, body: Data = Data()) { responseStatus = status; responseBody = body }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        #expect(request.url?.host == "console-test.sloppy.team")
        let path = request.url!.path; paths.append(path)
        if responseStatus != 200 { return (responseBody, responseStatus) }
        if path == "/v1/auth/device/start" {
            return (Data("{\"flowID\":\"private-flow\",\"userCode\":\"TEST-CODE\",\"verificationURL\":\"https://auth-test.sloppy.team/device/\",\"expiresIn\":600,\"interval\":5}".utf8),200)
        }
        if path == "/v1/auth/device/poll" || path == "/v1/auth/native/refresh" {
            return (Data("{\"accessToken\":\"private-access-token\",\"refreshToken\":\"private-refresh-token\",\"expiresIn\":3600}".utf8),200)
        }
        if path == "/v1/me" {
            struct Snapshot: Encodable { var account: ConsoleAccount; var devices: [ConsoleDevice] = []; var instances: [InstanceBinding] = []; var proposals: [AccessProposal] = [] }
            return (try ConsoleWire.encode(Snapshot(account:account, devices:device.map { [$0] } ?? [], proposals:proposal.map { [$0] } ?? [])),200)
        }
        return (Data("{}".utf8),200)
    }
}

private func dashboardSessionFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("console-dashboard-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    return directory.appendingPathComponent("session.json")
}

@Test func consoleDashboardLoginIsOwnerScopedAndNeverReturnsCredentials() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let cloud = DashboardCloudFixture()
    let transport: ConsoleDashboardController.Transport = { try await cloud.send($0) }
    let ownerController = try ConsoleDashboardController(file:file, transport:transport)
    let login = try await ownerController.start(owner:"owner-a",environment:.test)
    #expect(login.verificationURL.host == "auth-test.sloppy.team")
    #expect(URLComponents(url: login.verificationURL, resolvingAgainstBaseURL: false)?.path == "/if/flow/sloppy-login/")
    #expect(URLComponents(url: login.verificationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "next" }?.value == "https://auth-test.sloppy.team/device/")
    let serialized = String(decoding:try ConsoleWire.encode(login),as:UTF8.self)
    #expect(!serialized.contains("private-flow")); #expect(!serialized.contains("accessToken"))
    await #expect(throws: ConsoleDashboardError.self) { _ = try await ownerController.poll(id:login.id,owner:"owner-b",environment:.test) }
    #expect(try await ownerController.poll(id:login.id,owner:"owner-a",environment:.test))
    #expect(try await ownerController.account(owner:"owner-a",environment:.test).account.name == "Owner")
    await #expect(throws: ConsoleDashboardError.self) { _ = try await ownerController.account(owner:"owner-b",environment:.test) }
    await #expect(throws: ConsoleDashboardError.self) { _ = try await ownerController.poll(id:login.id,owner:"owner-a",environment:.test) }
    let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let restored = try ConsoleDashboardController(file:file, transport:transport)
    #expect(await restored.hasSession(owner:"owner-a",environment:.test))
    #expect(!(await restored.hasSession(owner:"owner-a",environment:.production)))
    try await restored.signOut(owner:"owner-a",environment:.test)
    #expect(!FileManager.default.fileExists(atPath:file.path))
    #expect(!(await restored.hasSession(owner:"owner-a",environment:.test)))
}

@Test(arguments: ["https://attacker.invalid/device/", "https://auth-test.sloppy.team:444/device/", "http://auth-test.sloppy.team/device/", "https://user:password@auth-test.sloppy.team/device/"])
func consoleDashboardRejectsVerificationRedirectOutsideTheSelectedIssuer(verificationURL: String) async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let controller = try ConsoleDashboardController(file:file,transport:{ _ in
        (Data("{\"flowID\":\"flow\",\"userCode\":\"CODE\",\"verificationURL\":\"\(verificationURL)\",\"expiresIn\":600,\"interval\":5}".utf8),200)
    })
    await #expect(throws:ConsoleDashboardError.self) { _ = try await controller.start(owner:"owner",environment:.test) }
}

@Test(arguments: [ConsoleEnvironment.test, .production])
func consoleDashboardFreshMFAReturnsToDeviceEntryInSelectedEnvironment(environment: ConsoleEnvironment) async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let host = environment == .test ? "auth-test.sloppy.team" : "auth.sloppy.team"
    let deviceURL = "https://\(host)/if/flow/sloppy-device-code/?code=TEST&source=dashboard"
    let controller = try ConsoleDashboardController(file: file, transport: { _ in
        (Data("{\"flowID\":\"flow\",\"userCode\":\"TEST\",\"verificationURL\":\"\(deviceURL)\",\"expiresIn\":600,\"interval\":5}".utf8), 200)
    })
    let login = try await controller.start(owner: "owner", environment: environment)
    let url = try #require(URLComponents(url: login.verificationURL, resolvingAgainstBaseURL: false))
    #expect(url.scheme == "https")
    #expect(url.host == host)
    #expect(url.path == "/if/flow/sloppy-login/")
    #expect(url.queryItems == [.init(name: "next", value: deviceURL)])
}

@Test func consoleDashboardEndpointsRequireLocalOwnerAndRejectExternalOrigins() async throws {
    let service = CoreService(config:CoreConfig.test)
    let router = CoreRouter(service:service)
    for (address,origin) in [("203.0.113.1", "http://localhost:25101"),("127.0.0.1", "https://attacker.invalid")] {
        let response = await router.handle(method:"GET",path:"/v1/console/account?environment=test",body:nil,headers:["origin":origin],remoteAddress:address)
        #expect(response.status == 403)
    }
    let response = await router.handle(method:"GET",path:"/v1/console/account?environment=attacker",body:nil,remoteAddress:"127.0.0.1")
    #expect(response.status == 403)
}

@Test func consoleBindingPersistsItsTestEndpointsAcrossRestart() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let store = try ConsoleInstanceTrustStore(url:file)
    let identity = await store.identity()
    let binding = InstanceBinding(id:identity.instanceID,ownerID:UUID(),spaceID:UUID(),name:"Test host",authorityPublicKey:identity.signingPublicKey,hostDeviceID:identity.deviceID,hostCertificateFingerprint:"certificate")
    let proposal = AccessProposal(kind:.bindInstance,actorAccountID:binding.ownerID,instanceID:binding.id,targetID:binding.id,version:1,expiresAt:Date().addingTimeInterval(300),payload:try ConsoleWire.encode(binding))
    let signed = try await store.sign(proposal)
    try await store.installBinding(signed,consolePublicKey:Data(repeating:7,count:32),environment:.test)
    let restarted = try ConsoleInstanceTrustStore(url:file)
    #expect(await restarted.environment() == .test)
    #expect(await restarted.environment().relayURL.host == "relay-test.sloppy.team")
    await #expect(throws:ConsoleTrustError.self) { try await restarted.installBinding(signed,consolePublicKey:Data(repeating:7,count:32),environment:.production) }
}

@Test func consoleDashboardExpiredCloudSessionDoesNotInvalidateLocalIdentity() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let cloud = DashboardCloudFixture()
    let controller = try ConsoleDashboardController(file:file,transport:{ try await cloud.send($0) })
    let login = try await controller.start(owner:"owner",environment:.test)
    #expect(try await controller.poll(id:login.id,owner:"owner",environment:.test))
    await cloud.fail(401)
    await #expect(throws:ConsoleDashboardError.self) { _ = try await controller.account(owner:"owner",environment:.test) }
    #expect(!(await controller.hasSession(owner:"owner",environment:.test)))
    #expect(ConsoleDashboardError.cloud(401).code == "console_sign_in_required")
}

@Test func consoleDashboardDistinguishesIdentityVerificationFromAccessDenial() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let cloud = DashboardCloudFixture()
    let controller = try ConsoleDashboardController(file: file, transport: { try await cloud.send($0) })
    let login = try await controller.start(owner: "owner", environment: .test)
    #expect(try await controller.poll(id: login.id, owner: "owner", environment: .test))
    for (body, expected) in [("{\"error\":\"identityVerificationRequired\"}", "console_identity_verification_required"), ("{\"error\":\"forbidden\"}", "console_access_denied"), ("upstream failure", "console_access_denied")] {
        await cloud.fail(403, body: Data(body.utf8))
        do {
            _ = try await controller.account(owner: "owner", environment: .test)
            Issue.record("Expected request failure")
        } catch let error as ConsoleDashboardError {
            #expect(error.code == expected)
        }
        #expect(await controller.hasSession(owner: "owner", environment: .test))
    }
}

@Test func consoleDashboardReusesPendingReviewAndRejectsKeySubstitution() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let cloud = DashboardCloudFixture()
    let controller = try ConsoleDashboardController(file:file,transport:{ try await cloud.send($0) })
    let login = try await controller.start(owner:"owner",environment:.test)
    #expect(try await controller.poll(id:login.id,owner:"owner",environment:.test))
    let account = await cloud.account, key = Curve25519.Signing.PrivateKey(), host = UUID()
    let device = ConsoleDevice(id:host,accountID:account.id,name:"Host",signingPublicKey:key.publicKey.rawRepresentation,certificateDER:Data([3]))
    let binding = InstanceBinding(ownerID:account.id,spaceID:account.personalSpaceID,name:"Host",authorityPublicKey:device.signingPublicKey,hostDeviceID:host,hostCertificateFingerprint:ConsoleTrust.fingerprint(device.certificateDER))
    let proposal = AccessProposal(kind:.bindInstance,actorAccountID:account.id,instanceID:binding.id,targetID:binding.id,version:3,expiresAt:Date().addingTimeInterval(300),payload:try ConsoleWire.encode(binding))
    await cloud.configure(device:device,proposal:proposal)
    #expect(try await controller.prepareBinding(binding,device:device,owner:"owner",environment:.test) == proposal)
    #expect(try await controller.prepareBinding(binding,device:device,owner:"owner",environment:.test) == proposal)
    #expect(!(await cloud.paths).contains("/v1/instances"))
    await #expect(throws:ConsoleDashboardError.self) { _ = try await controller.reviewedProposal(id:proposal.id,owner:"different-owner",environment:.test) }
    var replaced = binding; replaced.authorityPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    var forged = proposal; forged.payload = try ConsoleWire.encode(replaced)
    await cloud.configure(device:device,proposal:forged)
    await #expect(throws:ConsoleDashboardError.self) { _ = try await controller.prepareBinding(binding,device:device,owner:"owner",environment:.test) }
}

@Test func consoleDashboardRefreshRotationIsSharedByConcurrentRequests() async throws {
    let file = try dashboardSessionFile(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
    let expired = ConsoleDashboardController.Session(ownerID:"owner",environment:.test,accessToken:"expired-access",refreshToken:"old-refresh",expiresAt:Date().addingTimeInterval(-1))
    try ConsoleWire.encode(expired).write(to:file)
    let cloud = DashboardCloudFixture()
    let controller = try ConsoleDashboardController(file:file,transport:{ try await cloud.send($0) })
    async let first = controller.account(owner:"owner",environment:.test)
    async let second = controller.account(owner:"owner",environment:.test)
    let values = try await [first,second]
    #expect(values[0].account.id == values[1].account.id)
    #expect(await cloud.paths.filter { $0 == "/v1/auth/native/refresh" }.count == 1)
    let saved = try ConsoleWire.decode(ConsoleDashboardController.Session.self,from:Data(contentsOf:file))
    #expect(saved.refreshToken == "private-refresh-token")
}
