import Foundation
import PluginSDK
import Protocols
#if canImport(Security)
import Security
import LocalAuthentication
#endif

extension CoreService {
    func taskSyncProvider(id requestedId: String?) -> (any TaskSyncProvider)? {
        let providerId = requestedId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let providerId, !providerId.isEmpty else {
            return taskSyncProviders["github"]
        }
        return taskSyncProviders[providerId]
    }

    func registerTaskSyncProvider(_ provider: any TaskSyncProvider, manifest: PluginManifest? = nil) {
        taskSyncProviders[provider.id] = provider
        let sourceKinds = manifest?.config["sourceKinds"]?.asArray?
            .compactMap(\.asString)
            .compactMap(ProjectTaskSyncSourceKind.init(rawValue:)) ?? []
        taskSyncProviderDescriptors[provider.id] = TaskSyncProviderDescriptor(
            id: provider.id,
            displayName: manifest?.config["displayName"]?.asString ?? provider.id,
            sourceKinds: sourceKinds,
            capabilities: manifest?.config["capabilities"]?.asArray?.compactMap(\.asString) ?? []
        )
    }

    public func listTaskSyncProviders() -> [TaskSyncProviderDescriptor] {
        taskSyncProviderDescriptors.values.sorted { $0.displayName < $1.displayName }
    }

    public enum TaskSyncError: LocalizedError {
        case invalidProjectID
        case invalidPayload
        case projectNotFound
        case notConfigured
        case unsupportedProvider
        case tokenMissing
        case manualRepositoryRequired
        case signatureInvalid

        public var errorDescription: String? {
            switch self {
            case .invalidProjectID:
                return "Invalid project ID."
            case .invalidPayload:
                return "Invalid task sync payload."
            case .projectNotFound:
                return "Project not found."
            case .notConfigured:
                return "Task sync is not linked for this project. Configure a provider and source first."
            case .unsupportedProvider:
                return "Unsupported task sync provider."
            case .tokenMissing:
                return "Task sync token missing."
            case .manualRepositoryRequired:
                return "GitHub repository could not be inferred. Provide a repository URL or owner/repo."
            case .signatureInvalid:
                return "GitHub webhook signature is invalid."
            }
        }
    }

    public func getTaskSyncSettings(projectID: String) async throws -> ProjectTaskSyncSettings {
        let project = try await taskSyncProject(projectID)
        return project.taskSyncSettings
    }

