import Foundation
import Logging

// MARK: - Session Retention

extension CoreService {
    struct SessionRetentionCleanupResult: Sendable, Equatable {
        var agentSessionsDeleted: Int
        var channelSessionsDeleted: Int
    }

    func deleteExpiredAgentSessionsIfNeeded(referenceDate: Date = Date()) -> Int {
        let retention = currentConfig.sessionRetention
        guard retention.enabled else {
            return 0
        }

        let cutoffDate = referenceDate.addingTimeInterval(-TimeInterval(retention.days * 24 * 60 * 60))
        do {
            let agentIDs = try listAgents().map(\.id)
            // Preserve legacy project histories until their owner opens and migrates them.
            let separate = Set(try longChats().state.separateSessionIds ?? [])
            var protected = Set<String>()
            for agentID in agentIDs where try agentCatalogStore.getAgentRuntimeConfig(agentID: agentID).type == .native {
                for session in try sessionStore.listSessions(agentID: agentID)
                    where session.projectId != nil && session.parentSessionId == nil
                        && session.taskId == nil && session.workspaceId == nil
                        && !separate.contains(session.id) {
                    protected.insert(session.id)
                }
            }
            let deleted = try sessionStore.deleteExpiredSessions(
                agentIDs: agentIDs,
                olderThan: cutoffDate,
                protectedSessionIDs: protected
            )
            for summary in deleted {
                Task { try? await launches.deleteSession(agentID: summary.agentId, sessionID: summary.id) }
                sessionExtraRoots.removeValue(forKey: summary.id)
                sessionWorkingDirectories.removeValue(forKey: summary.id)
                sessionAddedRoots.removeValue(forKey: summary.id)
                sessionSubagentToolAllowList.removeValue(forKey: summary.id)
                sessionToolUsageLimitBypass.remove(summary.id)
                sessionToolApprovalBypass.remove(summary.id)
                toolApprovalSessionAllowances.removeValue(forKey: "\(summary.agentId)\nsession:\(summary.id)")
            }
            if !deleted.isEmpty {
                logger.info(
                    "session_retention.agent_sessions_deleted",
                    metadata: ["count": .stringConvertible(deleted.count)]
                )
            }
            return deleted.count
        } catch {
            logger.warning(
                "session_retention.agent_cleanup_failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return 0
        }
    }

    @discardableResult
    func deleteExpiredSessionsIfNeeded(referenceDate: Date = Date()) async -> SessionRetentionCleanupResult {
        let agentCount = deleteExpiredAgentSessionsIfNeeded(referenceDate: referenceDate)
        let retention = currentConfig.sessionRetention
        guard retention.enabled else {
            return SessionRetentionCleanupResult(
                agentSessionsDeleted: agentCount,
                channelSessionsDeleted: 0
            )
        }

        let cutoffDate = referenceDate.addingTimeInterval(-TimeInterval(retention.days * 24 * 60 * 60))
        do {
            let deleted = try await channelSessionStore.deleteExpiredSessions(olderThan: cutoffDate)
            for summary in deleted {
                clearChannelSessionDirectories(channelID: summary.channelId)
            }
            if !deleted.isEmpty {
                logger.info(
                    "session_retention.channel_sessions_deleted",
                    metadata: ["count": .stringConvertible(deleted.count)]
                )
            }
            return SessionRetentionCleanupResult(
                agentSessionsDeleted: agentCount,
                channelSessionsDeleted: deleted.count
            )
        } catch {
            logger.warning(
                "session_retention.channel_cleanup_failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return SessionRetentionCleanupResult(
                agentSessionsDeleted: agentCount,
                channelSessionsDeleted: 0
            )
        }
    }
}
