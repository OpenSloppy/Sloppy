import Foundation
import Protocols
import Testing
@testable import sloppy

@Suite("Plan input auto-approval")
struct PlanInputAutoApprovalTests {
    private func fixture(enabled: Bool? = nil) async throws -> (CoreService, String, String) {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let agentID = "auto-input-\(UUID().uuidString)"
        _ = try await service.createAgent(.init(id: agentID, displayName: "Auto input", role: "Developer"))
        let config = try await service.getAgentConfig(agentID: agentID)
        _ = try await service.updateAgentConfig(agentID: agentID, request: .init(
            role: config.role, selectedModel: config.selectedModel, documents: config.documents, autoApproveInput: enabled
        ))
        let session = try await service.createAgentSession(agentID: agentID, request: .init(title: "Auto input"))
        return (service, agentID, session.id)
    }

    private func request(service: CoreService, agentID: String, sessionID: String) async throws -> PlanInputRequest {
        let result = await service.handleAgentPlanInputTool(agentID: agentID, sessionID: sessionID, request: .init(
            tool: "planning.request_input", arguments: ["questions": .array([.object([
                "id": .string("publication"), "question": .string("Where should the report go?"),
                "allowCustomAnswer": .bool(false),
                "options": .array([
                    .object(["id": .string("comment"), "label": .string("Task comment")]),
                    .object(["id": .string("draft"), "label": .string("Save draft")])
                ])
            ])])]
        ), chatMode: .auto)
        #expect(result.ok)
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        return try #require(detail.events.compactMap(\.inputRequest).last)
    }

