import Foundation
import CoreGraphics
import SloppyComputerControl

/// Input is posted on MainActor. Typing yields between graphemes so Stop revokes the remainder.
@MainActor
struct DesktopComputerInput {
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    func click(_ input: DesktopComputerCommand.Input) throws {
        guard let x = input.x, let y = input.y,
              x.isFinite, y.isFinite, (input.width ?? 0).isFinite, (input.height ?? 0).isFinite,
              (input.width ?? 0) >= 0, (input.height ?? 0) >= 0 else {
            throw ComputerControlError.invalidArguments("The click requires finite screen coordinates and positive bounds.")
        }
        let point = CGPoint(x: x + (input.width ?? 0) / 2, y: y + (input.height ?? 0) / 2)
        guard point.x.isFinite, point.y.isFinite else {
            throw ComputerControlError.invalidArguments("The click lies outside the valid coordinate range.")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerControlError.operationFailed("Could not create mouse events.")
        }
        post(down)
        post(up)
    }

    func type(_ text: String, canContinue: () -> Bool) async throws {
        guard !text.isEmpty else { throw ComputerControlError.invalidArguments("Text is required.") }
        for character in text {
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerControlError.operationFailed("Could not create text events.")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            post(down)
            post(up)
            await Task.yield()
        }
    }

    func key(_ input: DesktopComputerCommand.Input) throws {
        guard let key = input.key?.lowercased(), let code = Self.keyCodes[key] else {
            throw ComputerControlError.invalidArguments("Unsupported keyboard key.")
        }
        var flags = CGEventFlags()
        for modifier in input.modifiers ?? [] {
            switch modifier.lowercased() {
            case "command", "cmd", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: throw ComputerControlError.invalidArguments("Unsupported keyboard modifier.")
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw ComputerControlError.operationFailed("Could not create keyboard events.")
        }
        down.flags = flags
        up.flags = flags
        post(down)
        post(up)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
}
