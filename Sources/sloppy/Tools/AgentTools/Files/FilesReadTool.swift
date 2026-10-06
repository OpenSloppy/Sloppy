import AnyLanguageModel
import Foundation
import Protocols

struct FilesReadTool: CoreTool {
    let domain = "files"
    let title = "Read file"
    let status = "fully_functional"
    let name = "files.read"
    let description = "Read UTF-8 text file from workspace. A complete read returns contentHash for expectedContentHash on files.edit/files.write; partial reads return no full-file hash."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "path", description: "Path to the file to read", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "maxBytes", description: "Max bytes to return", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "offset", description: "Byte offset to start reading from", schema: DynamicGenerationSchema(type: Int.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let pathValue = arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pathValue.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`path` is required.", retryable: false)
        }
        guard let fileURL = context.resolveReadablePath(pathValue) else {
            return toolFailure(tool: name, code: "path_not_allowed", message: "File path is outside allowed roots.", retryable: false)
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            let detail = FileSystemToolErrorMapping.describePathIsDirectory(operation: .read, path: fileURL.path)
            return toolFailure(
                tool: name,
                code: detail.code,
                message: detail.message,
                retryable: detail.retryable,
                hint: detail.hint
            )
        }
        if !exists {
            // Linux `Data(contentsOf:)` has historically not always thrown for missing paths; fail deterministically.
            let detail = FileSystemToolErrorMapping.describeMissingPath(operation: .read, path: fileURL.path)
            return toolFailure(
                tool: name,
                code: detail.code,
                message: detail.message,
                retryable: detail.retryable,
                hint: detail.hint
            )
        }
        do {
            let fileSize = try Self.fileSizeBytes(fileURL)
            let requestedOffset = arguments["offset"]?.asInt ?? 0
            guard requestedOffset >= 0 else {
                return toolFailure(tool: name, code: "invalid_arguments", message: "`offset` must be non-negative.", retryable: false)
            }
            let maxBytes = max(1, arguments["maxBytes"]?.asInt ?? context.policy.guardrails.maxReadBytes)
            let offset = min(UInt64(requestedOffset), fileSize)
            let data = try Self.readChunk(from: fileURL, offset: offset, maxBytes: maxBytes, fileSize: fileSize)
            let scan = Self.scanUTF8(data)
            guard !scan.invalid, !(scan.incompleteAtEnd && offset + UInt64(data.count) >= fileSize) else {
                return toolFailure(tool: name, code: "binary_not_supported", message: "Only UTF-8 files are supported.", retryable: false)
            }
            let contentData = Data(data.prefix(scan.validLength))
            guard let text = String(data: contentData, encoding: .utf8) else {
                return toolFailure(tool: name, code: "binary_not_supported", message: "Only UTF-8 files are supported.", retryable: false)
            }
            let readBytes = UInt64(contentData.count)
            let nextOffset = offset + readBytes
            return toolSuccess(tool: name, data: .object([
                "contentHash": offset == 0 && nextOffset == fileSize ? .string(TaskSyncCrypto.sha256Hex(contentData)) : .null,
                "path": .string(fileURL.path),
                "content": .string(text),
                "sizeBytes": .number(Double(fileSize)),
                "offset": .number(Double(offset)),
                "readBytes": .number(Double(readBytes)),
                "nextOffset": .number(Double(nextOffset)),
                "truncated": .bool(nextOffset < fileSize)
            ]))
        } catch {
            let detail = FileSystemToolErrorMapping.describe(error: error, operation: .read, path: fileURL.path)
            return toolFailure(
                tool: name,
                code: detail.code,
                message: detail.message,
                retryable: detail.retryable,
                hint: detail.hint
            )
        }
    }

    private static func fileSizeBytes(_ fileURL: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func readChunk(from fileURL: URL, offset: UInt64, maxBytes: Int, fileSize: UInt64) throws -> Data {
        guard offset < fileSize else {
            return Data()
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: offset)
        let remaining = fileSize - offset
        let readCount = Int(min(UInt64(maxBytes), remaining))
        var data = try handle.read(upToCount: readCount) ?? Data()

        let scan = scanUTF8(data)
        if scan.validLength == 0, scan.incompleteAtEnd, UInt64(data.count) < remaining {
            let extraCount = Int(min(UInt64(3), remaining - UInt64(data.count)))
            if let extra = try handle.read(upToCount: extraCount) {
                data.append(extra)
            }
        }

        return data
    }

    private static func scanUTF8(_ data: Data) -> (validLength: Int, incompleteAtEnd: Bool, invalid: Bool) {
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 0x7F {
                index += 1
                continue
            }
            if (0xC2...0xDF).contains(byte) {
                let result = scanContinuation(bytes, index: index, ranges: [0x80...0xBF])
                if result == .valid {
                    index += 2
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if byte == 0xE0 {
                let result = scanContinuation(bytes, index: index, ranges: [0xA0...0xBF, 0x80...0xBF])
                if result == .valid {
                    index += 3
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if (0xE1...0xEC).contains(byte) || (0xEE...0xEF).contains(byte) {
                let result = scanContinuation(bytes, index: index, ranges: [0x80...0xBF, 0x80...0xBF])
                if result == .valid {
                    index += 3
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if byte == 0xED {
                let result = scanContinuation(bytes, index: index, ranges: [0x80...0x9F, 0x80...0xBF])
                if result == .valid {
                    index += 3
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if byte == 0xF0 {
                let result = scanContinuation(bytes, index: index, ranges: [0x90...0xBF, 0x80...0xBF, 0x80...0xBF])
                if result == .valid {
                    index += 4
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if (0xF1...0xF3).contains(byte) {
                let result = scanContinuation(bytes, index: index, ranges: [0x80...0xBF, 0x80...0xBF, 0x80...0xBF])
                if result == .valid {
                    index += 4
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            if byte == 0xF4 {
                let result = scanContinuation(bytes, index: index, ranges: [0x80...0x8F, 0x80...0xBF, 0x80...0xBF])
                if result == .valid {
                    index += 4
                    continue
                }
                return (index, result == .incomplete, result == .invalid)
            }
            return (index, false, true)
        }

        return (index, false, false)
    }

    private enum UTF8ScanResult {
        case valid
        case incomplete
        case invalid
    }

    private static func scanContinuation(_ bytes: [UInt8], index: Int, ranges: [ClosedRange<UInt8>]) -> UTF8ScanResult {
        for (offset, range) in ranges.enumerated() {
            let nextIndex = index + offset + 1
            guard nextIndex < bytes.count else {
                return .incomplete
            }
            guard range.contains(bytes[nextIndex]) else {
                return .invalid
            }
        }
        return .valid
    }
}
