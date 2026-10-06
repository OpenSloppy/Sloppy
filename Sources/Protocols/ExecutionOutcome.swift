import Foundation

public enum ExecutionState: String, Codable, Sendable, Equatable {
    case completed
    case failed
    case cancelled
    case waitingInput = "waiting_input"
    case waitingApproval = "waiting_approval"
    case interrupted
}

public enum ExecutionFailureCategory: String, Codable, Sendable, Equatable {
    case provider
    case context
    case tool
    case policy
    case storage
    case unavailable
    case incomplete
    case unknown
}

/// Machine-readable execution state; the summary is display text only.
public struct ExecutionOutcome: Codable, Sendable, Equatable {
    public var state: ExecutionState
    public var category: ExecutionFailureCategory?
    public var code: String?
    public var retryable: Bool
    public var requiresReconciliation: Bool

    public init(state: ExecutionState, category: ExecutionFailureCategory? = nil, code: String? = nil, retryable: Bool = false, requiresReconciliation: Bool = false) {
        self.state = state
        self.category = category
        self.code = code
        self.retryable = retryable
        self.requiresReconciliation = requiresReconciliation
    }

    public static let completed = ExecutionOutcome(state: .completed)
}

public struct ToolCallReconciliationRequest: Codable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case notExecuted = "not_executed"
        case completed
        case failed
    }
    public var decision: Decision
    public var evidence: String

    public init(decision: Decision, evidence: String) {
        self.decision = decision
        self.evidence = evidence
    }
}
