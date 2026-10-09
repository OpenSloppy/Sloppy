import Foundation
import PluginSDK

/// Short-lived, caller/model/tool-call scoped native state for standard API
/// clients that cannot echo Sloppy's opaque replay extension.
actor ModelProxyReplayCache {
    private struct Entry {
        var replay: SloppyInferenceReplay
        var expires: Date
        var bytes: Int
    }
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private let capacity = 64 * 1024 * 1024
    func clear() { entries.removeAll(); bytes = 0 }

    func store(_ replay: SloppyInferenceReplay?, scope: String, model: String, callIDs: [String], now: Date = Date()) {
        prune(now)
        guard let replay, !callIDs.isEmpty, let data = try? JSONEncoder().encode(replay), data.count <= 8 * 1024 * 1024 else { return }
        let key = cacheKey(scope, model, callIDs)
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
        while entries.count >= 128 || bytes + data.count > capacity {
            guard let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key,
                  let old = entries.removeValue(forKey: oldest) else { break }
            bytes -= old.bytes
        }
        entries[key] = .init(replay: replay, expires: now.addingTimeInterval(600), bytes: data.count)
        bytes += data.count
    }

    func replay(scope: String, model: String, callIDs: [String], now: Date = Date()) -> SloppyInferenceReplay? {
        prune(now)
        return entries[cacheKey(scope, model, callIDs)]?.replay
    }
    private func cacheKey(_ scope: String, _ model: String, _ ids: [String]) -> String {
        // Length-prefixed JSON avoids delimiter collisions and stores no token.
        String(decoding: (try? JSONEncoder().encode([scope, model] + ids)) ?? Data(), as: UTF8.self)
    }
    private func prune(_ now: Date) {
        let expired = entries.filter { $0.value.expires <= now }.map(\.key)
        for key in expired {
            if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes }
        }
    }
}
