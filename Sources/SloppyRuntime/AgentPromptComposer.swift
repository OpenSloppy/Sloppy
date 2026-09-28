import Foundation
import AgentRuntime
import AnyLanguageModel
import Protocols

public struct AgentPromptComposer {
    public enum ComposerError: Error {
        case unsupportedProcess
    }

    private let templateLoader: PromptTemplateLoader
    private let fileManager: FileManager

    public init(templateLoader: PromptTemplateLoader = PromptTemplateLoader(), fileManager: FileManager = .default) {
        self.templateLoader = templateLoader
        self.fileManager = fileManager
    }

    public func compose(context: PromptRenderContext) throws -> Prompt {
        switch context.processKind {
        case .agentSessionBootstrap:
            return try composeAgentSessionBootstrap(context: context)
        case .swarmPlanner:
            throw ComposerError.unsupportedProcess
        }
    }

    public func composeLeanAgentSessionBootstrap(context: PromptRenderContext, inlineTokenLimit: Int) throws -> Prompt {
        guard let sessionID = context.sessionID,
              let bootstrapMarker = context.bootstrapMarker,
              let documents = context.documents
        else {
            throw ComposerError.unsupportedProcess
        }

        let estimator = TokenPressureEstimator()
        let effectiveInlineTokenLimit = max(0, inlineTokenLimit)
        func documentLine(_ name: String, _ content: String) -> String? {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let tokens = estimator.estimateTextTokens(trimmed)
            if tokens <= effectiveInlineTokenLimit {
                return "- \(name): inline below\n\n[\(name)]\n\(trimmed)"
            }
            return "- \(name): available in agent directory; load it with `files.read` when relevant (\(tokens) estimated tokens)."
        }

        let documentEntries = [
            documentLine("AGENTS.md", documents.agentsMarkdown),
            documentLine("USER.md", documents.userMarkdown),
            documentLine("IDENTITY.md", documents.identityMarkdown),
            documentLine("SOUL.md", documents.soulMarkdown),
            documentLine("MEMORY.md", documents.memoryMarkdown)
        ].compactMap { $0 }
        let skillsEntries = buildSkillsEntries(skills: context.installedSkills)

        return try Prompt {
            bootstrapMarker
            "Session context initialized."
            "Agent: \(context.agentID)"
            if let agentDirectoryPath = context.agentDirectoryPath,
               !agentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Agent directory: \(agentDirectoryPath)"
            }
            "Current session ID: \(sessionID)"
            ""
            "[Agent context manifest]"
            documentEntries.joined(separator: "\n")
            if !context.installedSkills.isEmpty {
                ""
                "[Skills manifest]"
                skillsEntries
            }
            ""
            try templateLoader.loadPartial(named: "session_capabilities")
            ""
            try templateLoader.loadPartial(named: "tools_instruction")
            if context.sharedMemoryEnabled {
                ""
                sharedMemoryPromptSection()
            }
        }
    }

    private func composeAgentSessionBootstrap(context: PromptRenderContext) throws -> Prompt {
        guard let sessionID = context.sessionID,
              let bootstrapMarker = context.bootstrapMarker,
              let documents = context.documents
        else {
            throw ComposerError.unsupportedProcess
        }

        let capabilities = try templateLoader.loadPartial(named: "session_capabilities")
        let runtimeRules = try templateLoader.loadPartial(named: "runtime_rules")
        let branchingRules = try templateLoader.loadPartial(named: "branching_rules")
        let workerRules = try templateLoader.loadPartial(named: "worker_rules")
        let toolsInstruction = try templateLoader.loadPartial(named: "tools_instruction")
        let skillsRules = try templateLoader.loadPartial(named: "skills_rules")
        let memoryRules = try templateLoader.loadPartial(named: "memory_rules")
        let taskPlanningRules = try templateLoader.loadPartial(named: "task_planning_rules")
        let taskSpecRules = try templateLoader.loadPartial(named: "task_spec_rules")
        let completionReflection = try templateLoader.loadPartial(named: "completion_reflection")
        let cliAwareness = try templateLoader.loadPartial(named: "cli_awareness")
        let documentationAwareness = try templateLoader.loadPartial(named: "documentation_awareness")
        let skillsEntries = buildSkillsEntries(skills: context.installedSkills)

        return Prompt {
            bootstrapMarker
            "Session context initialized."
            "Agent: \(context.agentID)"
            if let agentDirectoryPath = context.agentDirectoryPath,
               !agentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "Agent directory: \(agentDirectoryPath)"
            }
            "Current session ID: \(sessionID)"

            if !documents.agentsMarkdown.isEmpty {
                ""
                "[AGENTS.md]"
                documents.agentsMarkdown
            }
            if !documents.userMarkdown.isEmpty {
                ""
                "[USER.md]"
                documents.userMarkdown
            }
            if !documents.identityMarkdown.isEmpty {
                ""
                "[IDENTITY.md]"
                documents.identityMarkdown
            }
            if !documents.soulMarkdown.isEmpty {
                ""
                "[SOUL.md]"
                documents.soulMarkdown
            }
            if !documents.memoryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ""
                "[MEMORY.md]"
                documents.memoryMarkdown
            }
            if !context.installedSkills.isEmpty {
                ""
                "[Skills]"
                buildSkillsPrompt(entries: skillsEntries)
            }
            ""
            capabilities
            ""
            runtimeRules
            ""
            branchingRules
            ""
            workerRules
            ""
            toolsInstruction
            ""
            skillsRules
            ""
            memoryRules
            if context.sharedMemoryEnabled {
                ""
                sharedMemoryPromptSection()
            }
            ""
            taskPlanningRules
            ""
            taskSpecRules
            ""
            completionReflection
            ""
            cliAwareness
            ""
            documentationAwareness
        }
    }

    public func buildSkillsPrompt(entries: String) -> String {
        """
        ## Skills (mandatory)
        Before replying, scan the skills below. If a skill matches or is even partially relevant to your task, you MUST read it before answering and follow its instructions.
        Err on the side of loading — it is always better to have context you do not need than to miss critical steps, pitfalls, or established workflows.
        Skills contain specialized knowledge, tool-specific commands, proven workflows, and the user's preferred conventions and quality standards. Load the skill even if you think you could handle the task with basic tools.
        Use `files.read` on `entrypoint` when provided, otherwise on the skill path plus `/SKILL.md`; do not proceed without loading a genuinely relevant skill.
        If a loaded skill is missing steps, has wrong commands, or lacks pitfalls you discovered, mention that it should be updated before finishing.
        After difficult or iterative tasks, offer to save the workflow as a skill.

        <available_skills>
        \(entries)
        </available_skills>

        Only proceed without loading a skill if genuinely none are relevant to the task.
        """
    }

    public func sharedMemoryPromptSection() -> String {
        """
        [Shared memory]
        Shared memory is available to all agents that have it enabled. Use it for durable user-wide facts and preferences that should help every agent, such as the user's name, work domain, standing preferences, and stable collaboration context.
        To read shared memory, call `memory.recall` or `memory.search` with `scope_type: global` and `scope_id: shared`.
        Before writing shared memory, search the same scope to avoid duplicates; save with `memory.save`, `scope_type: global`, and `scope_id: shared`.
        Do not store secrets, credentials, short-lived task details, or guesses in shared memory.
        """
    }

    public func buildSkillsEntries(skills: [InstalledSkill]) -> String {
        skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                var parts: [String] = ["`\(skill.id)`", skill.name]
                let description = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !description.isEmpty {
                    parts.append(description)
                }
                if !skill.userInvocable {
                    parts.append("user-invocable: false")
                }
                if !skill.allowedTools.isEmpty {
                    parts.append("allowed-tools: \(skill.allowedTools.joined(separator: ", "))")
                }
                if let ctx = skill.context {
                    parts.append("context: \(ctx.rawValue)")
                }
                if let agent = skill.agent, !agent.isEmpty {
                    parts.append("agent: \(agent)")
                }
                if let autoRoute = skill.autoRoute?.trimmingCharacters(in: .whitespacesAndNewlines), !autoRoute.isEmpty {
                    parts.append("auto-route: \(autoRoute)")
                }
                parts.append("path: `\(skill.localPath)`")
                if let entrypoint = skillEntrypointPath(for: skill) {
                    parts.append("entrypoint: `\(entrypoint)`")
                }
                return "- " + parts.joined(separator: " | ")
            }
            .joined(separator: "\n")
    }

    private func skillEntrypointPath(for skill: InstalledSkill) -> String? {
        let localPath = skill.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localPath.isEmpty else {
            return nil
        }

        let skillDirectory = URL(fileURLWithPath: localPath, isDirectory: true)
        let directSkillFile = skillDirectory.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: directSkillFile.path) {
            return directSkillFile.path
        }

        if let nestedSkillFile = firstNestedSkillFile(in: skillDirectory) {
            return nestedSkillFile.path
        }

        for fallbackName in ["README.md", "CLAUDE.md", "skill.json"] {
            let fallbackFile = skillDirectory.appendingPathComponent(fallbackName)
            if fileManager.fileExists(atPath: fallbackFile.path) {
                return fallbackFile.path
            }
        }

        return nil
    }

    private func firstNestedSkillFile(in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.lowercased() == "skill.md" else {
                continue
            }
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == false {
                continue
            }
            candidates.append(fileURL.standardizedFileURL)
        }
        return candidates.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }.first
    }
}
