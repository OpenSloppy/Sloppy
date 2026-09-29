import Foundation
import AppKit
import ScreenCaptureKit
import SloppyClientCore

struct DesktopPointerContext: Sendable {
    var application: String
    var applicationPID: Int32?
    var selectedText: String?
    var elementRole: String?
    var elementTitle: String?
    var elementFrame: CGRect?
    var pointer: CGPoint
    var quartzPointer: CGPoint
    var capturedAt: Date

    var summary: String {
        [application, elementTitle, selectedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct DesktopImageCapture: Sendable {
    var png: Data
    var frame: CGRect
    var displayId: String
    var width: Int
    var height: Int

    var attachment: ChatAttachmentUpload {
        .init(name: "Desktop context.png", mimeType: "image/png", sizeBytes: png.count, contentBase64: png.base64EncodedString())
    }

    var result: DesktopComputerCompletion.Result {
        .init(width: width, height: height, displayId: displayId,
              screenX: frame.minX, screenY: frame.minY, screenWidth: frame.width, screenHeight: frame.height,
              scaleX: CGFloat(width) / frame.width, scaleY: CGFloat(height) / frame.height)
    }
}

enum DesktopCaptureError: LocalizedError {
    case screenPermission, missingDisplay, missingWindow, invalidRegion, encodeFailed
    var errorDescription: String? {
        switch self {
        case .screenPermission: "Allow screen recording for Sloppy Desktop Companion in System Settings."
        case .missingDisplay: "This display is no longer connected. Select the area again."
        case .missingWindow: "Could not find the window under the pointer. Select an area instead."
        case .invalidRegion: "Select an area of at least 4 × 4 points on a single display."
        case .encodeFailed: "Could not save the screen image."
        }
    }
}

@MainActor
final class DesktopContextCapture {
    var excludedWindowIDs: Set<CGWindowID> = []
    var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    func context(at point: CGPoint) -> DesktopPointerContext {
        var result = DesktopPointerContext(application: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Desktop",
                                           applicationPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                           pointer: point,
                                           quartzPointer: CGPoint(x: point.x, y: primaryTop - point.y), capturedAt: Date())
        guard AXIsProcessTrusted() else { return result }
        let position = DesktopPointerGeometry.quartzRect(CGRect(origin: point, size: .zero), primaryScreenTop: primaryTop).origin
        var resolvedElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(position.x), Float(position.y), &resolvedElement) == .success,
              let initialElement = resolvedElement else { return result }
        var element = initialElement
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            // A full-screen click-through trail window must not become the semantic target.
            if pid == ProcessInfo.processInfo.processIdentifier,
               let underlyingPID = applicationUnderPointer(at: position), underlyingPID != pid {
                var underlying: AXUIElement?
                if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(underlyingPID), Float(position.x), Float(position.y), &underlying) == .success,
                   let underlying {
                    element = underlying
                    pid = underlyingPID
                }
            }
            result.application = NSRunningApplication(processIdentifier: pid)?.localizedName ?? result.application
            result.applicationPID = pid
        }
        result.elementRole = stringAttribute(kAXRoleAttribute, of: element)
        result.elementTitle = stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXDescriptionAttribute, of: element)
        result.selectedText = stringAttribute(kAXSelectedTextAttribute, of: element)
        if stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole as String {
            result.selectedText = nil
            result.elementTitle = nil
        }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue,
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                result.elementFrame = CGRect(origin: origin, size: size)
            }
        }
        return result
    }

    func captureRegion(appKitFrame: CGRect) async throws -> DesktopImageCapture {
        guard appKitFrame.width >= 4, appKitFrame.height >= 4,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitFrame) }) else {
            throw DesktopCaptureError.invalidRegion
        }
        return try await capture(quartzFrame: DesktopPointerGeometry.quartzRect(appKitFrame, primaryScreenTop: primaryTop), screen: screen)
    }

    func capturePoint(_ context: DesktopPointerContext) async throws -> DesktopImageCapture {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(context.pointer) }) else { throw DesktopCaptureError.missingDisplay }
        let screenRect = DesktopPointerGeometry.quartzRect(screen.frame, primaryScreenTop: primaryTop)
        let point = CGPoint(x: context.pointer.x, y: primaryTop - context.pointer.y)
        let proposed = context.elementFrame.flatMap { frame in
            frame.width >= 20 && frame.height >= 20 && frame.width <= 1200 && frame.height <= 900 ? frame.insetBy(dx: -16, dy: -16) : nil
        } ?? CGRect(x: point.x - 320, y: point.y - 220, width: 640, height: 440)
        return try await capture(quartzFrame: proposed.intersection(screenRect), screen: screen)
    }

    func captureWindow(at point: CGPoint) async throws -> DesktopImageCapture {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { throw DesktopCaptureError.missingDisplay }
        let quartzPoint = CGPoint(x: point.x, y: primaryTop - point.y)
        let content = try await shareableContent()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  !excludedWindowIDs.contains(number.uint32Value),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(quartzPoint),
                  let window = content.windows.first(where: { $0.windowID == number.uint32Value }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * screen.backingScaleFactor)
            config.height = Int(window.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            return try makeCapture(image, frame: window.frame, displayId: String(displayID(screen)))
        }
        throw DesktopCaptureError.missingWindow
    }

    func captureDisplay(at point: CGPoint) async throws -> DesktopImageCapture {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { throw DesktopCaptureError.missingDisplay }
        return try await capture(quartzFrame: DesktopPointerGeometry.quartzRect(screen.frame, primaryScreenTop: primaryTop), screen: screen)
    }

    private func capture(quartzFrame: CGRect, screen: NSScreen) async throws -> DesktopImageCapture {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID(screen) }) else { throw DesktopCaptureError.missingDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludedWindowIDs.contains($0.windowID) })
        let config = SCStreamConfiguration()
        config.sourceRect = quartzFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(1, Int(quartzFrame.width * screen.backingScaleFactor))
        config.height = max(1, Int(quartzFrame.height * screen.backingScaleFactor))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try makeCapture(image, frame: quartzFrame, displayId: String(display.displayID))
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw DesktopCaptureError.screenPermission }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func makeCapture(_ image: CGImage, frame: CGRect, displayId: String) throws -> DesktopImageCapture {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DesktopCaptureError.encodeFailed }
        return .init(png: png, frame: frame, displayId: displayId, width: image.width, height: image.height)
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? String).map { String($0.prefix(8000)) }
    }

    private func applicationUnderPointer(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  !excludedWindowIDs.contains(number.uint32Value),
                  let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != ProcessInfo.processInfo.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            return owner.int32Value
        }
        return nil
    }
}
