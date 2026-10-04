import Foundation
import AuthenticationServices
import Testing
@testable import SloppyFeatureSettings

@MainActor
private final class FakeConsoleSession: ConsoleAuthenticationSession {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    let onStart: () -> Bool

    init(onStart: @escaping () -> Bool) { self.onStart = onStart }
    func start() -> Bool { onStart() }
}

@Test @MainActor
func consoleLoginAcceptsCallbackFromBackgroundExecutor() async throws {
    let callback = URL(string: "sloppy://console-login?code=test&state=test")!
    let login = ConsoleLoginPresentation { _, completion in
        FakeConsoleSession {
            Task.detached { completion(callback, nil) }
            return true
        }
    }
    #expect(try await login.authenticate(URL(string: "https://console.sloppy.team/auth/start")!) == callback)
    // The completed session must be released and another attempt allowed.
    #expect(try await login.authenticate(URL(string: "https://console.sloppy.team/auth/start")!) == callback)
}

@Test @MainActor
func consoleLoginPreservesBackgroundCancellation() async {
    let login = ConsoleLoginPresentation { _, completion in
        FakeConsoleSession {
            Task.detached {
                completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
            }
            return true
        }
    }
    do {
        _ = try await login.authenticate(URL(string: "https://console.sloppy.team/auth/start")!)
        Issue.record("Cancelled authentication returned a callback")
    } catch {
        #expect((error as? ASWebAuthenticationSessionError)?.code == .canceledLogin)
    }
}

@Test @MainActor
func consoleLoginFailedStartIgnoresLateCompletion() async throws {
    var oldCompletion: ConsoleLoginPresentation.Completion?
    let callback = URL(string: "sloppy://console-login?code=current")!
    var attempt = 0
    let login = ConsoleLoginPresentation { _, completion in
        attempt += 1
        if attempt == 1 {
            oldCompletion = completion
            return FakeConsoleSession { false }
        }
        let stale = oldCompletion
        return FakeConsoleSession {
            Task.detached {
                stale?(URL(string: "sloppy://console-login?code=stale")!, nil)
                completion(callback, nil)
                completion(callback, nil)
            }
            return true
        }
    }
    await #expect(throws: (any Error).self) {
        _ = try await login.authenticate(URL(string: "https://console.sloppy.team/auth/start")!)
    }
    #expect(try await login.authenticate(URL(string: "https://console.sloppy.team/auth/start")!) == callback)
}
