import Testing
#if os(macOS)
import AppKit
#endif

/// AppKit focus, window ordering, and animation share process-wide state.
/// Suite-level `.serialized` alone does not exclude other suites' windows.
public struct AppKitUITrait: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await AppKitTestGate.shared.acquire()
        #if os(macOS)
        let existingWindows = await MainActor.run {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return Set(NSApp.windows.map(ObjectIdentifier.init))
        }
        #endif
        do {
            try Task.checkCancellation()
            try await function()
        } catch {
            #if os(macOS)
            await closeTestWindows(excluding: existingWindows)
            #endif
            await AppKitTestGate.shared.release()
            throw error
        }
        #if os(macOS)
        await closeTestWindows(excluding: existingWindows)
        #endif
        await AppKitTestGate.shared.release()
    }

    #if os(macOS)
    @MainActor
    private func closeTestWindows(excluding existingWindows: Set<ObjectIdentifier>) {
        for window in NSApp.windows where !existingWindows.contains(ObjectIdentifier(window)) {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
    #endif
}

public extension Trait where Self == AppKitUITrait {
    static var appKitUI: Self { Self() }
}

private actor AppKitTestGate {
    static let shared = AppKitTestGate()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isHeld = true
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
