# PRD: Agent Runtime Vision

Status: Internal draft for maintainers and coding agents  
Date: 2026-05-14  
Audience: Sloppy maintainers and repository-aware agents  
Public docs: Excluded from VitePress via `srcExclude`

## 1. Executive Summary

- **Problem Statement**: Sloppy needs a dependable runtime layer that lets agents converse, use tools, spawn focused work, compact context, recover from interruption, and expose enough state for humans and other agents to understand what happened. Without a typed runtime contract, agent behavior drifts into ad hoc text parsing, brittle session state, and hard-to-debug orchestration.
- **Proposed Solution**: Treat `AgentRuntime` as Sloppy's typed control plane: actor-isolated channel, worker, branch, compactor, visor, event, memory, and model-session primitives connected through explicit protocols and recoverable event records.
- **Success Criteria**:
  - Runtime event payloads remain at or below `EventPayloadLimits.maxBytesPerEventPayload` of 16 KB, with regression coverage for representative event types.
  - `swift test --filter AgentRuntimeTests` passes on macOS and Linux-supported paths before runtime contract changes merge.
  - A channel message can produce a streamed response, tool observations, cancellation, persisted events, and recovery without relying on natural-language phrase matching.
  - Worker lifecycle transitions are observable through typed states: `queued`, `running`, `waitingInput`, `completed`, and `failed`.
  - Visor, compactor, and recovery flows can be tested with deterministic fake providers/executors.

## 2. User Experience & Functionality

- **User Personas**:
  - Maintainer: evolves Sloppy without breaking runtime contracts or stored sessions.
  - Coding agent: reads this repository and needs stable concepts for modifying orchestration safely.
  - Operator: runs Sloppy locally and needs visible, interruptible, recoverable agent activity.
  - Feature developer: builds Dashboard, CLI, TUI, Apple client, or plugin surfaces on top of runtime state.

- **User Stories**:
  - As a maintainer, I want runtime behavior represented by typed models and events so that tests can catch behavioral regressions.
  - As a coding agent, I want clear channel, worker, branch, compactor, and visor responsibilities so that changes stay inside the right module boundary.
  - As an operator, I want agent responses to stream and remain cancellable so that long-running work feels controlled.
  - As a feature developer, I want snapshots and event envelopes to expose runtime state so that UI surfaces do not infer state from assistant prose.
  - As a maintainer, I want recovery replay to rebuild useful runtime state so that restart does not erase active tasks, artifacts, or recent context.

- **Acceptance Criteria**:
  - Channel ingestion emits `channel.message.received` and `channel.route.decided` events with protocol version `1.0`.
  - Runtime decisions use `ChannelRouteDecision` and `RouteAction`, not localized text fragments.
  - Inline responses reuse a cached `LanguageModelSession` per channel until the model provider, selected model, bootstrap, or tool allowlist changes.
  - Tool calls and tool results are surfaced through `RuntimeResponseObservation` and bounded by `NativeAgentLoopConfig.maxToolRounds`.
  - Worker creation accepts `WorkerTaskSpec`, publishes lifecycle events, and exposes `WorkerSnapshot`.
  - Branch conclusions validate summary, token counts, duplicate artifact refs, and duplicate memory refs before publication.
  - Compactor thresholds trigger at `>0.80`, `>0.85`, and `>0.95` utilization and deduplicate repeated level work per channel.
  - Visor supervision can report branch timeout, memory maintenance, idle, and degraded-channel signals as typed events.
  - Recovery paths can restore channels, route decisions, workers, artifacts, and event-derived state without re-running completed work.

- **Non-Goals**:
  - Do not classify user intent, model progress, completion, or tool use by matching assistant text such as "I'll check" or localized equivalents.
  - Do not make `AgentRuntime` depend on Dashboard, TUI, CLI, or Apple client UI code.
  - Do not require a network model provider for deterministic unit tests.
  - Do not turn branch transcripts into full permanent chat histories unless a separate storage design is accepted.
  - Do not introduce distributed scheduling or remote node orchestration inside this PRD scope.

## 3. AI System Requirements

