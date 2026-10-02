import Foundation
import Protocols

/// Tool allowlists for isolated subagent runs (`agents.delegate_task`, worker-backed sessions).
enum SubagentDelegation {
    static let controlToolIDs: Set<String> = [
        "agent_delegate.finish",
    ]

    /// Tools subagents must never use (recursive delegation, user messaging, shared memory, etc.).
    static let hardDeniedToolIDs: Set<String> = [
        "agents.delegate_task",
        "long_chat.delegate", "long_chat.status", "long_chat.message", "long_chat.cancel", "long_chat.retry",
        "workers.spawn",
        "workers.route",
        "branches.spawn",
        "memory.recall",
        "memory.get",
        "memory.save",
        "memory.search",
        "messages.send",
        "sessions.send",
        "runtime.exec",
        "sessions.spawn",
    ]

    /// Maps high-level toolset names to concrete tool IDs (Sloppy).
    private static let toolsetToToolIDs: [String: Set<String>] = [
        "terminal": ["runtime.exec", "runtime.process"],
        "file": ["files.list", "files.read", "files.write", "files.edit"],
        "web": ["web.search", "web.fetch"],
        "browser": [
            "browser.open",
            "browser.navigate",
            "browser.click",
            "browser.type",
            "browser.screenshot",
            "browser.status",
            "browser.read",
            "browser.scroll",
            "browser.close",
        ],
        "skills": ["skills.search", "skills.list", "skills.install", "skills.uninstall"],
        "lsp": ["lsp.query"],
        "visor": ["visor.status"],
        "system": ["system.list_tools"],
        "project_tasks": [
            "project.current",
            "project.task_list",
            "project.task_create",
            "project.task_get",
            "project.task_update",
            "project.task_clarification_create",
        ],
        "project": [
            "project.list",
            "project.current",
            "project.create",
            "project.update",
            "project.delete",
            "project.task_list",
            "project.task_create",
            "project.task_get",
            "project.task_update",
            "project.task_clarification_create",
            "project.task_cancel",
            "project.escalate_to_user",
            "project.meta_memory_set",
        ],
    ]

    static func isToolAllowedByPolicy(toolID: String, policy: AgentToolsPolicy) -> Bool {
        if let explicit = policy.tools[toolID] {
            return explicit
        }
        return policy.defaultPolicy == .allow
    }

    /// Expands named toolsets into tool IDs. `mcp` includes every `mcp.*` tool present in `knownToolIDs`.
    static func toolIDs(forToolsetNames names: [String], knownToolIDs: Set<String>) -> Set<String> {
        var result = Set<String>()
        for raw in names {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if key == "mcp" {
                result.formUnion(knownToolIDs.filter { $0.hasPrefix("mcp.") })
            } else if let ids = toolsetToToolIDs[key] {
                result.formUnion(ids)
            }
        }
        return result
    }

    /// Converts worker `tools` entries to concrete tool IDs. Worker specs historically carry a
    /// mix of concrete tool IDs (`web.search`) and coarse aliases (`project_tasks`, `shell`).
    static func explicitToolIDs(forWorkerTools workerTools: [String], knownToolIDs: Set<String>) -> [String] {
        var result = Set<String>()
        for raw in workerTools {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if knownToolIDs.contains(key) {
                result.insert(key)
            }
            let toolsetName: String
            switch key {
            case "shell", "exec":
                toolsetName = "terminal"
            case "project-tasks", "tasks", "task":
                toolsetName = "project_tasks"
            default:
                toolsetName = key
            }
            result.formUnion(toolIDs(forToolsetNames: [toolsetName], knownToolIDs: knownToolIDs))
        }
        return result.sorted()
    }

    /// Effective tools for a subagent: parent policy ∩ optional toolsets − hard denials.
    static func effectiveToolIDs(
        policy: AgentToolsPolicy,
        knownToolIDs: Set<String>,
        toolsetNames: [String]?,
        explicitToolIDs: [String]? = nil
    ) -> Set<String> {
        let parentAllowed = Set(
            knownToolIDs.filter { isToolAllowedByPolicy(toolID: $0, policy: policy) }
        )
        var candidates: Set<String>
        if let names = toolsetNames, !names.isEmpty {
            let expanded = toolIDs(forToolsetNames: names, knownToolIDs: knownToolIDs)
            candidates = parentAllowed.intersection(expanded)
        } else {
            candidates = parentAllowed
        }
        if let explicitToolIDs {
            let explicit = Set(
                explicitToolIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            if !explicit.isEmpty {
                candidates.formIntersection(explicit)
            }
        }
        let controlTools = parentAllowed.intersection(controlToolIDs)
        return candidates
            .union(controlTools)
            .subtracting(hardDeniedToolIDs)
    }
}
