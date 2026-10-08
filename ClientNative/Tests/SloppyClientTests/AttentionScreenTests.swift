#if os(macOS)
import AppKit
import Foundation
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyUITestSupport
import SwiftUI
import Testing
@testable import SloppyClient

@Suite("Attention screen", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct AttentionScreenTests {
    @Test(arguments: [ColorScheme.light, .dark], [393.0, 900.0])
    func rendersFindingsAndReadActionUpdatesSharedBadge(colorScheme: ColorScheme, width: Double) async throws {
        let finding = ProactiveFinding(
            id: "qa", agentId: "agent", source: .init(id: "task", kind: .task, title: "APP-125 · Проверить замечания QA", projectId: "project", taskId: "task"),
            revision: "1", outcome: .needsInput,
            reason: "Исполнитель подготовил результат. Для продолжения нужно решение по одному замечанию.",
            evidence: "В задаче появился новый отчёт с шагами воспроизведения и результатами проверки.",
            nextStep: "Проверить приложенный отчёт и подтвердить ожидаемое поведение.", sessionId: "session"
        )
        let inbox = AttentionInbox(fetchAgents: { [.init(id: "agent", displayName: "Engineering agent")] },
                                   fetchInbox: { _ in .init(findings: [finding]) },
                                   updateFinding: { _, _, _ in
            var read = finding
            read.readAt = Date()
            return read
        })
        await inbox.refresh()
        AppKitTestAccessibility.enable()
        let host = NSHostingView(rootView: AttentionScreen(inbox: inbox)
            .environment(\.colorScheme, colorScheme)
            .theme(colorScheme == .dark ? .sloppyDark : .sloppyLight))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width < 400 ? 1100 : 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(inbox.unreadCount == 1)
        if let path = ProcessInfo.processInfo.environment["SLOPPY_ATTENTION_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("attention-\(colorScheme == .dark ? "dark" : "light")-\(Int(width)).png"))
        }
        let readButton = try #require(AppKitTestAccessibility.element(in: host, identifier: "attention.read.qa"))
        #expect(AppKitTestAccessibility.press(readButton))
        for _ in 0..<20 where inbox.unreadCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(inbox.unreadCount == 0)
        #expect(AppKitTestAccessibility.element(in: host, identifier: "attention.finding.qa") != nil)

    }
}
#endif