- **Tool Requirements**:
  - Runtime tool calls enter through `ToolInvocationRequest` and return `ToolInvocationResult`.
  - Channel-specific tool exposure is controlled by an explicit allowlist, not by prompt-only convention.
  - Worker execution is abstracted behind `WorkerExecutor` so tests and future backends can replace the default executor.
  - Memory recall and writes use `MemoryStore`, `MemoryRecallRequest`, `MemoryWriteRequest`, and `MemoryRef`.
  - Visor answers use injectable completion and streaming providers so supervision behavior is testable without a live provider.

- **Evaluation Strategy**:
  - Unit tests cover event envelope encoding, payload budget limits, worker execution modes, route handling, branch conclusion validation, compactor queueing, visor bulletins, and runtime recovery.
  - Contract tests assert enum raw values and JSON field compatibility for public protocol models.
  - Streaming tests verify response chunks, cancellation, tool observations, and native loop termination behavior.
  - Recovery tests replay persisted event and task state into a fresh `RuntimeSystem` and verify snapshots match expected state.
  - Behavioral tests must assert structured state or events, never model prose.

## 4. Technical Specifications

- **Architecture Overview**:
  - `RuntimeSystem` owns the runtime graph and composes `ChannelRuntime`, `WorkerRuntime`, `BranchRuntime`, `Compactor`, `Visor`, `EventBus`, memory, and model provider access.
  - `ChannelRuntime` stores channel messages, utilization estimates, active worker IDs, and last route decision.
  - `WorkerRuntime` manages worker state, artifact summaries, route inboxes, cancellation, and lifecycle publication.
  - `BranchRuntime` forks focused work, recalls scoped memory, saves validated conclusions, and emits branch events.
  - `Compactor` observes context utilization and enqueues deduplicated compaction jobs with retry/backoff.
  - `Visor` supervises runtime health and creates bulletins, signals, and answers from current runtime snapshots.
  - `EventBus` publishes `EventEnvelope` values to subscribers and buffers up to 256 events when no subscriber is attached.

- **Integration Points**:
  - Protocol models live in `Sources/Protocols`, especially `EventEnvelope.swift`, `RuntimeModels.swift`, and API request/response models.
  - Core service and gateway APIs call into `RuntimeSystem` for channel messages, workers, visor, tools, recovery, and task integration.
  - Dashboard, TUI, and client surfaces consume API snapshots/events rather than private actor state.
  - Persistence is owned outside `AgentRuntime`; recovery enters through explicit `RecoveryChannelState`, `RecoveryTaskState`, `RecoveryArtifactState`, and event replay methods.
  - Model providers are injected through `PluginSDK.ModelProvider` and selected per channel request when supported.

- **Security & Privacy**:
  - Runtime events must avoid storing full secret-bearing tool output unless a feature explicitly requires it and tests enforce redaction or size limits.
  - Tool allowlists must be honored before exposing tools to model sessions.
  - Cancellation and abort APIs must clear active response tasks and detach cancellable workers.
  - Memory writes from branch conclusions must include scope and source metadata.
  - Logs and event payloads must prefer IDs, summaries, and artifact refs over raw large content.

## 5. Risks & Roadmap

- **Phased Rollout**:
  - MVP: preserve the current actor-based runtime, typed event envelope, inline streaming, tool observation loop, worker lifecycle, branch conclusions, compactor thresholds, visor bulletins, and recovery replay.
  - v1.1: replace the placeholder direct route policy with a structured router that can choose `respond`, `spawn_branch`, or `spawn_worker` using typed semantic output and deterministic fallbacks.
  - v1.2: harden persisted runtime state by making event replay coverage part of API/router test fixtures and documenting schema invariants near storage code.
  - v2.0: support richer branch execution and external worker backends while keeping the same protocol-level event and snapshot contract.

- **Technical Risks**:
  - Cached model sessions can grow large or become invalid after provider/model/tool changes if invalidation paths are missed.
  - Runtime event payloads can leak too much raw content unless new event types keep summary/ref discipline.
  - Compaction currently schedules summary-shaped worker artifacts; replacing that with real compaction must preserve deterministic threshold behavior.
  - Recovery can become incomplete if new message types are added without replay handling.
  - Tool-call loops can become expensive or nonterminating if `NativeAgentLoopConfig` limits are bypassed.
  - Visor can become a second control plane if signal generation starts mutating runtime state directly instead of publishing typed observations.
