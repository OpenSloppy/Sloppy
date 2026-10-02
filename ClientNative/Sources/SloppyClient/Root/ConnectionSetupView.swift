import Foundation
import SwiftUI
import SloppyClientCore
import SloppyFeatureSettings
import SloppyClientUI

struct ConnectionSetupView: View {
    let settings: ClientSettings
    let onConnected: (URL) -> Void
    let onScannedCode: (URL) -> Void
    let onCloudConnected: (URL) -> Void
    var autoConnectCloud = true

    @State private var isSelfHosted = false

    @State private var hostDraft: String = ""
    @State private var portDraft: String = "25101"
    @State private var discoveredServers: [SavedServer] = []
    @State private var isScanning = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var connectionTask: Task<Void, Never>?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isSelfHosted {
            selfHostedView
        } else {
            ConsoleConnectionSetupView(settings: settings, autoConnect: autoConnectCloud, onConnected: onCloudConnected, onSelfHosted: {
                isSelfHosted = true
            })
        }
    }

    private var selfHostedView: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(alignment: .leading, spacing: 0) {
            Button { isSelfHosted = false } label: {
                Label("Sloppy Cloud", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(c.textSecondary)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.setup.backToCloud")
            .padding(.horizontal, sp.l)

            HStack(spacing: sp.m) {
                SloppyAssets.projectLogo
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundStyle(c.accentCyan)

                VStack(alignment: .leading, spacing: sp.xs) {
                    Text("Self Hosted")
                        .font(.system(size: ty.title, weight: .semibold))
                        .foregroundColor(c.textPrimary)
                    Text("Connect to your own Sloppy server.")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(sp.l)

            contentView
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    hostDraft = settings.serverHost == "localhost" ? "" : settings.serverHost
                    portDraft = String(settings.serverPort)
                    startScan()
                }
                .onDisappear {
                    scanTask?.cancel()
                    connectionTask?.cancel()
                    isScanning = false
                    isConnecting = false
                }
#if os(macOS)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .automatic) {
                        Button(isConnecting ? "Connecting" : "Connect") {
                            connectManual()
                        }
                        .buttonStyle(.glassProminent)
                        .tint(c.accentCyan)
                        .disabled(isConnecting || ServerAddress.parse(host: hostDraft, port: portDraft) == nil)
                        .accessibilityIdentifier("connection.setup.connect")
                    }
                }
#else
                .safeAreaInset(edge: .bottom) {
                    Button {
                        connectManual()
                    } label: {
                        Text(isConnecting ? "Connecting…" : "Connect")
                            .font(.system(size: ty.body, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, theme.spacing.m)
                    }
                    .buttonStyle(.plain)
                    .background(c.accentCyan, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("connection.setup.connect")
                    .padding(.horizontal, theme.spacing.l)
                    .disabled(isConnecting || ServerAddress.parse(host: hostDraft, port: portDraft) == nil)
                    .padding(.vertical, 12)
                    .background(c.background)
                    .frame(maxWidth: .infinity)
                }
#endif
        }
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var contentView: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return ScrollView {
            VStack(alignment: .leading, spacing: sp.l) {
                // Manual input section
                VStack(alignment: .leading, spacing: sp.m) {
                    Text("SERVER ADDRESS")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)

                    Text("Enter a hostname, IP address or HTTPS URL.")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)

                    VStack(alignment: .leading, spacing: 12) {
                        manualField("Host", hint: "sloppy.example.com", text: $hostDraft)

                        manualField("Port", hint: "25101", text: $portDraft)
                    }

                    DisclosureGroup("Connecting from another device?") {
                        Text("Use your computer’s LAN address on Wi-Fi, or its public address remotely. On an iPhone or iPad, localhost points to this device.")
                            .font(.footnote).foregroundStyle(c.textSecondary)
                            .padding(.top, 8)
                    }
                    .font(.footnote).foregroundStyle(c.textSecondary)

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: ty.caption))
                            .foregroundColor(c.statusBlocked)
                    }
                }

                // Scan section
                VStack(alignment: .leading, spacing: sp.m) {
                    HStack {
                        Text("LOCAL NETWORK")
                            .font(.system(size: ty.caption))
                            .foregroundColor(c.textMuted)
                        Spacer()
                        Button {
                            startScan()
                        } label: {
                            Text(isScanning ? "SCANNING..." : "SCAN")
                                .font(.system(size: ty.caption))
                                .foregroundColor(colorScheme == .light ? c.accent : c.accentCyan)
                                .padding(.vertical, theme.spacing.s)
                                .padding(.horizontal, theme.spacing.s)
                        }
                        .buttonStyle(.plain)
                        .backportGlassEffect(.regular.interactive(), in: .capsule)
                        .disabled(isScanning)
                    }

                    if discoveredServers.isEmpty && !isScanning {
                        Text("No servers found on this Wi-Fi. You can still connect using the address above.")
                            .font(.system(size: ty.caption))
                            .foregroundColor(c.textMuted)
                    }

                    ForEach(discoveredServers) { server in
                        Button(action: { connect(to: server.baseURL) }) {
                            HStack(spacing: sp.m) {
                                VStack(alignment: .leading, spacing: sp.xs) {
                                    Text(server.label)
                                        .font(.system(size: ty.body))
                                        .foregroundColor(c.textPrimary)
                                    Text(server.host + ":" + String(server.port))
                                        .font(.system(size: ty.micro))
                                        .foregroundColor(c.textMuted)
                                }
                                Spacer()
                                HStack(spacing: sp.xs) {
                                    Text("CONNECT")
                                        .font(.system(size: ty.caption))
                                    Icons.symbol(.arrowForward, size: ty.caption)
                                }
                                .foregroundColor(colorScheme == .light ? c.accent : c.accentCyan)
                            }
                            .padding(sp.m)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                // QR code hint
                VStack(alignment: .leading, spacing: sp.s) {
                    Text("QR CODE")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                    Text("Open Settings → Connect Client in your server’s Dashboard, then scan the connection code.")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textSecondary)
                    #if os(iOS)
                    QRCodeScannerButton(onScannedCode: onScannedCode)
                        .padding(.top, sp.s)
                    #endif
                }
                .padding(sp.m)
            }
            .padding(theme.spacing.l)
            .frame(maxWidth: 860, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func manualField(_ label: String, hint: String, text: Binding<String>) -> some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return HStack(spacing: sp.m) {
            Text(label.uppercased())
                .font(.system(size: ty.caption))
                .foregroundColor(c.textMuted)
                .frame(width: 40)
            TextField(hint, text: text)
                .font(.system(size: ty.body))
                .foregroundColor(c.textPrimary)
                .textFieldStyle(.plain)
                .accessibilityLabel(label)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(label == "Port" ? .numberPad : .URL)
                #endif
        }
        .padding(.horizontal, sp.m)
        .padding(.vertical, sp.m)
        .background(c.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).stroke(c.border, lineWidth: 1)
        }
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        discoveredServers = []
        scanTask = Task { @MainActor in
            let scanner = LocalNetworkScanner()
            for await server in await scanner.scan() {
                guard !Task.isCancelled else { return }
                discoveredServers.append(server)
            }
            isScanning = false
        }
    }

    private func connect(to url: URL) {
        guard !isConnecting else { return }
        isConnecting = true
        connectionTask = Task { @MainActor in
            let ok = await HealthService(baseURL: url).isHealthy()
            guard !Task.isCancelled else { return }
            isConnecting = false
            if ok {
                let server = SavedServer(
                    label: "Discovered",
                    scheme: url.scheme ?? "http",
                    host: url.host ?? "",
                    port: url.port ?? 25101,
                    isAutoDiscovered: true
                )
                settings.useServer(server)
                onConnected(url)
            } else {
                errorMessage = "Could not connect to \(url.host ?? "server")"
            }
        }
    }

    private func connectManual() {
        errorMessage = nil
        guard !isConnecting, let address = ServerAddress.parse(host: hostDraft, port: portDraft) else { return }

        isConnecting = true
        connectionTask = Task { @MainActor in
            let url = address.baseURL
            let ok = await HealthService(baseURL: url).isHealthy()
            guard !Task.isCancelled else { return }
            isConnecting = false
            if ok {
                let server = SavedServer(
                    label: "Sloppy @ \(address.host)",
                    scheme: address.scheme,
                    host: address.host,
                    port: address.port
                )
                settings.useServer(server)
                onConnected(url)
            } else {
                errorMessage = "Could not connect to \(address.host):\(String(address.port))"
            }
        }
    }
}

#Preview {
    ConnectionSetupView(
        settings: ClientSettings(),
        onConnected: { _ in },
        onScannedCode: { _ in },
        onCloudConnected: { _ in }
    )
}
