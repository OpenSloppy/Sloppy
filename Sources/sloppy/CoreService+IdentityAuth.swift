import Foundation
import Protocols
import SloppyConsoleProtocol

extension CoreService {
    func setIdentityAuthEnabled(_ enabled: Bool) async {
        await identityAuthService.setEnabled(enabled)
    }

    func identityAuthEnabled() async -> Bool {
        await identityAuthService.isEnabled()
    }

    func identityAuthChallenge() async -> AuthChallengeResponse {
        var challenge = await identityAuthService.challenge()
        let legacy = await identityAuthService.hasUsers()
        let migrated = await consoleTrustStore?.migrationConfirmed() ?? false
        if let binding = await consoleTrustStore?.binding(), binding.status == .active, !legacy || migrated { challenge.mode = .console; challenge.bootstrapRequired = false }
        else if migrated { challenge.mode = .token; challenge.bootstrapRequired = false }
        return challenge
    }

    func bootstrapIdentityAdmin(_ request: AuthBootstrapAdminRequest) async throws -> AuthSessionResponse {
        try await identityAuthService.bootstrapAdmin(request)
    }

    func loginIdentityUser(_ request: AuthLoginRequest) async throws -> AuthSessionResponse {
        guard await identityAuthChallenge().mode != .console, !(await consoleTrustStore?.migrationConfirmed() ?? false) else { throw CoreIdentityAuthError.disabled }
        return try await identityAuthService.login(request)
    }

    func refreshIdentitySession(_ request: AuthRefreshRequest) async throws -> AuthSessionResponse {
        try await identityAuthService.refresh(request)
    }

    func createIdentityDevicePairing(
        _ request: AuthDevicePairingCreateRequest,
        actor: AuthenticatedUserContext
    ) async throws -> AuthDevicePairingRecord {
        var pairing = try await identityAuthService.createDevicePairing(request, actor: actor)
        guard let primaryURL = try resolvedClientPairingURL() else {
            return pairing
        }

        let alternateURLs = try currentConfig.clientAlternateURLs
            .map(normalizedClientPairingURL)
            .filter { $0 != primaryURL }
        let fingerprint = try normalizedClientTLSFingerprint(currentConfig.clientTLSFingerprint)
        let payload = AuthDevicePairingSetupPayload(
            url: primaryURL,
            urls: alternateURLs.isEmpty ? nil : [primaryURL] + alternateURLs,
            bootstrapToken: pairing.token,
            expiresAt: pairing.expiresAt,
            tlsFingerprint: fingerprint,
            label: "Sloppy @ \(URL(string: primaryURL)?.host ?? primaryURL)"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let code = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "sloppy"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        pairing.setupCode = components.url?.absoluteString
        pairing.serverURL = primaryURL
        return pairing
    }

    private func resolvedClientPairingURL() throws -> String? {
        let configured = [currentConfig.clientPublicURL, currentConfig.nodeMeshPublicURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let configured else { return nil }
        return try normalizedClientPairingURL(configured)
    }

    private func normalizedClientPairingURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        switch scheme {
        case "https":
            break
        case "wss":
            components.scheme = "https"
        case "http":
            guard Self.isPrivateClientPairingHost(components.host) else {
                throw CoreIdentityAuthError.invalidDevicePairingConfiguration
            }
        case "ws":
            guard Self.isPrivateClientPairingHost(components.host) else {
                throw CoreIdentityAuthError.invalidDevicePairingConfiguration
            }
            components.scheme = "http"
        default:
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func normalizedClientTLSFingerprint(_ rawValue: String?) throws -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let normalized = rawValue.lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        return normalized
    }

    private static func isPrivateClientPairingHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host == "127.0.0.1" || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
    }

    func detectClientTLSFingerprint(
        actor: AuthenticatedUserContext
    ) async throws -> AuthTLSCertificateFingerprintResponse {
        guard actor.user.role == .admin else {
            throw CoreIdentityAuthError.forbidden
        }
        guard let rawURL = try resolvedClientPairingURL(),
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https" else {
            throw CoreIdentityAuthError.invalidDevicePairingConfiguration
        }
        let fingerprint = try await TLSCertificateFingerprintProbe.fingerprint(for: url)
        return AuthTLSCertificateFingerprintResponse(
            url: rawURL,
            fingerprint: fingerprint
        )
    }

    func redeemIdentityDevicePairing(_ request: AuthDevicePairingRedeemRequest) async throws -> AuthSessionResponse {
        try await identityAuthService.redeemDevicePairing(request)
    }

    func registerIdentityUser(_ request: AuthRegisterRequest) async throws -> AuthSessionResponse {
        try await identityAuthService.register(request)
    }

    func createIdentityInvite(_ request: AuthInviteCreateRequest, actor: AuthenticatedUserContext) async throws -> AuthInviteRecord {
        try await identityAuthService.createInvite(request, actor: actor)
    }

    func listIdentityUsers(actor: AuthenticatedUserContext) async throws -> [AuthUserProfile] {
        try await identityAuthService.listUsers(actor: actor)
    }

    func updateIdentityUser(login: String, request: AuthUserUpdateRequest, actor: AuthenticatedUserContext) async throws -> AuthUserProfile {
        try await identityAuthService.updateUser(login: login, request: request, actor: actor)
    }

    func updateCurrentIdentityUser(
        request: AuthUserUpdateRequest,
        actor: AuthenticatedUserContext
    ) async throws -> AuthUserProfile {
        try await identityAuthService.updateCurrentUser(request: request, actor: actor)
    }

    func generateIdentityRecoveryCodes(actor: AuthenticatedUserContext) async throws -> AuthRecoveryCodesResponse {
        try await identityAuthService.generateRecoveryCodes(actor: actor)
    }

    func changeIdentityPassword(_ request: AuthPasswordChangeRequest, actor: AuthenticatedUserContext) async throws -> AuthSessionResponse {
        try await identityAuthService.changePassword(request, actor: actor)
    }

    func createIdentityPasswordResetToken(login: String, actor: AuthenticatedUserContext) async throws -> AuthAdminPasswordResetResponse {
        try await identityAuthService.createPasswordResetToken(login: login, actor: actor)
    }

    func resetIdentityPassword(_ request: AuthPasswordResetRequest) async throws -> AuthSessionResponse {
        try await identityAuthService.resetPassword(request)
    }

    func createIdentityApplicationToken(
        _ request: AuthApplicationTokenCreateRequest,
        actor: AuthenticatedUserContext
    ) async throws -> AuthApplicationTokenRecord {
        try await identityAuthService.createApplicationToken(request, actor: actor)
    }

    func listIdentityApplicationTokens(actor: AuthenticatedUserContext) async throws -> [AuthApplicationTokenRecord] {
        try await identityAuthService.listApplicationTokens(actor: actor)
    }

    func revokeIdentityApplicationToken(id: String, actor: AuthenticatedUserContext) async throws {
        try await identityAuthService.revokeApplicationToken(id: id, actor: actor)
    }

    func authenticateIdentityAccessToken(_ token: String?) async -> AuthenticatedUserContext? {
        if let localIdentity = await identityAuthService.authenticateAccessToken(token) {
            return localIdentity
        }
        guard let token,
              let enterpriseIdentity = await authenticateEnterpriseIdentity(bearerToken: token)
        else {
            return nil
        }
        return AuthenticatedUserContext(
            user: enterpriseIdentity.profile,
            groups: enterpriseIdentity.groups,
            identityProviderID: enterpriseIdentity.providerID
        )
    }
}
