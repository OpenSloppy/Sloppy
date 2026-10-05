import Foundation
import Protocols
import SloppyNodeCore

struct AuthenticatedUserContext: Sendable, Equatable {
    var user: AuthUserProfile
    var groups: [String] = []
    var identityProviderID: String?
}

enum CoreIdentityAuthError: Error, Sendable {
    case disabled
    case bootstrapAlreadyCompleted
    case bootstrapRequired
    case invalidCredentials
    case invalidCurrentPassword
    case invalidNewPassword
    case invalidInvite
    case invalidRole
    case inviteExpired
    case inviteConsumed
    case invalidRecoverySecret
    case invalidApplicationTokenName
    case applicationTokenNotFound
    case invalidDevicePairing
    case invalidDevicePairingConfiguration
    case forbidden
    case lastAdmin
}

actor CoreIdentityAuthService {
    static let accessTokenLifetimeSeconds = 5 * 24 * 60 * 60
    static let refreshTokenLifetimeSeconds = 604_800
    static let applicationTokenLifetimeSeconds = 31_536_000
    static let maximumDevicePairingLifetimeSeconds = 300
    static let defaultPasswordHashIterations = 120_000

    private struct StoredUser: Codable, Sendable {
        var profile: AuthUserProfile
        var passwordHash: String
        var recoveryCodeHashes: [String]
    }

    private struct StoredInvite: Codable, Sendable {
        var record: AuthInviteRecord
        var tokenHash: String
    }

    private struct StoredResetToken: Codable, Sendable {
        var userID: String
        var tokenHash: String
        var expiresAt: Date
    }

    private struct StoredTokenSession: Codable, Sendable {
        var userID: String
        var expiresAt: Date
    }

    private struct StoredApplicationToken: Codable, Sendable {
        var record: AuthApplicationTokenRecord
        var userID: String
    }

    private struct StoredDevicePairing: Sendable {
        var id: String
        var userID: String
        var clientName: String
        var expiresAt: Date
    }

    private struct PersistedState: Codable, Sendable {
        var enabled: Bool
        var usersByID: [String: StoredUser]
        var userIDByLogin: [String: String]
        var refreshTokens: [String: StoredTokenSession]
        var invitesByID: [String: StoredInvite]
        var resetTokensByID: [String: StoredResetToken]
        var applicationTokensByHash: [String: StoredApplicationToken]?
        var localOwnerUserID: String?
    }

    private var enabled = false
    private var localOwnerUserID: String?
    private var usersByID: [String: StoredUser] = [:]
    private var userIDByLogin: [String: String] = [:]
    private var accessTokens: [String: StoredTokenSession] = [:]
    private var refreshTokens: [String: StoredTokenSession] = [:]
    private var invitesByID: [String: StoredInvite] = [:]
    private var resetTokensByID: [String: StoredResetToken] = [:]
    private var applicationTokensByHash: [String: StoredApplicationToken] = [:]
    private var devicePairingsByHash: [String: StoredDevicePairing] = [:]
    private let passwordHashIterations: Int
    private let stateURL: URL?

    init(passwordHashIterations: Int = 120_000, stateURL: URL? = nil) {
        self.passwordHashIterations = max(1, passwordHashIterations)
        self.stateURL = stateURL
        if let state = Self.loadState(from: stateURL) {
            enabled = state.enabled
            usersByID = state.usersByID
            userIDByLogin = state.userIDByLogin
            refreshTokens = state.refreshTokens
            invitesByID = state.invitesByID
            resetTokensByID = state.resetTokensByID
            applicationTokensByHash = state.applicationTokensByHash ?? [:]
            localOwnerUserID = state.localOwnerUserID
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        saveState()
    }

    func hasUsers() -> Bool { !usersByID.isEmpty }
    func profile(id: String) -> AuthUserProfile? { usersByID[id]?.profile }

    func isEnabled() -> Bool {
        enabled
    }

    func challenge() -> AuthChallengeResponse {
        AuthChallengeResponse(
            mode: enabled ? .loginPassword : .token,
            bootstrapRequired: enabled && usersByID.isEmpty,
            passkeySupported: false,
            accessTokenExpiresInSeconds: Self.accessTokenLifetimeSeconds,
            refreshTokenExpiresInSeconds: Self.refreshTokenLifetimeSeconds
        )
    }

    func bootstrapAdmin(_ request: AuthBootstrapAdminRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        guard usersByID.isEmpty else {
            throw CoreIdentityAuthError.bootstrapAlreadyCompleted
        }
        let login = normalizedLogin(request.login)
        guard !login.isEmpty, !request.password.isEmpty else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        let profile = AuthUserProfile(
            id: makeID(prefix: "user"),
            login: login,
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: request.avatar,
            description: request.description,
            role: .admin
        )
        usersByID[profile.id] = StoredUser(
            profile: profile,
            passwordHash: PasswordHash.make(for: request.password, iterations: passwordHashIterations),
            recoveryCodeHashes: []
        )
        userIDByLogin[profile.login] = profile.id
        localOwnerUserID = profile.id
        saveState()
        return makeSession(for: profile)
    }

    func login(_ request: AuthLoginRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        guard !usersByID.isEmpty else {
            throw CoreIdentityAuthError.bootstrapRequired
        }
        let login = normalizedLogin(request.login)
        guard let userID = userIDByLogin[login],
              let stored = usersByID[userID],
              stored.profile.status == .active,
              PasswordHash.verify(password: request.password, hash: stored.passwordHash)
        else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        return makeSession(for: stored.profile)
    }

    func refresh(_ request: AuthRefreshRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        let refreshToken = request.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = refreshTokens.removeValue(forKey: refreshToken),
              session.expiresAt > Date(),
              let stored = usersByID[session.userID],
              stored.profile.status == .active
        else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        return makeSession(for: stored.profile)
    }

    func createInvite(_ request: AuthInviteCreateRequest, actor: AuthenticatedUserContext) throws -> AuthInviteRecord {
        try requireAdmin(actor)
        guard request.role.isCommunityRole else {
            throw CoreIdentityAuthError.invalidRole
        }
        let ttl = max(60, min(request.ttlSeconds, Self.refreshTokenLifetimeSeconds))
        let token = "slp_inv_" + NodeIdentityGenerator.randomToken(byteCount: 24)
        let now = Date()
        let record = AuthInviteRecord(
            id: makeID(prefix: "invite"),
            token: token,
            role: request.role,
            expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
            createdAt: now
        )
        invitesByID[record.id] = StoredInvite(
            record: record,
            tokenHash: PasswordHash.make(for: token, iterations: passwordHashIterations)
        )
        saveState()
        return record
    }

    func listUsers(actor: AuthenticatedUserContext) throws -> [AuthUserProfile] {
        try requireAdmin(actor)
        return usersByID.values
            .map(\.profile)
            .sorted { lhs, rhs in
                lhs.login.localizedStandardCompare(rhs.login) == .orderedAscending
            }
    }

    func updateUser(login: String, request: AuthUserUpdateRequest, actor: AuthenticatedUserContext) throws -> AuthUserProfile {
        try requireAdmin(actor)
        let normalized = normalizedLogin(login)
        guard let userID = userIDByLogin[normalized],
              var stored = usersByID[userID] else {
            throw CoreIdentityAuthError.invalidCredentials
        }

        var profile = stored.profile
        if let name = request.name {
            profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let avatar = request.avatar {
            profile.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description = request.description {
            profile.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let role = request.role {
            guard role.isCommunityRole else {
                throw CoreIdentityAuthError.invalidRole
            }
            profile.role = role
        }
        if let status = request.status {
            profile.status = status
        }
        if stored.profile.role == .admin && (profile.role != .admin || profile.status != .active) {
            let activeAdminCount = usersByID.values.filter { user in
                user.profile.role == .admin && user.profile.status == .active
            }.count
            if activeAdminCount <= 1 {
                throw CoreIdentityAuthError.lastAdmin
            }
        }

        stored.profile = profile
        usersByID[userID] = stored
        saveState()
        return profile
    }

    func updateCurrentUser(
        request: AuthUserUpdateRequest,
        actor: AuthenticatedUserContext
    ) throws -> AuthUserProfile {
        guard var stored = usersByID[actor.user.id],
              stored.profile.status == .active else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        guard request.role == nil, request.status == nil else {
            throw CoreIdentityAuthError.forbidden
        }

        if let name = request.name {
            stored.profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let avatar = request.avatar {
            stored.profile.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description = request.description {
            stored.profile.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        usersByID[stored.profile.id] = stored
        saveState()
        return stored.profile
    }

    func register(_ request: AuthRegisterRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        let now = Date()
        guard let inviteID = invitesByID.first(where: {
            PasswordHash.verify(password: request.inviteToken, hash: $0.value.tokenHash)
        })?.key,
              var invite = invitesByID[inviteID]
        else {
            throw CoreIdentityAuthError.invalidInvite
        }
        guard invite.record.consumedAt == nil else {
            throw CoreIdentityAuthError.inviteConsumed
        }
        guard invite.record.expiresAt > now else {
            throw CoreIdentityAuthError.inviteExpired
        }

        let login = normalizedLogin(request.login)
        guard !login.isEmpty, !request.password.isEmpty, userIDByLogin[login] == nil else {
            throw CoreIdentityAuthError.invalidCredentials
        }

        let profile = AuthUserProfile(
            id: makeID(prefix: "user"),
            login: login,
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: request.avatar,
            description: request.description,
            role: invite.record.role
        )
        usersByID[profile.id] = StoredUser(
            profile: profile,
            passwordHash: PasswordHash.make(for: request.password, iterations: passwordHashIterations),
            recoveryCodeHashes: []
        )
        userIDByLogin[profile.login] = profile.id
        invite.record.consumedAt = now
        invite.record.token = nil
        invitesByID[inviteID] = invite
        saveState()
        return makeSession(for: profile)
    }

    func generateRecoveryCodes(actor: AuthenticatedUserContext) throws -> AuthRecoveryCodesResponse {
        guard var stored = usersByID[actor.user.id] else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        let codes = (0..<10).map { _ in "slp_rc_" + NodeIdentityGenerator.randomToken(byteCount: 18) }
        stored.recoveryCodeHashes = codes.map { PasswordHash.make(for: $0, iterations: passwordHashIterations) }
        usersByID[stored.profile.id] = stored
        saveState()
        return AuthRecoveryCodesResponse(codes: codes)
    }

    func changePassword(_ request: AuthPasswordChangeRequest, actor: AuthenticatedUserContext) throws -> AuthSessionResponse {
        guard enabled,
              var stored = usersByID[actor.user.id],
              stored.profile.status == .active else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        guard !request.newPassword.isEmpty else {
            throw CoreIdentityAuthError.invalidNewPassword
        }
        guard PasswordHash.verify(password: request.currentPassword, hash: stored.passwordHash) else {
            throw CoreIdentityAuthError.invalidCurrentPassword
        }

        stored.passwordHash = PasswordHash.make(for: request.newPassword, iterations: passwordHashIterations)
        usersByID[stored.profile.id] = stored
        accessTokens = accessTokens.filter { $0.value.userID != stored.profile.id }
        refreshTokens = refreshTokens.filter { $0.value.userID != stored.profile.id }
        saveState()
        return makeSession(for: stored.profile)
    }

    func createPasswordResetToken(login: String, actor: AuthenticatedUserContext) throws -> AuthAdminPasswordResetResponse {
        try requireAdmin(actor)
        let normalized = normalizedLogin(login)
        guard let userID = userIDByLogin[normalized],
              usersByID[userID] != nil else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        let token = "slp_reset_" + NodeIdentityGenerator.randomToken(byteCount: 24)
        let expiresAt = Date().addingTimeInterval(900)
        resetTokensByID[makeID(prefix: "reset")] = StoredResetToken(
            userID: userID,
            tokenHash: PasswordHash.make(for: token, iterations: passwordHashIterations),
            expiresAt: expiresAt
        )
        saveState()
        return AuthAdminPasswordResetResponse(resetToken: token, expiresAt: expiresAt)
    }

    func resetPassword(_ request: AuthPasswordResetRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        let login = normalizedLogin(request.login)
        guard let userID = userIDByLogin[login],
              var stored = usersByID[userID],
              !request.newPassword.isEmpty else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        if let resetToken = request.resetToken?.trimmingCharacters(in: .whitespacesAndNewlines), !resetToken.isEmpty {
            guard let tokenID = resetTokensByID.first(where: {
                $0.value.userID == userID
                    && $0.value.expiresAt > Date()
                    && PasswordHash.verify(password: resetToken, hash: $0.value.tokenHash)
            })?.key else {
                throw CoreIdentityAuthError.invalidRecoverySecret
            }
            resetTokensByID.removeValue(forKey: tokenID)
        } else if let recoveryCode = request.recoveryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !recoveryCode.isEmpty {
            guard let codeIndex = stored.recoveryCodeHashes.firstIndex(where: {
                PasswordHash.verify(password: recoveryCode, hash: $0)
            }) else {
                throw CoreIdentityAuthError.invalidRecoverySecret
            }
            stored.recoveryCodeHashes.remove(at: codeIndex)
        } else {
            throw CoreIdentityAuthError.invalidRecoverySecret
        }
        stored.passwordHash = PasswordHash.make(for: request.newPassword, iterations: passwordHashIterations)
        usersByID[userID] = stored
        saveState()
        return makeSession(for: stored.profile)
    }

    func createDevicePairing(
        _ request: AuthDevicePairingCreateRequest,
        actor: AuthenticatedUserContext
    ) throws -> AuthDevicePairingRecord {
        guard enabled,
              let stored = usersByID[actor.user.id],
              stored.profile.status == .active else {
            throw CoreIdentityAuthError.invalidCredentials
        }

        removeExpiredDevicePairings()
        let requestedClientName = request.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientName = String((requestedClientName.isEmpty ? "Sloppy Client" : requestedClientName).prefix(80))
        devicePairingsByHash = devicePairingsByHash.filter {
            $0.value.userID != stored.profile.id || $0.value.clientName != clientName
        }
        let ttl = max(60, min(request.ttlSeconds, Self.maximumDevicePairingLifetimeSeconds))
        let now = Date()
        let token = "slp_pair_" + NodeIdentityGenerator.randomToken(byteCount: 32)
        let pairing = StoredDevicePairing(
            id: makeID(prefix: "device_pairing"),
            userID: stored.profile.id,
            clientName: clientName,
            expiresAt: now.addingTimeInterval(TimeInterval(ttl))
        )
        devicePairingsByHash[devicePairingHash(token)] = pairing
        return AuthDevicePairingRecord(
            id: pairing.id,
            token: token,
            clientName: pairing.clientName,
            createdAt: now,
            expiresAt: pairing.expiresAt,
            user: stored.profile
        )
    }

    func redeemDevicePairing(_ request: AuthDevicePairingRedeemRequest) throws -> AuthSessionResponse {
        guard enabled else {
            throw CoreIdentityAuthError.disabled
        }
        let token = request.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("slp_pair_") else {
            throw CoreIdentityAuthError.invalidDevicePairing
        }

        let hash = devicePairingHash(token)
        guard let pairing = devicePairingsByHash.removeValue(forKey: hash),
              pairing.expiresAt > Date(),
              let stored = usersByID[pairing.userID],
              stored.profile.status == .active else {
            removeExpiredDevicePairings()
            throw CoreIdentityAuthError.invalidDevicePairing
        }
        return makeSession(for: stored.profile)
    }

    func createApplicationToken(
        _ request: AuthApplicationTokenCreateRequest,
        actor: AuthenticatedUserContext
    ) throws -> AuthApplicationTokenRecord {
        guard enabled, usersByID[actor.user.id]?.profile.status == .active else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CoreIdentityAuthError.invalidApplicationTokenName
        }
        let lifetime = max(
            3_600,
            min(request.expiresInSeconds ?? Self.applicationTokenLifetimeSeconds, Self.applicationTokenLifetimeSeconds)
        )
        let now = Date()
        let token = "slp_pat_" + NodeIdentityGenerator.randomToken(byteCount: 32)
        let record = AuthApplicationTokenRecord(
            id: makeID(prefix: "application_token"),
            name: name,
            token: token,
            tokenPrefix: String(token.prefix(16)) + "…",
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(lifetime))
        )
        var storedRecord = record
        storedRecord.token = nil
        applicationTokensByHash[applicationTokenHash(token)] = StoredApplicationToken(
            record: storedRecord,
            userID: actor.user.id
        )
        saveState()
        return record
    }

    func listApplicationTokens(actor: AuthenticatedUserContext) throws -> [AuthApplicationTokenRecord] {
        guard enabled, usersByID[actor.user.id]?.profile.status == .active else {
            throw CoreIdentityAuthError.invalidCredentials
        }
        return applicationTokensByHash.values
            .filter { $0.userID == actor.user.id }
            .map(\.record)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func revokeApplicationToken(id: String, actor: AuthenticatedUserContext) throws {
        guard let hash = applicationTokensByHash.first(where: {
            $0.value.record.id == id && $0.value.userID == actor.user.id
        })?.key else {
            throw CoreIdentityAuthError.applicationTokenNotFound
        }
        applicationTokensByHash.removeValue(forKey: hash)
        saveState()
    }

    func authenticateAccessToken(_ token: String?) -> AuthenticatedUserContext? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }
        let now = Date()
        if let session = accessTokens[trimmed],
           session.expiresAt > now,
           let stored = usersByID[session.userID],
           stored.profile.status == .active {
            return AuthenticatedUserContext(user: stored.profile)
        }
        guard let applicationToken = applicationTokensByHash[applicationTokenHash(trimmed)],
              applicationToken.record.expiresAt > now,
              let stored = usersByID[applicationToken.userID],
              stored.profile.status == .active else {
            return nil
        }
        return AuthenticatedUserContext(user: stored.profile)
    }

    func makeLocalOwnerSession() throws -> AuthSessionResponse {
        guard enabled else { throw CoreIdentityAuthError.disabled }
        if localOwnerUserID == nil {
            // Old state has no owner marker. Never guess among multiple admins.
            let admins = usersByID.values.filter { $0.profile.role == .admin }
            guard admins.count == 1 else { throw CoreIdentityAuthError.forbidden }
            localOwnerUserID = admins.first?.profile.id
        }
        guard let ownerID = localOwnerUserID,
              let owner = usersByID[ownerID],
              owner.profile.role == .admin, owner.profile.status == .active else {
            throw CoreIdentityAuthError.forbidden
        }
        return makeSession(for: owner.profile)
    }

    func requireAdmin(_ actor: AuthenticatedUserContext) throws {
        guard actor.user.role == .admin else {
            throw CoreIdentityAuthError.forbidden
        }
    }

    private func makeSession(for profile: AuthUserProfile) -> AuthSessionResponse {
        let now = Date()
        let accessToken = "slp_at_" + NodeIdentityGenerator.randomToken(byteCount: 32)
        let refreshToken = "slp_rt_" + NodeIdentityGenerator.randomToken(byteCount: 32)
        let accessExpiresAt = now.addingTimeInterval(TimeInterval(Self.accessTokenLifetimeSeconds))
        let refreshExpiresAt = now.addingTimeInterval(TimeInterval(Self.refreshTokenLifetimeSeconds))
        accessTokens[accessToken] = StoredTokenSession(userID: profile.id, expiresAt: accessExpiresAt)
        refreshTokens[refreshToken] = StoredTokenSession(userID: profile.id, expiresAt: refreshExpiresAt)
        saveState()
        return AuthSessionResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: accessExpiresAt,
            refreshTokenExpiresAt: refreshExpiresAt,
            user: profile
        )
    }

    private func normalizedLogin(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func makeID(prefix: String) -> String {
        prefix + "_" + NodeIdentityGenerator.randomToken(byteCount: 12)
    }

    private func applicationTokenHash(_ token: String) -> String {
        TaskSyncCrypto.hmacSHA256Hex(
            key: Data("sloppy.application-token.v1".utf8),
            message: Data(token.utf8)
        )
    }

    private func devicePairingHash(_ token: String) -> String {
        TaskSyncCrypto.hmacSHA256Hex(
            key: Data("sloppy.device-pairing.v1".utf8),
            message: Data(token.utf8)
        )
    }

    private func removeExpiredDevicePairings() {
        let now = Date()
        devicePairingsByHash = devicePairingsByHash.filter { $0.value.expiresAt > now }
    }

    private static func loadState(from stateURL: URL?) -> PersistedState? {
        guard let stateURL,
              let data = try? Data(contentsOf: stateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedState.self, from: data)
    }

    private func saveState() {
        guard let stateURL else {
            return
        }
        let state = PersistedState(
            enabled: enabled,
            usersByID: usersByID,
            userIDByLogin: userIDByLogin,
            refreshTokens: refreshTokens,
            invitesByID: invitesByID,
            resetTokensByID: resetTokensByID,
            applicationTokensByHash: applicationTokensByHash,
            localOwnerUserID: localOwnerUserID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            // Auth state remains in memory; callers still receive the boundary error paths above.
        }
    }
}

private enum PasswordHash {
    static let outputBytes = 32

    static func make(for password: String, iterations: Int) -> String {
        let salt = NodeIdentityGenerator.randomToken(byteCount: 24)
        let derived = pbkdf2(password: password, salt: Data(salt.utf8), iterations: iterations, outputBytes: outputBytes)
        return "pbkdf2-sha256:\(iterations):\(salt):\(base64URL(derived))"
    }

    static func verify(password: String, hash: String) -> Bool {
        let parts = hash.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] == "pbkdf2-sha256",
              let iterations = Int(parts[1])
        else {
            return false
        }
        let derived = pbkdf2(password: password, salt: Data(parts[2].utf8), iterations: iterations, outputBytes: outputBytes)
        return constantTimeEquals(base64URL(derived), parts[3])
    }

    private static func pbkdf2(password: String, salt: Data, iterations: Int, outputBytes: Int) -> [UInt8] {
        let blocks = Int(ceil(Double(outputBytes) / 32.0))
        var derived: [UInt8] = []
        let key = [UInt8](password.utf8)
        let saltBytes = [UInt8](salt)
        for blockIndex in 1...blocks {
            var blockSalt = saltBytes
            blockSalt.append(contentsOf: [
                UInt8((blockIndex >> 24) & 0xff),
                UInt8((blockIndex >> 16) & 0xff),
                UInt8((blockIndex >> 8) & 0xff),
                UInt8(blockIndex & 0xff),
            ])
            var u = TaskSyncCrypto.hmacSHA256(key: key, message: blockSalt)
            var block = u
            for _ in 1..<iterations {
                u = TaskSyncCrypto.hmacSHA256(key: key, message: u)
                for index in block.indices {
                    block[index] ^= u[index]
                }
            }
            derived.append(contentsOf: block)
        }
        return Array(derived.prefix(outputBytes))
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = [UInt8](lhs.utf8)
        let b = [UInt8](rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}
