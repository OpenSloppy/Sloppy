import Foundation
import AuthenticationServices
import SwiftUI
import SloppyClientCore

@MainActor
protocol ConsoleAuthenticationSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
}

extension ASWebAuthenticationSession: ConsoleAuthenticationSession {}

@MainActor
final class ConsoleLoginPresentation: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias Completion = @Sendable (URL?, (any Error)?) -> Void
    typealias SessionFactory = (URL, @escaping Completion) -> any ConsoleAuthenticationSession

    private let makeSession: SessionFactory
    private var session: (any ConsoleAuthenticationSession)?
    private var pending: (id: UUID, continuation: CheckedContinuation<URL, any Error>)?

    init(makeSession: @escaping SessionFactory = { url, completion in
        ASWebAuthenticationSession(url: url, callbackURLScheme: "sloppy", completionHandler: completion)
    }) {
        self.makeSession = makeSession
        super.init()
    }

    func authenticate(_ url: URL) async throws -> URL {
        guard pending == nil else { throw ConsoleTrustError.forbidden }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pending = (id, continuation)
            // Safari may deliver this callback on its XPC queue. A Sendable
            // callback avoids inheriting MainActor isolation at the ObjC boundary.
            let completion: Completion = { [weak self] callback, error in
                Task { @MainActor in
                    self?.finish(id: id, callback: callback, error: error)
                }
            }
            let session = makeSession(url, completion)
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                finish(id: id, callback: nil, error: ConsoleTrustError.forbidden)
            }
        }
    }

    private func finish(id: UUID, callback: URL?, error: (any Error)?) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        session = nil
        if let callback {
            pending.continuation.resume(returning: callback)
        } else {
            pending.continuation.resume(throwing: error ?? ConsoleTrustError.forbidden)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
