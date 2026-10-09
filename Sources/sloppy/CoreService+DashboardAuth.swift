import Foundation

struct DashboardAuthStatus: Sendable, Equatable {
    let enabled: Bool
    let acceptsLegacyToken: Bool
    let protectsMutatingRoutes: Bool
    let protectsTerminalWebSocket: Bool
}

extension CoreService {
    func dashboardAuthStatus() -> DashboardAuthStatus {
        let dashboardToken = currentConfig.ui.dashboardAuth.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyToken = currentConfig.auth.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = currentConfig.ui.dashboardAuth.enabled && !dashboardToken.isEmpty

        return DashboardAuthStatus(
            enabled: enabled,
            acceptsLegacyToken: !legacyToken.isEmpty,
            protectsMutatingRoutes: enabled,
            protectsTerminalWebSocket: enabled
        )
    }

    func validateDashboardAuthorizationHeader(_ headerValue: String?) -> Bool {
        let status = dashboardAuthStatus()
        guard status.enabled else {
            return true
        }
        guard let token = Self.extractBearerToken(from: headerValue) else {
            return false
        }
        return validateDashboardAuthToken(token)
    }

    func validateClientAuthorizationHeader(_ headerValue: String?) async -> Bool {
        if await identityAuthEnabled() {
            return await authenticateIdentityAccessToken(Self.extractBearerToken(from: headerValue)) != nil
        }
        return validateDashboardAuthorizationHeader(headerValue)
    }

    func validateClientAuthToken(_ token: String?) async -> Bool {
        if await identityAuthEnabled() {
            return await authenticateIdentityAccessToken(token) != nil
        }
        return validateDashboardAuthToken(token)
    }

    func validateDashboardAuthToken(_ token: String?) -> Bool {
        let status = dashboardAuthStatus()
        guard status.enabled else {
            return true
        }

        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedToken.isEmpty else {
            return false
        }

        let dashboardToken = currentConfig.ui.dashboardAuth.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dashboardToken.isEmpty, trimmedToken == dashboardToken {
            return true
        }

        let legacyToken = currentConfig.auth.token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !legacyToken.isEmpty && trimmedToken == legacyToken
    }

    static func extractBearerToken(from headerValue: String?) -> String? {
        let trimmed = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        return parts[1]
    }
}
