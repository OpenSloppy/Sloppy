import Foundation
import Testing
@testable import Protocols

@Suite("Session reference compatibility")
struct SessionReferenceTests {
    @Test func linksUseIDsAndDeduplicate() throws {
        let reference = AgentSessionReference(agentId: "other", sessionId: "session-123")
        let url = try #require(reference.url).absoluteString
        #expect(AgentSessionReference.parseLinks(in: "[@Same title](\(url)) \(url)") == [reference])
        #expect(AgentSessionReference.parseLinks(in: "@file.swift @skill email@example.org").isEmpty)
    }

    @Test func legacyMessagesDecodeWithoutCollaborationFields() throws {
        let message = AgentSessionMessage(role: .user, segments: [.init(kind: .text, text: "Old message")])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "peerOrigin")
        object.removeValue(forKey: "sessionReferences")
        let decoded = try JSONDecoder().decode(AgentSessionMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.peerOrigin == nil)
        #expect(decoded.sessionReferences == nil)
    }
}
