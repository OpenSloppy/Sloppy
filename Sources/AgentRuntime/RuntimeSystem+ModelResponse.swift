import AnyLanguageModel
import Foundation
import Logging
import PluginSDK
import Protocols

extension RuntimeSystem {
    func respondInline(
        channelId: String,
        userMessage: String,
        model: String?,
        reasoningEffort: ReasoningEffort?,
        onResponseChunk: (@Sendable (String) async -> Bool)?,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)?,
        nativeLoopConfig: NativeAgentLoopConfig,
        nativeLoopOutcomeHandler: (@Sendable (NativeAgentLoopOutcome) async -> Void)?,
        streamRetries: Int = 2,
        reconnectAttempt: Int = 0
    ) async {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = (normalizedModel?.isEmpty == false ? normalizedModel : nil) ?? defaultModel

        guard let modelProvider, let activeModel else {
            let fallback = "Responded inline"
            if let observationHandler {
                await observationHandler(.thinking("Using fallback inline response because no model provider is configured."))
            }
            if let onResponseChunk {
                _ = await onResponseChunk(fallback)
            }
            await channels.appendSystemMessage(channelId: channelId, content: fallback)
            await nativeLoopOutcomeHandler?(
                NativeAgentLoopOutcome(
                    maxToolRounds: nativeLoopConfig.maxToolRounds,
                    finishedNaturally: true,
                    lastAssistantText: fallback,
                    turnExitReason: .fallbackNoModel
                )
            )
            return
        }

        let tracker = StreamActivityTracker()
        let responseStartedAt = Date()

        do {
            try Task.checkCancellation()

            async let preparedSession = getOrCreateSession(
                channelId: channelId,
                activeModel: activeModel,
                modelProvider: modelProvider,
                includeTools: toolInvoker != nil
            )
            async let recalledUserMessage = userMessageWithAutoRecalledMemory(
                channelId: channelId,
                userMessage: userMessage
            )
            let (session, modelUserMessage) = try await (preparedSession, recalledUserMessage)

            if let invoker = toolInvoker {
                let observingHandler: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
                    await self.logNativeToolCallDecoded(channelId: channelId, model: activeModel, request: request)
                    let toolCallID = request.argumentDiagnostics?.toolCallId ?? UUID().uuidString
                    await tracker.toolStarted(id: toolCallID)
                    if let observationHandler {
                        await observationHandler(.toolCall(request))
                    }
                    let result = await invoker(request)
                    if let observationHandler {
                        await observationHandler(.toolResult(result))
                    }
                    await tracker.toolFinished(id: toolCallID, result: result)
                    return result
                }
                session.toolExecutionDelegate = makeToolExecutionDelegate(
                    for: session,
                    channelId: channelId,
                    model: activeModel,
                    toolCallHandler: observingHandler,
                    loopTracker: tracker,
                    nativeLoopConfig: nativeLoopConfig
                )
            }

            let options = modelProvider.generationOptions(for: activeModel, maxTokens: nativeLoopConfig.maxOutputTokens, reasoningEffort: reasoningEffort)
            let transcriptSize = session.transcript.count
            let streamMode = toolInvoker != nil ? "native_tool_stream" : "respond_stream"
            contextLedgerByChannel[channelId] = await makeContextLedgerSnapshot(
                channelId: channelId,
                userMessage: modelUserMessage,
                modelProvider: modelProvider,
                includeTools: toolInvoker != nil,
                maxOutputTokens: nativeLoopConfig.maxOutputTokens
            )
            if let ledger = contextLedgerByChannel[channelId] {
                await channels.recordContextLedger(channelId: channelId, snapshot: ledger)
            }

            logger.info(
                "Model stream started",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: modelUserMessage.count,
                    mode: streamMode,
                    transcriptEntries: transcriptSize
                )
            )

            let streamStartedAt = Date()
            let streamIdleTimeoutSeconds = 120

            let responseStream = session.streamResponse(to: modelUserMessage, images: imagesByChannel[channelId] ?? [], options: options)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(10))
                            if await tracker.shouldTriggerIdleTimeout(thresholdSeconds: streamIdleTimeoutSeconds) {
                                throw StreamIdleTimeoutError()
                            }
                        }
                    }
                    group.addTask { @Sendable [tracker] in
                        for try await snapshot in responseStream {
                            await tracker.recordChunk(content: snapshot.content)
                            if let onResponseChunk {
                                let shouldContinue = await onResponseChunk(snapshot.content)
                                if !shouldContinue {
                                    await tracker.markCancelledByConsumer()
                                    return
                                }
                            }
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch is StreamIdleTimeoutError {
                if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }
                let chunks = await tracker.chunks
                let content = await tracker.latestContent
                logger.warning(
                    "Model stream timed out (idle), retrying",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: content.count,
                        streamChunks: chunks,
                        error: "No data received for \(streamIdleTimeoutSeconds)s"
                    )
                )
                if streamRetries > 0 {
                    sessionsByChannel.removeValue(forKey: channelId)
                    await respondInline(
                        channelId: channelId,
                        userMessage: userMessage,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        onResponseChunk: onResponseChunk,
                        toolInvoker: toolInvoker,
                        observationHandler: observationHandler,
                        nativeLoopConfig: nativeLoopConfig,
                        nativeLoopOutcomeHandler: nativeLoopOutcomeHandler,
                        streamRetries: streamRetries - 1
                    )
                    return
                }
                logger.warning(
                    "All stream retries exhausted, trying non-streaming completion",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "non_streaming_fallback"
                    )
                )
                sessionsByChannel.removeValue(forKey: channelId)
                do {
                    let freshSession = try await getOrCreateSession(
                        channelId: channelId,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        includeTools: toolInvoker != nil
                    )
                    if let invoker = toolInvoker {
                        let observingHandler: @Sendable (ToolInvocationRequest) async -> ToolInvocationResult = { request in
                            await self.logNativeToolCallDecoded(channelId: channelId, model: activeModel, request: request)
                            let toolCallID = request.argumentDiagnostics?.toolCallId ?? UUID().uuidString
                            await tracker.toolStarted(id: toolCallID)
                            if let observationHandler {
                                await observationHandler(.toolCall(request))
                            }
                            let result = await invoker(request)
                            if let observationHandler {
                                await observationHandler(.toolResult(result))
                            }
                            await tracker.toolFinished(id: toolCallID, result: result)
                            return result
                        }
                        freshSession.toolExecutionDelegate = makeToolExecutionDelegate(
                            for: freshSession,
                            channelId: channelId,
                            model: activeModel,
                            toolCallHandler: observingHandler,
                            loopTracker: tracker,
                            nativeLoopConfig: nativeLoopConfig
                        )
                    }
                    let fallbackResponse = try await freshSession.respond(to: modelUserMessage, images: imagesByChannel[channelId] ?? [], options: options)
                    if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }
                    var fallbackContent = fallbackResponse.content
                    await consumeProviderUsageIfAvailable(
                        channelId: channelId,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        observationHandler: observationHandler
                    )
                    logger.info(
                        "Non-streaming fallback succeeded",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "non_streaming_fallback",
                            durationMs: elapsedMilliseconds(since: streamStartedAt),
                            outputChars: fallbackContent.count
                        )
                    )
                    if fallbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if await tracker.sawToolTimeout {
                            fallbackContent = "Tool execution timed out before the model produced a final response. Please review the timed-out tool result and retry when ready."
                            logger.warning(
                                "Non-streaming fallback returned empty response after tool timeout",
                                metadata: modelCallMetadata(
                                    channelId: channelId,
                                    model: activeModel,
                                    reasoningEffort: reasoningEffort,
                                    promptChars: modelUserMessage.count,
                                    mode: "non_streaming_fallback_empty_tool_timeout",
                                    outputChars: fallbackContent.count
                                )
                            )
                        } else if let repaired = await attemptEmptyResponseRepair(
                            channelId: channelId,
                            activeModel: activeModel,
                            modelProvider: modelProvider,
                            reasoningEffort: reasoningEffort,
                            originalUserMessage: modelUserMessage,
                            transcript: freshSession.transcript,
                            onResponseChunk: nil
                        ) {
                            fallbackContent = repaired
                        } else {
                            fallbackContent = "Model returned an empty response. Please try rephrasing or try again."
                            logger.warning(
                                "Non-streaming fallback returned empty response after repair",
                                metadata: modelCallMetadata(
                                    channelId: channelId,
                                    model: activeModel,
                                    reasoningEffort: reasoningEffort,
                                    promptChars: modelUserMessage.count,
                                    mode: "non_streaming_fallback_empty"
                                )
                            )
                        }
                    }
                    if await tracker.hitToolRoundLimit {
                        sessionsByChannel.removeValue(forKey: channelId)
                        fallbackContent = Self.toolRoundLimitMessage
                    }
                    if let onResponseChunk {
                        _ = await onResponseChunk(fallbackContent)
                    }
                    await channels.appendSystemMessage(channelId: channelId, content: fallbackContent)
                    await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                        maxToolRounds: nativeLoopConfig.maxToolRounds,
                        finishedNaturally: !(await tracker.hitToolRoundLimit),
                        lastAssistantText: fallbackContent,
                        turnExitReason: await tracker.hitToolRoundLimit ? .toolRoundLimit : .streamIdleTimeoutFallback
                    ))
                    return
                } catch {
                    logger.warning(
                        "Non-streaming fallback also failed",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "non_streaming_fallback",
                            error: String(describing: error)
                        )
                    )
                    throw StreamIdleTimeoutError()
                }
            } catch let error as LanguageModelSession.GenerationError {
                if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                if case .exceededContextWindowSize = error {
                    logger.warning(
                        "Context window exceeded, recreating session with summary",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: streamMode,
                            error: String(describing: error)
                        )
                    )
                    let recovered = await respondAfterContextReset(
                        channelId: channelId,
                        userMessage: modelUserMessage,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        reasoningEffort: reasoningEffort,
                        onResponseChunk: onResponseChunk,
                        toolInvoker: toolInvoker,
                        observationHandler: observationHandler,
                        loopTracker: tracker,
                        nativeLoopConfig: nativeLoopConfig
                    )
                    if let recovered {
                        await channels.appendSystemMessage(channelId: channelId, content: recovered)
                    }
                    await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                        maxToolRounds: nativeLoopConfig.maxToolRounds,
                        finishedNaturally: recovered != nil,
                        lastAssistantText: recovered ?? "",
                        turnExitReason: recovered != nil ? .contextWindowRecovered : .contextWindowRecoveryFailed
                    ))
                    return
                }
                logger.warning(
                    "Model stream failed",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks,
                        error: String(describing: error)
                    )
                )
                throw error
            } catch {
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.warning(
                    "Model stream failed",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks,
                        error: String(describing: error)
                    )
                )
                throw error
            }

            if Task.isCancelled {
                sessionsByChannel.removeValue(forKey: channelId)
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.info(
                    "Model stream task cancelled",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks
                    )
                )
                await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                    maxToolRounds: nativeLoopConfig.maxToolRounds,
                    finishedNaturally: false,
                    lastAssistantText: latest,
                    turnExitReason: .modelCancelled
                ))
                return
            }

            let cancelledByConsumer = await tracker.wasCancelledByConsumer
            if cancelledByConsumer {
                let latest = await tracker.latestContent
                let streamChunks = await tracker.chunks
                logger.info(
                    "Model stream cancelled by response consumer",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: streamMode,
                        durationMs: elapsedMilliseconds(since: streamStartedAt),
                        outputChars: latest.count,
                        streamChunks: streamChunks
                    )
                )
                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                }
                await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                    maxToolRounds: nativeLoopConfig.maxToolRounds,
                    finishedNaturally: false,
                    lastAssistantText: latest,
                    turnExitReason: .consumerCancelled
                ))
                return
            }

            var latest = await tracker.latestContent
            let streamChunks = await tracker.chunks
            logger.info(
                "Model stream finished",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: modelUserMessage.count,
                    mode: streamMode,
                    durationMs: elapsedMilliseconds(since: streamStartedAt),
                    outputChars: latest.count,
                    streamChunks: streamChunks
                )
            )

            if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }

            if await tracker.hitToolRoundLimit {
                sessionsByChannel.removeValue(forKey: channelId)
                latest = Self.toolRoundLimitMessage
                logger.warning(
                    "Model hit native tool round limit",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "native_tool_round_limit",
                        outputChars: latest.count
                    )
                )
                if let onResponseChunk {
                    _ = await onResponseChunk(latest)
                }
                await channels.appendSystemMessage(channelId: channelId, content: latest)
                await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                    maxToolRounds: nativeLoopConfig.maxToolRounds,
                    finishedNaturally: false,
                    lastAssistantText: latest,
                    turnExitReason: .toolRoundLimit
                ))
                return
            }

            let reasoningText = modelProvider.reasoningCapture(for: activeModel)?.consume() ?? ""
            if !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let observationHandler {
                    await observationHandler(.thinking(reasoningText))
                }
            }

            await consumeProviderUsageIfAvailable(
                channelId: channelId,
                activeModel: activeModel,
                modelProvider: modelProvider,
                observationHandler: observationHandler
            )

            if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let completionStartedAt = Date()
                logger.info(
                    "Model completion started",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "respond_complete"
                    )
                )
                do {
                    let response = try await session.respond(to: modelUserMessage, images: imagesByChannel[channelId] ?? [], options: options)
                    if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }
                    latest = response.content
                    await consumeProviderUsageIfAvailable(
                        channelId: channelId,
                        activeModel: activeModel,
                        modelProvider: modelProvider,
                        observationHandler: observationHandler
                    )
                } catch {
                    logger.warning(
                        "Model completion failed",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_complete",
                            durationMs: elapsedMilliseconds(since: completionStartedAt),
                            error: String(describing: error)
                        )
                    )
                    throw error
                }
                logger.info(
                    "Model completion finished",
                    metadata: modelCallMetadata(
                        channelId: channelId,
                        model: activeModel,
                        reasoningEffort: reasoningEffort,
                        promptChars: modelUserMessage.count,
                        mode: "respond_complete",
                        durationMs: elapsedMilliseconds(since: completionStartedAt),
                        outputChars: latest.count
                    )
                )
                if let onResponseChunk {
                    _ = await onResponseChunk(latest)
                }
                if await tracker.hitToolRoundLimit {
                    sessionsByChannel.removeValue(forKey: channelId)
                    latest = Self.toolRoundLimitMessage
                    logger.warning(
                        "Model hit native tool round limit during completion",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "native_tool_round_limit",
                            outputChars: latest.count
                        )
                    )
                    if let onResponseChunk {
                        _ = await onResponseChunk(latest)
                    }
                    await channels.appendSystemMessage(channelId: channelId, content: latest)
                    await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                        maxToolRounds: nativeLoopConfig.maxToolRounds,
                        finishedNaturally: false,
                        lastAssistantText: latest,
                        turnExitReason: .toolRoundLimit
                    ))
                    return
                }
            }

            var turnExitReason: NativeAgentLoopTurnExitReason = .completed
            if latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if await tracker.sawToolTimeout {
                    latest = "Tool execution timed out before the model produced a final response. Please review the timed-out tool result and retry when ready."
                    turnExitReason = .emptyAfterToolTimeout
                    logger.warning(
                        "Model returned empty response after tool timeout",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_empty_tool_timeout",
                            outputChars: latest.count
                        )
                    )
                    if let onResponseChunk {
                        _ = await onResponseChunk(latest)
                    }
                } else if let repaired = await attemptEmptyResponseRepair(
                    channelId: channelId,
                    activeModel: activeModel,
                    modelProvider: modelProvider,
                    reasoningEffort: reasoningEffort,
                    originalUserMessage: modelUserMessage,
                    transcript: session.transcript,
                    onResponseChunk: onResponseChunk
                ) {
                    latest = repaired
                    turnExitReason = .emptyResponseRepaired
                } else {
                    latest = "Model returned an empty response. Please try rephrasing or try again."
                    turnExitReason = .emptyResponse
                    logger.warning(
                        "Model returned empty response after stream + completion + repair",
                        metadata: modelCallMetadata(
                            channelId: channelId,
                            model: activeModel,
                            reasoningEffort: reasoningEffort,
                            promptChars: modelUserMessage.count,
                            mode: "respond_empty_fallback"
                        )
                    )
                    if let onResponseChunk {
                        _ = await onResponseChunk(latest)
                    }
                }
            }

            await channels.appendSystemMessage(channelId: channelId, content: latest)
            await performanceTelemetry.record(await tracker.performanceSample(
                channelId: channelId,
                model: activeModel,
                streamStartedAt: responseStartedAt
            ))
            await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                maxToolRounds: nativeLoopConfig.maxToolRounds,
                finishedNaturally: true,
                lastAssistantText: latest,
                turnExitReason: turnExitReason
            ))
        } catch is CancellationError {
            sessionsByChannel.removeValue(forKey: channelId)
            logger.info(
                "Model response cancelled",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: userMessage.count,
                    mode: "cancelled"
                )
            )
            await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                maxToolRounds: nativeLoopConfig.maxToolRounds,
                finishedNaturally: false,
                lastAssistantText: await tracker.latestContent,
                turnExitReason: .modelCancelled
            ))
        } catch is StreamIdleTimeoutError {
            sessionsByChannel.removeValue(forKey: channelId)
            let text = "Model stream timed out before a final response was produced. Please retry the request."
            if let onResponseChunk {
                _ = await onResponseChunk(text)
            }
            await channels.appendSystemMessage(channelId: channelId, content: text)
            await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                maxToolRounds: nativeLoopConfig.maxToolRounds,
                finishedNaturally: false,
                lastAssistantText: text,
                turnExitReason: .streamRetryFailed
            ))
        } catch {
            if await finishToolLoopBlock(channelId: channelId, tracker: tracker, config: nativeLoopConfig, onResponseChunk: onResponseChunk, outcomeHandler: nativeLoopOutcomeHandler) { return }
            if await retryInterruptedModelSessionIfNeeded(
                channelId: channelId,
                userMessage: userMessage,
                model: model,
                reasoningEffort: reasoningEffort,
                onResponseChunk: onResponseChunk,
                toolInvoker: toolInvoker,
                observationHandler: observationHandler,
                nativeLoopConfig: nativeLoopConfig,
                nativeLoopOutcomeHandler: nativeLoopOutcomeHandler,
                streamRetries: streamRetries,
                reconnectAttempt: reconnectAttempt,
                error: error
            ) {
                return
            }

            sessionsByChannel.removeValue(forKey: channelId)
            let text = "Model provider error: \(error)"
            if let onResponseChunk {
                _ = await onResponseChunk(text)
            }
            await channels.appendSystemMessage(
                channelId: channelId,
                content: text
            )
            await nativeLoopOutcomeHandler?(await tracker.nativeLoopOutcome(
                maxToolRounds: nativeLoopConfig.maxToolRounds,
                finishedNaturally: false,
                lastAssistantText: text,
                turnExitReason: .modelProviderError
            ))
        }
    }

    func retryInterruptedModelSessionIfNeeded(
        channelId: String,
        userMessage: String,
        model: String?,
        reasoningEffort: ReasoningEffort?,
        onResponseChunk: (@Sendable (String) async -> Bool)?,
        toolInvoker: (@Sendable (ToolInvocationRequest) async -> ToolInvocationResult)?,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)?,
        nativeLoopConfig: NativeAgentLoopConfig,
        nativeLoopOutcomeHandler: (@Sendable (NativeAgentLoopOutcome) async -> Void)?,
        streamRetries: Int,
        reconnectAttempt: Int,
        error: any Error
    ) async -> Bool {
        let nextAttempt = reconnectAttempt + 1
        guard isInterruptedModelSessionError(error),
              nextAttempt <= modelReconnectDelays.count
        else {
            return false
        }

        sessionsByChannel.removeValue(forKey: channelId)
        let retryMessage = "Reconnecting \(nextAttempt)/\(modelReconnectDelays.count)"
        logger.warning(
            "Model stream interrupted, reconnecting",
            metadata: [
                "channelId": "\(channelId)",
                "attempt": "\(nextAttempt)",
                "maxAttempts": "\(modelReconnectDelays.count)",
                "error": "\(String(describing: error))",
            ]
        )
        await channels.appendSystemMessage(channelId: channelId, content: retryMessage)
        await modelReconnectSleeper(modelReconnectDelays[nextAttempt - 1])

        await respondInline(
            channelId: channelId,
            userMessage: userMessage,
            model: model,
            reasoningEffort: reasoningEffort,
            onResponseChunk: onResponseChunk,
            toolInvoker: toolInvoker,
            observationHandler: observationHandler,
            nativeLoopConfig: nativeLoopConfig,
            nativeLoopOutcomeHandler: nativeLoopOutcomeHandler,
            streamRetries: streamRetries,
            reconnectAttempt: nextAttempt
        )
        return true
    }

    func isInterruptedModelSessionError(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .networkConnectionLost || urlError.code == .timedOut
        }

        let nsError = error as NSError
        if nsError.domain == "NSURLErrorDomain", nsError.code == -1005 || nsError.code == -1001 {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isInterruptedModelSessionError(underlying)
        }

        return false
    }

    func attemptEmptyResponseRepair(
        channelId: String,
        activeModel: String,
        modelProvider: any ModelProvider,
        reasoningEffort: ReasoningEffort?,
        originalUserMessage: String,
        transcript: Transcript,
        onResponseChunk: (@Sendable (String) async -> Bool)?
    ) async -> String? {
        let startedAt = Date()
        let repairPrompt = await emptyResponseRepairPrompt(
            channelId: channelId,
            originalUserMessage: originalUserMessage,
            transcript: transcript
        )
        let options = modelProvider.generationOptions(for: activeModel, maxTokens: 1024, reasoningEffort: reasoningEffort)

        do {
            let languageModel = try await modelProvider.createLanguageModel(for: activeModel)
            let repairSession: LanguageModelSession
            if let instructions = sessionInstructions(channelId: channelId, modelProvider: modelProvider) {
                repairSession = LanguageModelSession(model: languageModel, tools: [], instructions: instructions)
            } else {
                repairSession = LanguageModelSession(model: languageModel, tools: [])
            }

            let response = try await repairSession.respond(to: repairPrompt, options: options)
            let repaired = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = !repaired.isEmpty
            logger.info(
                succeeded ? "Empty model response repair succeeded" : "Empty model response repair returned empty output",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: repairPrompt.count,
                    mode: "respond_empty_repair",
                    durationMs: elapsedMilliseconds(since: startedAt),
                    outputChars: response.content.count,
                    repairSucceeded: succeeded
                )
            )

            guard succeeded else {
                return nil
            }
            if let onResponseChunk {
                _ = await onResponseChunk(repaired)
            }
            await consumeProviderUsageIfAvailable(
                channelId: channelId,
                activeModel: activeModel,
                modelProvider: modelProvider,
                observationHandler: nil
            )
            return repaired
        } catch {
            logger.warning(
                "Empty model response repair failed",
                metadata: modelCallMetadata(
                    channelId: channelId,
                    model: activeModel,
                    reasoningEffort: reasoningEffort,
                    promptChars: repairPrompt.count,
                    mode: "respond_empty_repair",
                    durationMs: elapsedMilliseconds(since: startedAt),
                    repairSucceeded: false,
                    error: String(describing: error)
                )
            )
            return nil
        }
    }

    func emptyResponseRepairPrompt(
        channelId: String,
        originalUserMessage: String,
        transcript: Transcript
    ) async -> String {
        let channelMessages = await formatChannelMessagesForRepair(channelId: channelId)
        let modelTranscript = formatModelTranscriptForRepair(transcript)
        return """
        The previous model turn completed but produced no user-visible final answer.

        Write the final concise response for the user now. Use only the visible transcript, completed tool results, and progress shown below. Do not call tools. Do not claim to run new commands. Do not repeat completed work; summarize the solution or current outcome.

        [Current user message]
        \(originalUserMessage)

        [Visible channel transcript]
        \(channelMessages)

        [Model transcript and completed tool context]
        \(modelTranscript)

        [Final answer]
        """
    }

    func consumeProviderUsageIfAvailable(
        channelId: String,
        activeModel: String,
        modelProvider: any ModelProvider,
        observationHandler: (@Sendable (RuntimeResponseObservation) async -> Void)?
    ) async {
        guard let captured = modelProvider.tokenUsageCapture(for: activeModel)?.consume() else {
            return
        }

        let tokenUsage = TokenUsage(
            prompt: captured.prompt,
            completion: captured.completion,
            cachedInputTokens: captured.cachedInputTokens,
            cacheCreationInputTokens: captured.cacheCreationInputTokens,
            reasoningTokens: captured.reasoningTokens
        )
        if let existingLedger = contextLedgerByChannel[channelId] {
            contextLedgerByChannel[channelId] = existingLedger.withProviderUsage(tokenUsage)
        }
        await channels.recordTokenUsage(channelId: channelId, usage: tokenUsage)
        if let updatedLedger = contextLedgerByChannel[channelId] {
            await channels.recordContextLedger(channelId: channelId, snapshot: updatedLedger)
        }
        if let observationHandler {
            await observationHandler(.usage(tokenUsage))
        }
    }

    func formatChannelMessagesForRepair(channelId: String, maxCharacters: Int = 6000) async -> String {
        let messages = await channels.snapshot(channelId: channelId)?.messages ?? []
        let lines = messages.suffix(20).map { message in
            "\(message.userId): \(message.content)"
        }
        return limitedRepairContext(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    func formatModelTranscriptForRepair(_ transcript: Transcript, maxCharacters: Int = 12000) -> String {
        let lines = transcript.suffix(50).map { entry -> String in
            switch entry {
            case .instructions:
                return "instructions: [omitted]"
            case let .prompt(prompt):
                return "user: \(Self.textContent(from: prompt.segments))"
            case let .response(response):
                return "assistant: \(Self.textContent(from: response.segments))"
            case let .toolCalls(calls):
                let names = calls.map(\.toolName).joined(separator: ", ")
                return "tool calls: \(names)"
            case let .toolOutput(output):
                let text = Self.textContent(from: output.segments)
                return "tool result \(output.toolName): \(text)"
            }
        }
        return limitedRepairContext(lines.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    nonisolated static func textContent(from segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case let .text(text):
                return text.content
            case let .structure(structure):
                return structure.content.jsonString
            case .image:
                return "[image]"
            }
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func limitedRepairContext(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "(empty)"
        }
        guard trimmed.count > maxCharacters else {
            return trimmed
        }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -maxCharacters)
        return "[truncated]\n" + String(trimmed[start...])
    }
}
