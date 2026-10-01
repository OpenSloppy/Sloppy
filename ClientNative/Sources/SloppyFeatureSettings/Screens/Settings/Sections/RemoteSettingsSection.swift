import CoreImage.CIFilterBuiltins
import Foundation
import SloppyClientCore
import SloppyClientUI
import SloppyRemoteProtocol
import SwiftUI

@MainActor
struct RemoteSettingsSection: View {
    let settings: ClientSettings
    @State private var invite = ""
    @State private var setupCode = ""
    @State private var recoverySpaceID = ""
    @State private var recoveryCode = ""
    @State private var status = "Disabled"
    @State private var message: String?
    @State private var busy = false
    @State private var recoveryCodes: [String] = []
    @State private var confirmRecoveryRotation = false
    @State private var pairingCode: RemotePairingCode?
    @State private var pairingKind: RemoteDeviceKind = .mobile
    @State private var pending: [ManagedPairingRequest] = []
    @State private var devices: [RemoteDevice] = []
    @State private var client = ManagedRemoteClient()

    @Environment(\.theme) private var theme

    private let qrContext = CIContext()
    private let qrFilter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConsoleSettingsSection(settings: settings)
            #if os(macOS)
            hostContent
            #else
            mobileContent
            #endif

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.remote.message")
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: pairingCode?.pairingID) {
            guard let pairingCode else { return }
            while !Task.isCancelled && Date() < pairingCode.expiresAt {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled { self.pairingCode = nil }
        }
        .confirmationDialog(
            "Replace all recovery codes? Existing codes will stop working immediately.",
            isPresented: $confirmRecoveryRotation
        ) {
            Button("Rotate recovery codes", role: .destructive) {
                Task { await rotateRecoveryCodes() }
            }
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var hostContent: some View {
        if ManagedRemoteCredentialStore.load() == nil {
            SettingsSectionCard("Enable Remote") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect this Mac to your private Sloppy Remote space.")
                        .foregroundStyle(.secondary)
                    TextField("Service invite", text: $invite)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.remote.invite")
                    Button(busy ? "Enabling…" : "Enable Remote") {
                        Task { await enableRemote() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.remote.enable")
                    Text("Already have a space? Paste an Add host QR link instead.")
                        .foregroundStyle(.secondary)
                    TextField("sloppy://remote-pair?code=…", text: $setupCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Join existing space") {
                        Task { await claimHostSetup() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || setupCode.isEmpty)
                    Text("Lost every trusted device? Use a saved recovery code.")
                        .foregroundStyle(.secondary)
                    TextField("Personal space ID", text: $recoverySpaceID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Recovery code", text: $recoveryCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Recover this space") {
                        Task { await recoverHost() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || recoverySpaceID.isEmpty || recoveryCode.isEmpty)
                }
                .padding(16)
            }
        } else {
            SettingsSectionCard("Remote status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(status, systemImage: status == "Online" ? "checkmark.circle.fill" : "wifi.slash")
                        Spacer()
                        Button("Refresh") { Task { await refresh() } }
                            .buttonStyle(.bordered)
                    }
                    if let spaceID = ManagedRemoteCredentialStore.load()?.device.spaceID {
                        Text("Personal space ID: \(spaceID.uuidString)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }

            SettingsSectionCard("Pair a phone") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The phone requests access. Approve it here before it can connect.")
                        .foregroundStyle(.secondary)
                    Button(busy ? "Creating…" : "Create pairing QR") {
                        Task { await createPairing(kind: .mobile) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .accessibilityIdentifier("settings.remote.createPairing")
                    Button("Add host") {
                        Task { await createPairing(kind: .host) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    if let pairingCode, let qr = qrImage(for: pairingCode) {
                        Text(pairingKind == .host ? "Scan on the new Mac" : "Scan on the phone")
                            .font(.headline)
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 220, height: 220)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        Text("Expires \(pairingCode.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }

            SettingsSectionCard("Pending devices") {
                if pending.isEmpty {
                    Text("No devices waiting for approval")
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(pending, id: \.id) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.claimedName ?? "New device")
                                    Text(item.kind.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.claimedSigningPublicKey.map {
                                        "SHA-256 " + RemoteDeviceKeys.fingerprint(signingPublicKey: $0)
                                    } ?? "")
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Reject") { Task { await decide(item.id, approve: false) } }
                                    .buttonStyle(.bordered)
                                Button("Approve") { Task { await decide(item.id, approve: true) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(16)
                            SettingsDivider()
                        }
                    }
                }
            }

            SettingsSectionCard("Connected devices") {
                if devices.isEmpty {
                    Text("No connected devices")
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(devices, id: \.id) { device in
                            HStack {
                                Label(device.name, systemImage: device.kind == .host ? "desktopcomputer" : "iphone")
                                Spacer()
                                Text(device.kind.rawValue.capitalized)
                                    .foregroundStyle(.secondary)
                                if device.id != ManagedRemoteCredentialStore.load()?.device.id {
                                    Button("Revoke", role: .destructive) {
                                        Task { await revoke(device.id) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(16)
                            SettingsDivider()
                        }
                    }
                }
            }

            SettingsSectionCard("Recovery") {
                Button("Rotate recovery codes") {
                    confirmRecoveryRotation = true
                }
                .buttonStyle(.bordered)
                .padding(16)
            }
        }
        if !recoveryCodes.isEmpty {
            SettingsSectionCard("Recovery codes") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save these now. Each code works once and will not be shown again.")
                    ForEach(recoveryCodes, id: \.self) { code in
                        Text(code).font(.system(.body, design: .monospaced))
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
    }
    #endif

    #if !os(macOS)
    private var mobileContent: some View {
        VStack(spacing: 20) {
            SettingsSectionCard("Connect to Remote") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan the QR shown on your Mac with Camera, or paste its Sloppy setup link here.")
                        .foregroundStyle(.secondary)
                    TextField("sloppy://remote-pair?code=…", text: $setupCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "Waiting for approval…" : "Request access") {
                        Task { await claimPairing() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || setupCode.isEmpty)
                }
                .padding(16)
            }
            SettingsSectionCard("Your hosts") {
                if devices.filter({ $0.kind == .host }).isEmpty {
                    Text("No hosts available yet")
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    ForEach(devices.filter { $0.kind == .host }, id: \.id) { host in
                        Label(host.name, systemImage: "desktopcomputer")
                            .padding(16)
                    }
                }
            }
        }
    }
    #endif

    private func refresh() async {
        guard ManagedRemoteCredentialStore.load() != nil else {
            status = "Disabled"
            return
        }
        do {
            _ = try await client.authenticate()
            devices = try await client.devices()
            #if os(macOS)
            pending = try await client.pendingPairings()
            #endif
            let ownID = ManagedRemoteCredentialStore.load()?.device.id
            status = devices.first(where: { $0.id == ownID })?.online == true
                ? "Online" : "Offline"
            message = nil
        } catch {
            if let remoteError = error as? ManagedRemoteError,
               case .server(let code) = remoteError,
               code == 401 || code == 403 {
                status = "Attention required"
            } else {
                status = "Offline"
            }
            message = error.localizedDescription
        }
    }

    #if os(macOS)
    private func enableRemote() async {
        busy = true
        status = "Enrolling"
        defer { busy = false }
        do {
            let result = try await client.enableRemote(
                invite: invite.trimmingCharacters(in: .whitespacesAndNewlines),
                hostName: Host.current().localizedName ?? "Sloppy Mac"
            )
            recoveryCodes = result.recoveryCodes
            invite = ""
            await ManagedRemoteHostManager.shared.startIfNeeded(localCoreURL: settings.baseURL)
            await refresh()
        } catch {
            status = "Attention required"
            if let remoteError = error as? ManagedRemoteError,
               case .credentialStorageFailed(let codes, let spaceID) = remoteError {
                recoveryCodes = codes
                recoverySpaceID = spaceID.uuidString
            }
            message = error.localizedDescription
        }
    }

    private func createPairing(kind: RemoteDeviceKind) async {
        busy = true
        defer { busy = false }
        do {
            pairingCode = try await client.createPairing(kind: kind)
            pairingKind = kind
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func claimHostSetup() async {
        busy = true
        defer { busy = false }
        do {
            guard let url = URL(string: setupCode) else {
                throw ManagedRemoteError.invalidResponse
            }
            let code = try RemotePairingCode.decode(url)
            let joiningClient = ManagedRemoteClient(relayURL: code.relayURL)
            _ = try await joiningClient.claimHostPairing(
                code, name: Host.current().localizedName ?? "Sloppy Mac"
            )
            setupCode = ""
            await ManagedRemoteHostManager.shared.startIfNeeded(localCoreURL: settings.baseURL)
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    private func recoverHost() async {
        busy = true
        defer { busy = false }
        do {
            guard let spaceID = UUID(uuidString: recoverySpaceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ManagedRemoteError.invalidResponse
            }
            _ = try await client.recoverHost(
                spaceID: spaceID,
                code: recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines),
                hostName: Host.current().localizedName ?? "Recovered Sloppy Mac"
            )
            recoveryCode = ""
            recoverySpaceID = ""
            await ManagedRemoteHostManager.shared.startIfNeeded(localCoreURL: settings.baseURL)
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    private func decide(_ id: UUID, approve: Bool) async {
        do {
            try await client.decidePairing(id: id, approve: approve)
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    private func revoke(_ id: UUID) async {
        do {
            try await client.revokeDevice(id)
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    private func qrImage(for code: RemotePairingCode) -> CGImage? {
        guard let link = try? code.encode() else { return nil }
        qrFilter.setValue(Data(link.absoluteString.utf8), forKey: "inputMessage")
        guard let output = qrFilter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return qrContext.createCGImage(output, from: output.extent)
    }
    #endif

    #if !os(macOS)
    private func claimPairing() async {
        busy = true
        defer { busy = false }
        do {
            guard let url = URL(string: setupCode) else {
                throw ManagedRemoteError.invalidResponse
            }
            let code = try RemotePairingCode.decode(url)
            let pairingClient = ManagedRemoteClient(relayURL: code.relayURL)
            _ = try await pairingClient.claimPhonePairing(code, name: "Sloppy iPhone")
            setupCode = ""
            if let credential = ManagedRemoteCredentialStore.load() {
                settings.installManagedHosts(
                    try await pairingClient.hosts(), relayURL: credential.relayURL
                )
            }
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }
    #endif

    private func rotateRecoveryCodes() async {
        do {
            recoveryCodes = try await client.rotateRecoveryCodes()
            message = "Save the new codes now. Previous codes are invalid."
        } catch {
            message = error.localizedDescription
        }
    }
}
