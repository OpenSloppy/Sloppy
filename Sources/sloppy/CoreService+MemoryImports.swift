import Foundation
import Protocols

protocol MemoryImportToolService: Sendable {
    func startMemoryImport(agentID: String, request: MemoryImportRequest) async throws -> MemoryImportJob
    func importSessionAttachments(agentID: String, sessionID: String) async throws -> MemoryImportJob
    func getMemoryImport(agentID: String, id: String) async throws -> MemoryImportJob
    func resumeMemoryImport(agentID: String, id: String) async throws -> MemoryImportJob
    func memoryImportSource(agentID: String, id: String, sourceID: String) async throws -> MemoryImportSourceContent
    func memoryImportSourceLocations(agentID: String, memoryID: String) async throws -> [MemoryImportSourceLocation]
}

extension CoreService: MemoryImportToolService {
    func startMemoryImport(agentID: String, request: MemoryImportRequest) async throws -> MemoryImportJob {
        let agentID = try getAgent(id: agentID).id
        if let projectID = request.projectId { _ = try await getProject(id: projectID) }
        let processor = try memoryImportProcessor(agentID: agentID)
        let sessionID: String
        if let existing = request.sessionId {
            _ = try getAgentSession(agentID: agentID, sessionID: existing)
            sessionID = existing
        } else {
            sessionID = try await createAgentSession(agentID: agentID, request: .init(title: "Memory import")).id
        }
        let job = try await memoryImports.create(agentID: agentID, sessionID: sessionID, files: request.attachments, projectID: request.projectId)
        return try await memoryImports.launch(agentID: agentID, id: job.id, processor: processor, observer: memoryImportObserver())
    }

    func importSessionAttachments(agentID: String, sessionID: String) async throws -> MemoryImportJob {
        let agentID = try getAgent(id: agentID).id
        let detail = try getAgentSession(agentID: agentID, sessionID: sessionID)
        var seen = Set<String>()
        let attachments = detail.events.filter { $0.message?.role == .user }.flatMap { $0.message?.segments.compactMap(\.attachment) ?? [] }
            .filter { ["md", "markdown"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) && seen.insert($0.id).inserted }
        guard !attachments.isEmpty, attachments.count <= 20 else { throw MemoryImportError.invalid("This session must contain between 1 and 20 Markdown attachments.") }
        let uploads = try attachments.map { attachment -> AgentAttachmentUpload in
            guard let url = try sessionStore.resolveAttachmentFileURL(agentID: agentID, attachment: attachment),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else {
                throw MemoryImportError.invalid("An attachment is missing or exceeds the 1 MB limit.")
            }
            let data = try Data(contentsOf: url)
            return .init(name: attachment.name, mimeType: "text/markdown", sizeBytes: data.count, contentBase64: data.base64EncodedString())
        }
        return try await startMemoryImport(agentID: agentID, request: .init(sessionId: sessionID, attachments: uploads))
    }

    func getMemoryImport(agentID: String, id: String) async throws -> MemoryImportJob {
        let agentID = try getAgent(id: agentID).id
        return try await memoryImports.get(agentID: agentID, id: id)
    }

    func listMemoryImports(agentID: String) async throws -> [MemoryImportJob] {
        let agentID = try getAgent(id: agentID).id
        return try await memoryImports.list(agentID: agentID)
    }

    func resumeMemoryImport(agentID: String, id: String) async throws -> MemoryImportJob {
        let agentID = try getAgent(id: agentID).id
        let processor = try memoryImportProcessor(agentID: agentID)
        return try await memoryImports.launch(agentID: agentID, id: id, processor: processor, observer: memoryImportObserver())
    }

    func cancelMemoryImport(agentID: String, id: String) async throws -> MemoryImportJob {
        let agentID = try getAgent(id: agentID).id
        let job = try await memoryImports.cancel(agentID: agentID, id: id)
        await recordMemoryImportProgress(job)
        return job
    }

