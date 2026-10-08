import AnyLanguageModel
import Foundation
import Protocols

/// Reads bounded image content from the session store's validated attachment paths.
public enum SessionImageLoader {
    public enum LoadError: Error, CustomStringConvertible {
        case unsupportedType, missingFile, invalidImage, oversized
        public var description: String {
            switch self {
            case .unsupportedType: "Use a PNG, JPEG or WebP image."
            case .missingFile: "The stored image file is unavailable."
            case .invalidImage: "The file does not contain the declared image format."
            case .oversized: "Images must be at most 8 MB each."
            }
        }
    }

    public static func load(store: AgentSessionFileStore, agentID: String, attachment: AgentAttachment) throws -> Transcript.ImageSegment {
        guard let url = try store.resolveAttachmentFileURL(agentID: agentID, attachment: attachment) else {
            throw LoadError.missingFile
        }
        return try load(url: url, mimeType: attachment.mimeType)
    }

    public static func load(url: URL, mimeType: String) throws -> Transcript.ImageSegment {
        guard ["image/png", "image/jpeg", "image/webp"].contains(mimeType.lowercased()) else {
            throw LoadError.unsupportedType
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw LoadError.oversized }
        let bytes = Array(data.prefix(12))
        let valid: Bool
        switch mimeType.lowercased() {
        case "image/png": valid = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "image/jpeg": valid = bytes.starts(with: [255, 216, 255])
        default:
            valid = bytes.count >= 12 && String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF"
                && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP"
        }
        guard valid else { throw LoadError.invalidImage }
        return .init(source: .data(data, mimeType: mimeType.lowercased()))
    }

    public static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: nil
        }
    }
}
