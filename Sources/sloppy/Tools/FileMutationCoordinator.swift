import Foundation
import Protocols

/// Owned by ToolExecutionService and shared by all of its sessions.
actor FileMutationCoordinator {
    private var transactions: [String: FileMutationTransaction] = [:]
    private var inFlight: [String: Int] = [:]

    func apply(
        at url: URL,
        operation: FileMutationOperation,
        expectedContentHash: String?,
        maxBytes: Int
    ) async throws -> FileMutationOutcome {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let key = canonicalURL.path
        let transaction = transactions[key] ?? FileMutationTransaction()
        transactions[key] = transaction
        inFlight[key, default: 0] += 1
        defer {
            let remaining = (inFlight[key] ?? 1) - 1
            if remaining == 0 {
                inFlight.removeValue(forKey: key)
                transactions.removeValue(forKey: key)
            } else { inFlight[key] = remaining }
        }
        return try await transaction.apply(
            at: canonicalURL, operation: operation,
            expectedContentHash: expectedContentHash, maxBytes: maxBytes
        )
    }
}

enum FileMutationOperation: Sendable {
    case edit(search: String, replacement: String, all: Bool)
    case write(String)
}

struct FileMutationError: Error, Sendable {
    let code: String
    let message: String
    var candidateLines: [Int] = []
}

struct FileMutationOutcome: Sendable {
    let data: [String: JSONValue]
    let content: String
}

/// No suspension within a read/modify/write transaction, even for parallel batches.
private actor FileMutationTransaction {
    func apply(
        at url: URL,
        operation: FileMutationOperation,
        expectedContentHash: String?,
        maxBytes: Int
    ) throws -> FileMutationOutcome {
        try Task.checkCancellation()
        let exists = FileManager.default.fileExists(atPath: url.path)
        let originalData: Data
        if exists {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxBytes else {
                throw FileMutationError(code: "content_too_large", message: "Existing file exceeds the mutation byte limit.")
            }
            originalData = try Data(contentsOf: url)
            guard originalData.count <= maxBytes else {
                throw FileMutationError(code: "content_too_large", message: "Existing file exceeds the mutation byte limit.")
            }
        } else {
            switch operation {
            case .edit:
                throw CocoaError(.fileReadNoSuchFile)
            case .write:
                originalData = Data()
            }
        }
        let originalHash = TaskSyncCrypto.sha256Hex(originalData)
        if let expectedContentHash, expectedContentHash != originalHash || !exists {
            throw FileMutationError(code: "file_changed", message: "File content changed or the file no longer exists. Re-read it before writing.")
        }
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw FileMutationError(code: "binary_not_supported", message: "Only UTF-8 files can be mutated by this tool.")
        }
        let updated: String
        var replacements: Int?
        switch operation {
        case .write(let content):
            updated = content
        case .edit(let search, let replacement, let all):
            guard !search.isEmpty else {
                throw FileMutationError(code: "invalid_arguments", message: "Search text must not be empty.")
            }
            var count = 0
            var candidateLines: [Int] = []
            var start = original.startIndex
            var line = 1
            while let range = original.range(of: search, options: .literal, range: start..<original.endIndex) {
                line += original[start..<range.lowerBound].utf8.filter { $0 == 10 }.count
                count += 1
                if candidateLines.count < 20 { candidateLines.append(line) }
                line += original[range].utf8.filter { $0 == 10 }.count
                start = range.upperBound
            }
            guard count > 0 else {
                throw FileMutationError(code: "search_not_found", message: "Search text not found. Re-read the file and provide an exact fragment.")
            }
            guard all || count == 1 else {
                throw FileMutationError(
                    code: "ambiguous_match",
                    message: "Search text matches \(count) locations. Provide more context or explicitly set all=true.",
                    candidateLines: candidateLines
                )
            }
            updated = original.replacingOccurrences(of: search, with: replacement, options: .literal)
            replacements = count
        }
        let updatedData = Data(updated.utf8)
        guard updatedData.count <= maxBytes else {
            throw FileMutationError(code: "content_too_large", message: "Result exceeds max writable bytes.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updatedData.write(to: url, options: .atomic)
        var data = FileMutationDiff.make(original: original, updated: updated)
        data["path"] = .string(url.path)
        data["sizeBytes"] = .number(Double(updatedData.count))
        data["contentHash"] = .string(TaskSyncCrypto.sha256Hex(updatedData))
        if let replacements { data["replacements"] = .number(Double(replacements)) }
        return FileMutationOutcome(data: data, content: updated)
    }
}

enum FileMutationDiff {
    /// A single exact replacement hunk. Bounds the returned text, not the mutation.
    static func make(original: String, updated: String) -> [String: JSONValue] {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
            return lines
        }
        let before = lines(original)
        let after = lines(updated)
        let sameEnding = original.hasSuffix("\n") == updated.hasSuffix("\n")
        var head = 0
        while head < min(before.count, after.count), before[head] == after[head],
              sameEnding || head < min(before.count, after.count) - 1 { head += 1 }
        var tail = 0
        while sameEnding, tail < min(before.count, after.count) - head,
              before[before.count - tail - 1] == after[after.count - tail - 1] { tail += 1 }
        let removed = before.count - head - tail
        let added = after.count - head - tail
        var diff = "@@ -\(removed == 0 ? head : head + 1),\(removed) +\(added == 0 ? head : head + 1),\(added) @@\n"
        var truncated = false
        for (lines, count, prefix, source) in [(before, removed, "-", original), (after, added, "+", updated)] {
            for index in head..<(head + count) {
                var line = prefix + lines[index] + "\n"
                if index == lines.count - 1 && !source.hasSuffix("\n") { line += "\\ No newline at end of file\n" }
                if diff.utf8.count + line.utf8.count > 16_384 {
                    truncated = true
                    break
                }
                diff += line
            }
            if truncated { break }
        }
        return [
            "diff": .string(removed == 0 && added == 0 ? "" : diff),
            "additions": .number(Double(added)),
            "deletions": .number(Double(removed)),
            "diffTruncated": .bool(truncated),
        ]
    }
}

func fileMutationFailure(tool: String, path: String, error: Error) -> ToolInvocationResult {
    if let error = error as? FileMutationError {
        var result = toolFailure(tool: tool, code: error.code, message: error.message, retryable: false)
        if !error.candidateLines.isEmpty {
            result.data = .object(["candidateLines": .array(error.candidateLines.map { .number(Double($0)) })])
        }
        return result
    }
    let detail = FileSystemToolErrorMapping.describe(error: error, operation: .write, path: path)
    return toolFailure(tool: tool, code: detail.code, message: detail.message, retryable: detail.retryable, hint: detail.hint)
}
