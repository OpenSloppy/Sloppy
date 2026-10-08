import Foundation
import AgentRuntime
import Protocols
import SloppyRuntime

// MARK: - Debug API

public struct DebugDocumentSizes: Encodable, Sendable {
    public var agentsMarkdown: Int
    public var userMarkdown: Int
    public var identityMarkdown: Int
    public var soulMarkdown: Int
    public var friendReminderMarkdown: Int
    public var memoryMarkdown: Int
}

public struct DebugSessionContextResponse: Encodable, Sendable {
    public var agentId: String
    public var sessionId: String
    public var channelId: String
    public var bootstrapContent: String?
    public var bootstrapChars: Int
    public var documentSizes: DebugDocumentSizes
    public var skillsCount: Int
    public var installedSkillIds: [String]
    public var contextUtilization: Double?
    public var channelMessageCount: Int?
    public var activeWorkerIds: [String]?
    public var selectedModel: String?
    public var runtimeType: String?
    public var conversationHistoryChars: Int?
    public var conversationHistoryMessageCount: Int?
    public var memoryDiagnostics: MemoryDiagnosticsSnapshot
    public var contextLedger: ContextLedgerSnapshot?
}

public struct DebugChannelInfo: Encodable, Sendable {
    public var channelId: String
    public var messageCount: Int
    public var contextUtilization: Double
    public var bootstrapChars: Int
    public var activeWorkerIds: [String]
}

public struct DebugChannelsResponse: Encodable, Sendable {
    public var channels: [DebugChannelInfo]
}

public struct DebugPromptTemplate: Encodable, Sendable {
    public var name: String
    public var content: String
    public var chars: Int
}

public struct DebugPromptTemplatesResponse: Encodable, Sendable {
    public var templates: [DebugPromptTemplate]
}

extension CoreService {
    private func sessionChannelID(agentID: String, sessionID: String) -> String {
        "agent:\(agentID):session:\(sessionID)"
    }

    public func getDebugSessionContext(agentID: String, sessionID: String) async -> DebugSessionContextResponse? {
        let normalizedAgentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgentID.isEmpty, !normalizedSessionID.isEmpty else {
            return nil
        }

        let channelID = sessionChannelID(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let bootstrap = await runtime.channelBootstrapContent(channelId: channelID)
        let snapshot = await runtime.channelState(channelId: channelID)

        let documents: AgentDocumentBundle
        do {
            documents = try agentCatalogStore.readAgentDocuments(agentID: normalizedAgentID)
        } catch {
            documents = AgentDocumentBundle(userMarkdown: "", agentsMarkdown: "", soulMarkdown: "", identityMarkdown: "")
        }

        let skills: [InstalledSkill]
        do {
            skills = try agentSkillsStore.listSkills(agentID: normalizedAgentID)
        } catch {
            skills = []
        }

        let agentConfig: AgentConfigDetail?
        do {
            agentConfig = try agentCatalogStore.getAgentConfig(
                agentID: normalizedAgentID,
                availableModels: availableAgentModels(),
                persistedModelAllowed: makePersistedModelAllowance()
            )
        } catch {
            agentConfig = nil
        }

        let sessionDetail = try? sessionStore.loadSession(agentID: normalizedAgentID, sessionID: normalizedSessionID)
        let bootstrapMarker = "[agent_session_context_bootstrap_v1]"
        let conversationMessages: [(role: String, text: String)] = sessionDetail?.events.compactMap { event in
            guard event.type == .message, let message = event.message else { return nil }
            let text = message.segments
                .filter { $0.kind == .text }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(bootstrapMarker) else { return nil }
            switch message.role {
            case .user: return ("User", text)
            case .assistant: return ("Assistant", text)
            case .system: return nil
            }
        } ?? []

        let historyChars = conversationMessages.reduce(0) { $0 + $1.role.count + 2 + $1.text.count + 1 }

        return DebugSessionContextResponse(
            agentId: normalizedAgentID,
            sessionId: normalizedSessionID,
            channelId: channelID,
            bootstrapContent: bootstrap,
            bootstrapChars: bootstrap?.count ?? 0,
            documentSizes: DebugDocumentSizes(
                agentsMarkdown: documents.agentsMarkdown.count,
                userMarkdown: documents.userMarkdown.count,
                identityMarkdown: documents.identityMarkdown.count,
                soulMarkdown: documents.soulMarkdown.count,
                friendReminderMarkdown: documents.friendReminderMarkdown.count,
                memoryMarkdown: documents.memoryMarkdown.count
            ),
            skillsCount: skills.count,
            installedSkillIds: skills.map(\.id),
            contextUtilization: snapshot?.contextUtilization,
            channelMessageCount: snapshot?.messages.count,
            activeWorkerIds: snapshot?.activeWorkerIds,
            selectedModel: agentConfig?.selectedModel,
            runtimeType: agentConfig?.runtime.type.rawValue,
            conversationHistoryChars: conversationMessages.isEmpty ? nil : historyChars,
            conversationHistoryMessageCount: conversationMessages.isEmpty ? nil : conversationMessages.count,
            memoryDiagnostics: await runtime.memoryDiagnostics.snapshot(channelId: channelID),
            contextLedger: await runtime.contextLedgerSnapshot(channelId: channelID)
        )
    }

    public func getDebugChannels() async -> DebugChannelsResponse {
        let snapshots = await runtime.activeChannelSnapshots()
        var infos: [DebugChannelInfo] = []
        for snapshot in snapshots {
            let bootstrapChars = await runtime.channelBootstrapContent(channelId: snapshot.channelId)?.count ?? 0
            infos.append(DebugChannelInfo(
                channelId: snapshot.channelId,
                messageCount: snapshot.messages.count,
                contextUtilization: snapshot.contextUtilization,
                bootstrapChars: bootstrapChars,
                activeWorkerIds: snapshot.activeWorkerIds
            ))
        }
        return DebugChannelsResponse(channels: infos)
    }

    public func getDebugPromptTemplates() async -> DebugPromptTemplatesResponse {
        let names = [
            "session_capabilities",
            "runtime_rules",
            "branching_rules",
            "worker_rules",
            "tools_instruction",
            "skills_rules",
            "memory_rules",
            "task_planning_rules",
            "completion_reflection",
            "cli_awareness"
        ]
        let loader = PromptTemplateLoader()
        let templates: [DebugPromptTemplate] = names.map { name in
            let content = (try? loader.loadPartial(named: name)) ?? ""
            return DebugPromptTemplate(name: name, content: content, chars: content.count)
        }
        return DebugPromptTemplatesResponse(templates: templates)
    }
}