    public func updateTaskSyncSettings(
        projectID: String,
        request: ProjectTaskSyncSettingsUpdateRequest
    ) async throws -> ProjectTaskSyncResponse {
        var project = try await taskSyncProject(projectID)
        var settings = project.taskSyncSettings
        if let enabled = request.enabled { settings.enabled = enabled }
        if request.providerId != nil { settings.providerId = trimmedOrNil(request.providerId) }
        if request.repositoryURL != nil { settings.repositoryURL = trimmedOrNil(request.repositoryURL) }
        if request.repositorySlug != nil { settings.repositorySlug = trimmedOrNil(request.repositorySlug) }
        if request.projectURL != nil { settings.projectURL = trimmedOrNil(request.projectURL) }
        if request.projectNodeId != nil { settings.projectNodeId = trimmedOrNil(request.projectNodeId) }
        if request.defaultRepo != nil { settings.defaultRepo = trimmedOrNil(request.defaultRepo) }
        if let source = request.source { settings.source = normalizedTaskSyncSource(source) }
        if let tokenMode = request.tokenMode { settings.tokenMode = tokenMode }
        if let mappings = request.statusMappings { settings.statusMappings = normalizedStatusMappings(mappings) }
        if let mappings = request.inboundStatusMappings { settings.inboundStatusMappings = normalizedStatusMappings(mappings) }
        if let linkedProjects = request.linkedProjects { settings.linkedProjects = linkedProjects }
        if let schedule = request.syncSchedule { settings.syncSchedule = normalizedTaskSyncSchedule(schedule) }
        settings.health = ProjectTaskSyncHealth(status: "configured", checkedAt: Date())
        project.taskSyncSettings = masked(settings, projectID: project.id)
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func discoverTaskSync(
        projectID: String,
        request: ProjectTaskSyncDiscoverRequest
    ) async throws -> ProjectTaskSyncDiscoveryResponse {
        let project = try await taskSyncProject(projectID)
        let tokenMode = request.tokenMode ?? project.taskSyncSettings.tokenMode
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: request.providerId, tokenMode: tokenMode)
        guard token != nil else { throw TaskSyncError.tokenMissing }
        if request.providerId != "github" {
            guard let provider = taskSyncProvider(id: request.providerId),
                  let source = request.source,
                  !source.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw TaskSyncError.invalidPayload }
            let descriptor = try await provider.resolveProject(
                url: source.value,
                token: token,
                defaultRepo: source.kind.rawValue
            )
            let linked = ProjectTaskSyncLinkedProject(
                title: descriptor.title ?? source.displayName ?? request.providerId,
                projectURL: descriptor.projectURL,
                projectNodeId: descriptor.projectNodeId,
                tag: "\(request.providerId):source",
                statusOptions: descriptor.statusOptions
            )
            return ProjectTaskSyncDiscoveryResponse(
                providerId: request.providerId,
                repositoryURL: descriptor.projectURL,
                repositorySlug: descriptor.projectNodeId,
                projects: [linked],
                statusOptions: descriptor.statusOptions
            )
        }
        guard let repo = try resolvedGitHubRepository(for: project, manualRepositoryURL: request.repositoryURL) else {
            return ProjectTaskSyncDiscoveryResponse(
                manualRepositoryRequired: true,
                message: "GitHub repository could not be inferred from this Sloppy project."
            )
        }
        let provider = GitHubProjectTaskSyncProvider()
        let discovery = try await provider.discoverProjects(repositoryURL: repo.slug, token: token)
        return ProjectTaskSyncDiscoveryResponse(
            repositoryURL: discovery.repository.url,
            repositorySlug: discovery.repository.slug,
            projects: discovery.projects,
            statusOptions: discovery.statusOptions,
            manualRepositoryRequired: false,
            message: discovery.projects.isEmpty ? "No GitHub Projects were found for this repository or owner." : nil
        )
    }

    public func linkTaskSync(
        projectID: String,
        request: ProjectTaskSyncLinkRequest
    ) async throws -> ProjectTaskSyncResponse {
        if request.providerId != "github" {
            return try await linkGenericTaskSync(projectID: projectID, request: request)
        }
        var project = try await taskSyncProject(projectID)
        let tokenMode = request.tokenMode ?? .inherit
        let provider = GitHubProjectTaskSyncProvider()
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: request.providerId, tokenMode: tokenMode)
        let legacyProjectURL = request.projectURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token != nil || !(legacyProjectURL ?? "").isEmpty else { throw TaskSyncError.tokenMissing }
        let fallbackRepo = try request.defaultRepo
            ?? resolvedGitHubRepository(for: project, manualRepositoryURL: request.repositoryURL)?.slug
            ?? defaultGitHubRepoSlug(for: project)
        guard let repoSlug = fallbackRepo else { throw TaskSyncError.manualRepositoryRequired }
        let repo = try GitHubProjectTaskSyncProvider.parseRepository(repoSlug)
        let linkedProjects: [ProjectTaskSyncLinkedProject]
        let projectURL: String?
        let projectNodeId: String?
        if let legacyProjectURL, !legacyProjectURL.isEmpty {
            let descriptor = try await provider.resolveProject(
                url: legacyProjectURL,
                token: token,
                defaultRepo: repoSlug
            )
            let title = descriptor.title ?? "Project"
            let linked = ProjectTaskSyncLinkedProject(
                title: title,
                projectURL: descriptor.projectURL,
                projectNodeId: descriptor.projectNodeId,
                tag: GitHubProjectTaskSyncProvider.projectTag(title: title),
                statusOptions: descriptor.statusOptions
            )
            linkedProjects = [linked]
            projectURL = descriptor.projectURL
            projectNodeId = descriptor.projectNodeId
        } else {
            let discovery = try await provider.discoverProjects(repositoryURL: repo.slug, token: token)
            linkedProjects = discovery.projects
            projectURL = discovery.projects.first?.projectURL
            projectNodeId = discovery.projects.first?.projectNodeId
        }
        let secret = existingWebhookSecret(projectID: project.id, providerId: request.providerId) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try saveWebhookSecret(secret, projectID: project.id, providerId: request.providerId)
        var schedule = request.syncSchedule ?? ProjectTaskSyncSchedule(enabled: true, intervalMinutes: 15)
        schedule.intervalMinutes = max(1, schedule.intervalMinutes)
        let settings = ProjectTaskSyncSettings(
            enabled: true,
            providerId: request.providerId,
            repositoryURL: repo.url,
            repositorySlug: repo.slug,
            projectURL: projectURL,
            projectNodeId: projectNodeId,
            defaultRepo: repo.slug,
            tokenMode: tokenMode,
            statusMappings: normalizedStatusMappings(request.statusMappings ?? [:]),
            inboundStatusMappings: normalizedStatusMappings(request.inboundStatusMappings ?? request.statusMappings ?? [:]),
            linkedProjects: linkedProjects,
            syncSchedule: schedule,
            webhook: ProjectTaskSyncWebhookState(
                enabled: true,
                webhookURL: "/v1/task-sync/github/webhook",
                secretMasked: true,
                manualSetupRequired: true
            ),
            health: ProjectTaskSyncHealth(
                status: linkedProjects.isEmpty ? "partial" : "linked",
                message: linkedProjects.isEmpty ? "No GitHub Projects were found for \(repo.slug)." : "Linked \(linkedProjects.count) GitHub Project\(linkedProjects.count == 1 ? "" : "s").",
                checkedAt: Date()
            )
        )
        project.taskSyncSettings = masked(settings, projectID: project.id)
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    private func linkGenericTaskSync(
        projectID: String,
        request: ProjectTaskSyncLinkRequest
    ) async throws -> ProjectTaskSyncResponse {
        var project = try await taskSyncProject(projectID)
        guard let provider = taskSyncProvider(id: request.providerId),
              let rawSource = request.source,
              !rawSource.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TaskSyncError.unsupportedProvider }
        let tokenMode = request.tokenMode ?? .override
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: request.providerId, tokenMode: tokenMode)
        guard token != nil else { throw TaskSyncError.tokenMissing }
        let descriptor = try await provider.resolveProject(
            url: rawSource.value,
            token: token,
            defaultRepo: rawSource.kind.rawValue
        )
        let source = ProjectTaskSyncSource(
            kind: rawSource.kind,
            value: rawSource.value.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: descriptor.title ?? rawSource.displayName,
            url: descriptor.projectURL
        )
        let linked = ProjectTaskSyncLinkedProject(
            title: descriptor.title ?? request.providerId,
            projectURL: descriptor.projectURL,
            projectNodeId: descriptor.projectNodeId,
            tag: "\(request.providerId):source",
            statusOptions: descriptor.statusOptions
        )
        var schedule = request.syncSchedule ?? ProjectTaskSyncSchedule(enabled: true, intervalMinutes: 5)
        schedule.intervalMinutes = max(1, schedule.intervalMinutes)
        project.taskSyncSettings = ProjectTaskSyncSettings(
            enabled: true,
            providerId: request.providerId,
            projectURL: descriptor.projectURL,
            projectNodeId: descriptor.projectNodeId,
            source: source,
            tokenMode: tokenMode,
            statusMappings: normalizedStatusMappings(request.statusMappings ?? [:]),
            inboundStatusMappings: normalizedStatusMappings(request.inboundStatusMappings ?? [:]),
            linkedProjects: [linked],
            syncSchedule: schedule,
            health: ProjectTaskSyncHealth(status: "linked", message: "Linked \(linked.title).", checkedAt: Date())
        )
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func unlinkTaskSync(projectID: String) async throws -> ProjectTaskSyncResponse {
        var project = try await taskSyncProject(projectID)
        let providerId = project.taskSyncSettings.providerId ?? "github"
        try? clearOverrideToken(projectID: project.id, providerId: providerId)
        try? clearWebhookSecret(projectID: project.id, providerId: providerId)
        project.taskSyncSettings = ProjectTaskSyncSettings()
        project.updatedAt = Date()
        await store.saveProject(project)
        await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
        return ProjectTaskSyncResponse(project: project, settings: project.taskSyncSettings)
    }

    public func syncTaskSyncNow(projectID: String, full: Bool = true) async throws -> ProjectTaskSyncNowResponse {
        var project = try await taskSyncProject(projectID)
        var settings = project.taskSyncSettings
        guard settings.enabled, let providerId = settings.providerId else {
            throw TaskSyncError.notConfigured
        }
        guard let provider = taskSyncProvider(id: providerId) else {
            throw TaskSyncError.unsupportedProvider
        }
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: providerId, tokenMode: settings.tokenMode)
        do {
            if full {
                settings.syncSchedule.lastRunAt = nil
            }
            let imported = try await provider.importTasks(settings: settings, token: token)
            var importedCount = 0
            var updatedCount = 0
            var seenExternalKeys = Set<String>()
            for external in imported {
                if let identity = taskSyncIdentity(external.metadata) {
                    seenExternalKeys.insert(identity)
                }
                if let index = project.tasks.firstIndex(where: { taskSyncTask($0, matches: external.metadata) }) {
                    project.tasks[index].title = external.title
                    project.tasks[index].description = external.description
                    if let status = external.status {
                        project.tasks[index].status = status
                    }
                    if let priority = external.priority, ["low", "medium", "high"].contains(priority) {
                        project.tasks[index].priority = priority
                    }
                    project.tasks[index].externalMetadata = external.metadata
                    project.tasks[index].tags = mergedTaskSyncTags(existing: project.tasks[index].tags, incoming: external.tags)
                    project.tasks[index].isArchived = false
                    project.tasks[index].updatedAt = Date()
                    mergeImportedTaskSyncComments(external.comments, projectID: project.id, taskID: project.tasks[index].id)
                    updatedCount += 1
                } else {
                    let task = ProjectTask(
                        id: nextProjectTaskID(for: project),
                        title: external.title,
                        description: external.description,
                        priority: external.priority.flatMap { ["low", "medium", "high"].contains($0) ? $0 : nil } ?? "medium",
                        status: external.status ?? ProjectTaskStatus.backlog.rawValue,
                        externalMetadata: external.metadata,
                        tags: external.tags,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    project.tasks.append(task)
                    mergeImportedTaskSyncComments(external.comments, projectID: project.id, taskID: task.id)
                    importedCount += 1
                }
            }
            if providerId == "startrek" {
                for index in project.tasks.indices {
                    guard project.tasks[index].externalMetadata?.providerId == providerId,
                          let identity = taskSyncIdentity(project.tasks[index].externalMetadata),
                          !seenExternalKeys.contains(identity)
                    else { continue }
                    project.tasks[index].isArchived = true
                    project.tasks[index].externalMetadata?.syncState = "out_of_scope"
                    project.tasks[index].updatedAt = Date()
                }
            }
            project.taskSyncSettings.syncSchedule.lastRunAt = Date()
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "ok", checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
            return ProjectTaskSyncNowResponse(imported: importedCount, updated: updatedCount)
        } catch {
            project.taskSyncSettings.health = ProjectTaskSyncHealth(
                status: isTaskSyncConflict(error) ? "conflict" : "error",
                message: error.localizedDescription,
                checkedAt: Date()
            )
            project.updatedAt = Date()
            await store.saveProject(project)
            return ProjectTaskSyncNowResponse(message: error.localizedDescription)
        }
    }

    func listTaskSyncSchedules() async -> [ProjectTaskSyncScheduleEntry] {
        await store.listProjects().compactMap { project in
            let settings = project.taskSyncSettings
            guard settings.enabled,
                  let providerId = settings.providerId,
                  taskSyncProviders[providerId] != nil,
                  settings.syncSchedule.enabled
            else { return nil }
            return ProjectTaskSyncScheduleEntry(
                projectId: project.id,
                intervalMinutes: settings.syncSchedule.intervalMinutes,
                lastRunAt: settings.syncSchedule.lastRunAt
            )
        }
    }

    func runScheduledTaskSync(projectID: String) async {
        do {
            _ = try await syncTaskSyncNow(projectID: projectID, full: false)
        } catch {
            logger.warning("task_sync.scheduled_failed", metadata: ["project_id": .string(projectID), "error": .string(error.localizedDescription)])
        }
    }

    public func setTaskSyncToken(
        projectID: String,
        providerId: String,
        token: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        guard taskSyncProvider(id: providerId) != nil else { throw TaskSyncError.unsupportedProvider }
        let project = try await taskSyncProject(projectID)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskSyncError.invalidPayload }
        try saveOverrideToken(trimmed, projectID: project.id, providerId: providerId)
        var settings = project.taskSyncSettings
        settings.tokenMode = .override
        _ = try await updateTaskSyncSettings(
            projectID: project.id,
            request: ProjectTaskSyncSettingsUpdateRequest(tokenMode: .override)
        )
        return ProjectTaskSyncTokenStatusResponse(tokenMode: .override, hasOverrideToken: true, maskedToken: maskedToken(trimmed))
    }

    public func clearTaskSyncToken(
        projectID: String,
        providerId: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        guard taskSyncProvider(id: providerId) != nil else { throw TaskSyncError.unsupportedProvider }
        let project = try await taskSyncProject(projectID)
        try? clearOverrideToken(projectID: project.id, providerId: providerId)
        _ = try await updateTaskSyncSettings(
            projectID: project.id,
            request: ProjectTaskSyncSettingsUpdateRequest(tokenMode: .inherit)
        )
        return ProjectTaskSyncTokenStatusResponse(tokenMode: .inherit, hasOverrideToken: false, maskedToken: nil)
    }

    public func taskSyncTokenStatus(
        projectID: String,
        providerId: String
    ) async throws -> ProjectTaskSyncTokenStatusResponse {
        let project = try await taskSyncProject(projectID)
        let override = overrideToken(projectID: project.id, providerId: providerId)
        return ProjectTaskSyncTokenStatusResponse(
            tokenMode: project.taskSyncSettings.tokenMode,
            hasOverrideToken: override != nil,
            maskedToken: override.map(maskedToken)
        )
    }

    public func receiveTaskSyncWebhook(
        providerId: String,
        headers: [String: String],
        body: Data
    ) async throws -> TaskSyncWebhookResponse {
        guard providerId == "github" else { throw TaskSyncError.unsupportedProvider }
        let deliveryId = headers["x-github-delivery"] ?? headers["X-GitHub-Delivery"] ?? ""
        guard !deliveryId.isEmpty else { throw TaskSyncError.invalidPayload }
        if webhookDeliverySeen(providerId: providerId, deliveryId: deliveryId) {
            return TaskSyncWebhookResponse(ok: true, duplicate: true)
        }
        let projects = await store.listProjects()
            .filter { $0.taskSyncSettings.enabled && $0.taskSyncSettings.providerId == providerId }
        guard projects.contains(where: { project in
            guard let secret = existingWebhookSecret(projectID: project.id, providerId: providerId) else { return false }
            return TaskSyncCrypto.verifyGitHubSignature(
                body: body,
                secret: secret,
                signatureHeader: headers["x-hub-signature-256"] ?? headers["X-Hub-Signature-256"]
            )
        }) else {
            throw TaskSyncError.signatureInvalid
        }
        markWebhookDeliverySeen(providerId: providerId, deliveryId: deliveryId)
        let event = headers["x-github-event"] ?? headers["X-GitHub-Event"] ?? ""
        await applyGitHubWebhook(event: event, deliveryId: deliveryId, body: body, projects: projects)
        return TaskSyncWebhookResponse(ok: true)
    }

    func syncOutboundTaskIfNeeded(projectID: String, taskID: String) async {
        guard var project = await store.project(id: projectID),
              project.taskSyncSettings.enabled,
              let providerId = project.taskSyncSettings.providerId,
              let provider = taskSyncProvider(id: providerId),
              let index = project.tasks.firstIndex(where: { $0.id == taskID })
        else { return }
        var task = project.tasks[index]
        guard task.externalMetadata?.origin != providerId else { return }
        guard task.externalMetadata?.externalIssueId != nil || task.externalMetadata?.externalIssueNumber != nil else { return }
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: providerId, tokenMode: project.taskSyncSettings.tokenMode)
        do {
            let metadata = try await provider.createOrUpdateTask(task, settings: project.taskSyncSettings, token: token)
            task.externalMetadata = metadata
            task.tags = Array(Set(task.tags + [providerId, "sloppy:\(project.id)"])).sorted()
            task.updatedAt = Date()
            project.tasks[index] = task
            project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "ok", checkedAt: Date())
            project.updatedAt = Date()
            await store.saveProject(project)
        } catch {
            project.taskSyncSettings.health = ProjectTaskSyncHealth(
                status: isTaskSyncConflict(error) ? "conflict" : "error",
                message: error.localizedDescription,
                checkedAt: Date()
            )
            project.updatedAt = Date()
            await store.saveProject(project)
        }
    }

    func mirrorOutboundCommentIfNeeded(projectID: String, taskID: String, commentID: String) async {
        // Provider calls suspend the Core actor. Serialize per task so simultaneous reports
        // observe the preceding delivery before checking for duplicates.
        let key = taskCommentsFileURL(projectID: projectID, taskID: taskID).path
        let previous = taskCommentMirrorQueues[key]?.task
        let id = UUID()
        let pending = Task {
            await previous?.value
            await self.performOutboundCommentMirror(projectID: projectID, taskID: taskID, commentID: commentID)
        }
        taskCommentMirrorQueues[key] = (id, pending)
        await pending.value
        if taskCommentMirrorQueues[key]?.id == id {
            taskCommentMirrorQueues.removeValue(forKey: key)
        }
    }

    private func performOutboundCommentMirror(projectID: String, taskID: String, commentID: String) async {
        guard let project = await store.project(id: projectID),
              project.taskSyncSettings.enabled,
              let providerId = project.taskSyncSettings.providerId,
              let provider = taskSyncProvider(id: providerId),
              let task = project.tasks.first(where: { $0.id == taskID })
        else { return }
        let comments = await listTaskComments(projectID: projectID, taskID: taskID)
        guard var comment = comments.first(where: { $0.id == commentID }),
              comment.externalMetadata?.origin != providerId,
              comment.externalMetadata?.externalCommentId == nil,
              comment.effectiveKind != .technical,
              !comment.isAgentReply,
              comment.mentionedActorId == nil
        else { return }
        // Collapse repeated automated reports, even when technical events occurred in between.
        // Human comments always retain their normal publishing behavior.
        if comment.effectiveKind == .result || comment.effectiveKind == .actionRequired,
           let index = comments.firstIndex(where: { $0.id == commentID }),
           let previous = comments[..<index].last(where: { $0.effectiveKind != .technical }),
           previous.effectiveKind == comment.effectiveKind,
           previous.content.trimmingCharacters(in: .whitespacesAndNewlines) == comment.content.trimmingCharacters(in: .whitespacesAndNewlines),
           previous.externalMetadata?.providerId == providerId,
           previous.externalMetadata?.externalCommentId != nil {
            // Preserve the remote identity so a later delivery attempt stays idempotent.
            comment.externalMetadata = previous.externalMetadata
            var updated = comments
            updated[index] = comment
            saveTaskComments(updated, projectID: projectID, taskID: taskID)
            return
        }
        let token = resolvedTaskSyncToken(projectID: project.id, providerId: providerId, tokenMode: project.taskSyncSettings.tokenMode)
        do {
            comment.externalMetadata = try await provider.mirrorComment(comment, task: task, settings: project.taskSyncSettings, token: token)
            var updated = await listTaskComments(projectID: projectID, taskID: taskID)
            if let index = updated.firstIndex(where: { $0.id == commentID }) {
                updated[index] = comment
                saveTaskComments(updated, projectID: projectID, taskID: taskID)
            }
        } catch {
            logger.warning("task_sync.comment_mirror_failed", metadata: ["project_id": .string(projectID), "task_id": .string(taskID), "error": .string(error.localizedDescription)])
        }
    }

    private func taskSyncProject(_ projectID: String) async throws -> ProjectRecord {
        guard let normalized = normalizedProjectID(projectID) else { throw TaskSyncError.invalidProjectID }
        guard let project = await store.project(id: normalized) else { throw TaskSyncError.projectNotFound }
        return project
    }

    private func providerDirectory(providerId: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("task-sync", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
    }

    private func overrideTokenURL(projectID: String, providerId: String) -> URL {
        providerDirectory(providerId: providerId).appendingPathComponent("\(projectID).token")
    }

    private func webhookSecretURL(projectID: String, providerId: String) -> URL {
        providerDirectory(providerId: providerId).appendingPathComponent("\(projectID).webhook-secret")
    }

    private func saveOverrideToken(_ token: String, projectID: String, providerId: String) throws {
        if providerId == "startrek" {
            #if canImport(Security)
            try saveTaskSyncKeychainToken(token, projectID: projectID, providerId: providerId)
            return
            #else
            throw NSError(
                domain: "Sloppy.TaskSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Persistent StartTrack OAuth storage is unavailable on this platform. Set STARTREK_TOKEN instead."]
            )
            #endif
        }
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
    }

    private func clearOverrideToken(projectID: String, providerId: String) throws {
        if providerId == "startrek" {
            #if canImport(Security)
            try deleteTaskSyncKeychainToken(projectID: projectID, providerId: providerId)
            #endif
            return
        }
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func overrideToken(projectID: String, providerId: String) -> String? {
        if providerId == "startrek" {
            #if canImport(Security)
            return taskSyncKeychainToken(projectID: projectID, providerId: providerId)
            #else
            return nil
            #endif
        }
        let url = overrideTokenURL(projectID: projectID, providerId: providerId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private func resolvedTaskSyncToken(projectID: String, providerId: String, tokenMode: TaskSyncTokenMode) -> String? {
        if tokenMode == .override {
            return overrideToken(projectID: projectID, providerId: providerId)
        }
        if providerId == "github" {
            return githubAuthService.currentToken()
        }
        if providerId == "startrek" {
            let token = ProcessInfo.processInfo.environment["STARTREK_TOKEN"] ?? ""
            return token.isEmpty ? nil : token
        }
        return nil
    }

    private func isTaskSyncConflict(_ error: Error) -> Bool {
        if case NodePluginRuntimeError.pluginError(let code, _) = error,
           code == "conflict" {
            return true
        }
        return error.localizedDescription.lowercased().contains("conflict")
    }

    #if canImport(Security)
    private func taskSyncKeychainQuery(projectID: String, providerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sloppy.task-sync",
            kSecAttrAccount as String: "\(providerId):\(projectID)",
        ]
    }

    private func saveTaskSyncKeychainToken(_ token: String, projectID: String, providerId: String) throws {
        let query = taskSyncKeychainQuery(projectID: projectID, providerId: providerId)
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func taskSyncKeychainToken(projectID: String, providerId: String) -> String? {
        var query = taskSyncKeychainQuery(projectID: projectID, providerId: providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // A rebuilt background daemon may need renewed Keychain approval.
        // Never hold CoreService while an OS authorization dialog waits for input.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authentication
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteTaskSyncKeychainToken(projectID: String, providerId: String) throws {
        let status = SecItemDelete(taskSyncKeychainQuery(projectID: projectID, providerId: providerId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    #endif

    private func saveWebhookSecret(_ secret: String, projectID: String, providerId: String) throws {
        let url = webhookSecretURL(projectID: projectID, providerId: providerId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(secret.utf8).write(to: url, options: .atomic)
    }

    private func clearWebhookSecret(projectID: String, providerId: String) throws {
        let url = webhookSecretURL(projectID: projectID, providerId: providerId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func existingWebhookSecret(projectID: String, providerId: String) -> String? {
        guard let data = try? Data(contentsOf: webhookSecretURL(projectID: projectID, providerId: providerId)) else {
            return nil
        }
        let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return secret.isEmpty ? nil : secret
    }

    private func webhookDeliveryURL(providerId: String, deliveryId: String) -> URL {
        workspaceRootURL
            .appendingPathComponent("task-sync", isDirectory: true)
            .appendingPathComponent("deliveries", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
            .appendingPathComponent(deliveryId)
    }

    private func webhookDeliverySeen(providerId: String, deliveryId: String) -> Bool {
        FileManager.default.fileExists(atPath: webhookDeliveryURL(providerId: providerId, deliveryId: deliveryId).path)
    }

    private func markWebhookDeliverySeen(providerId: String, deliveryId: String) {
        let url = webhookDeliveryURL(providerId: providerId, deliveryId: deliveryId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(Date().description.utf8).write(to: url, options: .atomic)
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return "********" }
        return "\(token.prefix(4))...\(token.suffix(4))"
    }

    private func masked(_ settings: ProjectTaskSyncSettings, projectID: String) -> ProjectTaskSyncSettings {
        var next = settings
        next.webhook.secretMasked = existingWebhookSecret(projectID: projectID, providerId: settings.providerId ?? "github") != nil
        return next
    }

    private func trimmedOrNil(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedStatusMappings(_ raw: [String: String]) -> [String: String] {
        raw.reduce(into: [:]) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
    }

    private func normalizedTaskSyncSchedule(_ schedule: ProjectTaskSyncSchedule) -> ProjectTaskSyncSchedule {
        ProjectTaskSyncSchedule(
            enabled: schedule.enabled,
            intervalMinutes: max(1, schedule.intervalMinutes),
            lastRunAt: schedule.lastRunAt
        )
    }

    private func normalizedTaskSyncSource(_ source: ProjectTaskSyncSource) -> ProjectTaskSyncSource {
        ProjectTaskSyncSource(
            kind: source.kind,
            value: source.value.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: trimmedOrNil(source.displayName),
            url: trimmedOrNil(source.url)
        )
    }

    private func mergedTaskSyncTags(existing: [String], incoming: [String]) -> [String] {
        let preserved = existing.filter { !$0.lowercased().hasPrefix("gh:") && $0 != "github" }
        return Array(Set(preserved + incoming)).sorted()
    }

    private func defaultGitHubRepoSlug(for project: ProjectRecord) throws -> String? {
        guard let repoPath = project.repoPath, !repoPath.isEmpty else { return nil }
        let metadata = GitRepositoryInspector().inspectRepository(at: URL(fileURLWithPath: repoPath))
        if let remote = metadata?.githubRemote {
            return "\(remote.owner)/\(remote.repo)"
        }
        return nil
    }

    private func resolvedGitHubRepository(
        for project: ProjectRecord,
        manualRepositoryURL: String?
    ) throws -> GitHubRepositoryReference? {
        if let manual = trimmedOrNil(manualRepositoryURL) {
            return try GitHubProjectTaskSyncProvider.parseRepository(manual)
        }
        if let slug = trimmedOrNil(project.taskSyncSettings.repositorySlug) {
            return try GitHubProjectTaskSyncProvider.parseRepository(slug)
        }
        if let repo = try defaultGitHubRepoSlug(for: project) {
            return try GitHubProjectTaskSyncProvider.parseRepository(repo)
        }
        return nil
    }

    private func taskSyncTask(_ task: ProjectTask, matches metadata: TaskExternalMetadata) -> Bool {
        guard let existing = task.externalMetadata else { return false }
        guard existing.providerId == nil || metadata.providerId == nil || existing.providerId == metadata.providerId else {
            return false
        }
        return (existing.externalIssueKey != nil && existing.externalIssueKey == metadata.externalIssueKey)
            || existing.externalIssueId == metadata.externalIssueId
            || existing.externalIssueURL == metadata.externalIssueURL
            || (existing.externalIssueNumber != nil && existing.externalIssueNumber == metadata.externalIssueNumber)
    }

    private func taskSyncIdentity(_ metadata: TaskExternalMetadata?) -> String? {
        guard let metadata else { return nil }
        return metadata.externalIssueKey ?? metadata.externalIssueId ?? metadata.externalIssueURL
            ?? metadata.externalIssueNumber.map(String.init)
    }

    private func mergeImportedTaskSyncComments(
        _ imported: [TaskSyncExternalComment],
        projectID: String,
        taskID: String
    ) {
        guard !imported.isEmpty else { return }
        var comments = (try? JSONDecoder().decode(
            [TaskComment].self,
            from: Data(contentsOf: taskCommentsFileURL(projectID: projectID, taskID: taskID))
        )) ?? []
        for external in imported {
            let externalID = external.metadata.externalCommentId
            if let index = comments.firstIndex(where: {
                externalID != nil && $0.externalMetadata?.externalCommentId == externalID
            }) {
                comments[index].content = external.body
                comments[index].sourceAuthor = external.author
                comments[index].externalMetadata = external.metadata
                if let createdAt = external.createdAt {
                    comments[index].createdAt = createdAt
                }
            } else {
                comments.append(TaskComment(
                    id: UUID().uuidString,
                    taskId: taskID,
                    content: external.body,
                    authorActorId: external.metadata.providerId ?? "external",
                    externalMetadata: external.metadata,
                    sourceAuthor: external.author,
                    createdAt: external.createdAt ?? Date()
                ))
            }
        }
        comments.sort { $0.createdAt < $1.createdAt }
        saveTaskComments(comments, projectID: projectID, taskID: taskID)
    }

    private func applyGitHubWebhook(
        event: String,
        deliveryId: String,
        body: Data,
        projects: [ProjectRecord]
    ) async {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        for var project in projects {
            var changed = false
            if event == "issues", let issue = object["issue"] as? [String: Any] {
                changed = applyGitHubIssue(issue, to: &project) || changed
            } else if event == "issue_comment",
                      let issue = object["issue"] as? [String: Any],
                      let comment = object["comment"] as? [String: Any] {
                changed = applyGitHubIssue(issue, to: &project) || changed
                changed = importGitHubComment(comment, issue: issue, project: project) || changed
            } else if event == "projects_v2_item" {
                project.taskSyncSettings.health = ProjectTaskSyncHealth(status: "received", message: "Project item webhook received.", checkedAt: Date())
                changed = true
            }
            if changed {
                project.taskSyncSettings.webhook.lastDeliveryId = deliveryId
                project.taskSyncSettings.webhook.lastReceivedAt = Date()
                project.updatedAt = Date()
                await store.saveProject(project)
                await kanbanEventService.push(KanbanEvent(type: .projectUpdated, projectId: project.id))
            }
        }
    }

    private func applyGitHubIssue(_ issue: [String: Any], to project: inout ProjectRecord) -> Bool {
        let issueId = issue["node_id"] as? String ?? (issue["id"] as? NSNumber)?.stringValue
        let issueURL = issue["html_url"] as? String
        let issueNumber = (issue["number"] as? NSNumber)?.intValue
        guard let index = project.tasks.firstIndex(where: { task in
            let external = task.externalMetadata
            return external?.externalIssueId == issueId
                || external?.externalIssueURL == issueURL
                || (issueNumber != nil && external?.externalIssueNumber == issueNumber)
        }) else {
            return false
        }
        if let title = issue["title"] as? String {
            project.tasks[index].title = title
        }
        if let body = issue["body"] as? String {
            project.tasks[index].description = body
        }
        if (issue["state"] as? String) == "closed" {
            project.tasks[index].status = ProjectTaskStatus.done.rawValue
        }
        var external = project.tasks[index].externalMetadata ?? TaskExternalMetadata(providerId: "github")
        external.externalIssueId = issueId
        external.externalIssueNumber = issueNumber
        external.externalIssueURL = issueURL
        external.origin = "github"
        external.syncState = "synced"
        external.lastSyncedAt = Date()
        project.tasks[index].externalMetadata = external
        project.tasks[index].tags = Array(Set(project.tasks[index].tags + ["github", "sloppy:\(project.id)"])).sorted()
        project.tasks[index].updatedAt = Date()
        return true
    }

    private func importGitHubComment(
        _ comment: [String: Any],
        issue: [String: Any],
        project: ProjectRecord
    ) -> Bool {
        let issueId = issue["node_id"] as? String ?? (issue["id"] as? NSNumber)?.stringValue
        let issueURL = issue["html_url"] as? String
        let issueNumber = (issue["number"] as? NSNumber)?.intValue
        guard let task = project.tasks.first(where: { task in
            let external = task.externalMetadata
            return external?.externalIssueId == issueId
                || external?.externalIssueURL == issueURL
                || (issueNumber != nil && external?.externalIssueNumber == issueNumber)
        }) else {
            return false
        }
        let commentId = (comment["id"] as? NSNumber)?.stringValue
        var comments = (try? JSONDecoder().decode([TaskComment].self, from: Data(contentsOf: taskCommentsFileURL(projectID: project.id, taskID: task.id)))) ?? []
        guard !comments.contains(where: { $0.externalMetadata?.externalCommentId == commentId }) else {
            return false
        }
        let user = (comment["user"] as? [String: Any])?["login"] as? String
        comments.append(TaskComment(
            id: UUID().uuidString,
            taskId: task.id,
            content: comment["body"] as? String ?? "",
            authorActorId: "github",
            externalMetadata: TaskExternalMetadata(
                providerId: "github",
                externalIssueId: issueId,
                externalIssueNumber: issueNumber,
                externalIssueURL: issueURL,
                externalCommentId: commentId,
                origin: "github",
                syncState: "synced",
                lastSyncedAt: Date()
            ),
            sourceAuthor: user,
            createdAt: Date()
        ))
        saveTaskComments(comments, projectID: project.id, taskID: task.id)
        return true
    }
}
