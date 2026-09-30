import Testing
import Foundation
@testable import SloppyClientCore

struct AgentBotIdentityTests {
    @Test func identityMatchesTheSharedUTF8Catalog() {
        for (id, shape) in [("a", "circle"), ("b", "triangle"), ("c", "diamond"), ("d", "square"), ("研究", "circle"), ("sloppy", "diamond")] {
            #expect(AgentBotIdentity.shape(for: id) == shape)
        }
        #expect(AgentBotIdentity.seed(for: "a") == 3_826_002_220)
    }
    @Test func persistedPaletteIsIndependentOfShapeAndLegacyJSONStillDecodes() throws {
        for id in ["a", "b", "c", "d"] {
            #expect(AgentBotIdentity.palette(for: id, paletteID: "rose").id == "rose")
        }
        let old = try JSONDecoder().decode(APIAgentRecord.self, from: Data(#"{"id":"a","displayName":"Agent","role":"Builder"}"#.utf8))
        #expect(old.pet == nil)
        let new = try JSONDecoder().decode(APIAgentRecord.self, from: Data(#"{"id":"a","displayName":"Agent","role":"Builder","pet":{"visual":{"paletteId":"rose","speciesId":"circle"}}}"#.utf8))
        #expect(new.pet?.visual?.paletteId == "rose")
    }

    @Test func facialEmotionsAndReducedMotionHaveDistinctPoses() {
        #expect(AgentBotEyePose.resolve(emotion: .happy, elapsed: 0).isSmiling)
        #expect(AgentBotEyePose.resolve(emotion: .surprised, elapsed: 0).scaleX > 1)
        #expect(AgentBotEyePose.resolve(emotion: .angry, elapsed: 0).leftRotation < 0)
        #expect(AgentBotEyePose.resolve(emotion: .error, elapsed: 0).leftScaleY < 1)
        #expect(AgentBotEyePose.resolve(emotion: .idle, elapsed: 3.9).leftScaleY < 0.1)
        #expect(AgentBotEyePose.resolve(emotion: .idle, elapsed: 3.9, reducedMotion: true).leftScaleY == 1)
    }

}
