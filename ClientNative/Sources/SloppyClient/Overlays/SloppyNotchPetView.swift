#if os(macOS)
import AppKit
import QuartzCore
import SpriteKit
import SwiftUI
import SloppyClientUI
import SloppyClientCore

enum SloppyNotchPetState: String, Equatable, Sendable {
    case idle
    case working
    case thinking
    case needsInput
    case error
}

struct SloppyNotchPetView: NSViewRepresentable {
    var agentID: String = "sloppy"
    var paletteID: String?
    var presentationScale: CGFloat = 1
    var state: SloppyNotchPetState = .idle
    var onClick: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> SloppyNotchPetSpriteView {
        SloppyNotchPetSpriteView(
            agentID: agentID,
            paletteID: paletteID,
            presentationScale: presentationScale,
            state: state,
            onClick: onClick
        )
    }

    func updateNSView(_ nsView: SloppyNotchPetSpriteView, context: Context) {
        nsView.setAgentID(agentID)
        nsView.setPaletteID(paletteID)
        nsView.setCommunicationState(state)
        nsView.onClick = onClick
    }

    static func dismantleNSView(_ nsView: SloppyNotchPetSpriteView, coordinator: Void) {
        nsView.stopAnimating()
    }
}

@MainActor
final class SloppyNotchPetSpriteView: SKView {
    private let petScene: SloppyNotchPetScene
    private var animationTimer: Timer?
    private var petTrackingArea: NSTrackingArea?
    var onClick: (@MainActor () -> Void)?

