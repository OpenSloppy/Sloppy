import Foundation
import PluginSDK
import Protocols
import SloppyRuntime

extension CoreService {
    func configureUsageAccounting() async {
        await runtime.configureUsageAccounting(onRequest: { [weak self] record in
            await self?.persistMeasuredUsage(record)
        }, provenance: { [weak self] channelId in
            await self?.usageProvenance(channelId: channelId) ?? UsageProvenance()
        }, onToolOutcome: { [weak self] channel, call, ok in
            guard let self else { return }
            do { try await self.store.updateUsageToolOutcome(channelId: channel, callId: call, ok: ok) }
            catch { self.logger.warning("Failed to persist tool usage outcome: \(error)") }
        })
    }
    private func persistMeasuredUsage(_ record: UsageRequestRecord) async {
        do { try await store.persistUsageRequest(record) }
        catch { logger.warning("Failed to persist request usage", metadata: ["request_id": .string(record.id), "error": .string(String(describing:error))]) }
    }
    private func usageProvenance(channelId: String) async -> UsageProvenance {
        var result = UsageProvenance()
        let parts = channelId.split(separator: ":").map(String.init)
        let sessionId = parts.count == 4 && parts[0] == "agent" && parts[2] == "session" ? parts[3] : nil
        let registry = sessionId.flatMap { acpSessionMCPRegistries[$0] } ?? mcpRegistry
        for tool in await registry.cachedDynamicTools() { result.toolServers[tool.id] = tool.serverID }
        if parts.count == 4, parts[0] == "agent", parts[2] == "session" {
            let skills = (try? agentSkillsStore.listSkills(agentID: parts[1])) ?? []
            let composer = AgentPromptComposer()
            result.skills = skills.map { .init(id:$0.id,directory:$0.localPath,catalogEntry:composer.buildSkillsEntries(skills:[$0])) }
        }
        return result
    }
    public func usageBreakdown(query: UsageBreakdownQuery) async throws -> UsageBreakdownResponse { try await store.usageBreakdown(query) }
}
