import AuthenticationServices
import SloppyClientCore
import SloppyRemoteProtocol
import SloppyClientUI
import SwiftUI

@MainActor
struct ConsoleSettingsSection: View {
    let settings: ClientSettings
    var onRemoteConnected: ((URL) -> Void)? = nil
    @State private var snapshot: ConsoleAccountClient.Snapshot?
    @State private var message: String?
    @State private var busy = false
    @State private var login = ConsoleLoginPresentation()
    @State private var reviewed: AccessProposal?
    @State private var localConnection: ConsoleConnectionCode?
    @State private var scannedConnection: ConsoleConnectionCode?
    @State private var showConnectionSetup = false
    private var deviceRevoked: Bool {
        guard let id = ConsoleDeviceCredential.load()?.deviceID else { return false }
        return snapshot?.devices.first(where: { $0.id == id })?.status == .revoked
    }
    var body: some View {
        SettingsSectionCard("Sloppy Console") {
            VStack(alignment: .leading, spacing: 12) {
                #if os(macOS)
                if let localConnection { ConsoleConnectionQRCodeView(code: localConnection) }
                #endif
                if let snapshot {
                    Text(snapshot.account.name).font(.headline)
                    Text(snapshot.account.email).foregroundStyle(.secondary)
                    Text("\(snapshot.instances.filter { $0.status == .active }.count) instances · \(snapshot.devices.filter { $0.status == .active }.count) trusted devices")
                    #if os(macOS)
                    Button("Connect this Sloppy instance") { Task { await perform { try await ConsoleAccountClient.shared.bind(localCoreURL: settings.baseURL) } } }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    ForEach(snapshot.proposals) { proposal in
                        Button("Review \(proposal.kind.rawValue.replacingOccurrences(of: "_", with: " "))") { reviewed = proposal }.disabled(busy)
                    }
                    #endif
                    if deviceRevoked {
                        Text(ConsoleAccountError.deviceRevoked.localizedDescription)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Request access again") {
                            Task { await perform(successMessage: ConsoleAccountError.deviceApprovalRequired.localizedDescription) { try await ConsoleAccountClient.shared.requestDeviceAccessAgain() } }
                        }
                        .buttonStyle(.borderedProminent).disabled(busy)
                        .accessibilityIdentifier("settings.console.requestAccessAgain")
                    } else {
                        Button("Connect to a server", systemImage: "server.rack") { showConnectionSetup = true }
                            .buttonStyle(.borderedProminent).disabled(busy)
                    }
                    #if os(iOS)
                    QRCodeScannerButton { url in
                        if let code = ConsoleConnectionCode.parse(url) { scannedConnection = code }
                        else { message = "Scan a server connection QR from Remote or Console → Instances." }
                    }.disabled(busy)
                    #endif
                    Link("Open Console", destination: ConsoleAccountClient.consoleURL)
                    Button("Verify with MFA") { Task { await signIn() } }.disabled(busy)
                    Button("Sign out of Console") { Task { await perform { try await ConsoleAccountClient.shared.signOut() }; self.snapshot = nil } }.disabled(busy)
                } else {
                    Text("Connect your account for cloud Relay, automatic mesh and company access. Sloppy also works without an account.").foregroundStyle(.secondary)
                    Button("Connect Sloppy Console") { Task { await signIn() } }.buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("settings.console.signIn")
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(16)
        }
        .task {
            if await ConsoleAccountClient.shared.isSignedIn() {
                do { snapshot = try await ConsoleAccountClient.shared.snapshot() }
                catch let error as ConsoleAccountError { message = error.localizedDescription }
                catch { message = "Could not load your Console account. Try again." }
            }
            await loadLocalConnection()
        }
        .sheet(isPresented: $showConnectionSetup) {
            ConsoleConnectionSetupView(settings: settings, onConnected: { url in
                showConnectionSetup = false
                onRemoteConnected?(url)
            }, onSelfHosted: { showConnectionSetup = false })
        }
        .sheet(item: $scannedConnection) { code in
            ConsoleConnectionSetupView(settings: settings, autoConnect: false, connectionCode: code, onConnected: { url in
                scannedConnection = nil
                onRemoteConnected?(url)
            }, onSelfHosted: { scannedConnection = nil })
        }
        .sheet(item: $reviewed) { proposal in
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm access change").font(.title2)
                Text(proposal.kind.rawValue.replacingOccurrences(of: "_", with: " ")).font(.headline)
                Text("Target: \(proposal.targetID.uuidString)").font(.caption.monospaced())
                Text("Compare the device key and certificate fingerprint with the target device before approving. Terminal and agent execution grant command execution on this host.").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(reviewText(proposal)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 140)
                HStack { Button("Cancel") { reviewed = nil }; Spacer(); Button("Approve and sign") { Task { await perform { try await ConsoleAccountClient.shared.approve(proposal, localCoreURL: settings.baseURL) }; reviewed = nil } }.buttonStyle(.borderedProminent).disabled(busy) }
            }.padding(24).frame(minWidth: 320, minHeight: 330)
        }
    }
    private func loadLocalConnection() async {
        #if os(macOS)
        localConnection = nil
        do {
            let core = BackendHTTPClient(baseURL: settings.baseURL)
            struct Status: Decodable { var binding: InstanceBinding?; var boundEnvironment: ConsoleEnvironment? }
            struct Identity: Decodable { var instanceID: UUID; var deviceID: UUID; var certificateDER: Data }
            let status = try ConsoleWire.decode(Status.self, from: await core.getData("/v1/console/account?environment=production"))
            let identity = try ConsoleWire.decode(Identity.self, from: await core.getData("/v1/console/identity"))
            if let binding = status.binding, status.boundEnvironment == .production, binding.id == identity.instanceID,
               binding.hostDeviceID == identity.deviceID,
               binding.hostCertificateFingerprint == ConsoleTrust.fingerprint(identity.certificateDER) {
                localConnection = ConsoleConnectionCode(instance: binding)
            }
        } catch { /* QR is available once the local administrator binds this instance. */ }
        #endif
    }

    private func reviewText(_ proposal: AccessProposal) -> String {
        if let object = try? JSONSerialization.jsonObject(with: proposal.payload), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { return text }
        return "Authority key SHA-256: " + ConsoleTrust.fingerprint(proposal.payload)
    }
    private func signIn() async {
        await perform {
            let verifier = ConsoleAccountClient.randomToken(), state = ConsoleAccountClient.randomToken()
            let url = await ConsoleAccountClient.shared.loginURL(verifier: verifier, state: state)
            let callback = try await login.authenticate(url)
            try await ConsoleAccountClient.shared.exchange(callback: callback, verifier: verifier, state: state)
        }
    }
    private func perform(successMessage: String = "Console updated.", _ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await action(); snapshot = try await ConsoleAccountClient.shared.snapshot(); message = successMessage; await loadLocalConnection() }
        catch let error as ConsoleAccountError { message = error.localizedDescription }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { message = "Sign-in cancelled." }
        catch let error as APIError where error.statusCode == 401 || error.statusCode == 403 {
            message = "Open Sloppy on the server's Mac and connect to its local backend as an administrator."
        }
        catch { message = "Could not connect. Check that the local Sloppy server is running and reachable." }
    }
}
