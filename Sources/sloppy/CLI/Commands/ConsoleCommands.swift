import ArgumentParser
import Foundation
import SloppyConsoleProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ConsoleCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(commandName: "console", abstract: "Connect an optional Sloppy Console account and manage trusted instance access.", subcommands: [ConsoleLoginCommand.self, ConsoleStatusCommand.self, ConsoleBindCommand.self, ConsoleApproveCommand.self, ConsoleLogoutCommand.self])
}

private struct ConsoleCLIClient {
    static let url = URL(string: "https://console.sloppy.team")!
    static var credentialURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sloppy/console-session.json") }
    struct Credential: Codable { var accessToken: String; var expiresAt: Date; var refreshToken: String? = nil }
    static func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        var request = URLRequest(url: url.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            var credential = try ConsoleWire.decode(Credential.self, from: Data(contentsOf: credentialURL))
            if credential.expiresAt <= Date(), let refresh = credential.refreshToken {
                struct Refreshed: Decodable { var accessToken: String; var refreshToken: String }
                let value = try ConsoleWire.decode(Refreshed.self, from: await Self.request("v1/auth/native/refresh", method: "POST", body: ConsoleWire.encode(["refreshToken": refresh]), authenticated: false))
                credential = Credential(accessToken: value.accessToken, expiresAt: Date().addingTimeInterval(3600), refreshToken: value.refreshToken)
                try ConsoleWire.encode(credential).write(to: credentialURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
            }
            guard credential.expiresAt > Date() else { throw ConsoleTrustError.expired }
            request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        }
        let session = URLSession(configuration: .ephemeral, delegate: ConsoleCLINoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ConsoleTrustError.forbidden }; return data
    }
}

private final class ConsoleCLINoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ConsoleLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Sign in in a browser using a device authorization code. No password or token is printed.")
    mutating func run() async throws {
        struct Start: Decodable { var flowID: String; var userCode: String; var verificationURL: URL; var expiresIn: Int; var interval: Int }
        struct Result: Decodable { var accessToken: String?; var refreshToken: String?; var status: String? }
        let start = try ConsoleWire.decode(Start.self, from: await ConsoleCLIClient.request("v1/auth/device/start", method: "POST", body: Data("{}".utf8), authenticated: false))
        print("Open \(start.verificationURL.absoluteString) and enter \(start.userCode).")
        let deadline = Date().addingTimeInterval(Double(start.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(max(start.interval, 5)))
            let result = try ConsoleWire.decode(Result.self, from: await ConsoleCLIClient.request("v1/auth/device/poll", method: "POST", body: ConsoleWire.encode(["flowID": start.flowID]), authenticated: false))
            if let token = result.accessToken {
                let file = ConsoleCLIClient.credentialURL
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try ConsoleWire.encode(ConsoleCLIClient.Credential(accessToken: token, expiresAt: Date().addingTimeInterval(3600), refreshToken: result.refreshToken)).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                print("Signed in to Sloppy Console."); return
            }
        }
        throw ConsoleTrustError.expired
    }
}

struct ConsoleStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show account and instance metadata without exposing credentials.")
    mutating func run() async throws {
        struct Snapshot: Decodable { var account: ConsoleAccount; var instances: [InstanceBinding]; var devices: [ConsoleDevice] }
        let value = try ConsoleWire.decode(Snapshot.self, from: await ConsoleCLIClient.request("v1/me"))
        print("\(value.account.name) <\(value.account.email)> · account \(value.account.id)")
        for instance in value.instances { print("\(instance.id)  \(instance.name)  \(instance.status.rawValue)") }
        print("\(value.devices.filter { $0.status == .active }.count) trusted devices")
    }
}

