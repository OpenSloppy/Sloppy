import Foundation

/// Coordinates are normalized against the displayed image, with a top-left origin.
public struct ChatImageRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double = 0, height: Double = 0) {
        self.x = Self.unit(x)
        self.y = Self.unit(y)
        self.width = min(Self.unit(width), 1 - self.x)
        self.height = min(Self.unit(height), 1 - self.y)
    }

    static func selection(from start: CGPoint, to end: CGPoint, imageFrame: CGRect) -> Self? {
        guard imageFrame.width > 0, imageFrame.height > 0, imageFrame.contains(start) else { return nil }
        let sx = Double((start.x - imageFrame.minX) / imageFrame.width)
        let sy = Double((start.y - imageFrame.minY) / imageFrame.height)
        let ex = Self.unit(Double((end.x - imageFrame.minX) / imageFrame.width))
        let ey = Self.unit(Double((end.y - imageFrame.minY) / imageFrame.height))
        if hypot(end.x - start.x, end.y - start.y) < 6 {
            return Self(x: sx, y: sy)
        }
        return Self(x: min(sx, ex), y: min(sy, ey), width: abs(ex - sx), height: abs(ey - sy))
    }

    static func imageFrame(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (canvasSize.width - size.width) / 2,
                      y: (canvasSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    var coordinateDescription: String {
        let point = "x: \(Self.percent(x))%, y: \(Self.percent(y))%"
        guard width > 0 || height > 0 else { return point }
        return "\(point), width: \(Self.percent(width))%, height: \(Self.percent(height))%"
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }
}

public struct ChatImageAnnotation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let region: ChatImageRegion
    public var comment: String

    public init(id: UUID = UUID(), region: ChatImageRegion, comment: String = "") {
        self.id = id
        self.region = region
        self.comment = comment
    }
}
