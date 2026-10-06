import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols

extension RuntimeSystem {
    func createUsageObservedModel(provider: any ModelProvider, model: String, channelId: String) async throws -> any LanguageModel {
        guard usageRequestHandler != nil, provider.supportsUsageObservation(for: model) else {
            observedUsageChannels.remove(channelId)
            return try await provider.createLanguageModel(for: model)
        }
        var provenance = await usageProvenanceProvider?(channelId) ?? UsageProvenance()
        provenance.toolNameMap = ModelToolNameSanitizer.sanitizeTools(filteredModelTools(channelId: channelId, modelProvider: provider, includeTools: true)).nameMap
        observedUsageChannels.insert(channelId)
        let context = ModelUsageContext(channelId: channelId, provider: model.split(separator: ":").first.map(String.init) ?? provider.id,
            model: model, provenance: provenance, provenanceProvider: { [weak self] in
                await self?.usageProvenanceProvider?(channelId) ?? UsageProvenance()
            }) { [weak self] record in
                await self?.receiveUsageRequest(record)
            }
        return try await provider.createLanguageModel(for: model, usageContext: context)
    }
    private func receiveUsageRequest(_ record: UsageRequestRecord) async {
        await usageRequestHandler?(record)
        guard let usage = record.usage else { return }
        var total = pendingRequestUsage[record.channelId] ?? TokenUsage(prompt: 0, completion: 0)
        total.prompt += usage.prompt; total.completion += usage.completion
        total.cachedInput += usage.cachedInput; total.cacheCreationInput += usage.cacheCreationInput; total.reasoning += usage.reasoning
        pendingRequestUsage[record.channelId] = total
        await channels.recordTokenUsage(channelId: record.channelId, usage: usage)
        if let ledger = contextLedgerByChannel[record.channelId] {
            contextLedgerByChannel[record.channelId] = ledger.withProviderUsage(usage)
        }
    }
}

public extension RuntimeSystem {
    func configureUsageAccounting(onRequest: @escaping @Sendable (UsageRequestRecord) async -> Void,
        provenance: @escaping @Sendable (String) async -> UsageProvenance,
        onToolOutcome: @escaping @Sendable (String, String, Bool) async -> Void) {
        usageRequestHandler = onRequest; usageProvenanceProvider = provenance; usageToolOutcomeHandler = onToolOutcome
        sessionsByChannel.removeAll()
    }
    func isRequestUsageObserved(channelId: String) -> Bool { observedUsageChannels.contains(channelId) }
}
