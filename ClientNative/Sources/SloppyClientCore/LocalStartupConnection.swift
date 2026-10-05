#if os(macOS)
import Foundation

/// Desktop launches enter the local workspace even when a remote server was used last.
@MainActor
public enum LocalStartupConnection {
    public static func connect(
        configuredURL: URL,
        ensureRunning: (URL) async -> LocalBackendLauncher.Result = {
            await LocalBackendLauncher.shared.ensureRunning(at: $0)
        }
    ) async -> URL? {
        let url = ServerAddress.isLoopbackHost(configuredURL.host)
            ? configuredURL
            : ServerAddress(host: "localhost").baseURL
        let result = await ensureRunning(url)
        guard !Task.isCancelled else { return nil }
        switch result {
        case .alreadyRunning, .started:
            return url
        case .unavailable, .failed:
            return nil
        }
    }
}
#endif
