import Foundation
import ManagedRelayCore
import SloppyRemoteProtocol
import Testing

@Test func presenceServiceCredentialCannotBeReplacedByUserTokens() async throws {
    let secret=String(repeating:"p",count:32)
    let authority=try ConsoleRelayAuthority(baseURL:URL(string:"https://console.example.test")!,serviceSecret:secret)
    #expect(authority.acceptsServiceCredential("Bearer "+secret))
    #expect(!authority.acceptsServiceCredential(nil))
    #expect(!authority.acceptsServiceCredential(secret))
    #expect(!authority.acceptsServiceCredential("Bearer "+String(repeating:"p",count:31)+"q"))
    let store=try ManagedRelayPostgresStore(databaseURL:URL(string:"postgresql://fixture@localhost/sloppy_relay_integration_presence")!,pepper:Data(repeating:1,count:32))
    let coordinator=ManagedRelayCoordinator(store:store,publicURL:URL(string:"https://relay.example.test")!,consoleAuthority:authority)
    await #expect(throws:ManagedRelayError.unauthorized) {try await coordinator.connectionPresence(deviceIDs:[],credential:nil)}
    #expect(try await coordinator.connectionPresence(deviceIDs:[],credential:"Bearer "+secret).isEmpty)
    await #expect(throws:ManagedRelayError.forbidden) {try await coordinator.connectionPresence(deviceIDs:Set((0..<1001).map {_ in UUID()}),credential:"Bearer "+secret)}
}
