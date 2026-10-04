import Foundation
import AuthenticationServices
import SloppyClientCore
import SloppyRemoteProtocol
import SloppyClientUI
import SwiftUI

@MainActor
public struct ConsoleConnectionSetupView: View {
    private let settings: ClientSettings
    private let autoConnect: Bool
    private let onConnected: (URL) -> Void
    private let onSelfHosted: () -> Void
    @State private var snapshot: ConsoleAccountClient.Snapshot?
    @State private var busy = true
    @State private var signedIn = false
    @State private var message: String?
    @State private var login = ConsoleLoginPresentation()
    @State private var verifying: InstanceBinding?
    @State private var fingerprint = ""
    @State private var pendingCode: ConsoleConnectionCode?
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    public init(settings: ClientSettings, autoConnect: Bool = true, connectionCode: ConsoleConnectionCode? = nil, onConnected: @escaping (URL) -> Void, onSelfHosted: @escaping () -> Void) {
        self.settings = settings
        self.autoConnect = autoConnect
        self._pendingCode = State(initialValue: connectionCode)
        self.onConnected = onConnected
        self.onSelfHosted = onSelfHosted
    }

    private var servers: [InstanceBinding] {
        CloudServerSelection.activeInstances(snapshot?.instances ?? [])
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 10) {
                        SloppyAssets.projectLogo
                            .renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                            .foregroundStyle(theme.colors.accentCyan)
                        Text("Sloppy").font(.headline)
                        Spacer()
                        Text("CLOUD").font(.caption.weight(.semibold)).tracking(2)
                            .foregroundStyle(theme.colors.textSecondary)
                    }
                    .padding(.bottom, 20)

