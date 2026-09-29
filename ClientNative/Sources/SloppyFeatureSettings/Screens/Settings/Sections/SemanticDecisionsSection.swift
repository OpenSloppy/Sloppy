import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

struct SemanticDecisionsSection: View {
    private struct Profile: Identifiable {
        let id = UUID()
        var name: String
        var model: String
        var description: String
    }

    let config: SloppyConfig
    let onSave: (SloppyConfig) -> Void

    @State private var draft: SloppyConfig.SemanticDecisions
    @State private var profiles: [Profile]
    @State private var timeout: String
    @State private var confidence: String
    @State private var inputPrice: String
    @State private var inputTokenLimit: String
    @State private var validationMessage = ""

    init(config: SloppyConfig, onSave: @escaping (SloppyConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _draft = State(initialValue: config.semanticDecisions)
        _profiles = State(initialValue: Self.profileRows(config.semanticDecisions))
        _timeout = State(initialValue: String(config.semanticDecisions.timeoutMs))
        _confidence = State(initialValue: String(config.semanticDecisions.minimumConfidence))
        _inputPrice = State(initialValue: String(config.semanticDecisions.inputCostPerMillionTokensUSD))
        _inputTokenLimit = State(initialValue: config.semanticDecisions.maxInputTokens.map(String.init) ?? "")
    }

    private var value: SloppyConfig.SemanticDecisions {
        var result = draft
        result.timeoutMs = Int(timeout) ?? draft.timeoutMs
        result.minimumConfidence = Double(confidence) ?? draft.minimumConfidence
        result.inputCostPerMillionTokensUSD = Double(inputPrice) ?? draft.inputCostPerMillionTokensUSD
        result.maxInputTokens = Int(inputTokenLimit)
        result.modelProfiles = profiles.reduce(into: [:]) { result, profile in
            result[profile.name.trimmingCharacters(in: .whitespacesAndNewlines)] = .init(
                model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
                description: profile.description
            )
        }
        return result
    }

    private var hasChanges: Bool {
        value != config.semanticDecisions ||
            timeout != String(config.semanticDecisions.timeoutMs) ||
            confidence != String(config.semanticDecisions.minimumConfidence) ||
            inputPrice != String(config.semanticDecisions.inputCostPerMillionTokensUSD) ||
            inputTokenLimit != (config.semanticDecisions.maxInputTokens.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionCard("Decision provider") {
                Picker("Provider", selection: Binding(
                    get: { draft.provider?.rawValue ?? "" },
                    set: {
                        guard draft.provider?.rawValue != $0 else { return }
                        draft = value
                        draft.selectProvider(.init(rawValue: $0))
                        syncNumericFields()
                    }
                )) {
                    Text("None").tag("")
                    Text("TypeSafe direct (Jev)").tag("typesafe")
                    Text("Vercel AI Gateway (Jev)").tag("vercel")
                    Text("Laya").tag("laya")
                }
                .padding(16)

                SettingsDivider()
                Picker("Executor routing", selection: $draft.executorModelRouting) {
                    Text("Disabled").tag(SloppyConfig.SemanticDecisions.Mode.disabled)
                    Text("Shadow").tag(SloppyConfig.SemanticDecisions.Mode.shadow)
                    Text("Active").tag(SloppyConfig.SemanticDecisions.Mode.active)
                }
                .pickerStyle(.segmented)
                .padding(16)

                SettingsFieldRow("Endpoint", hint: draft.provider?.defaultEndpoint, text: Binding(
                    get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0.isEmpty ? nil : $0 }
                ))
                SettingsFieldRow("Decision model", hint: draft.provider?.defaultModel, text: $draft.model)
                SettingsFieldRow("API key", hint: draft.provider == .laya ? "Optional when Laya authentication is disabled." : "Config key takes priority over the environment.", text: $draft.apiKey, isSecure: true)
                SettingsFieldRow("Key environment variable", hint: draft.provider?.defaultAPIKeyEnvironmentVariable, text: $draft.apiKeyEnvironmentVariable)
                SettingsFieldRow("Request timeout (ms)", text: $timeout)
                SettingsFieldRow("Minimum confidence", hint: draft.provider == .laya ? "Uses the selected answer probability. Validate this threshold on your tasks." : nil, text: $confidence)
                if draft.provider == .laya {
                    SettingsFieldRow("Input token limit", hint: "Leave empty for the server default. Multilingual supports up to 8192; match the selected checkpoint.", text: $inputTokenLimit)
                } else {
                    SettingsFieldRow("Input price per 1M tokens (USD)", text: $inputPrice)
                }
                Text("Shadow evaluates decisions without applying them. Errors and low confidence use the agent's configured model. Laya API calls are recorded at $0; hosting costs are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }

            SettingsSectionCard("Executor profiles") {
                ForEach($profiles) { $profile in
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsFieldRow("Profile ID", hint: "For example fast or senior.", text: $profile.name)
                        SettingsFieldRow("Executor model", hint: "Use a configured model ID, for example openai-api:gpt-5.4-mini.", text: $profile.model)
                        SettingsFieldRow("Description", text: $profile.description)
                        Button("Remove", role: .destructive) {
                            profiles.removeAll { $0.id == profile.id }
                        }
                        .padding(16)
                        SettingsDivider()
                    }
                }
                Button("Add profile") {
                    profiles.append(Profile(name: "", model: "", description: ""))
                }
                .padding(16)
                Text("At least two profiles with models available to the agent are required for automatic routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }

            if !validationMessage.isEmpty {
                Text(validationMessage).foregroundStyle(.red)
            }
            SettingsSaveBar(
                hasChanges: hasChanges,
                statusText: hasChanges ? "Unsaved changes" : "Saved",
                onSave: save,
                onCancel: {
                    draft = config.semanticDecisions
                    profiles = Self.profileRows(draft)
                    syncNumericFields()
                    validationMessage = ""
                }
            )
        }
    }

    private static func profileRows(_ config: SloppyConfig.SemanticDecisions) -> [Profile] {
        config.modelProfiles.keys.sorted().compactMap { name in
            config.modelProfiles[name].map { Profile(name: name, model: $0.model, description: $0.description) }
        }
    }

    private func save() {
        guard let timeoutValue = Int(timeout), timeoutValue >= 100,
              let confidenceValue = Double(confidence), confidenceValue.isFinite, (0...1).contains(confidenceValue),
              let priceValue = Double(inputPrice), priceValue.isFinite, priceValue >= 0,
              inputTokenLimit.isEmpty || Int(inputTokenLimit).map({ (1...8_192).contains($0) }) == true else {
            validationMessage = "Use a timeout of at least 100 ms, confidence from 0 to 1, a nonnegative price, and a token limit from 1 to 8192."
            return
        }
        let names = profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count,
              profiles.allSatisfy({ !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            validationMessage = "Each profile needs a unique ID and an executor model."
            return
        }
        var updated = config
        updated.semanticDecisions = value
        validationMessage = ""
        onSave(updated)
    }

    private func syncNumericFields() {
        timeout = String(draft.timeoutMs)
        confidence = String(draft.minimumConfidence)
        inputPrice = String(draft.inputCostPerMillionTokensUSD)
        inputTokenLimit = draft.maxInputTokens.map(String.init) ?? ""
    }
}
