import Foundation

public struct PromptTemplateRenderer {
    public init() {}

    public enum RenderError: Error, Equatable {
        case missingPlaceholder(String)
        case invalidPlaceholder
    }

    private let placeholderPattern = #"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}"#

    public func render(template: String, values: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: placeholderPattern)
        let matches = regex.matches(
            in: template,
            options: [],
            range: NSRange(template.startIndex..., in: template)
        )

        var rendered = template
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let placeholderRange = Range(match.range(at: 1), in: rendered),
                  let fullRange = Range(match.range(at: 0), in: rendered)
            else {
                throw RenderError.invalidPlaceholder
            }

            let key = String(rendered[placeholderRange])
            guard let value = values[key] else {
                throw RenderError.missingPlaceholder(key)
            }

            rendered.replaceSubrange(fullRange, with: value)
        }

        return rendered
    }
}
