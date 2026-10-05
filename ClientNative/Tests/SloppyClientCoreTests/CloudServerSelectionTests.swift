import Foundation
import Testing
@testable import SloppyClientCore

@Suite("Cloud server selection")
struct CloudServerSelectionTests {
    @Test @MainActor func directoryKeepsBothComputersAndRequiresTrustForTheSecond() {
        let settings = ClientSettings()
        let original = settings.instanceSelection
        defer { settings.instanceSelection = original }
        let first = instance(), second = instance(), revoked = instance(status: .revoked)
        let relay = URL(string: "https://relay.test")!
        settings.instanceSelection = .all
        settings.installConsoleInstances([first, second, revoked], unverifiedHostIDs: [second.hostDeviceID], relayURL: relay)
        #expect(settings.discoveredInstances.count == 2)
        #expect(settings.instanceSelection == .all)
        #expect(settings.activeInstanceEndpoint == .managed(relayURL: relay, targetDeviceID: first.hostDeviceID))
        #expect(settings.discoveredInstances.map(\.name) == [first.name, second.name])
        #expect(!settings.requiresConsoleVerification(settings.discoveredInstances[0]))
        #expect(settings.requiresConsoleVerification(settings.discoveredInstances[1]))
        settings.instanceSelection = .instance(settings.discoveredInstances[0].id)
        settings.installConsoleInstances([first, second], unverifiedHostIDs: [], relayURL: relay)
        #expect(settings.discoveredInstances.count == 2)
        #expect(settings.selectedInstance?.endpoint == .managed(relayURL: relay, targetDeviceID: first.hostDeviceID))
        #expect(!settings.requiresConsoleVerification(settings.discoveredInstances[1]))
    }

    @Test("An account with only pending or revoked servers has an empty workspace")
    func unavailableServersDoNotOpenWorkspace() {
        #expect(CloudServerSelection.activeInstances([]).isEmpty)
        #expect(CloudServerSelection.activeInstances([
            instance(status: .pending), instance(status: .revoked)
        ]).isEmpty)
    }

    @Test("Reconnect prefers the last selected active host and keeps other servers available")
    func prefersPreviouslySelectedHost() {
        let first = instance(), preferred = instance(), third = instance()
        let result = CloudServerSelection.orderedInstances([first, preferred, third], preferredHostID: preferred.hostDeviceID)
        #expect(result.map(\.id) == [preferred.id, first.id, third.id])
    }

    @Test("A revoked preferred host cannot displace an active server")
    func ignoresRevokedPreference() {
        let revoked = instance(status: .revoked), active = instance()
        let result = CloudServerSelection.orderedInstances([revoked, active], preferredHostID: revoked.hostDeviceID)
        #expect(result.map(\.id) == [active.id])
    }

    @Test("Only the same active server and verified certificate can reconnect automatically")
    func reconnectRequiresUnchangedTrust() {
        let certificate = Data("verified certificate".utf8)
        var saved = instance()
        saved.hostCertificateFingerprint = ConsoleTrust.fingerprint(certificate)
        #expect(ConsoleRemoteClientRegistry.trustMatches(instance: saved, savedInstance: saved, certificate: certificate))

        var changed = saved
        changed.hostCertificateFingerprint = ConsoleTrust.fingerprint(Data("replacement".utf8))
        #expect(!ConsoleRemoteClientRegistry.trustMatches(instance: changed, savedInstance: saved, certificate: certificate))
        changed = saved
        changed.id = UUID()
        #expect(!ConsoleRemoteClientRegistry.trustMatches(instance: changed, savedInstance: saved, certificate: certificate))
        changed = saved
        changed.hostDeviceID = UUID()
        #expect(!ConsoleRemoteClientRegistry.trustMatches(instance: changed, savedInstance: saved, certificate: certificate))
        changed = saved
        changed.status = .revoked
        #expect(!ConsoleRemoteClientRegistry.trustMatches(instance: changed, savedInstance: saved, certificate: certificate))
        #expect(!ConsoleRemoteClientRegistry.trustMatches(instance: saved, savedInstance: saved, certificate: Data("replacement".utf8)))
    }

    private func instance(status: ConsoleStatus = .active) -> InstanceBinding {
        InstanceBinding(ownerID: UUID(), spaceID: UUID(), name: "Test server", authorityPublicKey: Data(), hostDeviceID: UUID(), status: status)
    }
}
