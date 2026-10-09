import Foundation
import Protocols

struct SloppyTUIProviderDefinition {
    static let addNewProviderValue = "__add_new_provider__"
    static let catalog = [
        SloppyTUIProviderDefinition("openai-api"),
        SloppyTUIProviderDefinition("openai-oauth"),
        SloppyTUIProviderDefinition("openrouter"),
        SloppyTUIProviderDefinition("gemini"),
        SloppyTUIProviderDefinition("anthropic"),
        SloppyTUIProviderDefinition("anthropic-oauth"),
        SloppyTUIProviderDefinition("claude-code"),
        SloppyTUIProviderDefinition("ollama"),
    ]

    var id: String
    var title: String
    var apiURL: String
    var model: String
    var requiresAPIKey: Bool
    var setupDescription: String
    var probeID: ProviderProbeID {
        switch id {
        case "claude-code":
            return .claudeCode
        case "openrouter":
            return .openRouter
        case "gemini":
            return .gemini
        case "anthropic":
            return .anthropic
        case "anthropic-oauth":
            return .anthropicOAuth
        case "ollama":
            return .ollama
        case "openai-oauth":
            return .openAIOAuth
        default:
            return .openAIAPI
        }
    }

    init(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "claude-code":
            id = "claude-code"
            title = "Claude Code"
            apiURL = ""
            model = "sonnet"
            requiresAPIKey = false
            setupDescription = "Run claude auth login on the Sloppy server"
        case "openrouter":
            id = "openrouter"
            title = "openrouter"
            apiURL = "https://openrouter.ai/api/v1"
            model = "openai/gpt-5.4-mini"
            requiresAPIKey = true
            setupDescription = "OpenRouter API key"
        case "gemini":
            id = "gemini"
            title = "gemini"
            apiURL = "https://generativelanguage.googleapis.com"
            model = "gemini-2.5-flash"
            requiresAPIKey = true
            setupDescription = "Google AI Studio API key"
        case "anthropic":
            id = "anthropic"
            title = "anthropic"
            apiURL = "https://api.anthropic.com"
            model = "claude-sonnet-4-6"
            requiresAPIKey = true
            setupDescription = "Anthropic API key"
        case "anthropic-oauth":
            id = "anthropic-oauth"
            title = "anthropic-oauth"
            apiURL = "https://api.anthropic.com"
            model = "claude-sonnet-4-6"
            requiresAPIKey = false
            setupDescription = "Browser OAuth flow"
        case "ollama", "ollama-local":
            id = "ollama"
            title = "ollama-local"
            apiURL = "http://127.0.0.1:11434"
            model = "qwen3"
            requiresAPIKey = false
            setupDescription = "Local Ollama server"
        case "openai-oauth":
            id = "openai-oauth"
            title = "OpenAI Codex"
            apiURL = "https://chatgpt.com/backend-api"
            model = "gpt-5.4"
            requiresAPIKey = false
            setupDescription = "Codex device auth"
        default:
            id = "openai-api"
            title = "OpenAI API"
            apiURL = "https://api.openai.com/v1"
            model = "gpt-5.4-mini"
            requiresAPIKey = true
            setupDescription = "OpenAI API key"
        }
    }

    func runtimeModelID(_ modelID: String) -> String {
        if id == "claude-code" { return "claude-code:\(modelID)" }
        if id == "openrouter" { return "openrouter:\(modelID)" }
        if id == "gemini" { return "gemini:\(modelID)" }
        if id == "anthropic" || id == "anthropic-oauth" { return "anthropic:\(modelID)" }
        if id == "ollama" { return "ollama:\(modelID)" }
        if id == "openai-oauth" { return "openai-oauth:\(modelID)" }
        return "openai-api:\(modelID)"
    }
}
