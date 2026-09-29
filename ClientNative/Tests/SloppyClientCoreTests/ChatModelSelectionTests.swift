import SloppyClientCore
import Testing

@Suite("Chat model selection")
struct ChatModelSelectionTests {
    @Test("Auto JEV omits the per-turn model override")
    func automaticJEVUsesNoOverride() {
        #expect(ChatModelSelection.requestOverride(for: ChatModelSelection.automaticJEVId) == nil)
        #expect(ChatModelSelection.requestOverride(for: "") == nil)
    }

    @Test("Concrete model remains an explicit override")
    func concreteModelUsesOverride() {
        #expect(ChatModelSelection.requestOverride(for: " openai-oauth:gpt-5.6-sol ") == "openai-oauth:gpt-5.6-sol")
    }

    @Test("Auto option has a stable user-facing identity")
    func automaticJEVOption() {
        #expect(ChatModelSelection.automaticJEVOption.id == "auto:jev")
        #expect(ChatModelSelection.automaticJEVOption.title == "Auto")
        #expect(ChatModelSelection.automaticJEVOption.supportsReasoningEffort == false)
    }
}

