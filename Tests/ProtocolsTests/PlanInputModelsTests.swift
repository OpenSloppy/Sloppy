import Foundation
import Protocols
import Testing

@Suite("Plan input protocol models")
struct PlanInputModelsTests {
    @Test("plan input request and response round-trip through session event")
    func planInputRoundTrip() throws {
        let request = PlanInputRequest(
            id: "req-1",
            title: "Choose direction",
            questions: [
                PlanInputQuestion(
                    id: "direction",
                    header: "Scope",
                    question: "What should we do?",
                    options: [
                        PlanInputOption(id: "small", label: "Small"),
                        PlanInputOption(id: "large", label: "Large", description: "Broader work")
                    ]
                )
            ],
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let response = PlanInputResponse(
            requestId: "req-1",
            status: .answered,
            answers: [PlanInputAnswer(questionId: "direction", selectedOptionId: "small")],
            userId: "tester",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let event = AgentSessionEvent(
            id: "event-1",
            agentId: "assistant",
            sessionId: "session-1",
            type: .inputRequest,
            inputRequest: request,
            inputResponse: response
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSessionEvent.self, from: data)

        #expect(decoded.type == .inputRequest)
        #expect(decoded.inputRequest?.questions.first?.allowCustomAnswer == true)
        #expect(decoded.inputRequest?.questions.first?.options.last?.description == "Broader work")
        #expect(decoded.inputResponse?.answers.first?.selectedOptionId == "small")
    }

    @Test("legacy plan input records decode without automatic approval metadata")
    func legacyPlanInputRecords() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(PlanInputRequest.self, from: Data(
            #"{"id":"legacy","mode":"plan","questions":[],"createdAt":"2026-10-02T00:00:00Z"}"#.utf8
        ))
        let response = try decoder.decode(PlanInputResponse.self, from: Data(
            #"{"requestId":"legacy","status":"cancelled","answers":[],"userId":"tester","createdAt":"2026-10-02T00:00:00Z"}"#.utf8
        ))
        #expect(request.autoApproveAt == nil)
        #expect(response.autoApproved == nil)
    }

    @Test("build progress round-trips through session event")
    func buildProgressRoundTrip() throws {
        let progress = AgentBuildProgressEvent(
            title: "Progress",
            items: [
                AgentBuildProgressItem(
                    id: "tests",
                    title: "Add tests",
                    status: .inProgress,
                    definitionOfDone: "Targeted tests cover validation",
                    details: "Writing cases"
                ),
                AgentBuildProgressItem(
                    id: "verify",
                    title: "Run verification",
                    status: .pending,
                    definitionOfDone: "Relevant checks pass"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let event = AgentSessionEvent(
            id: "event-progress",
            agentId: "assistant",
            sessionId: "session-1",
            type: .buildProgress,
            buildProgress: progress
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSessionEvent.self, from: data)

        #expect(decoded.type == .buildProgress)
        #expect(decoded.buildProgress?.title == "Progress")
        #expect(decoded.buildProgress?.items.map(\.id) == ["tests", "verify"])
        #expect(decoded.buildProgress?.items.first?.status == .inProgress)
        #expect(decoded.buildProgress?.items.first?.definitionOfDone == "Targeted tests cover validation")
    }
}