    @Test func timeoutDelegatesChoiceWithoutInventingUserAnswers() async throws {
        let (service, agentID, sessionID) = try await fixture()
        let input = try await request(service: service, agentID: agentID, sessionID: sessionID)
        let deadline = try #require(input.autoApproveAt)
        #expect(deadline.timeIntervalSince(input.createdAt) == 120)
        _ = try await service.resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
            payload: nil, automatically: true, now: deadline)
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        let response = try #require(detail.events.compactMap(\.inputResponse).last)
        #expect(response.autoApproved == true)
        #expect(response.answers.isEmpty)
        let text = detail.events.compactMap(\.message).flatMap(\.segments).compactMap(\.text).joined(separator: "\n")
        #expect(text.contains("Decide how to proceed"))
        #expect(text.contains("Task comment"))
        #expect(text.contains("Save draft"))
        await #expect(throws: CoreService.AgentSessionError.self) {
            _ = try await service.resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
                payload: nil, automatically: true, now: deadline)
        }
        await service.stop()
    }

    @Test func deadlineAndDisabledSettingPreventAutomaticResponse() async throws {
        let (service, agentID, sessionID) = try await fixture()
        let input = try await request(service: service, agentID: agentID, sessionID: sessionID)
        await #expect(throws: CoreService.AgentSessionError.self) {
            _ = try await service.resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
                payload: nil, automatically: true, now: input.createdAt.addingTimeInterval(119))
        }
        let config = try await service.getAgentConfig(agentID: agentID)
        _ = try await service.updateAgentConfig(agentID: agentID, request: .init(
            role: config.role, selectedModel: config.selectedModel, documents: config.documents, autoApproveInput: false
        ))
        await #expect(throws: CoreService.AgentSessionError.self) {
            _ = try await service.resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
                payload: nil, automatically: true, now: input.createdAt.addingTimeInterval(120))
        }
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.compactMap(\.inputResponse).isEmpty)
        await service.stop()
    }

    @Test(arguments: [PlanInputResponseStatus.answered, .cancelled])
    func userResponseWins(status: PlanInputResponseStatus) async throws {
        let (service, agentID, sessionID) = try await fixture()
        let input = try await request(service: service, agentID: agentID, sessionID: sessionID)
        _ = try await service.answerAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
            payload: .init(status: status, answers: status == .answered ? [.init(questionId: "publication", selectedOptionId: "draft")] : [], userId: "tester"))
        await #expect(throws: CoreService.AgentSessionError.self) {
            _ = try await service.resolveAgentPlanInput(agentID: agentID, sessionID: sessionID, requestID: input.id,
                payload: nil, automatically: true, now: input.createdAt.addingTimeInterval(120))
        }
        let responses = try await service.getAgentSession(agentID: agentID, sessionID: sessionID).events.compactMap(\.inputResponse)
        #expect(responses.count == 1)
        #expect(responses.first?.autoApproved != true)
        #expect(responses.first?.status == status)
        await service.stop()
    }

    @Test func defaultsOnAndOmittedUpdatePreservesExplicitOptOut() async throws {
        let (service, agentID, sessionID) = try await fixture()
        let input = try await request(service: service, agentID: agentID, sessionID: sessionID)
        #expect(input.autoApproveAt != nil)
        let config = try await service.getAgentConfig(agentID: agentID)
        #expect(config.autoApproveInput)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        legacy.removeValue(forKey: "autoApproveInput")
        let decoded = try JSONDecoder().decode(AgentConfigDetail.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.autoApproveInput)
        _ = try await service.updateAgentConfig(agentID: agentID, request: .init(
            role: config.role, selectedModel: config.selectedModel, documents: config.documents, autoApproveInput: false
        ))
        _ = try await service.updateAgentConfig(agentID: agentID, request: .init(
            role: config.role, selectedModel: config.selectedModel, documents: config.documents
        ))
        let updated = try await service.getAgentConfig(agentID: agentID)
        #expect(updated.autoApproveInput == false)
        let disabledInput = try await request(service: service, agentID: agentID, sessionID: sessionID)
        #expect(disabledInput.autoApproveAt == nil)
        await service.stop()
    }

    @Test func channelTimeoutAndUserAnswerResolveOnlyOnce() async throws {
        let (service, agentID, _) = try await fixture()
        let channelID = "channel:auto-input-\(UUID().uuidString)"
        let input = PlanInputRequest(questions: [
            .init(id: "publication", question: "Where?", options: [.init(id: "draft", label: "Draft")])
        ], autoApproveAt: Date())
        let session = try await service.channelSessionStore.ensureOpenSession(channelId: channelID)
        try await service.channelSessionStore.recordInputRequest(channelId: channelID, request: input)
        async let automatic: Void = {
            _ = try? await service.resolveChannelPlanInput(sessionID: session.sessionId, requestID: input.id,
                payload: nil, automaticAgentID: agentID)
        }()
        async let manual: Void = {
            _ = try? await service.answerChannelPlanInput(sessionID: session.sessionId, requestID: input.id,
                payload: .init(answers: [.init(questionId: "publication", selectedOptionId: "draft")], userId: "tester"))
        }()
        _ = await (automatic, manual)
        let detail = try await service.channelSessionStore.loadSessionDetail(sessionID: session.sessionId)
        #expect(detail.events.compactMap(\.inputResponse).count == 1)
        #expect(try await service.channelSessionStore.pendingInputRequest(channelId: channelID) == nil)
        await service.stop()
    }

    @Test func interruptedOrSupersededRequestCannotResume() {
        let input = PlanInputRequest(questions: [])
        let event = AgentSessionEvent(agentId: "a", sessionId: "s", type: .inputRequest, inputRequest: input)
        #expect(CoreService.autoApprovalCanResume(requestID: input.id, events: [event]))
        let interrupted = CoreService.autoApprovalCanResume(requestID: input.id, events: [event,
            .init(agentId: "a", sessionId: "s", type: .runControl, runControl: .init(action: .interrupt, requestedBy: "tester"))])
        let superseded = CoreService.autoApprovalCanResume(requestID: input.id, events: [event,
            .init(agentId: "a", sessionId: "s", type: .inputRequest, inputRequest: .init(questions: []))])
        #expect(interrupted == false)
        #expect(superseded == false)
    }

    @Test(arguments: [false, true])
    func serverTimerResolvesPersistedRequest(recover: Bool) async throws {
        let (service, agentID, sessionID) = try await fixture()
        let input = PlanInputRequest(questions: [], autoApproveAt: Date().addingTimeInterval(0.1))
        _ = try await service.appendAgentSessionEvents(agentID: agentID, sessionID: sessionID, request: .init(events: [
            .init(agentId: agentID, sessionId: sessionID, type: .inputRequest, inputRequest: input),
            // Recovery must find pending control state outside the history page.
            .init(agentId: agentID, sessionId: sessionID, type: .message,
                  message: .init(role: .assistant, segments: [.init(kind: .text, text: "Waiting")]))
        ]))
        if recover {
            await service.resetPlanInputAutoApprovalRecoveryForTest()
            await service.restorePlanInputAutoApprovalsIfNeeded()
        } else {
            await service.schedulePlanInputAutoApproval(agentID: agentID, sessionID: sessionID, request: input)
        }
        for _ in 0..<100 {
            let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
            if detail.events.contains(where: { $0.inputResponse?.autoApproved == true }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let detail = try await service.getAgentSession(agentID: agentID, sessionID: sessionID)
        #expect(detail.events.contains(where: { $0.inputResponse?.requestId == input.id && $0.inputResponse?.autoApproved == true }))
        await service.stop()
    }
}

private extension CoreService {
    func resetPlanInputAutoApprovalRecoveryForTest() { planInputAutoApprovalRecovered = false }
}
