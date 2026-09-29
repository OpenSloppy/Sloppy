import AnyLanguageModel
import Foundation
import Protocols

struct HeartbeatReportTool: CoreTool {
    let domain = "system"
    let title = "Report proactive attention"
    let status = "fully_functional"
    let name = "heartbeat.report"
    let description = "Report a typed decision for one supplied proactive source. Available only during background attention analysis. Call once per source; quiet requires no finding, notify and needs_input require reason, evidence and nextStep."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "sourceId", description: "Exact source ID from the supplied snapshots", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "outcome", description: "quiet, notify or needs_input", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "reason", description: "Why user attention is needed", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "evidence", description: "Facts supporting the finding, with source references", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "nextStep", description: "Suggested action or a concrete question for the user", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
    }

    static func decode(_ arguments: [String: JSONValue]) throws -> ProactiveReport {
        guard let id = arguments["sourceId"]?.asString, !id.isEmpty,
              let raw = arguments["outcome"]?.asString, let outcome = ProactiveReportOutcome(rawValue: raw) else {
            throw ProactiveHeartbeatError.invalidReport
        }
        let report = ProactiveReport(sourceID: id, outcome: outcome, reason: arguments["reason"]?.asString ?? "",
                                     evidence: arguments["evidence"]?.asString ?? "", nextStep: arguments["nextStep"]?.asString ?? "")
        if outcome != .quiet && [report.reason, report.evidence, report.nextStep].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ProactiveHeartbeatError.invalidReport
        }
        guard [report.reason, report.evidence, report.nextStep].allSatisfy({ $0.count <= 8_000 }) else {
            throw ProactiveHeartbeatError.invalidReport
        }
        return report
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        toolFailure(tool: name, code: "not_available", message: "This tool is only available in a proactive analysis run.", retryable: false)
    }
}

actor ProactiveReportRecorder {
    private let sourceIDs: Set<String>
    private var reports: [String: ProactiveReport] = [:]
    private var assistantText = ""

    init(sourceIDs: Set<String>) { self.sourceIDs = sourceIDs }

    func invoke(_ request: ToolInvocationRequest) -> ToolInvocationResult {
        guard request.tool == "heartbeat.report" else {
            return toolFailure(tool: request.tool, code: "proactive_tool_forbidden", message: "Proactive analysis is read-only. Only heartbeat.report is allowed.", retryable: false)
        }
        do {
            let report = try HeartbeatReportTool.decode(request.arguments)
            guard sourceIDs.contains(report.sourceID), reports[report.sourceID] == nil || reports[report.sourceID] == report else {
                throw ProactiveHeartbeatError.invalidReport
            }
            reports[report.sourceID] = report
            return toolSuccess(tool: request.tool, data: .object(["accepted": .bool(true), "sourceId": .string(report.sourceID)]))
        } catch {
            return toolFailure(tool: request.tool, code: "invalid_report", message: "Use a supplied sourceId and a valid outcome; actionable findings require reason, evidence and nextStep.", retryable: true)
        }
    }

    func updateText(_ text: String) -> Bool { assistantText = text; return true }
    func result() throws -> [ProactiveReport] {
        guard Set(reports.keys) == sourceIDs else { throw ProactiveHeartbeatError.missingReport }
        return sourceIDs.sorted().compactMap { reports[$0] }
    }
}
