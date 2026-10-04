import Foundation
import Testing

@Suite("SwiftUI compat source")
struct SwiftUICompatSourceTests {
    private func source(_ path: String...) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = path.reduce(packageRoot) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("compat defines a visionOS glassEffect backport")
    func compatDefinesAVisionOSGlassEffectBackport() throws {
        let source = try source("Sources", "SloppyClientUI", "SwiftUICompat.swift")

        #expect(source.contains("func backportGlassEffect"))
        #expect(source.contains("#if os(visionOS)"))
        #expect(source.contains("self.glassBackgroundEffect(.plate, in: shape)"))
    }
}
