#if os(macOS)
import AppKit
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import Testing
import SloppyUITestSupport
@testable import SloppyClient

@Suite("Sidebar and project navigation", .serialized, .appKitUI)
@MainActor
struct SidebarChromeRenderingTests {
    @Test func sessionActivityUsesTypedRunState() {
        #expect(SidebarSessionActivity.resolve(runStage: .thinking) == .working)
        #expect(SidebarSessionActivity.resolve(runStage: .responding) == .working)
        #expect(SidebarSessionActivity.resolve(runStage: .done) == .completed)
        #expect(SidebarSessionActivity.resolve(runStage: .interrupted) == .failed)
        #expect(SidebarSessionActivity.resolve(hasPendingInputRequest: true, runStage: .responding) == .waitingForInput)
        #expect(SidebarSessionActivity.resolve(runStage: nil) == nil)
    }

    @Test func completedAndFailedIndicatorsClearOnlyForViewedEvent() {
        for activity in [SidebarSessionActivity.completed, .failed] {
            let result = SidebarSessionActivityRecord(activity: activity, eventID: "run-2")
            #expect(result.visibleActivity(readEventID: nil) == activity)
            #expect(result.visibleActivity(readEventID: "run-1") == activity)
            #expect(result.visibleActivity(readEventID: "run-2") == nil)
        }
        let waiting = SidebarSessionActivityRecord(activity: .waitingForInput, eventID: "run-2")
        #expect(waiting.visibleActivity(readEventID: "run-2") == .waitingForInput)
    }

    @Test func sidebarFadesScrolledCardsAndFooterIsOpaque() async throws {
        let projects = (0..<4).map { index in
            APIProjectRecord(id: "sidebar-fixture-\(index)", name: "Project \(index + 1)",
                             description: "Project description", tasks: [
                                .init(id: "1", title: "Working", status: "in_progress"),
                                .init(id: "2", title: "Review", status: "needs_review"),
                                .init(id: "3", title: "Working", status: "in_progress"),
                             ])
        }
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(projects) { project in
                        VStack(alignment: .leading) {
                            Text(project.name).font(.headline)
                            Spacer()
                            SidebarProjectTaskCounts(project: project)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .background(AppTheme.sloppyDark.colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 24))
                    }
                }.padding(.horizontal, 8)
            }
            .modifier(SidebarScrollFade())
            HStack { Text("All instances"); Spacer(); Image(systemName: "gearshape") }
                .padding(.horizontal, 16).frame(height: 64)
                .background(SidebarFooterBackground())
                .background(.red)
        }
        .background(AppTheme.sloppyDark.colors.background)
        .environment(\.theme, .sloppyDark)
        .preferredColorScheme(.dark))
        let window = makeWindow(host, width: 300, height: 580)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let before = try snapshot(host)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(250))
        let after = try snapshot(host)
        let x = after.pixelsWide / 2
        let topBefore = try #require(before.colorAt(x: x, y: 2)?.usingColorSpace(.sRGB))
        let topAfter = try #require(after.colorAt(x: x, y: 2)?.usingColorSpace(.sRGB))
        #expect(topAfter.redComponent < topBefore.redComponent - 0.02)
        let footer = try #require(after.colorAt(x: x, y: after.pixelsHigh - 12)?.usingColorSpace(.sRGB))
        let background = try #require(after.colorAt(x: 2, y: after.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(abs(footer.redComponent - background.redComponent) < 0.01)
        #expect(abs(footer.greenComponent - footer.redComponent) < 0.01)
        try save(after, name: "sidebar-fade-and-footer.png")
    }

    @Test func commandNumberSelectsMatchingSectionAndDisablesOutsideProject() async throws {
        var selected: ProjectModeSection?
        let context = ProjectModeCommandContext(selectedSection: .kanban) { selected = $0 }
        let host = NSHostingView(rootView: VStack { ProjectModeSelectionButtons(context: context) })
        let window = makeWindow(host, width: 260, height: 240)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        for (section, code) in zip(ProjectModeSection.allCases, [18, 19, 20, 21]) {
            let event = try keyEvent(section.shortcutCharacter, code: UInt16(code), window: window)
            #expect(host.performKeyEquivalent(with: event))
            #expect(selected == section)
        }
        host.rootView = VStack { ProjectModeSelectionButtons(context: nil) }
        selected = nil
        try await Task.sleep(for: .milliseconds(100))
        _ = host.performKeyEquivalent(with: try keyEvent("1", code: 18, window: window))
        #expect(selected == nil)
    }

    @Test func projectSectionsRenderVerticallyOnRight() async throws {
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            Text("Project workspace").frame(maxWidth: .infinity, maxHeight: .infinity)
            ProjectModeRail(selectedSection: .chats, onSelect: { _ in })
        }
        .background(AppTheme.sloppyDark.colors.background)
        .environment(\.theme, .sloppyDark)
        .preferredColorScheme(.dark))
        let window = makeWindow(host, width: 760, height: 500)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let before = try snapshot(host)
        let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 730, y: 467), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        window.makeKeyAndOrderFront(nil)
        window.sendEvent(move)
        for view in [host] + descendants(host) {
            for area in view.trackingAreas {
                let point = view.convert(move.locationInWindow, from: nil)
                let rect = area.options.contains(.inVisibleRect) ? view.bounds : area.rect
                if rect.contains(point) {
                    if let responder = area.owner as? NSResponder {
                        // Route the same pointer location through the owning AppKit tracking responder.
                        responder.mouseEntered(with: move)
                    }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(350))
        let after = try snapshot(host)
        #expect(before.representation(using: .png, properties: [:]) != after.representation(using: .png, properties: [:]))
        try save(after, name: "project-navigation-right.png")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func makeWindow(_ view: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SLOPPY_SIDEBAR_SCREENSHOTS"] else { return }
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func keyEvent(_ character: Character, code: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code))
    }
}
#endif
