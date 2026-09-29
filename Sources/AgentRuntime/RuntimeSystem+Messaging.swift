import AnyLanguageModel
import Foundation
import Logging
import PluginSDK
import Protocols

public extension RuntimeSystem {
    func generateText(
        prompt: String,
        model: String?,
        reasoningEffort: ReasoningEffort? = nil,
        maxTokens: Int = 1024
    ) async -> String? {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = (normalizedModel?.isEmpty == false ? normalizedModel : nil) ?? defaultModel
        guard let modelProvider, let activeModel else {
            return nil
        }

        do {
            let languageModel = try await modelProvider.createLanguageModel(for: activeModel)
            let session = LanguageModelSession(model: languageModel, tools: [])
            let options = modelProvider.generationOptions(
                for: activeModel,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort
            )
            let response = try await session.respond(to: prompt, options: options)
            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.warning(
                "One-shot model generation failed",
                metadata: [
                    "model": .string(activeModel),
                    "prompt_chars": .stringConvertible(prompt.count),
                    "error": .string(error.localizedDescription),
                ]
            )
            return nil
        }
    }

    /// Posts channel message and executes route-specific orchestration flow.
    func postMessage(
        channelId: String,
        request: ChannelMessageRequest,
        onResponseChunk: (@Sendable (String) async -> Bool)? = nil,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)? = nil,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)? = nil,
        forceInlineResponse: Bool = false,
        nativeLoopConfig: NativeAgentLoopConfig = NativeAgentLoopConfig(),
        nativeLoopOutcomeHandler: (@Sendable (NativeAgentLoopOutcome) async -> Void)? = nil
    ) async -> ChannelRouteDecision {
        let ingest = await channels.ingest(channelId: channelId, request: request)
        let decision = forceInlineResponse
            ? ChannelRouteDecision(action: .respond, reason: "inline_response_required", confidence: 1, tokenBudget: ingest.decision.tokenBudget)
            : ingest.decision

        switch decision.action {
        case .respond:
            let taskID = UUID()
            let responseTask = Task { [weak self] in
                guard let self else { return }
                await self.respondInline(
                    channelId: channelId,
                    userMessage: Self.contentForModel(content: request.content, attachments: request.attachments),
                    model: request.model,
                    reasoningEffort: request.reasoningEffort,
                    onResponseChunk: onResponseChunk,
                    toolInvoker: toolInvoker,
                    observationHandler: observationHandler,
                    nativeLoopConfig: nativeLoopConfig,
                    nativeLoopOutcomeHandler: nativeLoopOutcomeHandler
                )
            }
            activeResponseTasks[channelId] = ActiveResponseTask(id: taskID, task: responseTask)
            await withTaskCancellationHandler {
                await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
            if activeResponseTasks[channelId]?.id == taskID {
                activeResponseTasks.removeValue(forKey: channelId)
            }

        case .spawnBranch:
            _ = await executeBranch(
                channelId: channelId,
                prompt: request.content
            )

        case .spawnWorker:
            let spec = WorkerTaskSpec(
                taskId: UUID().uuidString,
                channelId: channelId,
                title: "Channel worker",
                objective: request.content,
                tools: ["shell", "file", "exec", "browser"],
                mode: .interactive
            )
            let workerId = await workers.spawn(spec: spec, autoStart: true)
            await channels.attachWorker(channelId: channelId, workerId: workerId)
        }

        let effectiveUtilization: Double
        if let channelUtilization = await channels.snapshot(channelId: channelId)?.contextUtilization {
            effectiveUtilization = channelUtilization
        } else if let ledgerUtilization = contextLedgerByChannel[channelId]?.utilization {
            effectiveUtilization = ledgerUtilization
        } else {
            effectiveUtilization = ingest.contextUtilization
        }
        if let job = await compactor.evaluate(channelId: channelId, utilization: effectiveUtilization) {
            await compactor.apply(job: job, workers: workers)
            await channels.appendSystemMessage(channelId: channelId, content: "Compactor scheduled \(job.level.rawValue) policy")
        }

        return decision
    }

    func executeBranch(
        channelId: String,
        prompt: String,
        title: String = "Branch analysis"
    ) async -> BranchExecutionResult? {
        let branchId = await branches.spawn(channelId: channelId, prompt: prompt)
        let spec = WorkerTaskSpec(
            taskId: "branch-\(branchId)",
            channelId: channelId,
            title: title,
            objective: prompt,
            tools: ["shell", "file", "exec"],
            mode: .fireAndForget
        )
        let workerId = await workers.spawn(spec: spec, autoStart: false)
        await branches.attachWorker(branchId: branchId, workerId: workerId)
        await channels.attachWorker(channelId: channelId, workerId: workerId)

        let artifact = await workers.completeNow(workerId: workerId, summary: "Branch worker completed objective")
        await channels.detachWorker(channelId: channelId, workerId: workerId)

        guard let conclusion = await branches.conclude(
            branchId: branchId,
            summary: "Branch finished with focused conclusion",
            artifactRefs: artifact.map { [$0] } ?? [],
            tokenUsage: TokenUsage(prompt: 300, completion: 120)
        ) else {
            return nil
        }

        await channels.applyBranchConclusion(channelId: channelId, conclusion: conclusion)
        return BranchExecutionResult(
            branchId: branchId,
            workerId: workerId,
            conclusion: conclusion
        )
    }

    internal static func contentForModel(content: String, attachments: [ChannelAttachment]) -> String {
        guard !attachments.isEmpty else { return content }
        var lines: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(trimmed)
            lines.append("")
        }
        lines.append("Attachments:")
        for (index, attachment) in attachments.enumerated() {
            var details = ["type=\(attachment.type.rawValue)"]
            if let mimeType = attachment.mimeType { details.append("mime=\(mimeType)") }
            if let filename = attachment.filename { details.append("filename=\(filename)") }
            if let size = attachment.sizeBytes { details.append("size=\(size) bytes") }
            if let url = attachment.url { details.append("url=\(url)") }
            if let localPath = attachment.localPath { details.append("localPath=\(localPath)") }
            lines.append("- [\(index + 1)] id=\(attachment.id) \(details.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Uses configured model provider for direct responses or falls back to static response.
    /// Reuses a persistent `LanguageModelSession` per channel so the full transcript
    /// (tool calls, tool outputs, previous responses) is preserved across turns.
}
