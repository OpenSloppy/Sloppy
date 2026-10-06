import AgentRuntime
import Foundation
import Protocols

enum ExecutionOutcomeClassifier {
    static func classify(reason: NativeAgentLoopTurnExitReason, interrupted: Bool = false, waitingInput: Bool = false, blocked: Bool = false, incomplete: Bool = false) -> ExecutionOutcome {
        if interrupted || reason == .consumerCancelled || reason == .modelCancelled { return .init(state: .cancelled) }
        if waitingInput { return .init(state: .waitingInput) }
        switch reason {
        case .modelProviderError, .streamRetryFailed, .streamIdleTimeoutFallback:
            return .init(state: .failed, category: .provider, code: reason.rawValue, retryable: true)
        case .contextWindowRecoveryFailed:
            return .init(state: .failed, category: .context, code: reason.rawValue)
        case .toolLoopDetected, .emptyAfterToolTimeout:
            return .init(state: .failed, category: .tool, code: reason.rawValue)
        case .fallbackNoModel:
            return .init(state: .failed, category: .unavailable, code: reason.rawValue)
        case .toolRoundLimit, .emptyResponse:
            return .init(state: .failed, category: .incomplete, code: reason.rawValue)
        default: break
        }
        if blocked { return .init(state: .failed, category: .tool, code: "blocked") }
        if incomplete { return .init(state: .failed, category: .incomplete, code: "completion_missing") }
        return .completed
    }
}
