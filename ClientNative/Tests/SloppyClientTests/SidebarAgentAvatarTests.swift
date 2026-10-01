#if os(macOS)
import AppKit
import ImageIO
import SloppyClientCore
import SloppyClientUI
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import SloppyClient

@Suite("Sidebar agent avatars", .serialized)
@MainActor
struct SidebarAgentAvatarTests {
    @Test func activitiesSelectExpressionsFromTypedState() {
        #expect(SidebarSessionActivity.working.avatarEmotion == .working)
        #expect(SidebarSessionActivity.waitingForInput.avatarEmotion == .needsInput)
        #expect(SidebarSessionActivity.failed.avatarEmotion == .error)
        #expect(SidebarSessionActivity.completed.avatarEmotion == .happy)
    }

    @Test func nativeChatRowsRenderCharactersAndAnimate() async throws {
        let host = NSHostingView(rootView: SidebarAvatarFixture()
            .environment(\.theme, .sloppyDark)
            .environment(\.scenePhase, .active)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 348, height: 390),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let first = try snapshot(host)
        try await Task.sleep(for: .milliseconds(300))
        let second = try snapshot(host)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(first.representation(using: .png, properties: [:]) != second.representation(using: .png, properties: [:]))
        }
        // All five rows must contain a colored character in the leading column.
        let scale = CGFloat(second.pixelsWide) / host.bounds.width
        for row in 0..<5 {
            var coloredPixels = 0
            for x in 18..<50 {
                for y in (62 + row * 58)..<(96 + row * 58) {
                    let color = try #require(second.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
                    if max(color.redComponent, color.greenComponent, color.blueComponent)
                        - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.08 {
                        coloredPixels += 1
                    }
                }
            }
            #expect(coloredPixels > 20)
        }
        guard let directory = ProcessInfo.processInfo.environment["SLOPPY_SIDEBAR_SCREENSHOTS"] else { return }
        let baseURL = URL(fileURLWithPath: directory)
        try #require(second.representation(using: .png, properties: [:]))
            .write(to: baseURL.appendingPathComponent("sidebar-agent-avatars.png"))
        let destination = try #require(CGImageDestinationCreateWithURL(
            baseURL.appendingPathComponent("sidebar-agent-avatars.gif") as CFURL,
            UTType.gif.identifier as CFString, 44, nil
        ))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for _ in 0..<44 {
            try await Task.sleep(for: .milliseconds(100))
            let image = try #require(snapshot(host).cgImage)
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))

        host.rootView = SidebarAvatarFixture()
            .environment(\.theme, .sloppyDark)
            .environment(\.scenePhase, .background)
            .preferredColorScheme(.dark)
        try await Task.sleep(for: .milliseconds(250))
        let backgroundFrame = try snapshot(host).representation(using: .png, properties: [:])
        try await Task.sleep(for: .milliseconds(300))
        let nextBackgroundFrame = try snapshot(host).representation(using: .png, properties: [:])
        #expect(backgroundFrame == nextBackgroundFrame)
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}

private struct SidebarAvatarFixture: View {
    private let states: [SidebarSessionActivity?] = [nil, .working, .waitingForInput, .failed, .completed]
    private let titles = ["Plan the release", "Update the client", "Review deployment", "Check the build", "Parallel agents"]
    private let agents = ["a", "b", "c", "d", "a"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sloppy").font(.headline).foregroundStyle(.secondary).padding(.leading, 12).frame(height: 40)
            ForEach(0..<5, id: \.self) { index in
                SidebarSessionRow(
                    session: .init(id: "fixture-\(index)", agentId: agents[index], title: titles[index]),
                    projectName: "Sloppy", instanceName: "home_machine", showsProjectName: false,
                    isPinned: false, isSelected: index == 1, activity: states[index],
                    avatarAgents: index == 4 ? [
                        .init(id: "parent", agentID: "a", paletteID: "mint"),
                        .init(id: "child-1", agentID: "b", paletteID: "violet", emotion: .working),
                        .init(id: "child-2", agentID: "c", paletteID: "coral", emotion: .thinking)
                    ] : [],
                    onOpen: {}, onTogglePin: {}, onCopyDebugLink: {}, onDelete: {}
                )
                .frame(height: 54)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 348, height: 390)
        .background(AppTheme.sloppyDark.colors.background)
    }
}
#endif
