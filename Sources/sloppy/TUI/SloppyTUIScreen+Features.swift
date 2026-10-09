import AgentRuntime
import Foundation
#if canImport(AppKit)
import AppKit
#endif
import ChannelPluginSupport
import Logging
import Protocols
import TauTUI

enum SloppyTUIContextUsageSummaryBuilder {
    static func makeSummary(
        modelTitle: String,
        modelID: String,
        contextWindowLabel: String,
        contextWindowTokens: Int,
        usage: TokenUsageResponse,
        ledger: ContextLedgerSnapshot?,
        pendingContextAttached: Bool,
        pendingUploadCount: Int
    ) -> SloppyTUIContextUsageSummary {
        let ledgerCategories = ledger?.entries.map {
            SloppyTUIContextCategorySummary(label: $0.category.rawValue, tokens: $0.estimatedTokens)
        } ?? []
        let effectivePromptTokens = ledger?.contextWindowUsedTokens ?? usage.totalPromptTokens
        let effectiveTotalTokens = ledger.map { _ in effectivePromptTokens } ?? usage.totalTokens
        return SloppyTUIContextUsageSummary(
            modelTitle: modelTitle,
            modelID: modelID,
            contextWindowLabel: contextWindowLabel,
            promptTokens: effectivePromptTokens,
            completionTokens: usage.totalCompletionTokens,
            totalTokens: effectiveTotalTokens,
            contextWindowTokens: contextWindowTokens,
            pendingContextAttached: pendingContextAttached,
            pendingUploadCount: pendingUploadCount,
            semanticDecisionUsage: usage.semanticDecisionUsage,
            ledgerCategories: ledgerCategories,
            lastTurnInputTokens: ledger?.lastTurnInputTokens ?? 0,
            lastTurnCachedInputTokens: ledger?.lastTurnCachedInputTokens ?? 0,
            lastTurnUncachedInputTokens: ledger?.lastTurnUncachedInputTokens ?? 0,
            lastTurnCacheCreationInputTokens: ledger?.lastTurnCacheCreationInputTokens ?? 0,
            lastTurnCompletionTokens: ledger?.lastTurnCompletionTokens ?? 0,
            lastTurnReasoningTokens: ledger?.lastTurnReasoningTokens ?? 0
        )
    }
}

@MainActor
extension SloppyTUIScreen {
    func forkCurrentSession(task: String) async {
        guard hasPersistedSession else {
            appendLocalCard("No session yet. Send a message first or open an existing session with `/sessions`.")
            return
        }
        do {
            let titleTail = task.trimmingCharacters(in: .whitespacesAndNewlines)
            let child = try await service.createAgentSession(
                agentID: agent.id,
                request: AgentSessionCreateRequest(
                    title: titleTail.isEmpty ? "Fork of \(SloppyTUITheme.sessionDisplayTitle(session))" : "Fork: \(String(titleTail.prefix(48)))",
                    parentSessionId: session.id,
                    projectId: project.id
                )
            )
            session = child
            persistSelection()
            streamSession()
            await reloadSession()
            appendLocalCard("Forked into `\(child.title)`.", autoDismissAfter: 8)
            if !titleTail.isEmpty {
                await sendMessage(titleTail)
            }
        } catch {
            appendLocalCard("Fork failed: \(String(describing: error))")
        }
    }

