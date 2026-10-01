import Foundation
import SwiftUI
import SloppyClientCore
import SloppyFeatureSettings
import SloppyClientUI

struct ConnectionSetupView: View {
    let settings: ClientSettings
    let onConnected: (URL) -> Void
    let onScannedCode: (URL) -> Void

    @State private var hostDraft: String = ""
    @State private var portDraft: String = "25101"
    @State private var discoveredServers: [SavedServer] = []
    @State private var isScanning = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: sp.m) {
                SloppyAssets.projectLogo
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundStyle(c.accentCyan)

                VStack(alignment: .leading, spacing: sp.xs) {
                    Text("Connect to Sloppy")
                        .font(.system(size: ty.title, weight: .semibold))
                        .foregroundColor(c.textPrimary)
                    Text("No server found automatically. Set up your connection below.")
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
#if os(macOS)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .automatic) {
                        Button(isConnecting ? "Connecting" : "Connect") {
                            connectManual()
                        }
                        .buttonStyle(.glassProminent)
                        .tint(c.accentCyan)
                        .disabled(isConnecting || hostDraft.isEmpty)
                        .accessibilityIdentifier("connection.setup.connect")
                    }
                }
#else
                .safeAreaInset(edge: .bottom) {
                    Button {
                        connectManual()
                    } label: {
                        Text(isConnecting ? "CONNECTING..." : "CONNECT")
                            .font(.system(size: ty.body, weight: .semibold))
                            .foregroundColor(c.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, theme.spacing.m)
                    }
                    .backportGlassEffect(.regular.interactive().tint(c.accentCyan), in: .capsule)
                    .padding(.horizontal, theme.spacing.l)
                    .disabled(isConnecting || hostDraft.isEmpty)
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
            VStack(alignment: .leading, spacing: sp.xxl) {
                ConsoleConnectionSetupView(settings: settings, onConnected: onConnected)

                // Warning banner
                GlassEffectContainer(spacing: sp.xs) {
                    HStack(spacing: sp.s) {
                        Icons.symbol(.warning, size: ty.caption)
                        Text("Local network scan only works on your current Wi-Fi.\nFor remote access, enter the address manually.")
                            .font(.system(size: ty.caption))
                    }
                    .foregroundColor(c.statusWarning)
                    .padding(sp.m)
                    .glassEffect(
                        .regular.tint(c.statusWarning.opacity(0.15)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
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
                                .foregroundColor(c.accentCyan)
                                .padding(.vertical, theme.spacing.s)
                                .padding(.horizontal, theme.spacing.s)
                        }
                        .buttonStyle(.plain)
                        .backportGlassEffect(.regular.interactive(), in: .capsule)
                        .disabled(isScanning)
                    }

                    if discoveredServers.isEmpty && !isScanning {
                        Text("No servers found. Try scanning or enter manually.")
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
                                .foregroundColor(c.accentCyan)
                            }
                            .padding(sp.m)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                // Manual input section
                VStack(alignment: .leading, spacing: sp.m) {
                    Text("MANUAL")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)

                    Text("On a physical iPhone or iPad, “localhost” is the device itself, not your Mac. Use your computer’s LAN address (for example 192.168.x.x) or run Sloppy Core on the same device.")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)

                    VStack(alignment: .leading, spacing: 12) {
                        manualField("Host", hint: "192.168.1.50 or hostname", text: $hostDraft)

                        manualField("Port", hint: "25101", text: $portDraft)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: ty.caption))
                            .foregroundColor(c.statusBlocked)
                    }
                }

                // QR code hint
                VStack(alignment: .leading, spacing: sp.s) {
                    Text("QR CODE")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                    Text("Open the Sloppy Dashboard in a browser and navigate to \nSettings > Connect Client to display a QR code. Scan it with your device camera to connect automatically.")
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
                .foregroundColor(.white)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, sp.m)
        .padding(.vertical, sp.m)
        .glassEffect(.regular, in: .capsule)
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        discoveredServers = []
        Task { @MainActor in
            let scanner = LocalNetworkScanner()
            for await server in await scanner.scan() {
                discoveredServers.append(server)
            }
            isScanning = false
        }
    }

    private func connect(to url: URL) {
        guard !isConnecting else { return }
        isConnecting = true
        Task { @MainActor in
            let ok = await HealthService(baseURL: url).isHealthy()
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
        guard let address = ServerAddress.parse(host: hostDraft, port: portDraft) else { return }

        isConnecting = true
        Task { @MainActor in
            let url = address.baseURL
            let ok = await HealthService(baseURL: url).isHealthy()
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
        onScannedCode: { _ in }
    )
}
