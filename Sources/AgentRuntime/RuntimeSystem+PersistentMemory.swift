import Foundation
import Protocols

extension RuntimeSystem {
    public func setMemoryProject(channelId: String, projectID: String?) {
        let normalized = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        memoryProjectByChannel[channelId] = normalized?.isEmpty == false ? normalized : nil
    }

    func persistentMemoryScopes(channelId: String) -> [MemoryScope] {
        guard channelId.hasPrefix("agent:"),
              let separator = channelId.range(of: ":session:"),
              !channelId.contains(":memory-checkpoint:") else { return [] }
        let agentID = String(channelId[channelId.index(channelId.startIndex, offsetBy: 6)..<separator.lowerBound])
        guard !agentID.isEmpty else { return [] }
        var scopes: [MemoryScope] = [.agent(agentID)]
        if let projectID = memoryProjectByChannel[channelId] {
            scopes.append(.project(projectID))
        }
        return scopes
    }

    /// A bounded session-start snapshot, separate from the agent's curated markdown.
    /// Only explicitly shared agent/project scopes cross session boundaries.
    public func persistentMemoryContext(channelId: String, maxCharacters: Int = 6_000) async -> String {
        guard maxCharacters > 0 else { return "" }
        var sections: [String] = []
        let scopes = persistentMemoryScopes(channelId: channelId)
        let scopeBudget = maxCharacters / max(1, scopes.count)
        for scope in scopes {
            let started = ContinuousClock.now
            let entries = await memoryStore.entries(filter: MemoryEntryFilter(
                scope: scope, classes: [.semantic, .procedural]
            ))
            let listingDuration = memoryElapsedMilliseconds(since: started)
            let sorted = entries.sorted {
                let leftProfile = $0.kind == .preference || $0.kind == .identity
                let rightProfile = $1.kind == .preference || $1.kind == .identity
                if leftProfile != rightProfile { return leftProfile }
                if $0.importance != $1.importance { return $0.importance > $1.importance }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
            var section = "[Persistent \(scope.type.rawValue) memory: \(scope.id)]\nHistorical context; verify changing facts and follow current user corrections.\n"
            let headerCount = section.count
            var selected: [MemoryHit] = []
            for entry in sorted.prefix(24) {
                let content = compactMemoryContent(summary: entry.summary, note: entry.note, maxCharacters: 500)
                let line = "- \(entry.id) [\(entry.kind.rawValue)]: \(content)\n"
                guard section.count + line.count <= scopeBudget else { continue }
                section += line
                selected.append(MemoryHit(ref: MemoryRef(id: entry.id, score: entry.importance,
                    kind: entry.kind, memoryClass: entry.memoryClass), note: entry.note, summary: entry.summary))
            }
            await memoryDiagnostics.record(
                request: MemoryRecallRequest(query: "", limit: 24, scope: scope, classes: [.semantic, .procedural]),
                result: MemoryRecallResult(hits: selected, durationMs: memoryElapsedMilliseconds(since: started), stages: [
                    MemoryRetrievalStage(name: "entries", durationMs: listingDuration, candidateCount: entries.count)
                ]), channelId: channelId, source: .bootstrap
            )
            if section.count > headerCount { sections.append(section) }
        }
        return String(sections.joined(separator: "\n").prefix(maxCharacters))
    }
}
