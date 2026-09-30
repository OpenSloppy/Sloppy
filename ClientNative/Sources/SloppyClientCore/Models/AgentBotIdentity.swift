import Foundation

/// A stable identity shared with the dashboard and Core's bundled bot catalog.
public enum AgentBotIdentity {
    public static let shapes = ["circle", "triangle", "diamond", "square"]

    public static func seed(for agentID: String) -> UInt32 {
        agentID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    public static func shape(for agentID: String) -> String {
        shapes[Int(seed(for: agentID) % UInt32(shapes.count))]
    }

    public static let palettes: [AgentBotPalette] = [
        .init(id: "mint", body: 0x42C9B5, eyes: 0xFFF9ED),
        .init(id: "violet", body: 0x9C8FFF, eyes: 0xFFF9ED),
        .init(id: "coral", body: 0xFF8A65, eyes: 0xFFF7E7),
        .init(id: "amber", body: 0xF4C657, eyes: 0x473023),
        .init(id: "sky", body: 0x60B9EC, eyes: 0xF6FBFF),
        .init(id: "rose", body: 0xF295BB, eyes: 0x493048),
        .init(id: "lime", body: 0xACD66B, eyes: 0x294732),
        .init(id: "graphite", body: 0x636B82, eyes: 0xFAF7EE)
    ]

    public static func palette(for agentID: String, paletteID: String? = nil) -> AgentBotPalette {
        palettes.first { $0.id == paletteID } ?? palettes[Int((seed(for: agentID) >> 8) % UInt32(palettes.count))]
    }

    public static func eyeSize(for agentID: String) -> (width: Double, height: Double) {
        switch shape(for: agentID) {
        case "circle": (1.9, 4.2)
        case "triangle": (2.3, 2.3)
        default: (2.3, 2.3)
        }
    }

    public static func eyeBaseline(for agentID: String) -> Double {
        shape(for: agentID) == "triangle" ? 0.25 : 1.2
    }
}

public struct AgentBotPalette: Equatable, Sendable {
    public let id: String
    public let body: UInt32
    public let eyes: UInt32
}

public enum AgentBotEmotion: String, Sendable {
    case idle, working, thinking, needsInput, error, happy, surprised, angry
}

public struct AgentBotEyePose: Equatable, Sendable {
    public var scaleX = 1.0
    public var leftScaleY = 1.0
    public var rightScaleY = 1.0
    public var leftRotation = 0.0
    public var rightRotation = 0.0
    public var isSmiling = false

    public static func resolve(emotion: AgentBotEmotion, elapsed: Double, reducedMotion: Bool = false) -> Self {
        var pose = Self()
        switch emotion {
        case .happy: pose.isSmiling = true
        case .surprised:
            pose.scaleX = 1.25; pose.leftScaleY = 1.3; pose.rightScaleY = 1.3
        case .angry:
            pose.scaleX = 1.4; pose.leftScaleY = 0.3; pose.rightScaleY = 0.3
            pose.leftRotation = -0.38; pose.rightRotation = 0.38
        case .error:
            pose.scaleX = 1.25; pose.leftScaleY = 0.35; pose.rightScaleY = 0.35
            pose.leftRotation = 0.18; pose.rightRotation = -0.18
        case .thinking: pose.leftScaleY = 0.65
        case .needsInput: pose.leftScaleY = 1.2; pose.rightScaleY = 0.8
        case .idle, .working: break
        }
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 4.2)
        if !reducedMotion, !pose.isSmiling, phase >= 3.8, phase < 4.0 {
            let blink = max(0.07, abs((phase - 3.9) / 0.1))
            pose.leftScaleY *= blink; pose.rightScaleY *= blink
        }
        return pose
    }
}

public struct APIAgentBotPet: Codable, Sendable {
    public struct Visual: Codable, Sendable {
        public var paletteId: String?
        public init(paletteId: String? = nil) { self.paletteId = paletteId }
    }
    public var visual: Visual?
    public init(visual: Visual? = nil) { self.visual = visual }
}
