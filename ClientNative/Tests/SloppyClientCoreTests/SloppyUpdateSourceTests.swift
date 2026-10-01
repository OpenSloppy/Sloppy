import Foundation
import Testing

@Suite("Sloppy macOS updates")
struct SloppyUpdateSourceTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("macOS target links Sparkle and embeds signed feed settings")
    func projectConfiguresSparkle() throws {
        let project = try source("project.yml")
        let plist = try source("SupportingFiles/macOS/Info.plist")

        #expect(project.contains("exactVersion: 2.9.6"))
        #expect(project.contains("product: Sparkle"))
        #expect(project.contains("SLOPPY_UPDATE_FEED_URL: https://github.com/TeamSloppy/Sloppy/releases/latest/download/appcast.xml"))
        #expect(project.contains("SLOPPY_UPDATE_PUBLIC_KEY: /HaP1yvSO8EUYuKzJi43d+Wf/lr5Re/ZMoRFIz4SAus="))
        #expect(plist.contains("<key>SUFeedURL</key>"))
        #expect(plist.contains("<key>SUPublicEDKey</key>"))
        #expect(plist.contains("<key>SUEnableAutomaticChecks</key>"))
        #expect(plist.contains("<key>SUAutomaticallyUpdate</key>"))
        #expect(project.contains("SUScheduledCheckInterval: 3600"))
        #expect(plist.contains("<key>SUScheduledCheckInterval</key>\n\t<integer>3600</integer>"))
    }

    @Test("application starts Sparkle and exposes a manual update command")
    func appStartsUpdaterAndExposesCommand() throws {
        let app = try source("Sources/SloppyClient/App/SloppyClientApp.swift")
        let updater = try source("Sources/SloppyClient/App/SloppyUpdateController.swift")

        #expect(app.contains("SloppyUpdateController.shared.start()"))
        #expect(app.contains("Button(\"Check for Updates…\")"))
        #expect(app.contains("SloppyUpdateController.shared.checkForUpdates()"))
        #expect(updater.contains("SPUStandardUpdaterController"))
        #expect(updater.contains("Data(base64Encoded: key)?.count == 32"))
        #expect(updater.contains("userDriverDelegate: self"))
        #expect(updater.contains("SPUStandardUserDriverDelegate"))
    }

    @Test("release helpers package the app and sign an appcast")
    func releaseHelpersPackageAndSignAppcast() throws {
        let packaging = try source("script/package_sparkle_archive.sh")
        let appcast = try source("script/generate_sparkle_appcast.sh")
        let workflow = try source("../.github/workflows/release.yml")
        let readme = try source("README.md")

        #expect(packaging.contains("ditto -c -k --sequesterRsrc --keepParent"))
        #expect(packaging.contains("SUPublicEDKey"))
        #expect(appcast.contains("generate_appcast"))
        #expect(appcast.contains("--ed-key-file"))
        #expect(appcast.contains("sparkle:edSignature="))
        #expect(!appcast.contains("SPARKLE_PRIVATE_KEY=\""))
        #expect(workflow.contains("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"))
        #expect(workflow.contains("release-assets/SloppyClient-macos-*.zip"))
        #expect(workflow.contains("release-assets/appcast.xml"))
        #expect(readme.contains("SPARKLE_PRIVATE_KEY"))
        #expect(readme.contains("never commit an exported key"))
    }
}