    func changeBarColor(_ rawColor: String?) {
        guard let rawColor, !rawColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLocalCard("Usage: `/bar <red|blue|green|yellow|purple|orange|pink|cyan|default>`")
            return
        }
        guard SloppyTUITheme.setBarColor(rawColor) else {
            appendLocalCard("Unknown bar color `\(rawColor)`. Use red, blue, green, yellow, purple, orange, pink, cyan, or default.")
            return
        }
        editor.apply(theme: SloppyTUITheme.palette)
        tui?.apply(theme: SloppyTUITheme.palette)
        refreshStaticChrome(statusLine: "bar color set to \(rawColor)")
        requestRender()
    }

    func showThemePicker() {
        let catalog = SloppyTUIThemeStore(workspaceRoot: runtime.workspaceRoot).loadCatalog()
        if !catalog.warnings.isEmpty {
            let details = catalog.warnings
                .prefix(5)
                .map { "- `\($0.fileName)`: \($0.message)" }
                .joined(separator: "\n")
            let suffix = catalog.warnings.count > 5 ? "\n- ...and \(catalog.warnings.count - 5) more" : ""
            appendLocalCard("""
            Some TUI themes could not be loaded:
            \(details)\(suffix)
            """, autoDismissAfter: 12)
        }

        let currentID = SloppyTUITheme.currentTheme.id
        let items = catalog.themes.map { theme in
            SloppyTUIPickerItem(
                value: theme.id,
                label: theme.name,
                description: theme.source,
                isCurrent: theme.id == currentID,
                group: theme.id == SloppyTUIResolvedTheme.defaultID ? "Built-in" : "Custom"
            )
        }
        guard !items.isEmpty else {
            appendLocalCard("No TUI themes found.")
            return
        }

        activePicker = SloppyTUIPicker(
            kind: .theme,
            title: "Select theme",
            items: items,
            selectedIndex: max(0, items.firstIndex(where: { $0.isCurrent }) ?? 0),
            allItems: items,
            supportsSearch: true
        )
        refreshStaticChrome(statusLine: "type to search themes, arrows to select, Enter to apply, Esc to cancel")
    }

    func applyTheme(_ id: String) {
        let catalog = SloppyTUIThemeStore(workspaceRoot: runtime.workspaceRoot).loadCatalog()
        guard let theme = catalog.theme(id: id) else {
            appendLocalCard("Theme `\(id)` is not available. Put custom themes in `\(SloppyTUIThemeStore(workspaceRoot: runtime.workspaceRoot).themesURL.path)`.", autoDismissAfter: 10)
            return
        }

        SloppyTUITheme.apply(theme)
        state.themeID = theme.id
        stateStore.save(state)
        editor.apply(theme: SloppyTUITheme.palette)
        tui?.apply(theme: SloppyTUITheme.palette)
        renderTimeline()
        refreshStaticChrome(statusLine: "theme set to \(theme.name)")
        requestRender()
    }

    func copyLastAssistantResponse() {
        guard let text = sessionCards.reversed().compactMap({ block -> String? in
            if case .message(let role, let text) = block, role == .assistant {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }).first, !text.isEmpty else {
            appendLocalCard("No agent response to copy.", autoDismissAfter: 6)
            return
        }

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLocalCard("Copied last agent response to clipboard.", autoDismissAfter: 6)
        #else
        appendLocalCard("Clipboard copy is not available on this platform.", autoDismissAfter: 6)
        #endif
    }

    func showDiff() async {
        do {
            let sourceControl = try await service.projectWorkingTreeSourceControl(projectID: project.id)
            updateProjectSourceControlFooter(sourceControl)
            guard sourceControl.isRepository else {
                appendLocalCard(sourceControl.message ?? "Project is not a source-control repository.")
                return
            }
            guard !sourceControl.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                appendLocalCard(sourceControl.message ?? "No uncommitted source-control changes.")
                return
            }
            let branch = sourceControl.branch ?? "unknown"
            let truncated = sourceControl.diffTruncated ? "\n\nDiff was truncated by the backend." : ""
            appendLocalCard("""
            ## Source-Control Diff
            `\(sourceControl.providerId)` on `\(branch)`: +\(sourceControl.linesAdded) -\(sourceControl.linesDeleted)

            \(fencedBlock("diff", sourceControl.diff, maxCharacters: 12_000))\(truncated)
            """)
        } catch {
            appendLocalCard("Could not read source-control diff: \(String(describing: error))")
        }
    }

    func openPlanWebPage(planName: String?) async {
        guard hasPersistedSession else {
            appendLocalCard("No session yet. Send a Plan mode message first or open an existing session with `/sessions`.", autoDismissAfter: 8)
            return
        }

        do {
            let detail = try await service.getAgentSession(agentID: agent.id, sessionID: session.id)
            guard let artifact = SloppyTUIPlanArtifactLookup.resolve(planName, in: detail.events) else {
                let suffix = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let suffix, !suffix.isEmpty {
                    appendLocalCard("No plan web page named `\(suffix)` in this session.", autoDismissAfter: 8)
                } else {
                    appendLocalCard("No plan web page in this session yet. Switch to Plan mode with Tab and send a planning request.", autoDismissAfter: 10)
                }
                return
            }

            let target = SloppyTUIPlanWebTargetResolver.target(
                for: artifact,
                runtime: runtime,
                service: service
            )
            try SloppyTUIExternalURLOpener.open(target.url)
            appendLocalCard("""
            Opened plan web page: `\(artifact.planName)`

            \(target.display)
            """, autoDismissAfter: 8)
        } catch {
            appendLocalCard("Could not open plan web page: \(String(describing: error))", autoDismissAfter: 10)
        }
    }

    func openFeedbackPage() {
        guard let url = SloppyTUIFeedbackCommand.issuesURL else {
            appendLocalCard("Could not open feedback page: invalid feedback URL.", autoDismissAfter: 10)
            return
        }
        do {
            try SloppyTUIExternalURLOpener.open(url)
            appendLocalCard("""
            Opened feedback page:

            \(url.absoluteString)
            """, autoDismissAfter: 8)
        } catch {
            appendLocalCard("""
            Could not open feedback page: \(String(describing: error))

            \(url.absoluteString)
            """, autoDismissAfter: 10)
        }
    }

    func setReasoningEffort(_ raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !value.isEmpty else {
            showReasoningEffortSelector()
            return
        }
        if value == "default" || value == "none" || value == "off" {
            reasoningEffort = nil
            appendLocalCard("Reasoning effort reset to model default.", autoDismissAfter: 6)
            return
        }
        guard let effort = ReasoningEffort(rawValue: value) else {
            appendLocalCard("Unknown effort `\(value)`. Use low, medium, high, default, or run `/effort` to pick interactively.")
            return
        }
        reasoningEffort = effort
        appendLocalCard("Reasoning effort set to `\(effort.rawValue)`.", autoDismissAfter: 6)
    }

    func showSkills() async {
        do {
            let response = try await service.listAgentSkills(agentID: agent.id)
            guard !response.skills.isEmpty else {
                appendLocalCard("No enabled skills for `\(agent.displayName)`.", autoDismissAfter: 8)
                return
            }
            let lines = response.skills.map { skill -> String in
                let slash = skillSlashCommands.first { $0.description?.hasPrefix(skill.name) == true }?.name
                let suffix = slash.map { " `@\($0)`" } ?? ""
                return "- \(skill.name)\(suffix) — `\(skill.id)`"
            }.joined(separator: "\n")
            appendLocalCard("""
            ## Skills
            \(lines)
            """)
        } catch {
            appendLocalCard("Could not load skills: \(String(describing: error))")
        }
    }

    func openCodeEditor(_ args: [String]) async {
        do {
            let preferredEditor = SloppyTUIEditorCommand.preferredEditor(
                args: args,
                defaultEditor: runtime.config.tui.defaultEditor
            )
            let result = try await SloppyTUICodeEditorLauncher.open(path: runtime.cwd, preferredEditor: preferredEditor)
            appendLocalCard("Opened `\(result.path)` in `\(result.label)`.", autoDismissAfter: 6)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            appendLocalCard("Could not open code editor: \(message)", autoDismissAfter: 10)
        }
    }

    func showStatus() async {
        let config = try? await service.getAgentConfig(agentID: agent.id)
        let model = config?.selectedModel ?? selectedModel
        selectedModel = model
        let sessionLines = hasPersistedSession
            ? """
            - session: `\(session.title)`
            - session id: `\(session.id)`
            - resume: `sloppy -s \(session.id)`
            """
            : """
            - session: `not created yet`
            - resume: unavailable until the first message
            """
        appendLocalCard("""
        ## Status
        - project: `\(project.name)`
        - agent: `\(agent.displayName)`
        \(sessionLines)
        - model: `\(model)`
        - provider: `\(providerLabel(from: model))`
        - pet: \(petStatusSummary())
        - scrollback: \(scrollbackStatusSummary())
        """, autoDismissAfter: 20)
    }

    func showWorkspace() async {
        let projectRoot = ((try? await service.resolveProjectWorkspaceRoot(projectID: project.id))
            ?? URL(fileURLWithPath: runtime.cwd, isDirectory: true))
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let projectRoots = sessionToolRoots(forWorkingDirectory: projectRoot)
        let sessionDirectories = normalizedDirectoryList(persistedDirectoriesForCurrentSession())
            .filter { directory in
                !projectRoots.contains { root in
                    SloppyTUIWorkspaceAccess.contains(directory, inside: root)
                }
            }
        let projectLines = projectRoots.map { "- `\($0)`" }.joined(separator: "\n")
        let extraLines = sessionDirectories.isEmpty
            ? "- none"
            : sessionDirectories.map { "- `\($0)`" }.joined(separator: "\n")
        let deniedDirectories = deniedWorkspaceAccessDirectoriesForCurrentSession()
        let pendingDeniedLines = deniedDirectories.isEmpty
            ? "- none"
            : deniedDirectories.map { "- `\($0)`" }.joined(separator: "\n")
        let sessionLabel = hasPersistedSession ? "`\(session.title)` (`\(session.id)`)" : "`draft session`"

        appendLocalCard("""
        ## Workspace
        - project: `\(project.name)`
        - agent: `\(agent.displayName)`
        - session: \(sessionLabel)

        Agent working roots:
        \(projectLines)

        Added directories for this session:
        \(extraLines)

        Denied in this TUI session:
        \(pendingDeniedLines)

        Use `/add_dir <path>` to allow another directory for this session.
        """, autoDismissAfter: 24)
    }

    func configureScrollback(_ args: [String]) {
        guard !args.isEmpty else {
            showScrollbackModeSelector()
            return
        }
        switch SloppyTUIScrollbackCommand.parse(args) {
        case .status:
            showScrollbackStatus()
        case .update(let mode, let lineLimit):
            applyScrollbackMode(mode, lineLimit: lineLimit)
            appendLocalCard("""
            ## Scrollback
            - mode: `\(state.scrollbackMode.rawValue)`
            - line limit: `\(state.scrollbackLineLimit)`
            - behavior: \(scrollbackBehaviorDescription())
            """, autoDismissAfter: 12)
        case .failure(let message):
            appendLocalCard(message, autoDismissAfter: 10)
        }
    }

    func applyScrollbackMode(_ mode: SloppyTUIScrollbackMode, lineLimit: Int? = nil) {
        state.scrollbackMode = mode
        if let lineLimit {
            state.scrollbackLineLimit = SloppyTUIScrollbackPolicy.normalizedLineLimit(lineLimit)
        }
        timelineScrollOffset = 0
        stateStore.save(state)
        refreshStaticChrome()
    }

    func showScrollbackStatus() {
        appendLocalCard("""
        ## Scrollback
        - mode: `\(state.scrollbackMode.rawValue)`
        - line limit: `\(state.scrollbackLineLimit)`
        - behavior: \(scrollbackBehaviorDescription())
        \(SloppyTUIScrollbackCommand.usage)
        """, autoDismissAfter: 16)
    }

    func scrollbackStatusSummary() -> String {
        "`\(state.scrollbackMode.rawValue)` limit \(state.scrollbackLineLimit)"
    }

    func scrollbackBehaviorDescription() -> String {
        switch state.scrollbackMode {
        case .auto:
            return "native scrollback until the timeline exceeds the limit, then fast viewport scrolling"
        case .viewport:
            return "fast internal viewport scrolling"
        case .limited:
            return "fast internal viewport scrolling over the recent line limit"
        case .full:
            return "fast internal viewport scrolling over the full in-app chat history"
        }
    }

    func showPetStatus(toggle: Bool) {
        if toggle {
            state.petEnabled.toggle()
            stateStore.save(state)
        }
        appendLocalCard("""
        ## Sloppie pet
        - status: `\(state.petEnabled ? "on" : "off")`
        - face: `\(terminalPetFace())`
        - species: `\(agent.pet?.visual?.displayName ?? "legacy sloppie")`
        - stage: `\(agent.pet?.visual?.currentStage ?? 1)/\(agent.pet?.visual?.stageCount ?? 3)`
        - xp: `\(agent.pet?.evolution?.totalXp ?? 0)`
        """, autoDismissAfter: 12)
        refreshStaticChrome()
    }

    func petStatusSummary() -> String {
        guard state.petEnabled else {
            return "`off`"
        }
        let visual = agent.pet?.visual
        let stage = visual.map { "\($0.currentStage)/\($0.stageCount)" } ?? "1/3"
        return "`\(terminalPetFace())` \(visual?.displayName ?? "Sloppie") stage \(stage)"
    }

    func showAgentPicker() async {
        let agents = (try? await service.listAgents(includeSystem: false)) ?? []
        guard !agents.isEmpty else {
            appendLocalCard("No agents available.")
            return
        }
        let ordered = orderedAgentsForPicker(agents)
        activePicker = SloppyTUIPicker(
            kind: .agent,
            title: "Select agent",
            items: ordered.map { item in
                SloppyTUIPickerItem(
                    value: item.id,
                    label: item.displayName,
                    description: item.role.isEmpty ? item.id : item.role,
                    isCurrent: item.id == agent.id
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select agent with arrows, Enter to apply, Esc to cancel")
    }

    func showSessionPicker() async {
        let sessions = ((try? await service.listAgentSessions(agentID: agent.id, projectID: project.id)) ?? [])
            .sorted { lhs, rhs in
                if lhs.id == session.id { return true }
                if rhs.id == session.id { return false }
                return lhs.updatedAt > rhs.updatedAt
            }

        guard !sessions.isEmpty else {
            appendLocalCard("No sessions for `\(agent.displayName)` in this directory.")
            return
        }

        activePicker = SloppyTUIPicker(
            kind: .session,
            title: "Select session",
            items: sessions.map { item in
                SloppyTUIPickerItem(
                    value: item.id,
                    label: SloppyTUITheme.sessionDisplayTitle(item),
                    description: SloppyTUITheme.sessionPickerDescription(item),
                    isCurrent: item.id == session.id
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select session with arrows, Enter to open, Esc to cancel")
    }

    func showSubSessionPicker() {
        let children = orderedSubSessions()
        guard !children.isEmpty else {
            appendLocalCard("No subagent sessions have been spawned from this session yet.", autoDismissAfter: 8)
            return
        }

        activePicker = SloppyTUIPicker(
            kind: .subSession,
            title: "Open subagent session",
            items: children.map { item in
                SloppyTUIPickerItem(
                    value: item.childSessionId,
                    label: item.title,
                    description: "\(item.status.plainText) · \(item.childSessionId)",
                    isCurrent: false
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select subagent with arrows, Enter to enter, Esc to cancel")
    }

    func openLatestSubSession() async {
        guard let child = orderedSubSessions().first else {
            appendLocalCard("No subagent session to enter yet.", autoDismissAfter: 6)
            return
        }
        await switchSession(child.childSessionId)
    }

    func openParentSession() async {
        guard let parentSessionID = session.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentSessionID.isEmpty else {
            appendLocalCard("This session does not have a parent session.", autoDismissAfter: 6)
            return
        }
        await switchSession(parentSessionID)
    }

    func orderedSubSessions() -> [SloppyTUISubSessionCard] {
        var seen: Set<String> = []
        return subSessionCards.reversed().compactMap { item in
            guard seen.insert(item.childSessionId).inserted else {
                return nil
            }
            return item
        }
    }

    func switchModel(_ model: String?) async {
        guard let model, !model.isEmpty else {
            await showModelPicker()
            return
        }
        await applyModel(model)
    }

    func showModelPicker(exitAfterSelection: Bool = false) async {
        exitAfterModelSelection = exitAfterSelection
        beginOperationStatus(.modelLoading, label: "Loading models", detail: "providers")
        defer { endOperationStatus(.modelLoading) }
        refreshStaticChrome(statusLine: "loading models from providers...")
        do {
            let config = try await service.getAgentConfig(agentID: agent.id)
            let selected = config.selectedModel ?? selectedModel
            selectedModel = selected
            let models = orderedModelsForPicker(
                await selectableModels(base: config.availableModels, selected: selected),
                selected: selected
            )
            guard !models.isEmpty else {
                appendLocalCard("No available models.")
                return
            }
            let items = models.map { model in
                let group = modelPickerGroup(for: model.id)
                return SloppyTUIPickerItem(
                    value: model.id,
                    label: modelPickerLabel(for: model.id, group: group),
                    description: SloppyTUITheme.modelPickerDescription(model),
                    isCurrent: model.id == selected,
                    group: group
                )
            }
            activePicker = SloppyTUIPicker(
                kind: .model,
                title: "Select model",
                items: items,
                selectedIndex: models.firstIndex(where: { $0.id == selected }) ?? 0,
                allItems: items,
                supportsSearch: true
            )
            refreshStaticChrome(statusLine: "type to search models, arrows to select, Enter to apply, Esc to cancel")
        } catch {
            exitAfterModelSelection = false
            appendLocalCard("Could not load models: \(String(describing: error))")
        }
    }

    func applyPickerItem(_ item: SloppyTUIPickerItem, kind: SloppyTUIPickerKind) async {
        switch kind {
        case .project:
            await switchProject(item.value)
        case .model:
            await applyModel(item.value)
            if exitAfterModelSelection {
                await stopTUI(reason: "TUI model picker")
            }
        case .agent:
            await switchAgent(item.value)
        case .session:
            await switchSession(item.value)
        case .subSession:
            await switchSession(item.value)
        case .workspaceAccess:
            await applyWorkspaceAccessDecision(item.value)
        case .toolApproval:
            await applyToolApprovalDecision(item.value)
        case .provider:
            if item.value == SloppyTUIProviderDefinition.addNewProviderValue {
                showProviderCatalogPicker()
            } else {
                await applyModel(item.value)
            }
        case .providerCatalog:
            await beginProviderSetup(item.value)
        case .remoteInstance:
            await applyRemoteInstancePickerItem(item)
        case .remoteProject:
            await applyRemoteProjectPickerItem(item)
        case .projectFile:
            applyProjectFileSearchItem(item)
        case .projectTask:
            applyProjectTaskSearchItem(item)
        case .planInput:
            await answerPlanInput(with: item)
        case .theme:
            applyTheme(item.value)
        }
    }

    func selectableModels(base: [ProviderModelOption], selected: String) async -> [ProviderModelOption] {
        var seen: Set<String> = []
        var models: [ProviderModelOption] = []

        func add(_ option: ProviderModelOption) {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else {
                return
            }
            models.append(ProviderModelOption(
                id: id,
                title: option.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : option.title,
                contextWindow: option.contextWindow,
                capabilities: option.capabilities
            ))
        }

        for option in base {
            add(option)
        }

        let config = await service.getConfig()
        for entry in config.models where !entry.disabled {
            let definition = providerDefinition(for: entry)
            let response = await service.probeProvider(
                request: ProviderProbeRequest(
                    providerId: definition.probeID,
                    apiKey: entry.apiKey,
                    apiUrl: entry.apiUrl
                )
            )
            guard response.ok else {
                continue
            }
            for option in response.models {
                let rawId = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = runtimeModelID(rawId, provider: definition)
                add(ProviderModelOption(
                    id: id,
                    title: option.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawId : option.title,
                    contextWindow: option.contextWindow,
                    capabilities: option.capabilities
                ))
            }
        }

        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !seen.contains(selected) {
            add(CoreService.providerModelOption(for: selected))
        }

        return models
    }

    func applyModel(_ model: String) async {
        do {
            let config = try await service.getAgentConfig(agentID: agent.id)
            _ = try await service.updateAgentConfig(
                agentID: agent.id,
                request: AgentConfigUpdateRequest(
                    role: config.role,
                    selectedModel: model,
                    documents: config.documents,
                    heartbeat: config.heartbeat,
                    channelSessions: config.channelSessions,
                    runtime: config.runtime
                )
            )
            selectedModel = model
            selectedModelContextWindowTokens = contextWindowTokens(for: model, in: config.availableModels)
            dismissFirstStartBootstrapCard()
            dismissModelSwitchCards()
            await refreshTokenUsage(includeCost: true)
            appendLocalCard("Model switched to `\(model)`.", autoDismissAfter: 6)
        } catch {
            appendLocalCard("Model switch failed: \(String(describing: error))")
        }
    }

    func orderedModelsForPicker(_ models: [ProviderModelOption], selected: String) -> [ProviderModelOption] {
        let indexed = models.enumerated().map { index, model in
            (index: index, model: model, group: modelPickerGroup(for: model.id))
        }
        guard let selectedGroup = indexed.first(where: { $0.model.id == selected })?.group else {
            return indexed
                .sorted { lhs, rhs in
                    if lhs.group != rhs.group {
                        return lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
                    }
                    return lhs.index < rhs.index
                }
                .map { $0.model }
        }
        return indexed
            .sorted { lhs, rhs in
                if lhs.group == selectedGroup, rhs.group != selectedGroup { return true }
                if rhs.group == selectedGroup, lhs.group != selectedGroup { return false }
                if lhs.group != rhs.group {
                    return lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
                }
                if lhs.model.id == selected { return true }
                if rhs.model.id == selected { return false }
                return lhs.index < rhs.index
            }
            .map { $0.model }
    }

    func modelPickerGroup(for modelID: String) -> String {
        let parts = modelID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let provider = parts.count == 2 ? String(parts[0]) : "configured"
        let remainder = parts.count == 2 ? String(parts[1]) : modelID
        var groupParts = [modelPickerProviderTitle(provider)]

        let scopedParts = remainder.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        if scopedParts.count > 1 {
            groupParts.append(scopedParts[0])
            if let namespace = modelPickerNamespace(from: scopedParts.dropFirst().joined(separator: ":")) {
                groupParts.append(namespace)
            }
        } else if let namespace = modelPickerNamespace(from: remainder) {
            groupParts.append(namespace)
        }

        return groupParts.joined(separator: " / ")
    }

    func modelPickerProviderTitle(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic":
            return "Anthropic"
        case "gemini":
            return "Gemini"
        case "ollama":
            return "Ollama"
        case "openai-api":
            return "OpenAI API"
        case "openai-oauth":
            return "OpenAI Codex"
        case "opencode":
            return "OpenCode"
        case "openrouter":
            return "OpenRouter"
        case "configured":
            return "Configured"
        default:
            return provider
                .split(separator: "-")
                .map { segment in
                    segment.prefix(1).uppercased() + segment.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    func modelPickerNamespace(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let namespace = String(trimmed[..<slash])
            return namespace.isEmpty ? nil : namespace
        }
        let separators: Set<Character> = ["-", "_", "."]
        let prefix = String(trimmed.prefix { !separators.contains($0) })
        guard prefix.count >= 2, prefix.count < trimmed.count else {
            return nil
        }
        return prefix
    }

    func modelPickerLabel(for modelID: String, group: String) -> String {
        let providerTitle = group.split(separator: "/").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let providerPrefix = providerTitle.isEmpty ? "" : providerTitle.lowercased() + ":"
        var label = modelID
        if let colon = label.firstIndex(of: ":") {
            label = String(label[label.index(after: colon)...])
        }
        let groupParts = group
            .split(separator: "/")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in groupParts {
            if label.hasPrefix(part + ":") {
                label = String(label.dropFirst(part.count + 1))
            } else if label.hasPrefix(part + "/") {
                label = String(label.dropFirst(part.count + 1))
            }
        }
        if label == modelID, !providerPrefix.isEmpty, modelID.lowercased().hasPrefix(providerPrefix) {
            label = String(modelID.dropFirst(providerPrefix.count))
        }
        return label
    }

    func orderedAgentsForPicker(_ agents: [AgentSummary]) -> [AgentSummary] {
        guard let selectedIndex = agents.firstIndex(where: { $0.id == agent.id }) else {
            return agents
        }
        var ordered = agents
        let selectedAgent = ordered.remove(at: selectedIndex)
        ordered.insert(selectedAgent, at: 0)
        return ordered
    }

    func showProviderPicker() async {
        let config = await service.getConfig()
        let agentConfig = try? await service.getAgentConfig(agentID: agent.id)
        let selected = agentConfig?.selectedModel ?? selectedModel
        selectedModel = selected

        var items = config.models
            .filter { !$0.disabled }
            .map { model -> SloppyTUIPickerItem in
                let runtimeModel = runtimeModelID(for: model)
                return SloppyTUIPickerItem(
                    value: runtimeModel,
                    label: providerTitle(for: model),
                    description: SloppyTUITheme.compactPickerDescription(runtimeModel),
                    isCurrent: runtimeModel == selected || model.model == selected
                )
            }

        items.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        items.append(
            SloppyTUIPickerItem(
                value: SloppyTUIProviderDefinition.addNewProviderValue,
                label: "+ Add new provider",
                description: "Configure another provider",
                isCurrent: false
            )
        )

        activePicker = SloppyTUIPicker(
            kind: .provider,
            title: "Select provider",
            items: items,
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select provider with arrows, Enter to apply, Esc to cancel")
    }

    func showProviderCatalogPicker() {
        activePicker = SloppyTUIPicker(
            kind: .providerCatalog,
            title: "Add provider",
            items: SloppyTUIProviderDefinition.catalog.map { definition in
                SloppyTUIPickerItem(
                    value: definition.id,
                    label: definition.title,
                    description: definition.setupDescription,
                    isCurrent: false
                )
            },
            selectedIndex: 0
        )
        refreshStaticChrome(statusLine: "select provider type with arrows, Enter to configure, Esc to cancel")
    }

    func beginProviderSetup(_ providerID: String) async {
        let definition = SloppyTUIProviderDefinition(providerID)
        switch definition.id {
        case "openai-oauth":
            await startOpenAIDeviceFlow()
        case "anthropic-oauth":
            await startAnthropicOAuth()
        default:
            if definition.requiresAPIKey {
                editor.setText("/provider \(definition.id) ")
                persistDraft(editor.getText())
                refreshStaticChrome(statusLine: "enter API key for \(definition.title), optionally followed by a model")
            } else {
                await configureProvider([definition.id])
            }
        }
    }

    func switchAgent(_ agentID: String) async {
        do {
            let agents = try await service.listAgents(includeSystem: false)
            guard let nextAgent = agents.first(where: { $0.id == agentID }) else {
                appendLocalCard("Agent `\(agentID)` is no longer available.")
                return
            }
            agent = nextAgent
            session = SloppyTUIApp.makeDraftSession(agent: nextAgent, projectID: project.id)
            hasPersistedSession = false
            pendingDraftCheckpointSessionID = nil
            sessionCards = []
            subSessionCards = []
            invalidateSessionTimelineCache()
            lastRenderedSessionEventIDs = []
            lastAgentToolActivityAt = nil
            dismissAutoDiffPreview()
            persistSelection()
            streamTask?.cancel()
            await reloadSkillSlashCommands()
            await refreshSelectedModel()
            appendLocalCard("Agent switched to `\(nextAgent.displayName)`.")
        } catch {
            appendLocalCard("Agent switch failed: \(String(describing: error))")
        }
    }

    func switchProject(_ projectID: String) async {
        guard projectID != project.id else {
            appendLocalCard("Already in project `\(project.name)`.", autoDismissAfter: 6)
            return
        }
        await switchBackend(service, projectID: projectID, statusPrefix: "\(service.displayName) project")
    }

    func switchSession(_ sessionID: String) async {
        var sessions = (try? await service.listAgentSessions(agentID: agent.id, projectID: project.id)) ?? []
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions = (try? await service.listAgentSessions(agentID: agent.id)) ?? sessions
        }
        guard let nextSession = sessions.first(where: { $0.id == sessionID }) else {
            appendLocalCard("Session `\(sessionID)` is no longer available for `\(agent.displayName)`.")
            return
        }
        session = nextSession
        hasPersistedSession = true
        pendingDraftCheckpointSessionID = nil
        pendingPlanInputRequest = nil
        liveTurnTokenUsageTracker.reset()
        if activePicker?.kind == .planInput {
            activePicker = nil
        }
        lastAgentToolActivityAt = nil
        dismissAutoDiffPreview()
        persistSelection()
        trackSession(nextSession, opened: true)
        streamSession()
        await restorePersistedDirectoriesForCurrentSession()
        await prepareCurrentSessionContext()
        loadProjectFileIndex()
        await reloadSession()
        appendLocalCard("Session switched to `\(nextSession.title)`.\nResume shortcut: `sloppy -s \(nextSession.id)`")
    }

    func attachContext(_ mode: String?) async {
        switch mode?.lowercased() {
        case nil, "":
            await showContextUsage()
        case "changes":
            guard let lastChangeBatch else {
                appendLocalCard("No workspace change batch yet.")
                return
            }
            let paths = lastChangeBatch.changes.map { "- \($0.kind.rawValue): \($0.path)" }.joined(separator: "\n")
            pendingContext = "Workspace changes:\n\(paths)"
            appendLocalCard("Workspace change list will be attached to the next message.")
        case "diff":
            do {
                let sourceControl = try await service.projectWorkingTreeSourceControl(projectID: project.id)
                updateProjectSourceControlFooter(sourceControl)
                guard sourceControl.isRepository, !sourceControl.diff.isEmpty else {
                    appendLocalCard(sourceControl.message ?? "No source-control diff to attach.")
                    return
                }
                pendingContext = "Source-control working tree diff:\n```diff\n\(sourceControl.diff)\n```"
                appendLocalCard("Source-control diff will be attached to the next message.")
            } catch {
                appendLocalCard("Could not read source-control diff: \(String(describing: error))")
            }
        default:
            appendLocalCard("Use `/context`, `/context changes`, or `/context diff`.")
        }
    }

    func showContextUsage() async {
        await refreshTokenUsage(includeCost: false)
        let config = try? await service.getAgentConfig(agentID: agent.id)
        let model = config?.selectedModel ?? selectedModel
        selectedModel = model
        let models = config?.availableModels ?? []
        let option = models.first { $0.id == model } ?? CoreService.providerModelOption(for: model)
        let contextWindow = max(
            contextWindowTokens(for: model, in: models),
            CoreService.parseContextWindowString(option.contextWindow ?? "")
        )
        if contextWindow > 0 {
            selectedModelContextWindowTokens = contextWindow
            refreshStaticChrome()
        }

        let usage = await service.listTokenUsage(channelId: currentSessionChannelID())
        let ledger = await service.contextLedgerSnapshot(channelId: currentSessionChannelID())
        let summary = SloppyTUIContextUsageSummaryBuilder.makeSummary(
            modelTitle: option.title,
            modelID: model,
            contextWindowLabel: option.contextWindow ?? (contextWindow > 0 ? formatContextWindowLabel(contextWindow) : "unknown"),
            contextWindowTokens: contextWindow,
            usage: usage,
            ledger: ledger,
            pendingContextAttached: pendingContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            pendingUploadCount: pendingUploads.count
        )
        appendLocalCard(SloppyTUITheme.contextUsageMarkdown(summary), autoDismissAfter: 20)
    }

    func formatContextWindowLabel(_ tokens: Int) -> String {
        let value = max(0, tokens)
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(millions))M"
                : String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000
            return thousands.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(thousands))K"
                : String(format: "%.1fK", thousands)
        }
        return "\(value)"
    }

    func reloadProjectForTaskAutocompleteIfNeeded() {
        guard SloppyTUIAutocompleteFeatureFlags.projectTaskAutocompleteEnabled,
              projectTaskAutocompleteTask == nil,
              !projectTaskAutocompleteLoading else {
            return
        }
        projectTaskAutocompleteLoading = true
        projectTaskAutocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await service.getProject(id: project.id)
                await MainActor.run {
                    self.project = refreshed
                    self.projectTaskGeneration += 1
                    self.projectTaskSearchCache = nil
                    self.projectTaskAutocompleteLoading = false
                    self.projectTaskAutocompleteTask = nil
                    self.requestRender()
                }
            } catch {
                await MainActor.run {
                    self.projectTaskAutocompleteLoading = false
                    self.projectTaskAutocompleteTask = nil
                }
            }
        }
    }

    func showTasks() async {
        do {
            let refreshed = try await service.getProject(id: project.id)
            project = refreshed
            projectTaskGeneration += 1
            projectTaskSearchCache = nil
            if refreshed.tasks.isEmpty {
                appendLocalCard("No project tasks.")
                return
            }
            appendLocalCard(refreshed.tasks.map { "- `\($0.id)` [\($0.status)] \($0.title)" }.joined(separator: "\n"))
        } catch {
            appendLocalCard("Could not load tasks: \(String(describing: error))")
        }
    }

    func runtimeModelID(for model: CoreConfig.ModelConfig) -> String {
        let rawModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return runtimeModelID(rawModel, provider: providerDefinition(for: model))
    }

    func runtimeModelID(_ rawModel: String, provider: SloppyTUIProviderDefinition) -> String {
        let rawModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawModel.hasPrefix("openai-api:")
            || rawModel.hasPrefix("openai-oauth:")
            || rawModel.hasPrefix("openrouter:")
            || rawModel.hasPrefix("ollama:")
            || rawModel.hasPrefix("gemini:")
            || rawModel.hasPrefix("anthropic:")
            || rawModel.hasPrefix("claude-code:") {
            return rawModel
        }
        return provider.runtimeModelID(rawModel)
    }

    func providerTitle(for model: CoreConfig.ModelConfig) -> String {
        providerDefinition(for: model).title
    }

    func providerDefinition(for model: CoreConfig.ModelConfig) -> SloppyTUIProviderDefinition {
        if let catalog = model.providerCatalogId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !catalog.isEmpty {
            return SloppyTUIProviderDefinition(catalog)
        }
        let title = model.title.lowercased()
        let apiURL = model.apiUrl.lowercased()
        let rawModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawModel.hasPrefix("claude-code:") {
            return SloppyTUIProviderDefinition("claude-code")
        }
        if rawModel.hasPrefix("openrouter:") {
            return SloppyTUIProviderDefinition("openrouter")
        }
        if rawModel.hasPrefix("ollama:") {
            return SloppyTUIProviderDefinition("ollama")
        }
        if rawModel.hasPrefix("gemini:") {
            return SloppyTUIProviderDefinition("gemini")
        }
        if rawModel.hasPrefix("anthropic:") {
            return SloppyTUIProviderDefinition("anthropic")
        }
        if rawModel.hasPrefix("openai-api:") {
            return SloppyTUIProviderDefinition("openai-api")
        }
        if rawModel.hasPrefix("openai-oauth:") {
            return SloppyTUIProviderDefinition("openai-oauth")
        }
        if title.contains("openrouter") || apiURL.contains("openrouter") {
            return SloppyTUIProviderDefinition("openrouter")
        }
        if title.contains("gemini") || apiURL.contains("generativelanguage") {
            return SloppyTUIProviderDefinition("gemini")
        }
        if title.contains("anthropic") || apiURL.contains("anthropic") {
            return SloppyTUIProviderDefinition("anthropic")
        }
        if title.contains("ollama") || apiURL.contains("11434") {
            return SloppyTUIProviderDefinition("ollama")
        }
        if title.contains("oauth") || apiURL.contains("chatgpt.com") {
            return SloppyTUIProviderDefinition("openai-oauth")
        }
        return SloppyTUIProviderDefinition("openai-api")
    }

    func configureProvider(_ args: [String]) async {
        guard let providerID = args.first else {
            appendLocalCard("Usage: `/provider openai-api|openai-oauth|openrouter|gemini|anthropic|ollama <api-key> [model]` or `/provider claude-code [model]`")
            return
        }
        let key = args.dropFirst().first ?? ""
        let model = providerID == "claude-code" ? args.dropFirst().first : args.dropFirst(2).first
        let definition = SloppyTUIProviderDefinition(providerID)
        if definition.requiresAPIKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLocalCard("Enter an API key: `/provider \(definition.id) <api-key> [model]`")
            return
        }
        var config = await service.getConfig()
        config.workspace.name = CoreConfig.defaultWorkspaceName
        config.workspace.basePath = "~"
        let entry = CoreConfig.ModelConfig(
            title: definition.title,
            apiKey: definition.requiresAPIKey ? key : "",
            apiUrl: definition.apiURL,
            model: model ?? definition.model,
            providerCatalogId: definition.id
        )
        if let existingIndex = config.models.firstIndex(where: { providerDefinition(for: $0).id == definition.id }) {
            config.models[existingIndex] = entry
        } else {
            config.models.append(entry)
        }
        config.onboarding.completed = false
        do {
            _ = try await service.updateConfig(config)
            dismissFirstStartBootstrapCard()
            appendLocalCard("Provider saved as `\(definition.id)`. Use `/model \(definition.runtimeModelID(model ?? definition.model))` if you want to switch the active agent now.")
        } catch {
            appendLocalCard("Provider save failed: \(String(describing: error))")
        }
    }

    func startOpenAIDeviceFlow() async {
        do {
            let response = try await service.startOpenAIDeviceCode()
            appendLocalCard("""
            ## OpenAI Codex device auth
            Open \(response.verificationURL) and enter code `\(response.userCode)`.
            Polling automatically until approval or timeout.
            """)
            devicePollTask?.cancel()
            devicePollTask = Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(TimeInterval(response.expiresIn))
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(max(response.interval, 2)) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    do {
                        let poll = try await self.service.pollOpenAIDeviceCode(
                            request: .init(deviceAuthId: response.deviceAuthId, userCode: response.userCode)
                        )
                        await MainActor.run {
                            self.appendLocalCard("OpenAI device auth: \(poll.message)")
                        }
                        if poll.ok { break }
                    } catch {
                        await MainActor.run {
                            self.appendLocalCard("OpenAI device auth failed: \(String(describing: error))")
                        }
                        break
                    }
                }
            }
            await configureProvider(["openai-oauth"])
        } catch {
            appendLocalCard("Could not start OpenAI device flow: \(String(describing: error))")
        }
    }

    func startAnthropicOAuth() async {
        do {
            let response = try await service.startAnthropicOAuth(
                request: .init(redirectURI: "http://localhost:54545/oauth/anthropic/callback")
            )
            appendLocalCard("""
            ## Anthropic OAuth
            Open \(response.authorizationURL)

            Then paste the callback URL with `/anthropic-callback <url>`.
            """)
            await configureProvider(["anthropic-oauth", ""])
        } catch {
            appendLocalCard("Could not start Anthropic OAuth: \(String(describing: error))")
        }
    }

    func completeAnthropicOAuth(_ callbackURL: String) async {
        guard !callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLocalCard("Paste the full callback URL: `/anthropic-callback <url>`.")
            return
        }
        do {
            let response = try await service.completeAnthropicOAuth(request: .init(callbackURL: callbackURL))
            appendLocalCard(response.message)
        } catch {
            appendLocalCard("Anthropic OAuth failed: \(String(describing: error))")
        }
    }
}
