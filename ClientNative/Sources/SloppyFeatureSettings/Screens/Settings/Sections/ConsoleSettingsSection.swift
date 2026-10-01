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
    @State private var fingerprint = ""
    var body: some View {
        SettingsSectionCard("Sloppy Console") {
            VStack(alignment: .leading, spacing: 12) {
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
                    TextField("Host certificate SHA-256 from trusted Sloppy", text: $fingerprint)
                        .font(.caption.monospaced())
                    ForEach(snapshot.instances.filter { $0.status == .active }) { instance in
                        Button("Connect to \(instance.name)") {
                            Task { await perform {
                                guard let host = snapshot.devices.first(where: { $0.id == instance.hostDeviceID }) else { throw ConsoleTrustError.forbidden }
                                let orgID = snapshot.grants.first(where: { $0.instanceID == instance.id && $0.deviceID == ConsoleDeviceCredential.load()?.deviceID && $0.status == .active })?.organizationID
                                try await ConsoleRemoteClientRegistry.shared.connect(instance: instance, hostCertificate: host.certificateDER, expectedFingerprint: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines), organizationID: orgID)
                                let remote = RemoteDevice(id: instance.hostDeviceID, spaceID: instance.spaceID, principalID: instance.ownerID, kind: .host, name: instance.name, signingPublicKey: instance.authorityPublicKey, encryptionPublicKey: Data(), encryptionKeySignature: Data(), capabilities: ["console.remote.v2"], online: true)
                                settings.installManagedHosts([remote], relayURL: ManagedRemoteClient.productionURL)
                                if let selected = settings.discoveredInstances.first(where: { if case .managed(_, let id) = $0.endpoint { return id == instance.hostDeviceID }; return false }) { settings.instanceSelection = .instance(selected.id) }
                                onRemoteConnected?(ManagedRemoteClient.productionURL)
                            } }
                        }.disabled(busy || fingerprint.count != 64)
                        Text("Certificate SHA-256: \(instance.hostCertificateFingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                    }
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
        .task { snapshot = try? await ConsoleAccountClient.shared.snapshot() }
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
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await action(); snapshot = try? await ConsoleAccountClient.shared.snapshot(); message = "Console updated." }
        catch { message = "Could not complete the Console action. Check your connection, local owner access and MFA sign-in." }
    }
}

@MainActor
private final class ConsoleLoginPresentation: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "sloppy") { callback, error in
                if let callback { continuation.resume(returning: callback) } else { continuation.resume(throwing: error ?? ConsoleTrustError.forbidden) }
            }
            session.presentationContextProvider = self; self.session = session
            if !session.start() { self.session = nil; continuation.resume(throwing: ConsoleTrustError.forbidden) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}

@MainActor
public struct ConsoleConnectionSetupView: View {
    private let settings: ClientSettings
    private let onConnected: (URL) -> Void
    public init(settings: ClientSettings, onConnected: @escaping (URL) -> Void) { self.settings = settings; self.onConnected = onConnected }
    public var body: some View { ConsoleSettingsSection(settings: settings, onRemoteConnected: onConnected) }
}
