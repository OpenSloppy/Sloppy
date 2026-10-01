import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Chat sub-session events")
struct ChatSubSessionTests {
    @Test("sub-session links decode from REST history and embedded events")
    func decodeLinks() throws {
        for payload in [
            #"{"id":"e","type":"sub_session","subSession":{"childSessionId":"child","title":"Review"}}"#,
            #"{"id":"e","type":"sub_session","event":{"subSession":{"childSessionId":"child","title":"Review"}}}"#,
        ] {
            let event = try JSONDecoder().decode(ChatEventEnvelope.self, from: Data(payload.utf8))
            #expect(event.subSession?.childSessionId == "child")
            #expect(event.subSession?.title == "Review")
        }
    }

    @Test("ordinary history without sub-session metadata still decodes")
    func ordinaryHistory() throws {
        let event = try JSONDecoder().decode(ChatEventEnvelope.self, from: Data(#"{"id":"e","type":"message"}"#.utf8))
        #expect(event.subSession == nil)
    }
}
