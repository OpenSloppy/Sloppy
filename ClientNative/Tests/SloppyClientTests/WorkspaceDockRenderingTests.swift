#if os(macOS)
import AppKit
import SwiftUI
import ScreenCaptureKit
import SloppyClientUI
import Testing
import SloppyUITestSupport
@testable import SloppyClient

@Suite("Workspace dock rendering", .serialized, .appKitUI)
@MainActor
struct WorkspaceDockRenderingTests {
    @Test func blankBrowserToolsOpenTabsAndAddressActionFocusesField() async throws {
        let state = WorkspaceDockState()
        let tab = state.open(.browser)
        let model = try #require(tab.browser)
        let host = NSHostingView(rootView:
            WorkspaceDockView(state: state, onOpen: { state.open($0) }) { tab in
                if let browser = tab.browser {
                    WorkspaceBrowserPanelView(viewModel: browser, onOpenTool: { state.open($0) })
                } else {
                    Text(tab.title)
                }
            }
            .environment(\.theme, .sloppyDark)
            .preferredColorScheme(.dark)
        )
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))

        for width in [320.0, 700.0] {
            window.setContentSize(NSSize(width: width, height: 520))
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["SLOPPY_DOCK_SCREENSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try #require(bitmap.representation(using: .png, properties: [:]))
                try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent("browser-start-\(Int(width)).png"))
            }
        }

        // Send real clicks through the AppKit event path at the fixture's control centers.
        func click(_ point: NSPoint) throws {
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            host.layoutSubtreeIfNeeded()
        }
        try click(NSPoint(x: 350, y: 150))
        #expect(window.firstResponder is NSTextView)
        try click(NSPoint(x: 170, y: 263))
        #expect(state.selectedID == tab.id)
        try click(NSPoint(x: 500, y: 319))
        #expect(state.selectedTab?.kind == .terminal)
        #expect(state.tabs.count == 2)
        #expect(tab.browser === model)
    }

    @Test func middleClickClosesSideTabsAndRevealsTerminalBrowserPicker() async throws {
        let state = WorkspaceDockState()
        state.open(.sideChat)
        state.open(.browser)
        let host = NSHostingView(rootView:
            WorkspaceDockView(state: state, onOpen: { state.open($0) }) { tab in
                Text(tab.title)
            }
            .environment(\.theme, .sloppyDark)
            .preferredColorScheme(.dark)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        for _ in 0..<2 {
            let tabID = try #require(state.tabs.first?.id)
            let closeArea = try #require(descendants(of: host).compactMap {
                $0 as? MiddleClickCloseNSView
            }.first)
            let cgEvent = try #require(CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseUp,
                mouseCursorPosition: .zero,
                mouseButton: .center
            ))
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(event.buttonNumber == 2)
            closeArea.otherMouseUp(with: event)
            try await Task.sleep(for: .milliseconds(50))
            #expect(!state.tabs.contains(where: { $0.id == tabID }))
        }

        #expect(state.tabs.isEmpty)
        #expect(state.isPresented)
        #expect(state.selectedTab == nil)
        if let directory = ProcessInfo.processInfo.environment["SLOPPY_DOCK_SCREENSHOTS"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dock-empty-picker.png"))
        }
    }

    @Test func rendersTabsResizesAndKeepsBlankBrowserDark() async throws {
        let state = WorkspaceDockState()
        let browser = state.open(.browser)
        state.open(.terminal)
        state.open(.sideChat)
        state.select(browser)
        let library = CanvasWorkspaceViewModel()
        var contentFrame = CGRect.zero
        var panelFrame = CGRect.zero
        let host = NSHostingView(rootView: WorkspaceResizableSidePanel(state: state) {
            HStack(spacing: 0) {
                CanvasWorkspaceLibraryView(viewModel: library, allowsProjectSelection: false)
                ProjectModeRail(selectedSection: .workspaces, onSelect: { _ in })
            }
            .background(AppTheme.sloppyDark.colors.background)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel-test")) } action: { contentFrame = $0 }
        } panel: {
            WorkspaceDockView(state: state, onOpen: { state.open($0) }) { tab in
                if let browser = tab.browser {
                    WorkspaceBrowserPanelView(viewModel: browser, onOpenTool: { state.open($0) })
                }
                else { Text(tab.title) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel-test")) } action: { panelFrame = $0 }
        }.coordinateSpace(name: "panel-test").environment(\.theme, .sloppyDark).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 1200, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let webView = try #require(browser.browser?.browserRuntime?.webView)
        let originalWidth = webView.bounds.width
        #expect(abs(originalWidth - 480) < 4)
        #expect(contentFrame.width > 0)
        #expect(abs(contentFrame.maxX - panelFrame.minX) < 0.5)

        // Dispatch real pointer events through this test window's AppKit event path.
        for (type, x) in [(NSEvent.EventType.leftMouseDown, 716.0), (.leftMouseDragged, 516.0), (.leftMouseUp, 516.0)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 350), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(80))
        }
        host.layoutSubtreeIfNeeded()
        #expect(state.preferredWidth > 600)
        #expect(webView.bounds.width > originalWidth + 100)

        state.hide()
        try await Task.sleep(for: .milliseconds(300))
        state.toggleVisibility()
        try await Task.sleep(for: .milliseconds(350))
        #expect(browser.browser?.browserRuntime?.webView === webView)
        #expect(state.selectedID == browser.id)

        if let directory = ProcessInfo.processInfo.environment["SLOPPY_DOCK_SCREENSHOTS"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dock-wide.png"))
            if CGPreflightScreenCaptureAccess() {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                if let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(window.frame.width * window.backingScaleFactor)
                    configuration.height = Int(window.frame.height * window.backingScaleFactor)
                    configuration.showsCursor = false
                    let capture = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
                    let png = try #require(NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dock-wide-window.png"))
                }
            }
        }
    }

    @Test func enterInAddressFieldLoadsPageWithoutOpenButton() async throws {
        let server = try BrowserHTTPFixture()
        let url = try await server.start()
        let model = WorkspaceWebViewModel()
        let host = NSHostingView(rootView: WorkspaceBrowserPanelView(viewModel: model))
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "workspace-browser-address" || $0.placeholderString == "Enter a URL"
        })
        #expect(!descendants(host).compactMap { $0 as? NSButton }.contains { $0.title == "Open" })
        model.addressText = url.absoluteString
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.makeFirstResponder(field))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        for _ in 0..<500 {
            if model.pageTitle == "Loaded through HTTP" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.lastError == nil)
        #expect(model.currentURL == url)
        #expect(try await model.ensureBrowserRuntime().read().title == "Loaded through HTTP")
        #expect(model.pageTitle == "Loaded through HTTP")
        withExtendedLifetime(server) {}
    }

    @Test func terminalRetainsShellAndBufferAcrossViewRemoval() async throws {
        let session = WorkspaceTerminalSession(id: UUID(), workingDirectory: FileManager.default.temporaryDirectory)
        let view = session.localTerminalView()
        defer { session.terminate() }
        let process = try #require(view.process)
        let pid = process.shellPid
        #expect(pid > 0)
        let token = "dock-retained-\(UUID().uuidString)"
        process.send(data: Array("printf '\\n\(token)\\n'\n".utf8)[...])
        for _ in 0..<100 {
            if String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains(token) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let host = NSHostingView(rootView: WorkspaceTerminalMacHostView(session: session, onHostReady: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 350)
        host.layoutSubtreeIfNeeded()
        // This is what happens when SwiftUI switches tabs / hides the panel.
        WorkspaceTerminalMacHostView.dismantleNSView(view, coordinator: .init())
        let restored = session.localTerminalView()
        #expect(restored === view)
        #expect(restored.process.shellPid == pid)
        #expect(String(decoding: restored.getTerminal().getBufferAsData(), as: UTF8.self).contains(token))
        session.terminate()
        #expect(!session.isRunning)
    }
}
#endif
