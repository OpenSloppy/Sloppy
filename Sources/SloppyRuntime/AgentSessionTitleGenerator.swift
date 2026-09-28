import Foundation
import Protocols

public enum AgentSessionTitleGenerator {
    public static let fallbackTitle = "New session"
    public static let maxCharacters = 72
    public static let maxWords = 11
    public static let maxSourceMessages = 2

    public static func title(for messages: [AgentSessionMessage], fallback: String = fallbackTitle) -> String {
        let source = messages
            .prefix(maxSourceMessages)
            .flatMap(meaningfulLines)
            .prefix(3)
            .joined(separator: " — ")
        return title(for: source, fallback: fallback)
    }

    public static func title(for raw: String, fallback: String = fallbackTitle) -> String {
        let lines = meaningfulLines(in: raw)
        guard !lines.isEmpty else { return fallback }
        return truncate(lines.prefix(3).joined(separator: " — "))
    }

    private static func meaningfulLines(from message: AgentSessionMessage) -> [String] {
        message.segments.flatMap { segment in
            guard segment.kind == .text, let text = segment.text else { return [String]() }
            return meaningfulLines(in: text)
        }
    }

    private static func meaningfulLines(in raw: String) -> [String] {
        var insideFence = false
        var lines: [String] = []

        for rawLine in raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, !isServiceLine(line) else { continue }

            line = stripLeadingInvocation(from: line)
            line = clean(line)
            guard line.count >= 3 else { continue }
            lines.append(line)
        }
        return lines
    }

    private static func isServiceLine(_ line: String) -> Bool {
        if line.hasPrefix("[") && line.hasSuffix("]") { return true }
        if line.hasPrefix("[") && line.contains(":") { return true }
        if line.hasPrefix("- ") && line.contains(" bytes") { return true }
        return false
    }

    private static func stripLeadingInvocation(from text: String) -> String {
        guard let first = text.first, first == "@" || first == "/" else { return text }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return text }
        return String(parts[1])
    }

    private static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = value.first, "#>-*".contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?-—–_`'\"“”‘’()[]{}<>"))
    }

    private static func truncate(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var candidate = words.prefix(maxWords).joined(separator: " ")
        if candidate.count <= maxCharacters { return candidate }

        let end = candidate.index(candidate.startIndex, offsetBy: maxCharacters)
        candidate = String(candidate[..<end])
        if let lastSpace = candidate.lastIndex(of: " "), candidate.distance(from: candidate.startIndex, to: lastSpace) >= 24 {
            candidate = String(candidate[..<lastSpace])
        }
        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?-—–_`'\"“”‘’()[]{}<>"))
    }
}
