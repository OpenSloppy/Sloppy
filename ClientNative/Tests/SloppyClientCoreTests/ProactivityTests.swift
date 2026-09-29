import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Proactivity client")
struct ProactivityTests {
    @Test func legacyHeartbeatSettingsRemainCompatible() throws {
        let heartbeat = try JSONDecoder().decode(AgentHeartbeatSettings.self, from: Data("{\"enabled\":true,\"intervalMinutes\":5}".utf8))
        #expect(heartbeat.mode == .checklist)
        #expect(AgentHeartbeatSettings(mode: .proactive).intervalMinutes == 30)
    }

    @Test func findingDeepLinksRoundTripEncodedIdentifiers() throws {
        let link = DeepLink.proactivity(agentId: "my agent", findingId: "finding/a")
        let url = try #require(link.url)
        #expect(DeepLink.parse(url) == link)
        #expect(DeepLink.parse(URL(string: "sloppy://proactivity?id=x")!) == nil)
    }

    @Test func proactiveNotificationDecodesWithContext() throws {
        let text = """
        {"id":"proactive:1","type":"proactive_attention","title":"PR","message":"Review needed",
         "timestamp":0,"metadata":{"agentId":"a","findingId":"1","sessionId":"s"}}
        """
        let notification = try JSONDecoder().decode(AppNotification.self, from: Data(text.utf8))
        #expect(notification.type == .proactiveAttention)
        #expect(notification.metadata["findingId"] == "1")
    }

    @Test func notificationWindowRespectsLocalTimeAndInvalidZones() throws {
        let settings = AgentProactiveSettings()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-29T06:00:00Z"))
        #expect(settings.permitsNotification(at: date))
        #expect(!settings.permitsNotification(at: date.addingTimeInterval(-1)))
        #expect(!settings.permitsNotification(at: date.addingTimeInterval(12 * 3_600)))
        var invalid = settings; invalid.timeZone = "Bad/Zone"
        #expect(!invalid.isValid)
    }
}