    func memoryImportSource(agentID: String, id: String, sourceID: String) async throws -> MemoryImportSourceContent {
        let agentID = try getAgent(id: agentID).id
        return try await memoryImports.source(agentID: agentID, id: id, sourceID: sourceID)
    }

    func resumePendingMemoryImports() async {
        do {
            for job in try await memoryImports.pending() {
                do { _ = try await resumeMemoryImport(agentID: job.agentId, id: job.id) }
                catch {
                    try? await memoryImports.markFailed(agentID: job.agentId, id: job.id, message: error.localizedDescription)
                    logger.error("memory.import.resume_failed", metadata: ["job_id": .string(job.id), "error": .string(error.localizedDescription)])
                }
            }
        } catch {
            logger.error("memory.import.recovery_failed", metadata: ["error": .string(error.localizedDescription)])
        }
    }

    func memoryImportSourceLocations(agentID: String, memoryID: String) async throws -> [MemoryImportSourceLocation] {
        let agentID = try getAgent(id: agentID).id
        let records = await memoryStore.entries(filter: .init(scope: .agent(agentID)))
        var exists = records.contains(where: { $0.id == memoryID })
        if !exists {
            let projects = Set(try await memoryImports.list(agentID: agentID).compactMap(\.projectId))
            for projectID in projects {
                let projectRecords = await memoryStore.entries(filter: .init(scope: .project(projectID)))
                if projectRecords.contains(where: { $0.id == memoryID }) { exists = true; break }
            }
        }
        guard exists else { throw MemoryImportError.notFound }
        return try await memoryImports.sourceLocations(agentID: agentID, memoryID: memoryID)
    }

    func memoryImportProcessor(agentID: String) throws -> MemoryImportModelProcessor {
        let config = try getAgentConfig(agentID: agentID)
        guard config.runtime.type == .native, let provider = modelProvider,
              let model = config.selectedModel ?? provider.supportedModels.first else {
            throw MemoryImportError.invalid("Memory import requires a configured native model for this agent.")
        }
        return MemoryImportModelProcessor(provider: provider, model: model)
    }

    private func memoryImportObserver() -> MemoryImportService.Observer {
        { [weak self] job in await self?.recordMemoryImportProgress(job) }
    }

    private func recordMemoryImportProgress(_ job: MemoryImportJob) async {
        let details = "\(job.completedUnits)/\(job.totalUnits) source parts verified; \(job.savedCount) records saved; \(job.duplicateCount) duplicates; \(job.ignoredCount) parts discarded after review."
        let stage: AgentRunStage = job.status == .completed ? .done : [.failed, .cancelled].contains(job.status) ? .interrupted : .thinking
        var events = [AgentSessionEvent(agentId: job.agentId, sessionId: job.sessionId, type: .runStatus,
            runStatus: .init(stage: stage, label: "Memory import: \(job.status.rawValue)", details: details + (job.error.map { " \($0)" } ?? "")))]
        if [.completed, .failed, .cancelled].contains(job.status) {
            let message = "Memory import \(job.status.rawValue). \(details)\n\n" +
                (job.error.map { "Remaining work is saved for retry. Error: \($0)\n\n" } ?? "") +
                "Source snapshots are stored in the import archive independently of chat attachments. Job ID: \(job.id)."
            events.append(.init(agentId: job.agentId, sessionId: job.sessionId, type: .message,
                message: .init(role: .assistant, segments: [.init(kind: .text, text: message)])))
        }
        do {
            let summary = try sessionStore.appendEvents(agentID: job.agentId, sessionID: job.sessionId, events: events)
            publishLiveSessionEvents(agentID: job.agentId, sessionID: job.sessionId, summary: summary, events: events)
        } catch {
            // Deleting a chat must not delete or interrupt an independent import job.
            logger.debug("memory.import.session_unavailable", metadata: ["job_id": .string(job.id)])
        }
    }
}
