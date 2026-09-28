import SloppyRuntime
enum SloppyTUISessionTitleGenerator {
    static let fallbackTitle = AgentSessionTitleGenerator.fallbackTitle
    static let maxCharacters = AgentSessionTitleGenerator.maxCharacters
    static let maxWords = AgentSessionTitleGenerator.maxWords

    static func title(for raw: String, fallback: String = fallbackTitle) -> String {
        AgentSessionTitleGenerator.title(for: raw, fallback: fallback)
    }
}
