import AnyLanguageModel
import Foundation
import Protocols
import SloppyRuntime
import Testing
@testable import sloppy

@Suite("Session reliability")
struct SessionReliabilityTests {
    private func events(ok: Bool = false, linked: Bool = true) -> [AgentSessionEvent] {
        [
            .init(id: "attempt", agentId: "agent", sessionId: "session", type: .toolCall,
                toolCall: .init(tool: "long_chat.delegate", arguments: ["assignment": .string("{}")])),
            .init(id: "result", agentId: "agent", sessionId: "session", type: .toolResult,
                toolResult: .init(tool: "long_chat.delegate", ok: ok,
                    data: ok ? .object(["id": .string("assignment-1")]) : nil,
                    error: ok ? nil : .init(code: "invalid_arguments", message: "acceptanceCriteria must be a string", retryable: false,
                        hint: "Correct acceptanceCriteria and call again.", argumentRecovery: .init(invalidFields: ["assignment"])),
                    callEventId: linked ? "attempt" : nil)),
        ]
    }

    @Test func typedDelegationAcceptsObjectsAndLegacyStringsButRejectsWrongFieldTypes() throws {
        let raw = #"{"requestKey":"import","title":"Import","acceptanceCriteria":"Visible and readable","tasks":[{"key":"import","title":"Import","objective":"Import authorized skills","resourceKeys":["agent:skills"],"dependsOn":[],"readOnly":false}]}"#
        let object = try JSONDecoder().decode(Protocols.JSONValue.self, from: Data(raw.utf8))
        #expect(try LongChatDelegationDecoder.decode(object).tasks[0].readOnly == false)
        #expect(try LongChatDelegationDecoder.decode(.string(raw)).requestKey == "import")
        var invalid = try #require(object.asObject)
        invalid["acceptanceCriteria"] = .array([.string("Visible")])
        #expect(throws: DecodingError.self) { try LongChatDelegationDecoder.decode(.object(invalid)) }
    }

