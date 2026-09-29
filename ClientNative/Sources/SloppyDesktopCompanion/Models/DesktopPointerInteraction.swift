import Foundation

enum DesktopPointerAction: String, CaseIterable, Identifiable {
    case write, region, regionVoice, voice, window, chat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .write: "Write"
        case .region: "Area"
        case .regionVoice: "Area + Voice"
        case .voice: "Speak"
        case .window: "Window"
        case .chat: "Chat"
        }
    }
    var symbol: String {
        switch self {
        case .write: "text.cursor"
        case .region: "crop"
        case .regionVoice: "viewfinder"
        case .voice: "mic.fill"
        case .window: "macwindow"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    static func at(offset: CGPoint, deadZone: CGFloat = 32) -> Self? {
        guard hypot(offset.x, offset.y) >= deadZone else { return nil }
        let count = CGFloat(allCases.count)
        let angle = atan2(offset.x, offset.y)
        let index = Int((angle / (2 * .pi) * count).rounded())
        return allCases[(index % allCases.count + allCases.count) % allCases.count]
    }

    static func at(pointer: CGPoint, wheelCenter: CGPoint, invocationPoint: CGPoint) -> Self? {
        guard hypot(pointer.x - invocationPoint.x, pointer.y - invocationPoint.y) >= 32 else { return nil }
        return at(offset: CGPoint(x: pointer.x - wheelCenter.x, y: pointer.y - wheelCenter.y))
    }
}

enum DesktopPointerShortcutMode: String, CaseIterable, Identifiable, Sendable {
    case optionSpace = "option-space"
    case modifier

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "None (⌥ Space only)"
        case .modifier: "Modifier key gestures"
        }
    }
}

enum DesktopPointerModifier: UInt16 {
    case rightCommand = 54, leftOption = 58, rightOption = 61

    // Device-specific modifier bits from IOKit/hidsystem/IOLLEvent.h.
    var deviceMask: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .leftOption: 0x20
        case .rightOption: 0x40
        }
    }

    func isStandalone(rawFlags: UInt64) -> Bool {
        let siblingMask: UInt64 = switch self {
        case .rightCommand: 0x08
        case .leftOption: 0x40
        case .rightOption: 0x20
        }
        let familyMask: UInt64 = self == .rightCommand ? 0x100000 : 0x080000
        let otherModifiers = rawFlags & 0x1E0000 & ~familyMask
        return rawFlags & deviceMask != 0 && rawFlags & siblingMask == 0 && otherModifiers == 0
    }
}

/// Only a standalone modifier invokes the pointer. Ordinary combinations cancel it.
struct DesktopPointerShortcutState {
    enum Release: Equatable { case tap, wheel }
    private(set) var pressedAt: TimeInterval?
    private(set) var wheelPresented = false

    mutating func press(at time: TimeInterval) {
        guard pressedAt == nil else { return }
        pressedAt = time
        wheelPresented = false
    }

    mutating func presentWheel(at time: TimeInterval) -> Bool {
        guard let pressedAt, time - pressedAt >= 0.25, !wheelPresented else { return false }
        wheelPresented = true
        return true
    }

    mutating func release() -> Release? {
        guard pressedAt != nil else { return nil }
        let result: Release = wheelPresented ? .wheel : .tap
        cancel()
        return result
    }

    mutating func cancel() { pressedAt = nil; wheelPresented = false }
}

struct DesktopPointerTapSequence {
    private var previous: (keyCode: UInt16, time: TimeInterval)?

    mutating func registerTap(keyCode: UInt16, at time: TimeInterval) -> Bool {
        if let previous, previous.keyCode == keyCode, time >= previous.time, time - previous.time <= 0.3 {
            self.previous = nil
            return true
        }
        previous = (keyCode, time)
        return false
    }

    mutating func cancel() { previous = nil }
}

enum DesktopPointerGeometry {
    static func anchor(for frame: CGRect, orbOffset: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + orbOffset.x, y: frame.minY + orbOffset.y)
    }

    static func panelFrame(anchor: CGPoint, size: CGSize, visibleFrame: CGRect, orbOffset: CGPoint) -> CGRect {
        let proposed = CGPoint(x: anchor.x - orbOffset.x, y: anchor.y - orbOffset.y)
        return CGRect(
            x: min(max(proposed.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
            y: min(max(proposed.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height)),
            width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height)
        )
    }

    static func quartzRect(_ appKitRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryScreenTop - appKitRect.maxY,
               width: appKitRect.width, height: appKitRect.height)
    }
}
