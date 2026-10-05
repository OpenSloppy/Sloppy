import Foundation
import Testing

@Suite("Splash screen source")
struct SplashScreenSourceTests {
    @Test("Centers the branded connection status")
    func centeredProjectLogoAndStatus() throws {
        let source = try String(contentsOf: splashScreenURL, encoding: .utf8)

        #expect(source.contains("SloppyAssets.projectLogo"))
        #expect(source.contains(".renderingMode(.template)"))
        #expect(source.contains(".foregroundColor(c.textMuted)"))
        #expect(!source.contains("Icons.symbol(.autoAwesome"))
        #expect(source.contains(".multilineTextAlignment(.center)"))
        #expect(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
    }

    @Test("macOS starts an installed local backend before network discovery")
    func startsInstalledLocalBackend() throws {
        let source = try String(contentsOf: splashScreenURL, encoding: .utf8)
        let launcher = try #require(source.range(of: "LocalStartupConnection.connect(configuredURL: settings.baseURL)"))
        let scan = try #require(source.range(of: "let scanner = LocalNetworkScanner()"))

        #expect(source.contains("#if os(macOS)"))
        #expect(launcher.lowerBound < scan.lowerBound)
    }

    private var splashScreenURL: URL {
        packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SloppyClient")
            .appendingPathComponent("Root")
            .appendingPathComponent("SplashScreen.swift")
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