struct ConsoleBindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bind", abstract: "Bind a locally owned Core to Console, keeping execution and data local.")
    @Option(help: "Local Core URL") var url: String?
    @Flag(help: "Confirm the local-owner binding") var confirm = false
    mutating func run() async throws {
        guard confirm else { throw ValidationError("Review the local instance, then use --confirm to bind it to your Console account.") }
        let local = SloppyCLIClient.resolve(url: url, token: nil, verbose: false)
        struct Identity: Decodable { var instanceID: UUID; var deviceID: UUID; var signingPublicKey: Data; var certificateDER: Data }
        struct Me: Decodable { var account: ConsoleAccount; var devices: [ConsoleDevice] }
        let identity = try ConsoleWire.decode(Identity.self, from: await local.get("/v1/console/identity"))
        let me = try ConsoleWire.decode(Me.self, from: await ConsoleCLIClient.request("v1/me"))
        if !me.devices.contains(where: { $0.id == identity.deviceID }) {
            let device = ConsoleDevice(id: identity.deviceID, accountID: me.account.id, name: "Sloppy Host", signingPublicKey: identity.signingPublicKey, certificateDER: identity.certificateDER)
            _ = try await ConsoleCLIClient.request("v1/devices", method: "POST", body: ConsoleWire.encode(device))
        }
        let binding = InstanceBinding(id: identity.instanceID, ownerID: me.account.id, spaceID: me.account.personalSpaceID, name: "Sloppy Instance", authorityPublicKey: identity.signingPublicKey, hostDeviceID: identity.deviceID, hostCertificateFingerprint: ConsoleTrust.fingerprint(identity.certificateDER))
        let proposal = try ConsoleWire.decode(AccessProposal.self, from: await ConsoleCLIClient.request("v1/instances", method: "POST", body: ConsoleWire.encode(binding)))
        let signed = try ConsoleWire.decode(SignedAccessProposal.self, from: await local.post("/v1/console/approve", body: ConsoleWire.encode(proposal)))
        _ = try await ConsoleCLIClient.request("v1/proposals/approve", method: "POST", body: ConsoleWire.encode(signed))
        struct Key: Decodable { var publicKey: String }; let key = try ConsoleWire.decode(Key.self, from: await ConsoleCLIClient.request("v1/proof-key"))
        guard let publicKey = Data(base64Encoded: key.publicKey) else { throw ConsoleTrustError.invalidConfiguration }
        struct Install: Encodable { var signed: SignedAccessProposal; var consolePublicKey: Data }
        _ = try await local.post("/v1/console/binding", body: ConsoleWire.encode(Install(signed: signed, consolePublicKey: publicKey)))
        print("Bound instance \(binding.id). Host certificate SHA-256: \(binding.hostCertificateFingerprint)")
    }
}

struct ConsoleApproveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve", abstract: "Review and sign a pending access proposal on a trusted local Sloppy.")
    @Argument var proposalID: String
    @Option var url: String?
    @Flag(help: "Sign the displayed proposal after reviewing its keys and permissions") var confirm = false
    mutating func run() async throws {
        struct Snapshot: Decodable { var proposals: [AccessProposal] }
        let snapshot = try ConsoleWire.decode(Snapshot.self, from: await ConsoleCLIClient.request("v1/me"))
        guard let proposal = snapshot.proposals.first(where: { $0.id.uuidString.lowercased() == proposalID.lowercased() }) else { throw ConsoleTrustError.forbidden }
        print("\(proposal.kind.rawValue) · target \(proposal.targetID) · version \(proposal.version)")
        if let value = String(data: proposal.payload, encoding: .utf8) { print(value) }
        else { print("Authority SHA-256: \(ConsoleTrust.fingerprint(proposal.payload))") }
        guard confirm else { print("Review the proposal, then repeat with --confirm."); return }
        let local = SloppyCLIClient.resolve(url: url, token: nil, verbose: false)
        let signed = try ConsoleWire.decode(SignedAccessProposal.self, from: await local.post("/v1/console/approve", body: ConsoleWire.encode(proposal)))
        _ = try await ConsoleCLIClient.request("v1/proposals/approve", method: "POST", body: ConsoleWire.encode(signed))
        if let instanceID = proposal.instanceID {
            let snapshot = try await ConsoleCLIClient.request("v1/instances/\(instanceID)/trust")
            _ = try await local.post("/v1/console/trust", body: snapshot)
        }
        print("Access proposal signed and applied.")
    }
}

struct ConsoleLogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Sign out of this CLI without unbinding instances.")
    mutating func run() async throws {
        _ = try await ConsoleCLIClient.request("v1/auth/logout", method: "POST")
        try FileManager.default.removeItem(at: ConsoleCLIClient.credentialURL)
        print("Signed out of Console. Instance bindings remain active.")
    }
}