                    hero
                    #if os(iOS)
                    QRCodeScannerButton { url in
                        Task { await acceptConnectionCode(url) }
                    }
                    .disabled(busy)
                    #endif
                    if busy {
                        HStack(spacing: 12) {
                            ProgressView().tint(theme.colors.accentCyan)
                            Text(signedIn ? "Connecting to your workspace…" : "Just a moment…")
                                .font(.subheadline).foregroundStyle(theme.colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .accessibilityIdentifier("connection.cloud.loading")
                    } else if let snapshot {
                        accountBadge(snapshot)
                        if servers.isEmpty {
                            emptyWorkspace
                        } else {
                            serverList
                        }
                    } else if signedIn {
                        Text("Your account is signed in. Refresh to load your servers.")
                            .foregroundStyle(theme.colors.textSecondary)
                        primaryButton("Try again", symbol: "arrow.clockwise") {
                            Task { await reload() }
                        }
                        Button("Sign in again") { Task { await signIn() } }
                            .disabled(busy)
                        Button("Sign out") { Task { await signOut() } }
                            .disabled(busy)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            benefit("Your agents, everywhere", detail: "Pick up your work from any device.", symbol: "bubble.left.and.bubble.right")
                            benefit("One account. All your servers.", detail: "Your connected workspace, in one place.", symbol: "square.stack.3d.up")
                        }
                        .padding(20)
                        .background(theme.colors.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 24))
                        primaryButton("Sign in to Sloppy Cloud", symbol: "arrow.right") {
                            Task { await signIn() }
                        }
                        .accessibilityIdentifier("connection.cloud.signIn")
                        Text("Secure sign-in opens in your browser.")
                            .font(.footnote).foregroundStyle(theme.colors.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    if let message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(theme.colors.statusBlocked)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connection.cloud.error")
                    }
                }
                .padding(24)
                .padding(.top, 20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .foregroundStyle(theme.colors.textPrimary)
        .background(theme.colors.background)
        .task { await reload(autoConnect: autoConnect) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && signedIn && !busy { Task { await reload(autoConnect: false) } }
        }
        .sheet(item: $verifying) { instance in
            verificationSheet(instance)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: signedIn ? (servers.isEmpty ? "square.stack.3d.up" : "server.rack") : "cloud")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.colors.accentCyan)
                .frame(width: 80, height: 80)
                .background(theme.colors.accentCyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
            Text(signedIn ? (servers.isEmpty ? "Your workspace\nstarts here." : "Welcome back.") : "Your Sloppy.\nEverywhere.")
                .font(.largeTitle.weight(.bold)).tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text(signedIn ? (servers.isEmpty ? "Connect your first server to bring your agents and projects with you." : "Choose a server to continue with your agents and projects.") : "Sign in to Sloppy Cloud to connect to your agents, projects and servers.")
                .font(.body).foregroundStyle(theme.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accountBadge(_ snapshot: ConsoleAccountClient.Snapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.title2)
                .foregroundStyle(theme.colors.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.account.name).font(.subheadline.weight(.semibold))
                Text(snapshot.account.email).font(.caption).foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 0)
            Button { Task { await signOut() } } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Sign out of Sloppy Cloud")
            .disabled(busy)
        }
        .padding(12)
        .background(theme.colors.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("No servers yet", systemImage: "plus.circle").font(.headline)
            Text("Add a server in Sloppy Cloud, then come back here. Already running Sloppy? Connect it using Self Hosted below.")
                .font(.subheadline).foregroundStyle(theme.colors.textSecondary)
            Link(destination: ConsoleAccountClient.consoleURL) {
                actionLabel("Open Sloppy Cloud", symbol: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.cloud.openConsole")
            Button("Refresh servers", systemImage: "arrow.clockwise") { Task { await reload() } }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("connection.cloud.refresh")
        }
        .accessibilityIdentifier("connection.cloud.emptyWorkspace")
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR SERVERS").font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(theme.colors.textSecondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .font(.subheadline).frame(minHeight: 44)
            }
            ForEach(servers) { instance in
                Button {
                    Task {
                        if await ConsoleRemoteClientRegistry.shared.hasTrustedPin(for: instance) {
                            await connect(instance)
                        } else {
                            fingerprint = ""
                            verifying = instance
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack").foregroundStyle(theme.colors.accentCyan)
                        Text(instance.name).font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(theme.colors.textSecondary)
                    }
                    .padding(20).frame(maxWidth: .infinity, minHeight: 64)
                    .background(theme.colors.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).disabled(busy)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Rectangle().fill(theme.colors.border).frame(height: 1).padding(.bottom, 12)
            Text("Have your own server?").font(.footnote).foregroundStyle(theme.colors.textSecondary)
            Button("Self Hosted", systemImage: "server.rack", action: onSelfHosted)
                .font(.body.weight(.semibold)).foregroundStyle(theme.colors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("connection.cloud.selfHosted")
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
        .frame(maxWidth: 480).frame(maxWidth: .infinity)
        .background(theme.colors.background)
    }

    private func benefit(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(theme.colors.accentCyan)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(theme.colors.textSecondary)
            }
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: symbol)
        }
        .font(.body.weight(.semibold)).foregroundStyle(Color.black)
        .padding(.horizontal, 20).frame(minHeight: 56)
        .background(theme.colors.accentCyan, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, symbol: symbol) }
            .buttonStyle(.plain).disabled(busy)
    }

