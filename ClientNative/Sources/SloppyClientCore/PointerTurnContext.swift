import Foundation

/// A voice turn's pointing evidence. Screen/AX content is data, never user instructions.
public struct PointerTurnContext: Codable, Sendable, Equatable {
    public struct Rect: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(_ rect: CGRect) {
            x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        }

        public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    public struct Display: Codable, Sendable, Equatable {
        public var id: String
        public var bounds: Rect
        public var geometryRevision: Int
        public init(id: String, bounds: CGRect, geometryRevision: Int = 0) {
            self.id = id; self.bounds = Rect(bounds); self.geometryRevision = geometryRevision
        }
    }

    public struct Geometry: Codable, Sendable, Equatable {
        public var revision: Int
        public var primaryScreenTop: Double
        public init(revision: Int, primaryScreenTop: Double) { self.revision = revision; self.primaryScreenTop = primaryScreenTop }
    }

    public struct Sample: Codable, Sendable, Equatable {
        public var tMs: Int
        public var x: Double
        public var y: Double
        public var displayID: String
        public var segmentID: Int
        public var buttons: UInt64
        public var geometryRevision: Int

        public init(tMs: Int, point: CGPoint, displayID: String, segmentID: Int, buttons: UInt64 = 0, geometryRevision: Int = 0) {
            self.tMs = tMs; x = point.x; y = point.y
            self.displayID = displayID; self.segmentID = segmentID; self.buttons = buttons
            self.geometryRevision = geometryRevision
        }
    }

    public struct Utterance: Codable, Sendable, Equatable {
        public var text: String
        public var captureStartMs: Int
        public var startMs: Int
        public var endMs: Int
        public var wordAlignment = "unavailable"
        public init(text: String = "", captureStartMs: Int, startMs: Int, endMs: Int) {
            self.text = text; self.captureStartMs = captureStartMs
            self.startMs = startMs; self.endMs = endMs
        }
    }

    public struct Frame: Codable, Sendable, Equatable {
        public var id: String
        public var tMs: Int
        public var captureStartMs: Int
        public var captureEndMs: Int
        public var attachmentName: String
        public var annotatedAttachmentName: String
        public var displayID: String
        public var screenRect: Rect
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var scaleX: Double
        public var scaleY: Double
        public var geometryRevision: Int
        public var annotationStartMs: Int
        public var annotationEndMs: Int

        public init(id: String, captureStartMs: Int, captureEndMs: Int,
                    attachmentName: String, annotatedAttachmentName: String, displayID: String,
                    screenRect: CGRect, pixelWidth: Int, pixelHeight: Int, geometryRevision: Int = 0) {
            self.id = id; self.captureStartMs = captureStartMs; self.captureEndMs = captureEndMs
            tMs = captureStartMs + (captureEndMs - captureStartMs) / 2
            self.attachmentName = attachmentName; self.annotatedAttachmentName = annotatedAttachmentName
            self.displayID = displayID; self.screenRect = Rect(screenRect)
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            scaleX = screenRect.width > 0 ? Double(pixelWidth) / screenRect.width : 0
            scaleY = screenRect.height > 0 ? Double(pixelHeight) / screenRect.height : 0
            self.geometryRevision = geometryRevision
            annotationStartMs = max(0, captureStartMs - 500); annotationEndMs = captureEndMs + 100
        }

        public func pixelPoint(for sample: Sample) -> CGPoint? {
            guard sample.displayID == displayID, sample.geometryRevision == geometryRevision, scaleX > 0, scaleY > 0,
                  screenRect.cgRect.contains(CGPoint(x: sample.x, y: sample.y)) else { return nil }
            return CGPoint(x: (sample.x - screenRect.x) * scaleX, y: (sample.y - screenRect.y) * scaleY)
        }
    }

    public struct Element: Codable, Sendable, Equatable {
        public var frameID: String
        public var tMs: Int
        public var application: String
        public var role: String?
        public var title: String?
        public var selectedText: String?
        public var bounds: Rect?

        public init(frameID: String, tMs: Int, application: String, role: String?, title: String?,
                    selectedText: String?, bounds: CGRect?) {
            self.frameID = frameID; self.tMs = tMs; self.application = String(application.prefix(200))
            self.role = role; self.title = title.map { String($0.prefix(1_000)) }
            self.selectedText = selectedText.map { String($0.prefix(2_000)) }
            self.bounds = bounds.map(Rect.init)
        }
    }

    public struct Coverage: Codable, Sendable, Equatable {
        public var droppedSamples = 0
        public var omittedFrames = 0
        public var truncated = false
        public init() {}
    }

    public var schemaVersion = 1
    public var source = "desktop_magic_pointer"
    public var conversationID: String
    public var turnID: String
    public var deviceID: String
    public var agentID: String
    public var sessionID: String
    public var timebase = "conversation_monotonic_ms"
    public var coordinateSpace = "screen_points_top_left"
    public var samplingHz = 60
    public var contentTrust = "untrusted_screen_content"
    public var utterance: Utterance
    public var displays: [Display] = []
    public var geometries: [Geometry] = []
    public var samples: [Sample] = []
    public var frames: [Frame] = []
    public var elements: [Element] = []
    public var coverage = Coverage()

    public init(conversationID: String, turnID: String = UUID().uuidString, deviceID: String,
                agentID: String, sessionID: String, captureStartMs: Int) {
        self.conversationID = conversationID; self.turnID = turnID; self.deviceID = deviceID
        self.agentID = agentID; self.sessionID = sessionID
        utterance = Utterance(captureStartMs: captureStartMs, startMs: captureStartMs, endMs: captureStartMs)
    }

    /// Keep both endpoints when bounding evidence; report every removed sample.
    public mutating func boundSamples(to limit: Int) {
        let limit = max(2, limit)
        guard samples.count > limit else { return }
        let original = samples
        samples = (0..<limit).map { index in
            original[index * (original.count - 1) / (limit - 1)]
        }
        coverage.droppedSamples += original.count - samples.count
        coverage.truncated = true
    }

    public mutating func encoded(maxBytes: Int = 256 * 1_024) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        while data.count > maxBytes, samples.count > 2 {
            boundSamples(to: max(2, samples.count * 3 / 4))
            data = try encoder.encode(self)
        }
        guard data.count <= maxBytes else { throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Pointer context exceeds its byte budget.")) }
        return data
    }
}
