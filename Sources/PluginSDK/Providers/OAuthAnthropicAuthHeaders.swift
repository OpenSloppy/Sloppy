import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Anthropic Messages API auth (Console API key vs OAuth / Claude Code)

/// Builds request headers for Anthropic's Messages API, aligned with Claude Code–style routing:
/// - Console API keys (`sk-ant-api…`) → `x-api-key`
/// - OAuth / setup tokens (everything else on `api.anthropic.com`) → `Authorization: Bearer` + Claude Code identity headers
/// - Third-party proxies (non-Anthropic hosts) → always `x-api-key` (proxy's key)
/// - MiniMax Anthropic-compatible endpoints → `Authorization: Bearer`
public enum OAuthAnthropicAuthHeaders {
    public static let defaultAPIVersion = "2023-06-01"

    private static let commonBetas = [
        "interleaved-thinking-2025-05-14",
        "fine-grained-tool-streaming-2025-05-14",
    ]

    private static let oauthOnlyBetas = [
        "claude-code-20250219",
        "oauth-2025-04-20",
    ]

    private static let claudeCodeVersionFallback = "2.1.74"

    nonisolated(unsafe) private static var cachedClaudeCLIVersion: String?
    private static let versionCacheLock = NSLock()

    static func make(
        apiKey: String,
        baseURL: URL,
        apiVersion: String,
        additionalBetas: [String]?
    ) -> [String: String] {
        if requiresBearerAuth(for: baseURL) {
            let betas = mergeBetas(commonBetas, additionalBetas ?? [])
            var headers: [String: String] = [
                "Authorization": "Bearer \(apiKey)",
                "anthropic-version": apiVersion,
            ]
            if !betas.isEmpty {
                headers["anthropic-beta"] = betas.joined(separator: ",")
            }
            return headers
        }

        if isThirdPartyAnthropicEndpoint(baseURL) {
            let betas = mergeBetas(commonBetas, additionalBetas ?? [])
            var headers: [String: String] = [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
            ]
            if !betas.isEmpty {
                headers["anthropic-beta"] = betas.joined(separator: ",")
            }
            return headers
        }

        if isOAuthStyleToken(apiKey) {
            let betas = mergeBetas(commonBetas, oauthOnlyBetas, additionalBetas ?? [])
            return [
                "Authorization": "Bearer \(apiKey)",
                "anthropic-version": apiVersion,
                "anthropic-beta": betas.joined(separator: ","),
                "user-agent": "claude-cli/\(resolvedClaudeCodeCLIVersion()) (external, cli)",
                "x-app": "cli",
            ]
        }

        let betas = mergeBetas(commonBetas, additionalBetas ?? [])
        var headers: [String: String] = [
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
        ]
        if !betas.isEmpty {
            headers["anthropic-beta"] = betas.joined(separator: ",")
        }
        return headers
    }

    /// `true` for Anthropic-compatible endpoints that expect `Authorization: Bearer` for all keys (e.g. MiniMax).
    static func requiresBearerAuth(for baseURL: URL) -> Bool {
        let normalized = normalizedBaseURLString(baseURL)
        return normalized.hasPrefix("https://api.minimax.io/anthropic")
            || normalized.hasPrefix("https://api.minimaxi.com/anthropic")
    }

    /// Third-party proxies (Azure, Bedrock bridges, self-hosted) use their own keys with `x-api-key`, not OAuth heuristics.
    static func isThirdPartyAnthropicEndpoint(_ baseURL: URL) -> Bool {
        let normalized = normalizedBaseURLString(baseURL)
        return !normalized.contains("anthropic.com")
    }

    /// Regular Console API keys use `x-api-key`; OAuth/setup tokens and other shapes use Bearer on direct Anthropic API.
    static func isOAuthStyleToken(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("sk-ant-api") { return false }
        return true
    }

    private static func normalizedBaseURLString(_ url: URL) -> String {
        var s = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s.lowercased()
    }

    private static func mergeBetas(_ parts: [String]...) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            for b in part {
                if seen.insert(b).inserted {
                    out.append(b)
                }
            }
        }
        return out
    }

    private static func resolvedClaudeCodeCLIVersion() -> String {
        versionCacheLock.lock()
        defer { versionCacheLock.unlock() }
        if let cached = cachedClaudeCLIVersion {
            return cached
        }
        for command in ["claude", "claude-code"] {
            if let v = runCLIVersion(command: command) {
                cachedClaudeCLIVersion = v
                return v
            }
        }
        cachedClaudeCLIVersion = claudeCodeVersionFallback
        return claudeCodeVersionFallback
    }

    private static func runCLIVersion(command: String) -> String? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return nil
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command, "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        // e.g. "2.1.74 (Claude Code)" or "2.1.74"
        let firstToken = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init).first ?? raw
        guard let ch = firstToken.first, ch.isNumber else { return nil }
        return firstToken
        #endif
    }

    /// Authentication headers for Anthropic Messages API (shared with provider probe and ``OAuthAnthropicURLProtocol``).
    public static func authenticationHeaders(
        apiKey: String,
        baseURL: URL,
        apiVersion: String = defaultAPIVersion,
        additionalBetas: [String]? = nil
    ) -> [String: String] {
        make(
            apiKey: apiKey,
            baseURL: baseURL,
            apiVersion: apiVersion,
            additionalBetas: additionalBetas
        )
    }
}
