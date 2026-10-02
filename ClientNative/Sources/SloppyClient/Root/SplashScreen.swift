import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

enum SplashResult {
    case connected(URL)
    case managed
    case needsSetup
}

struct SplashScreen: View {
    let settings: ClientSettings
    let onResult: (SplashResult) -> Void

    @State private var status: String = "Connecting..."
    @State private var isScanning = false
    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(spacing: sp.xxl) {
            Spacer()

            VStack(spacing: sp.m) {
                SloppyAssets.projectLogo
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundColor(c.textMuted)

                Text("Sloppy")
                    .font(.system(size: ty.hero))
                    .foregroundColor(c.textPrimary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: sp.s) {
                Text(status.uppercased())
                    .font(.system(size: ty.caption))
                    .foregroundColor(c.textMuted)
                    .multilineTextAlignment(.center)

                if isScanning {
                    Text("Scanning local network...")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task { await attemptConnection() }
    }

    @MainActor
    private func attemptConnection() async {
        if await ConsoleAccountClient.shared.isSignedIn() {
            onResult(.needsSetup)
            return
        }
        #if !os(macOS)
        if settings.savedServers.isEmpty && ManagedRemoteCredentialStore.load() == nil {
            onResult(.needsSetup)
            return
        }
        if ManagedRemoteCredentialStore.load()?.device.kind == .mobile {
            onResult(.managed)
            return
        }
        #endif
        // 1. Try configured host:port (includes default localhost:25101 on first launch).
        status = "Trying \(settings.serverHost):\(settings.serverPort)..."
        let url = settings.baseURL
        if await HealthService(baseURL: url).isHealthy() {
            guard !Task.isCancelled else { return }
            onResult(.connected(url))
            return
        }

        #if os(macOS)
        // The TUI owns a local CoreService. The native macOS client reaches the
        // same local workspace through HTTP, so start an installed backend when
        // localhost is not already serving it.
        if ServerAddress.isLoopbackHost(url.host) {
            status = "Starting local Sloppy..."
            switch await LocalBackendLauncher.shared.ensureRunning(at: url) {
            case .alreadyRunning, .started:
                guard !Task.isCancelled else { return }
                onResult(.connected(url))
                return
            case .unavailable, .failed:
                break
            }
        }
        #endif

        guard !Task.isCancelled else { return }

        #if !os(macOS)
        onResult(.needsSetup)
        return
        #else
        // 2. Scan local network
        status = "Scanning network..."
        isScanning = true
        let scanner = LocalNetworkScanner()
        var found: SavedServer?
        for await server in await scanner.scan() {
            guard !Task.isCancelled else { return }
            found = server
            break
        }
        isScanning = false

        if let server = found {
            status = "Found \(server.host)"
            settings.useServer(server)
            onResult(.connected(server.baseURL))
            return
        }

        // 3. Give up -- show setup
        status = "No server found"
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        onResult(.needsSetup)
        #endif
    }
}
