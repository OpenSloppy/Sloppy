import Foundation

/// Owns only the physical Right Option double tap; ordinary chords remain untouched.
struct MagicPointerTapGesture {
    private var pressedAt: TimeInterval?
    private var previousRelease: TimeInterval?

    mutating func handle(keyCode: UInt16, rawFlags: UInt64, at time: TimeInterval) -> Bool {
        guard time.isFinite else { cancel(); return false }
        guard keyCode == DesktopPointerModifier.rightOption.rawValue else { cancel(); return false }
        let modifier = DesktopPointerModifier.rightOption
        if rawFlags & modifier.deviceMask != 0 {
            guard modifier.isStandalone(rawFlags: rawFlags) else { cancel(); return false }
            if pressedAt == nil { pressedAt = time }
            return false
        }
        guard let pressedAt else { return false }
        self.pressedAt = nil
        // Shift/Command/Control or the other Option held on release cancels the gesture too.
        guard rawFlags & 0x1E007F == 0, time >= pressedAt, time - pressedAt < 0.25 else {
            previousRelease = nil
            return false
        }
        if let previousRelease, time >= previousRelease, time - previousRelease <= 0.3 {
            self.previousRelease = nil
            return true
        }
        previousRelease = time
        return false
    }

    mutating func cancel() { pressedAt = nil; previousRelease = nil }
}

struct MagicPointerVoiceActivity {
    enum Boundary: Equatable { case recording, speechEnded, emptyLimit }
    private(set) var firstSpeechAt: TimeInterval?
    private var voicedSince: TimeInterval?
    private var lastVoiceAt: TimeInterval?
    var silenceDuration: TimeInterval = 0.8
    var maximumDuration: TimeInterval = 60
    var threshold: Double = 0.075

    mutating func update(elapsed: TimeInterval, level: Double, powerDBFS: Double? = nil) -> Boundary {
        guard elapsed.isFinite, level.isFinite, elapsed >= 0 else { return .recording }
        // The orb's normalized level has a visual floor. Use the actual audio meter for VAD.
        let voiced = powerDBFS.flatMap { $0.isFinite ? $0 >= -42 : nil } ?? (level >= threshold)
        if voiced {
            if voicedSince == nil { voicedSince = elapsed }
            if let voicedSince, elapsed - voicedSince >= 0.12 {
                if firstSpeechAt == nil { firstSpeechAt = voicedSince }
                lastVoiceAt = elapsed
            }
        } else {
            voicedSince = nil
        }
        if let lastVoiceAt, elapsed - lastVoiceAt >= silenceDuration { return .speechEnded }
        if elapsed >= maximumDuration { return firstSpeechAt == nil ? .emptyLimit : .speechEnded }
        return .recording
    }
}

struct PointerTrailPoint: Sendable, Equatable {
    var point: CGPoint
    var time: TimeInterval
    var displayID: String
    var segmentID: Int
}

struct PointerTrailHistory {
    static let lifetime: TimeInterval = 0.9
    private(set) var points: [PointerTrailPoint] = []
    private(set) var segmentID = 0

    mutating func append(point: CGPoint, displayID: String, at time: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return }
        if let previous = points.last {
            let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
            if previous.displayID != displayID || time < previous.time || time - previous.time > Self.lifetime || distance > 700 {
                segmentID += 1
            } else if distance < 0.7 { return }
        }
        points.append(.init(point: point, time: time, displayID: displayID, segmentID: segmentID))
        expire(at: time)
        if points.count > 512 { points.removeFirst(points.count - 512) }
    }

    mutating func breakSegment() { segmentID += 1 }
    mutating func expire(at time: TimeInterval) { points.removeAll { time - $0.time >= Self.lifetime } }
    mutating func clear() { points = []; segmentID = 0 }

    static func opacity(age: TimeInterval) -> Double {
        pow(max(0, min(1, 1 - age / lifetime)), 1.7)
    }

    static func width(age: TimeInterval) -> Double {
        3 + 15 * pow(max(0, min(1, 1 - age / lifetime)), 0.65)
    }
}
