#if os(macOS)
import AppKit
import Testing
import SloppyUITestSupport
import WebKit
@testable import SloppyClient

@Suite("Workspace browser behavior", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct WorkspaceBrowserRuntimeTests {
    private func loadedRuntime() async throws -> WorkspaceBrowserToolRuntime {
        let runtime = WorkspaceBrowserToolRuntime()
        runtime.webView.loadHTMLString("""
        <!doctype html><title>Browser fixture</title>
        <button id="increment" onclick="document.querySelector('#result').textContent='Clicked'">Increment</button>
        <button disabled id="disabled">Disabled</button>
        <textarea id="editor" oninput="document.querySelector('#result').textContent=this.value"></textarea>
        <div id="result">Ready</div><div style="height:2000px"></div>
        <button id="bottom">Bottom</button>
        """, baseURL: nil)
        _ = try await runtime.read()
        return runtime
    }

    @Test func readsElementsAndVerifiesClick() async throws {
        let runtime = try await loadedRuntime()
        let before = try await runtime.read()
        #expect(before.title == "Browser fixture")
        #expect(before.elements.contains { $0.selector == "#increment" && $0.name == "Increment" })
        #expect(before.elements.contains { $0.selector == "#disabled" && $0.disabled })
        _ = try await runtime.click(selector: "#increment")
        #expect(try await runtime.read().visibleText.contains("Clicked"))
    }

    @Test func typingPreservesMultilineAndQuotesAndFiresInput() async throws {
        let runtime = try await loadedRuntime()
        let text = "first line\n'quote' \\ backslash ` ${literal}"
        _ = try await runtime.type(selector: "#editor", text: text)
        let typed = try await runtime.webView.evaluateJavaScript("document.querySelector('#editor').value") as? String
        let observed = try await runtime.webView.evaluateJavaScript("document.querySelector('#result').textContent") as? String
        #expect(typed == text)
        #expect(observed == text)
        _ = try await runtime.type(selector: "#editor", text: "")
        let value = try await runtime.webView.evaluateJavaScript("document.querySelector('#editor').value") as? String
        #expect(value == "")
    }

    @Test func rejectsMissingAmbiguousDisabledAndUnsafeNavigation() async throws {
        let runtime = try await loadedRuntime()
        await #expect(throws: (any Error).self) { try await runtime.click(selector: "#missing") }
        await #expect(throws: (any Error).self) { try await runtime.click(selector: "button") }
        await #expect(throws: (any Error).self) { try await runtime.click(selector: "#disabled") }
        #expect(throws: (any Error).self) { try WorkspaceBrowserToolRuntime.resolveURL("file:///etc/passwd") }
        #expect(throws: (any Error).self) { try WorkspaceBrowserToolRuntime.resolveURL("javascript://alert(1)") }
        #expect(try WorkspaceBrowserToolRuntime.resolveURL(" localhost:8080 ").absoluteString == "https://localhost:8080")
    }

    @Test func opensBlankAndRetainsPageAcrossPanelOwnership() async throws {
        let model = WorkspaceWebViewModel()
        let runtime = model.ensureBrowserRuntime()
        #expect(model.ensureBrowserRuntime() === runtime)
        #expect(try await runtime.open(url: "about:blank").url == "about:blank")
    }

    @Test func opensHTTPPageWaitsForLoadAndCapturesResult() async throws {
        let server = try BrowserHTTPFixture()
        let url = try await server.start()
        let runtime = WorkspaceBrowserToolRuntime()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = runtime.webView
        defer { window.orderOut(nil) }
        let loaded = try await runtime.open(url: url.absoluteString)
        #expect(loaded.title == "Loaded through HTTP")
        #expect(loaded.url == url.absoluteString)
        _ = try await runtime.type(selector: "#name", text: "Sloppy")
        _ = try await runtime.click(selector: "#check")
        #expect(try await runtime.read().visibleText.contains("Verified: Sloppy"))
        let image = try await runtime.screenshot().imageData
        #expect(image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        if let path = ProcessInfo.processInfo.environment["SLOPPY_BROWSER_SMOKE_SCREENSHOT"] {
            try image.write(to: URL(fileURLWithPath: path))
        }
        withExtendedLifetime(server) {}
    }

    @Test func scrollsToObservedElement() async throws {
        let runtime = try await loadedRuntime()
        _ = try await runtime.scrollTo(selector: "#bottom")
        let y = try await runtime.webView.evaluateJavaScript("window.scrollY") as? Double
        #expect((y ?? 0) > 0)
    }
}
#endif
