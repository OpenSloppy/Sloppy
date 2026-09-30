import AnyLanguageModel
import Foundation

/// Actual image bytes supplied to the model, independent of their durable project reference.
public struct SloppyImageInput: Sendable {
    public let data: Data
    public let mimeType: String
    public let relativePath: String?
    public init(data: Data, mimeType: String = "image/png", relativePath: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.relativePath = relativePath
    }
    var segment: Transcript.ImageSegment { .init(source: .data(data, mimeType: mimeType)) }
}