    private func verificationSheet(_ instance: InstanceBinding) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Connect to \(instance.name)").font(.title2.weight(.bold))
                    Text("On your server’s Mac, open Sloppy → Settings → Remote and show its connection QR. You can also find it in Console → Instances → Connection QR. Scan it here to connect. Future connections will open automatically.")
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    QRCodeScannerButton { url in Task { await acceptConnectionCode(url, expectedInstance: instance) } }
                        .disabled(busy)
                    #endif
                    Text("Or copy Certificate SHA-256 from the same screen.").font(.footnote).foregroundStyle(.secondary)
                    TextField("Certificate SHA-256", text: $fingerprint)
                        .font(.body.monospaced()).textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    if let message { Text(message).font(.footnote).foregroundStyle(theme.colors.statusBlocked) }
                    primaryButton(busy ? "Connecting…" : "Connect securely", symbol: "lock") {
                        Task { await connect(instance, fingerprint: ConsoleConnectionCode.normalizeFingerprint(fingerprint) ?? "") }
                    }
                    .disabled(ConsoleConnectionCode.normalizeFingerprint(fingerprint) == nil)
                }.padding(24)
            }
            .navigationTitle("Verify server").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { verifying = nil }.disabled(busy) }
            }
        }
    }

    private func reload(autoConnect: Bool = true) async {
        busy = true
        message = nil
        defer { busy = false }
        signedIn = await ConsoleAccountClient.shared.isSignedIn()
        guard signedIn else { snapshot = nil; return }
        do {
            snapshot = try await ConsoleAccountClient.shared.snapshot()
            if let code = pendingCode {
                guard let instance = servers.first(where: { code.matches($0) }) else {
                    pendingCode = nil
                    message = "This QR does not match an active server in your account. Show a new QR on the trusted server."
                    return
                }
                try await establishConnection(instance, fingerprint: code.fingerprint)
                pendingCode = nil
                verifying = nil
                return
            }
        } catch {
            guard !Task.isCancelled else { return }
            message = pendingCode == nil
                ? "Could not load your workspace. Check your connection and try again."
                : "Could not connect. Approve this device’s access in Console and check that your server is online, then refresh."
            return
        }
        guard !Task.isCancelled, autoConnect else { return }
        let preferredHostID = servers.first {
            settings.instanceSelection.instanceID == "managed:\($0.spaceID):\($0.hostDeviceID)"
        }?.hostDeviceID
        let ordered = CloudServerSelection.orderedInstances(servers, preferredHostID: preferredHostID)
        for instance in ordered {
            if await ConsoleRemoteClientRegistry.shared.hasTrustedPin(for: instance) {
                do {
                    try await establishConnection(instance, fingerprint: instance.hostCertificateFingerprint)
                } catch {
                    guard !Task.isCancelled else { return }
                    message = "Your server is unavailable. Try again or choose another server."
                }
                return
            }
        }
        if ordered.count == 1 {
            fingerprint = ""
            verifying = ordered.first
        }
    }

    private func acceptConnectionCode(_ url: URL, expectedInstance: InstanceBinding? = nil) async {
        guard !busy else { return }
        guard let code = ConsoleConnectionCode.parse(url),
              expectedInstance.map({ code.matches($0) }) ?? true else {
            message = "Scan the connection QR for this server from Remote or Console → Instances."
            return
        }
        pendingCode = code
        verifying = nil
        await reload(autoConnect: false)
    }

    private func signIn() async {
        guard !busy else { return }
        busy = true
        message = nil
        do {
            let verifier = ConsoleAccountClient.randomToken(), state = ConsoleAccountClient.randomToken()
            let url = await ConsoleAccountClient.shared.loginURL(verifier: verifier, state: state)
            let callback = try await login.authenticate(url)
            try await ConsoleAccountClient.shared.exchange(callback: callback, verifier: verifier, state: state)
            snapshot = nil
            await reload()
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                message = "Could not sign in to Sloppy Cloud. Please try again."
            }
        }
        busy = false
    }

    private func signOut() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await ConsoleAccountClient.shared.signOut()
            snapshot = nil
            signedIn = false
            message = nil
        } catch { message = "Could not sign out. Please try again." }
    }

    private func connect(_ instance: InstanceBinding, fingerprint: String? = nil) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await establishConnection(instance, fingerprint: fingerprint ?? instance.hostCertificateFingerprint)
            verifying = nil
        } catch { message = "Could not connect. Check the server certificate, access permissions and connection, then try again." }
    }

    private func establishConnection(_ instance: InstanceBinding, fingerprint: String) async throws {
        guard let snapshot, let host = snapshot.devices.first(where: { $0.id == instance.hostDeviceID && $0.status == .active }) else {
            throw ConsoleTrustError.forbidden
        }
        let orgID = snapshot.grants.first(where: {
            $0.instanceID == instance.id && $0.deviceID == ConsoleDeviceCredential.load()?.deviceID && $0.status == .active
        })?.organizationID
        try await ConsoleRemoteClientRegistry.shared.connect(instance: instance, hostCertificate: host.certificateDER, expectedFingerprint: fingerprint, organizationID: orgID)
        guard !Task.isCancelled else { return }
        let remote = RemoteDevice(id: instance.hostDeviceID, spaceID: instance.spaceID, principalID: instance.ownerID, kind: .host, name: instance.name, signingPublicKey: instance.authorityPublicKey, encryptionPublicKey: Data(), encryptionKeySignature: Data(), capabilities: ["console.remote.v2"], online: true)
        settings.installManagedHosts([remote], relayURL: ManagedRemoteClient.productionURL)
        if let selected = settings.discoveredInstances.first(where: {
            if case .managed(_, let id) = $0.endpoint { return id == instance.hostDeviceID }
            return false
        }) { settings.instanceSelection = .instance(selected.id) }
        onConnected(ManagedRemoteClient.productionURL)
    }
}