    @Test func recordedFailedAttemptSurvivesRecoveryAndIsNotAnAbsentAssignment() throws {
        let ledger = SessionActionLedger(events: events(linked: false))
        #expect(ledger.totalCalls == 1)
        #expect(ledger.callsByTool["long_chat.delegate"] == 1)
        #expect(ledger.actions[0].resultEventId == "result")
        #expect(ledger.actions[0].ok == false)
        #expect(ledger.actions[0].assignmentId == nil)
        #expect(ledger.repairableFailure?.callEventId == "attempt")
        let detail = AgentSessionDetail(summary: .init(id: "session", agentId: "agent", title: "Test", messageCount: 0), events: events())
        let restored = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)
        #expect(restored.contains { if case .toolOutput(let output) = $0 { return output.segments.description.contains("acceptanceCriteria") }; return false })
        #expect(SessionActionLedger(events: events(ok: true)).repairableFailure == nil)
    }

    @Test func ledgerCountsIncludeOmittedCallsAndSuccessfulCorrectionsResolveFailure() {
        var records = events()
        records.append(contentsOf: events(ok: true).map { event in
            var changed = event
            changed.id += "-corrected"
            changed.toolResult?.callEventId = "attempt-corrected"
            return changed
        })
        let ledger = SessionActionLedger(events: records, limit: 1)
        #expect(ledger.totalCalls == 2 && ledger.omittedCalls == 1)
        #expect(ledger.callsByTool["long_chat.delegate"] == 2)
        #expect(ledger.repairableFailure == nil)
        #expect(ledger.actions[0].assignmentId == "assignment-1")
    }

    @Test func falseDenialIsRevisedAndRecheckedBeforePublication() async {
        let ledger = SessionActionLedger(events: events())
        let corrected = "I attempted delegation (call attempt), but acceptanceCriteria had the wrong type. No worker started."
        let replies = ReviewReplies([#"{"supported":false,"correctedResponse":"\#(corrected)"}"#, #"{"supported":true,"correctedResponse":null}"#])
        let answer = await CoordinatorResponseReview.verifiedResponse(
            candidate: "There was no delegation call. I invented the attempt.", userRequest: "What error?", ledger: ledger,
            review: { prompt in
                #expect(prompt.contains("attempt") && prompt.contains("invalid_arguments"))
                return await replies.next()
            })
        #expect(answer == corrected)
        #expect(await replies.count == 2)
    }

    @Test func invalidReviewCannotPublishUnsupportedExplanation() async {
        let ledger = SessionActionLedger(events: events())
        let answer = await CoordinatorResponseReview.verifiedResponse(candidate: "Permission was denied.", userRequest: "Why?", ledger: ledger, review: { _ in "not JSON" })
        #expect(answer == ledger.factualFallback)
        #expect(answer.contains("invalid_arguments") && answer.contains("attempt"))
    }

    @Test func successfulToolTransportDoesNotHideFailedCommand() {
        let ledger = SessionActionLedger(events: [
            .init(id: "ocr", agentId: "agent", sessionId: "session", type: .toolCall, toolCall: .init(tool: "runtime.exec", arguments: [:])),
            .init(agentId: "agent", sessionId: "session", type: .toolResult,
                toolResult: .init(tool: "runtime.exec", ok: true, data: .object(["exitCode": .number(255), "timedOut": .bool(false)]), callEventId: "ocr")),
        ])
        #expect(ledger.actions[0].ok == true && ledger.actions[0].exitCode == 255)
        #expect(ledger.factualFallback.contains("process exit code 255"))
    }

    @Test func missingOrInvalidImageKeepsMetadataWithoutInventingPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        #expect(throws: SessionImageLoader.LoadError.self) { try SessionImageLoader.load(url: bad, mimeType: "image/png") }
    }

    @Test func restoredImageBudgetUsesActualBytesInsteadOfDeclaredSize() {
        let data = Data(repeating: 0, count: 8 * 1024 * 1024)
        let events = (0..<4).map { index in
            AgentSessionEvent(agentId: "agent", sessionId: "session", type: .message,
                message: .init(role: .user, segments: [.init(kind: .attachment, attachment: .init(
                    id: "image-\(index)", name: "image.png", mimeType: "image/png", sizeBytes: 0))]))
        }
        let detail = AgentSessionDetail(summary: .init(id: "session", agentId: "agent", title: "Images", messageCount: 4), events: events)
        let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail, imageLoader: { _ in .init(source: .data(data, mimeType: "image/png")) })
        let count = transcript.reduce(0) { count, entry in
            guard case .prompt(let prompt) = entry else { return count }
            return count + prompt.segments.filter { if case .image = $0 { return true }; return false }.count
        }
        #expect(count == 3)
    }
}

private actor ReviewReplies {
    private let replies: [String]
    private(set) var count = 0
    init(_ replies: [String]) { self.replies = replies }
    func next() -> String? {
        defer { count += 1 }
        return count < replies.count ? replies[count] : nil
    }
}

extension CoreService {
    fileprivate func reserveReliabilityTurn(sessionID: String) { longChatCurrentTurns[sessionID] = UUID().uuidString }
}

@Test func malformedLongChatDelegationExplainsCorrectionWithoutCreatingWork() async throws {
    let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
    _ = try await service.createAgent(.init(id: "reliable", displayName: "Reliable", role: "Test"))
    let session = try await service.openLongChat(agentID: "reliable", userID: "local")
    await service.reserveReliabilityTurn(sessionID: session.id)
    let invalid: Protocols.JSONValue = .object(["requestKey": .string("import"), "title": .string("Import"), "acceptanceCriteria": .array([.string("Visible")]), "tasks": .array([])])
    let result = await service.invokeLongChatTool(agentID: "reliable", sessionID: session.id, request: .init(tool: "long_chat.delegate", arguments: ["assignment": invalid]))
    #expect(!result.ok)
    #expect(result.error?.code == "invalid_arguments")
    #expect(result.error?.hint?.contains("acceptanceCriteria must be a string") == true)
    #expect(result.error?.argumentRecovery?.invalidFields == ["assignment"])
    #expect(try await service.getLongChat(agentID: "reliable", sessionID: session.id).assignments.isEmpty)
    await service.stop()
}
