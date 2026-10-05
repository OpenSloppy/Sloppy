import Foundation

/// A Markdown file link. Coordinates are one-based, as in editor links.
public struct SourceFileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil else { return nil }

        var path: String
        if url.isFileURL {
            guard components.host == nil || components.host == "" || components.host == "localhost" else { return nil }
            path = components.path
        } else if components.scheme == nil {
            guard components.host == nil else { return nil }
            path = components.path
        } else {
            // URL treats a bare filename followed by :line as a scheme.
            guard let scheme = components.scheme, scheme.contains("."),
                  !url.absoluteString.contains("://") else { return nil }
            path = scheme + ":" + components.path
        }

        var line: Int?
        var column: Int?
        if let suffix = path.range(of: #":([0-9]+)(?::([0-9]+))?$"#, options: .regularExpression) {
            let coordinates = path[suffix].dropFirst().split(separator: ":")
            guard let number = Int(coordinates[0]), number > 0 else { return nil }
            line = number
            if coordinates.count == 2 {
                guard let number = Int(coordinates[1]), number > 0 else { return nil }
                column = number
            }
            path = String(path[..<suffix.lowerBound])
        }
        if let fragment = components.fragment {
            // GitHub-style anchors can also specify an inclusive range.
            guard line == nil,
                  fragment.range(of: #"^L[0-9]+(?:-L?[0-9]+)?$"#, options: .regularExpression) != nil,
                  let number = Int(fragment.dropFirst().split(separator: "-")[0]), number > 0 else { return nil }
            if let end = fragment.split(separator: "-").dropFirst().first {
                guard let endLine = Int(end.hasPrefix("L") ? end.dropFirst() : end[...]), endLine >= number else { return nil }
            }
            line = number
        }
        guard !path.isEmpty, !path.hasSuffix("/"),
              !path.contains(":"), !path.contains("\0"),
              !path.contains("\n"), !path.contains("\r") else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty else { return nil }
        self.init(path: path, line: line, column: column)
    }
}
