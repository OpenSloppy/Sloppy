import Foundation

/// A brief greeting that leaves the agent's underlying activity unchanged.
public struct AgentBotHoverReaction: Equatable, Sendable {
    public let emotion: AgentBotEmotion
    public var motion = AgentBotMotionPose()

    public static func resolve(
        baseEmotion: AgentBotEmotion, isHovered: Bool, elapsed: Double, reducedMotion: Bool = false
    ) -> Self {
        guard isHovered else { return Self(emotion: baseEmotion) }
        let time = max(0, elapsed)
        var reaction = Self(emotion: reducedMotion || time >= 0.18 ? .happy : .surprised)
        guard !reducedMotion else { return reaction }

        // Anticipation, a hop, then a smaller rebound and a soft landing.
        if time < 0.08 {
            let squash = sin(time / 0.08 * .pi) * 0.08
            reaction.motion.scaleX = 1 + squash
            reaction.motion.scaleY = 1 - squash
        } else if time < 0.44 {
            let progress = (time - 0.08) / 0.36
            let lift = sin(progress * .pi)
            reaction.motion.offsetY = -lift * 0.18
            reaction.motion.scaleX = 1 - lift * 0.04
            reaction.motion.scaleY = 1 + lift * 0.06
            reaction.motion.rotation = sin(progress * .pi * 2) * 5
        } else if time < 0.66 {
            let progress = (time - 0.44) / 0.22
            reaction.motion.offsetY = -sin(progress * .pi) * 0.055
        } else if time < 0.78 {
            let squash = sin((time - 0.66) / 0.12 * .pi) * 0.04
            reaction.motion.scaleX = 1 + squash
            reaction.motion.scaleY = 1 - squash
        }
        return reaction
    }
}
