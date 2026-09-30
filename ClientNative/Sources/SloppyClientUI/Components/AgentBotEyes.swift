import SwiftUI
import SloppyClientCore
#if os(macOS)
import AppKit
#endif

extension AgentBotPalette {
    public var bodyColor: Color { color(body) }
    public var eyeColor: Color { color(eyes) }

    private func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }

    #if os(macOS)
    public var bodyNSColor: NSColor { nsColor(body) }
    public var eyeNSColor: NSColor { nsColor(eyes) }
    private func nsColor(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    #endif
}

public struct AgentBotEyes: View {
    public let agentID: String
    public var paletteID: String? = nil
    public var emotion: AgentBotEmotion = .idle

    public init(agentID: String, paletteID: String? = nil, emotion: AgentBotEmotion = .idle) {
        self.agentID = agentID; self.paletteID = paletteID; self.emotion = emotion
    }

    public var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 24
            let metrics = AgentBotIdentity.eyeSize(for: agentID)
            let pose = AgentBotEyePose.resolve(emotion: emotion, elapsed: 0)
            let color = AgentBotIdentity.palette(for: agentID, paletteID: paletteID).eyeColor
            ForEach(0..<2, id: \.self) { index in
                eye(smiling: pose.isSmiling, color: color)
                    .frame(width: metrics.width * unit, height: (pose.isSmiling ? 1.5 : metrics.height) * unit)
                    .scaleEffect(x: pose.scaleX, y: index == 0 ? pose.leftScaleY : pose.rightScaleY)
                    .rotationEffect(.radians(-(index == 0 ? pose.leftRotation : pose.rightRotation)))
                    .position(x: geometry.size.width / 2 + (index == 0 ? -2.45 : 2.45) * unit,
                              y: geometry.size.height / 2 - AgentBotIdentity.eyeBaseline(for: agentID) * unit)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func eye(smiling: Bool, color: Color) -> some View {
        if smiling {
            BotSmileEye().stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        } else {
            switch AgentBotIdentity.shape(for: agentID) {
            case "circle": Capsule().fill(color)
            case "triangle": Circle().fill(color)
            case "diamond": BotRoundedEye().fill(color).rotationEffect(.degrees(45))
            default: BotRoundedEye().fill(color)
            }
        }
    }
}

private struct BotSmileEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private struct BotRoundedEye: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.22)
    }
}
