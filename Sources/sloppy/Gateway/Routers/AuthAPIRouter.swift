import Foundation
import Protocols

struct AuthAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/auth/challenge", metadata: RouteMetadata(summary: "Get auth challenge", description: "Returns the authentication challenge expected by this Core instance", tags: ["Auth"])) { _ in
            CoreRouter.encodable(status: HTTPStatus.ok, payload: await service.identityAuthChallenge())
        }

        router.post("/v1/auth/mode", metadata: RouteMetadata(summary: "Enable login/password auth", description: "Irreversibly switches this Core instance to login/password auth", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthModeUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            if payload.mode == .console {
                let challenge = await service.identityAuthChallenge()
                guard challenge.mode == .console else { return CoreRouter.json(status: 409, payload: ["error": "console_binding_or_migration_required"]) }
                return CoreRouter.encodable(status: 200, payload: challenge)
            }
            guard payload.mode == .loginPassword else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
                    "error": "unsupported_auth_mode",
                    "message": "Login/password auth can only be enabled, not reverted to token auth."
                ])
            }
            guard payload.confirmIrreversible else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
                    "error": "confirmation_required",
                    "message": "Set confirmIrreversible to true to acknowledge that login/password auth cannot be reverted."
                ])
            }
            await service.setIdentityAuthEnabled(true)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: await service.identityAuthChallenge())
        }

        router.get("/v1/auth/me", metadata: RouteMetadata(summary: "Current identity user", description: "Returns the authenticated login/password user profile", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: actor.user)
        }

        router.patch("/v1/auth/me", metadata: RouteMetadata(summary: "Update current identity user", description: "Updates the authenticated user's profile fields", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard let payload = request.decode(AuthUserUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.updateCurrentIdentityUser(request: payload, actor: actor)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/bootstrap", metadata: RouteMetadata(summary: "Bootstrap first admin", description: "Creates the first Admin account for login/password auth", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthBootstrapAdminRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.bootstrapIdentityAdmin(payload))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/login", metadata: RouteMetadata(summary: "Login", description: "Creates an auth session from login and password", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthLoginRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.loginIdentityUser(payload))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/refresh", metadata: RouteMetadata(summary: "Refresh auth session", description: "Rotates a refresh token and returns a new auth session", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthRefreshRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.refreshIdentitySession(payload))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/device-pairing", metadata: RouteMetadata(summary: "Create device pairing", description: "Creates a short-lived one-time pairing token for the authenticated user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard let payload = request.decode(AuthDevicePairingCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.created,
                    payload: try await service.createIdentityDevicePairing(payload, actor: actor)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/device-pairing/tls-fingerprint", metadata: RouteMetadata(summary: "Detect client TLS fingerprint", description: "Reads the leaf certificate fingerprint from the configured public client URL", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.detectClientTLSFingerprint(actor: actor)
                )
            } catch let error as TLSCertificateFingerprintProbeError {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: [
                    "error": "tls_fingerprint_probe_failed",
                    "message": error.localizedDescription,
                ])
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/device-pairing/redeem", metadata: RouteMetadata(summary: "Redeem device pairing", description: "Consumes a short-lived pairing token and creates a user auth session", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthDevicePairingRedeemRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.redeemIdentityDevicePairing(payload)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/register", metadata: RouteMetadata(summary: "Register invited user", description: "Consumes an invite and creates a user account", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthRegisterRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.registerIdentityUser(payload))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/invites", metadata: RouteMetadata(summary: "Create auth invite", description: "Creates an invite token for another user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard actor.user.role == .admin else {
                return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
            }
            guard let payload = request.decode(AuthInviteCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.createIdentityInvite(payload, actor: actor))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.get("/v1/auth/users", metadata: RouteMetadata(summary: "List auth users", description: "Lists login/password user profiles for admins", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard actor.user.role == .admin else {
                return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.listIdentityUsers(actor: actor))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.patch("/v1/auth/users/:login", metadata: RouteMetadata(summary: "Update auth user", description: "Updates a login/password user profile, role, or status for admins", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard actor.user.role == .admin else {
                return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
            }
            guard let payload = request.decode(AuthUserUpdateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.updateIdentityUser(
                        login: request.pathParam("login") ?? "",
                        request: payload,
                        actor: actor
                    )
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/recovery-codes", metadata: RouteMetadata(summary: "Generate recovery codes", description: "Generates one-time recovery codes for the authenticated user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.created, payload: try await service.generateIdentityRecoveryCodes(actor: actor))
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/password", metadata: RouteMetadata(summary: "Change password", description: "Changes the authenticated user's password after verifying the current password", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard let payload = request.decode(AuthPasswordChangeRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.changeIdentityPassword(payload, actor: actor)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.get("/v1/auth/application-tokens", metadata: RouteMetadata(summary: "List application tokens", description: "Lists long-lived application tokens owned by the authenticated user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: try await service.listIdentityApplicationTokens(actor: actor)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/application-tokens", metadata: RouteMetadata(summary: "Create application token", description: "Creates a long-lived bearer token for SloppySafari or another application", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard let payload = request.decode(AuthApplicationTokenCreateRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.created,
                    payload: try await service.createIdentityApplicationToken(payload, actor: actor)
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.delete("/v1/auth/application-tokens/:tokenId", metadata: RouteMetadata(summary: "Revoke application token", description: "Revokes an application token owned by the authenticated user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            do {
                try await service.revokeIdentityApplicationToken(
                    id: request.pathParam("tokenId") ?? "",
                    actor: actor
                )
                return CoreRouterResponse(status: 204, body: Data(), contentType: "application/json")
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/users/:login/password-reset-token", metadata: RouteMetadata(summary: "Create password reset token", description: "Creates a short-lived admin password reset token for a user", tags: ["Auth"])) { request in
            guard let actor = await CoreRouter.identityActor(for: request, service: service) else {
                return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
            }
            guard actor.user.role == .admin else {
                return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
            }
            do {
                return CoreRouter.encodable(
                    status: HTTPStatus.created,
                    payload: try await service.createIdentityPasswordResetToken(
                        login: request.pathParam("login") ?? "",
                        actor: actor
                    )
                )
            } catch {
                return authErrorResponse(error)
            }
        }

        router.post("/v1/auth/password-reset", metadata: RouteMetadata(summary: "Reset password", description: "Resets a password with a recovery code or admin reset token", tags: ["Auth"])) { request in
            guard let payload = request.decode(AuthPasswordResetRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await service.resetIdentityPassword(payload))
            } catch {
                return authErrorResponse(error)
            }
        }
    }
}

private func authErrorResponse(_ error: Error) -> CoreRouterResponse {
    switch error {
    case CoreIdentityAuthError.forbidden:
        return CoreRouter.json(status: HTTPStatus.forbidden, payload: ["error": "forbidden"])
    case CoreIdentityAuthError.bootstrapAlreadyCompleted:
        return CoreRouter.json(status: HTTPStatus.conflict, payload: ["error": "bootstrap_completed"])
    case CoreIdentityAuthError.bootstrapRequired:
        return CoreRouter.json(status: HTTPStatus.conflict, payload: ["error": "bootstrap_required"])
    case CoreIdentityAuthError.lastAdmin:
        return CoreRouter.json(status: HTTPStatus.conflict, payload: ["error": "last_admin"])
    case CoreIdentityAuthError.disabled:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "auth_disabled"])
    case CoreIdentityAuthError.invalidRole:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_role"])
    case CoreIdentityAuthError.invalidApplicationTokenName:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_application_token_name"])
    case CoreIdentityAuthError.invalidDevicePairingConfiguration:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_device_pairing_configuration"])
    case CoreIdentityAuthError.invalidCurrentPassword:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_current_password"])
    case CoreIdentityAuthError.invalidNewPassword:
        return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_new_password"])
    case CoreIdentityAuthError.applicationTokenNotFound:
        return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "application_token_not_found"])
    case CoreIdentityAuthError.invalidCredentials,
         CoreIdentityAuthError.invalidInvite,
         CoreIdentityAuthError.inviteExpired,
         CoreIdentityAuthError.inviteConsumed,
         CoreIdentityAuthError.invalidDevicePairing,
         CoreIdentityAuthError.invalidRecoverySecret:
        return CoreRouter.json(status: HTTPStatus.unauthorized, payload: ["error": ErrorCode.unauthorized])
    default:
        return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "auth_failed"])
    }
}