    init(
        agentID: String,
        paletteID: String? = nil,
        presentationScale: CGFloat,
        state: SloppyNotchPetState,
        onClick: (@MainActor () -> Void)?
    ) {
        petScene = SloppyNotchPetScene(
            size: CGSize(width: 24, height: 24),
            agentID: agentID,
            paletteID: paletteID,
            presentationScale: presentationScale,
            communicationState: state
        )
        self.onClick = onClick
        super.init(frame: .zero)
        allowsTransparency = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        preferredFramesPerSecond = 30
        isPaused = false
        petScene.scaleMode = .resizeFill
        presentScene(petScene)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            startAnimating()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let petTrackingArea {
            removeTrackingArea(petTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        petTrackingArea = trackingArea
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        petScene.handlePointerEntered(at: scenePoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        petScene.handlePointerExited()
    }

    override func mouseMoved(with event: NSEvent) {
        petScene.handlePointerMove(at: scenePoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        petScene.handlePointerMove(at: scenePoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        reactToPoke(at: scenePoint(for: event))
        onClick?()
    }

    func setAgentID(_ agentID: String) {
        petScene.setAgentID(agentID)
    }

    func setPaletteID(_ paletteID: String?) {
        petScene.setPaletteID(paletteID)
    }

    func reactToPoke(at point: CGPoint, time: TimeInterval? = nil) {
        petScene.handlePoke(at: point, time: time)
    }

    func setCommunicationState(_ state: SloppyNotchPetState) {
        petScene.setCommunicationState(state)
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1 / 30,
            target: self,
            selector: #selector(advanceAnimation),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1 / 120
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func advanceAnimation() {
        advanceFrame(to: CACurrentMediaTime())
    }

    func advanceFrame(to time: TimeInterval, pointer: CGPoint? = nil) {
        isPaused = false
        petScene.advanceFrame(to: time, pointer: pointer ?? pointerPositionInScene())
    }

    private func pointerPositionInScene() -> CGPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = convert(windowPoint, from: nil)
        return petScene.convertPoint(fromView: viewPoint)
    }

    private func scenePoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return petScene.convertPoint(fromView: viewPoint)
    }
}

@MainActor
private final class SloppyNotchPetScene: SKScene {
    private enum Reaction: Equatable {
        case none
        case happy
        case surprised
        case angry
    }

    private typealias Expression = AgentBotEmotion

    private let glowNode = SKNode()
    private let characterNode = SKNode()
    private let bodyNode = SKSpriteNode()
    private let leftEyeNode = SKShapeNode()
    private let rightEyeNode = SKShapeNode()
    private var bodyTextureIdentity: String?
    private var paletteID: String?
    private var eyeOffset = CGVector.zero
    private var eyesAreSmiling = false
    private var agentID: String
    private let thoughtBubbleNode = SKShapeNode(circleOfRadius: 2.7)
    private let bubbleSymbolNode = SKLabelNode(fontNamed: "SFProRounded-Semibold")
    private let presentationScale: CGFloat
    private var communicationState: SloppyNotchPetState

    private var startedAt: TimeInterval?
    private var lastUpdate: TimeInterval = 0
    private var gazeRotation: CGFloat = 0
    private var bubbleAlpha: CGFloat = 0
    private var reaction: Reaction = .none
    private var reactionEndsAt: TimeInterval = 0
    private var pokeTimes: [TimeInterval] = []
    private var lastPetPoint: CGPoint?
    private var pettingDistance: CGFloat = 0
    private var lastPetMoveAt: TimeInterval = 0

    init(
        size: CGSize,
        agentID: String,
        paletteID: String?,
        presentationScale: CGFloat,
        communicationState: SloppyNotchPetState
    ) {
        self.agentID = agentID
        self.paletteID = paletteID
        self.presentationScale = presentationScale
        self.communicationState = communicationState
        super.init(size: size)
        backgroundColor = .clear
        anchorPoint = .zero
    }

    required init?(coder aDecoder: NSCoder) {
        nil
    }

    override func didMove(to view: SKView) {
        buildScene()
        layoutScene()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layoutScene()
    }

    func advanceFrame(to currentTime: TimeInterval, pointer: CGPoint?) {
        if startedAt == nil {
            startedAt = currentTime
            lastUpdate = currentTime
        }
        guard let startedAt else { return }

        let elapsed = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : currentTime - startedAt
        let delta = min(max(currentTime - lastUpdate, 0), 1 / 15)
        lastUpdate = currentTime
        if reaction != .none, currentTime >= reactionEndsAt {
            reaction = .none
        }
        let expression = currentExpression

        let dx = (pointer?.x ?? characterNode.position.x) - characterNode.position.x
        let target = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : max(-0.06, min(0.06, dx * 0.002))
        gazeRotation += (target - gazeRotation) * min(CGFloat(delta * 12), 1)
        updateEyes(pointer: pointer, expression: expression, elapsed: elapsed, delta: delta)
        updateBody(expression: expression, elapsed: elapsed, delta: delta)
    }

    func setAgentID(_ agentID: String) {
        guard self.agentID != agentID else { return }
        self.agentID = agentID
        updateTexture()
    }

    func setPaletteID(_ paletteID: String?) {
        guard self.paletteID != paletteID else { return }
        self.paletteID = paletteID
        applyPalette()
    }

    private func applyPalette() {
        let palette = AgentBotIdentity.palette(for: agentID, paletteID: paletteID)
        let identity = AgentBotIdentity.shape(for: agentID) + "/" + palette.id
        if bodyTextureIdentity != identity,
           let image = AgentBotAvatar.coloredImage(for: agentID, paletteID: paletteID) {
            let texture = SKTexture(image: image)
            texture.filteringMode = .linear
            bodyNode.texture = texture
            bodyTextureIdentity = identity
        }
        for eye in [leftEyeNode, rightEyeNode] {
            eye.fillColor = eyesAreSmiling ? .clear : palette.eyeNSColor
            eye.strokeColor = eyesAreSmiling ? palette.eyeNSColor : .clear
        }
    }

    private func configureEyes(smiling: Bool) {
        eyesAreSmiling = smiling
        let metrics = AgentBotIdentity.eyeSize(for: agentID)
        let rect = CGRect(x: -metrics.width / 2, y: -metrics.height / 2, width: metrics.width, height: metrics.height)
        let path: CGPath
        if smiling {
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: -metrics.width / 2, y: 0))
            arc.addQuadCurve(to: CGPoint(x: metrics.width / 2, y: 0), control: CGPoint(x: 0, y: 1.3))
            path = arc
        } else if AgentBotIdentity.shape(for: agentID) == "triangle" {
            path = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let radius = AgentBotIdentity.shape(for: agentID) == "circle" ? metrics.width / 2 : 0.5
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        for eye in [leftEyeNode, rightEyeNode] {
            eye.path = path
            eye.lineWidth = 0.65
            eye.zPosition = 4
        }
        applyPalette()
    }

    private func updateEyes(pointer: CGPoint?, expression: Expression, elapsed: TimeInterval, delta: TimeInterval) {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pose = AgentBotEyePose.resolve(emotion: expression, elapsed: elapsed, reducedMotion: reducedMotion)
        if eyesAreSmiling != pose.isSmiling { configureEyes(smiling: pose.isSmiling) }
        var target = CGVector.zero
        if !reducedMotion {
            switch expression {
            case .thinking: target = CGVector(dx: -0.6, dy: 0.7)
            case .error: target = CGVector(dx: 0, dy: -0.45)
            case .angry: break
            default:
                if let pointer {
                    let local = characterNode.convert(pointer, from: self)
                    let distance = max(hypot(local.x, local.y), 1)
                    target = CGVector(dx: local.x / distance * 0.9, dy: local.y / distance * 0.75)
                }
            }
        }
        let smoothing = min(CGFloat(delta * 12), 1)
        eyeOffset.dx += (target.dx - eyeOffset.dx) * smoothing
        eyeOffset.dy += (target.dy - eyeOffset.dy) * smoothing
        let baseline = AgentBotIdentity.eyeBaseline(for: agentID)
        leftEyeNode.position = CGPoint(x: -2.45 + eyeOffset.dx, y: baseline + eyeOffset.dy)
        rightEyeNode.position = CGPoint(x: 2.45 + eyeOffset.dx, y: baseline + eyeOffset.dy)
        let shapeRotation = !pose.isSmiling && AgentBotIdentity.shape(for: agentID) == "diamond" ? Double.pi / 4 : 0
        leftEyeNode.xScale = pose.scaleX
        rightEyeNode.xScale = pose.scaleX
        leftEyeNode.yScale = pose.leftScaleY
        rightEyeNode.yScale = pose.rightScaleY
        leftEyeNode.zRotation = shapeRotation + pose.leftRotation
        rightEyeNode.zRotation = shapeRotation + pose.rightRotation
    }

    private func updateTexture() {
        bodyNode.size = CGSize(width: 23, height: 23)
        configureEyes(smiling: eyesAreSmiling)
    }

    func setCommunicationState(_ state: SloppyNotchPetState) {
        guard communicationState != state else { return }
        communicationState = state
        if state == .error || state == .needsInput {
            reaction = .none
        }
    }

    func handlePointerEntered(at point: CGPoint) {
        lastPetPoint = point
        pettingDistance = 0
        lastPetMoveAt = CACurrentMediaTime()
    }

    func handlePointerExited() {
        lastPetPoint = nil
        pettingDistance = 0
    }

    func handlePointerMove(at point: CGPoint) {
        let now = CACurrentMediaTime()
        defer {
            lastPetPoint = point
            lastPetMoveAt = now
        }
        guard let lastPetPoint, now - lastPetMoveAt < 0.22 else {
            pettingDistance = 0
            return
        }

        let distance = hypot(point.x - lastPetPoint.x, point.y - lastPetPoint.y)
        guard distance < 18 else {
            pettingDistance = 0
            return
        }
        pettingDistance += distance
        if pettingDistance >= 28 {
            setReaction(.happy, duration: 1.8, at: now)
            pettingDistance = 0
        }
    }

    func handlePoke(at point: CGPoint, time: TimeInterval? = nil) {
        let now = time ?? CACurrentMediaTime()
        pokeTimes = pokeTimes.filter { now - $0 < 1.35 }
        pokeTimes.append(now)

        switch pokeTimes.count {
        case 1:
            setReaction(.surprised, duration: 0.75, at: now)
        case 2:
            setReaction(.happy, duration: 1.25, at: now)
        default:
            setReaction(.angry, duration: 2.2, at: now)
            pokeTimes.removeAll()
        }
        lastPetPoint = point
    }

    private var currentExpression: Expression {
        if communicationState == .error {
            return .error
        }
        if communicationState == .needsInput {
            return .needsInput
        }
        switch reaction {
        case .happy: return .happy
        case .surprised: return .surprised
        case .angry: return .angry
        case .none: break
        }
        switch communicationState {
        case .idle: return .idle
        case .working: return .working
        case .thinking: return .thinking
        case .needsInput: return .needsInput
        case .error: return .error
        }
    }

    private func setReaction(_ reaction: Reaction, duration: TimeInterval, at time: TimeInterval) {
        guard communicationState != .error, communicationState != .needsInput else { return }
        self.reaction = reaction
        reactionEndsAt = time + duration
    }

    private func buildScene() {
        guard children.isEmpty else { return }

        glowNode.zPosition = 0
        addChild(glowNode)
        for (index, diameter) in [22.0, 17.0].enumerated() {
            let glow = SKShapeNode(circleOfRadius: diameter / 2)
            glow.fillColor = NSColor(
                calibratedRed: 0.05,
                green: 0.58,
                blue: 0.92,
                alpha: index == 0 ? 0.08 : 0.13
            )
            glow.strokeColor = .clear
            glowNode.addChild(glow)
        }

        characterNode.zPosition = 2
        addChild(characterNode)

        updateTexture()
        bodyNode.zPosition = 2
        characterNode.addChild(bodyNode)
        leftEyeNode.name = "left-eye"
        rightEyeNode.name = "right-eye"
        characterNode.addChild(leftEyeNode)
        characterNode.addChild(rightEyeNode)

        thoughtBubbleNode.fillColor = NSColor(calibratedRed: 0.08, green: 0.64, blue: 0.96, alpha: 1)
        thoughtBubbleNode.strokeColor = NSColor(calibratedRed: 0.42, green: 0.86, blue: 1, alpha: 0.8)
        thoughtBubbleNode.lineWidth = 0.35
        thoughtBubbleNode.zPosition = 6
        thoughtBubbleNode.alpha = 0
        addChild(thoughtBubbleNode)

        bubbleSymbolNode.fontSize = 3.1
        bubbleSymbolNode.fontColor = NSColor(calibratedWhite: 0.02, alpha: 0.9)
        bubbleSymbolNode.horizontalAlignmentMode = .center
        bubbleSymbolNode.verticalAlignmentMode = .center
        bubbleSymbolNode.position = CGPoint(x: 0, y: 0.15)
        bubbleSymbolNode.zPosition = 7
        thoughtBubbleNode.addChild(bubbleSymbolNode)
    }

    private func layoutScene() {
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 0.25)
        glowNode.position = center
        glowNode.setScale(presentationScale)
        characterNode.position = center
        characterNode.setScale(presentationScale)
        thoughtBubbleNode.position = CGPoint(
            x: center.x - 6.2 * presentationScale,
            y: center.y + 6.2 * presentationScale
        )
        thoughtBubbleNode.setScale(presentationScale)
    }

    private func updateBody(expression: Expression, elapsed: TimeInterval, delta: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 0.25)
        let baseX = sin(elapsed * 0.72) * 0.25
        let baseY = sin(elapsed * 2.05) * 0.32
        let reactionX: CGFloat
        let reactionY: CGFloat
        let rotation: CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat

        switch expression {
        case .happy:
            reactionX = 0
            reactionY = abs(sin(elapsed * 7.5)) * 0.9
            rotation = sin(elapsed * 6.5) * 0.07
            scaleX = 1.04
            scaleY = 0.98
        case .surprised:
            reactionX = 0
            reactionY = abs(sin(elapsed * 10)) * 0.45
            rotation = 0
            scaleX = 0.92
            scaleY = 1.1
        case .angry:
            reactionX = sin(elapsed * 30) * 0.55
            reactionY = 0
            rotation = sin(elapsed * 24) * 0.045
            scaleX = 1.05
            scaleY = 0.96
        case .error:
            reactionX = 0
            reactionY = -0.35 + sin(elapsed * 1.4) * 0.1
            rotation = -0.055
            scaleX = 0.98
            scaleY = 0.96
        case .idle, .working, .thinking, .needsInput:
            reactionX = 0
            reactionY = 0
            rotation = sin(elapsed * 0.83) * 0.025
            scaleX = 1
            scaleY = 1
        }

        characterNode.position = CGPoint(
            x: center.x + (baseX + reactionX) * presentationScale,
            y: center.y + (baseY + reactionY) * presentationScale
        )
        characterNode.zRotation = rotation + gazeRotation
        characterNode.xScale = presentationScale * scaleX
        characterNode.yScale = presentationScale * scaleY

        let bubble = bubblePresentation(for: expression)
        let desiredBubbleAlpha: CGFloat = bubble == nil ? 0 : 1
        bubbleAlpha += (desiredBubbleAlpha - bubbleAlpha) * min(CGFloat(delta * 9), 1)
        thoughtBubbleNode.alpha = bubbleAlpha
        if let bubble {
            thoughtBubbleNode.fillColor = bubble.color
            thoughtBubbleNode.strokeColor = bubble.stroke
            bubbleSymbolNode.text = bubble.symbol
        }
        thoughtBubbleNode.setScale(presentationScale * (0.82 + bubbleAlpha * 0.18))
        thoughtBubbleNode.position = CGPoint(
            x: characterNode.position.x - 6.2 * presentationScale,
            y: characterNode.position.y
                + (6.2 + sin(elapsed * 3.2) * 0.22) * presentationScale
        )

        let palette = glowPalette(for: expression)
        for (index, child) in glowNode.children.enumerated() {
            let pulse = 1 + sin(elapsed * 1.3 + Double(index) * 0.45) * 0.025
            child.setScale(pulse * palette.scale)
            (child as? SKShapeNode)?.fillColor = palette.color.withAlphaComponent(
                index == 0 ? 0.08 : 0.13
            )
        }

    }

    private func bubblePresentation(
        for expression: Expression
    ) -> (symbol: String, color: NSColor, stroke: NSColor)? {
        switch expression {
        case .thinking:
            ("•••", .systemCyan, .cyan)
        case .needsInput:
            ("?", .systemOrange, .orange)
        case .error:
            ("!", .systemRed, .red)
        case .happy:
            ("♥", .systemPink, .systemPink)
        case .surprised:
            ("!", .systemYellow, .systemYellow)
        case .angry:
            ("!", .systemRed, .systemOrange)
        case .idle, .working:
            nil
        }
    }

    private func glowPalette(for expression: Expression) -> (color: NSColor, scale: CGFloat) {
        switch expression {
        case .needsInput, .surprised:
            (.systemOrange, 1.08)
        case .error, .angry:
            (.systemRed, 1.1)
        case .happy:
            (.systemPink, 1.12)
        case .thinking:
            (.systemCyan, 1.12)
        case .idle:
            (.systemTeal, 0.96)
        case .working:
            (.systemCyan, 1)
        }
    }

}
#endif
