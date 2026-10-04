import Foundation
import Testing
@testable import SloppyClientCore

@Test func consoleErrorsDoNotMislabelAccessDenialAsIdentityVerification() {
    #expect(ConsoleAccountError.response(status: 403, data: Data("{\"error\":\"identityVerificationRequired\"}".utf8)) == .identityVerificationRequired)
    for body in ["{\"error\":\"forbidden\"}", "{\"error\":\"invalid_signature\"}", "unexpected response"] {
        #expect(ConsoleAccountError.response(status: 403, data: Data(body.utf8)) == .accessDenied)
    }
    #expect(ConsoleAccountError.response(status: 401, data: Data()) == .signInRequired)
    #expect(ConsoleAccountError.response(status: 503, data: Data()) == .unavailable)
}
