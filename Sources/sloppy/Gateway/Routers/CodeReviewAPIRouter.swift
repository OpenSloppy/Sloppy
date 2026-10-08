import Foundation
import Protocols

struct CodeReviewAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get(
            "/v1/code-reviews/providers",
            metadata: RouteMetadata(
                summary: "List code-review providers",
                description: "Returns built-in and plugin-backed Pull Requests providers",
                tags: ["Code Review"]
            )
        ) { _ in
            let providers = await service.listCodeReviewProviders()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: providers)
        }

        router.get(
            "/v1/code-reviews",
            metadata: RouteMetadata(
                summary: "List pull requests",
                description: "Aggregates pull requests from connected code-review providers",
                tags: ["Code Review"]
            )
        ) { request in
            let state = CodeReviewState(rawValue: request.queryParam("state") ?? "open") ?? .open
            let roles = (request.queryParam("roles") ?? "authored,review_requested")
                .split(separator: ",")
                .compactMap { CodeReviewRole(rawValue: String($0)) }
            let providerIDs = Set(
                (request.queryParam("providers") ?? "")
                    .split(separator: ",")
                    .map(String.init)
            )
            let limit = Int(request.queryParam("limit") ?? "") ?? 100
            let response = await service.codeReviewInbox(
                query: CodeReviewQuery(state: state, roles: roles, limit: limit),
                providerIDs: providerIDs
            )
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
        }

        router.get(
            "/v1/code-reviews/:providerId/:reviewId",
            metadata: RouteMetadata(
                summary: "Get pull request details",
                description: "Returns comments and a bounded code diff from one code-review provider",
                tags: ["Code Review"]
            )
        ) { request in
            let maxDiffBytes = Int(request.queryParam("maxDiffBytes") ?? "") ?? 1_048_576
            do {
                let detail = try await service.codeReviewDetail(
                    providerID: request.pathParam("providerId") ?? "",
                    reviewID: request.pathParam("reviewId") ?? "",
                    maxDiffBytes: maxDiffBytes
                )
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: detail)
            } catch {
                return CoreRouter.json(
                    status: HTTPStatus.badRequest,
                    payload: ["error": "code_review_detail_failed", "message": error.localizedDescription]
                )
            }
        }

        router.get("/v1/code-reviews/:providerId/:reviewId/sessions") { request in
            do {
                let sessions = try await service.codeReviewSessions(.init(
                    providerId: request.pathParam("providerId") ?? "",
                    reviewId: request.pathParam("reviewId") ?? "",
                    repository: request.queryParam("repository") ?? ""
                ))
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: sessions)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest,
                    payload: ["error": "code_review_sessions_failed", "message": error.localizedDescription])
            }
        }

        router.post("/v1/code-reviews/:providerId/:reviewId/sessions") { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: CodeReviewSessionRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_code_review_session_payload"])
            }
            do {
                let session = try await service.openCodeReviewSession(.init(
                    providerId: request.pathParam("providerId") ?? "",
                    reviewId: request.pathParam("reviewId") ?? "",
                    repository: payload.repository
                ), request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: session)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest,
                    payload: ["error": "code_review_session_failed", "message": error.localizedDescription])
            }
        }

        router.post(
            "/v1/code-reviews/:providerId/:reviewId/comments",
            metadata: RouteMetadata(
                summary: "Reply to code-review comment",
                description: "Creates a reply in an existing provider comment thread",
                tags: ["Code Review"]
            )
        ) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: CodeReviewCommentReplyRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_comment_reply_payload"])
            }
            do {
                let comment = try await service.replyToCodeReviewComment(
                    providerID: request.pathParam("providerId") ?? "",
                    reviewID: request.pathParam("reviewId") ?? "",
                    parentCommentID: payload.parentCommentID,
                    body: payload.body
                )
                return CoreRouter.encodable(status: HTTPStatus.created, payload: comment)
            } catch {
                return CoreRouter.json(
                    status: HTTPStatus.badRequest,
                    payload: ["error": "code_review_comment_reply_failed", "message": error.localizedDescription]
                )
            }
        }

        router.get(
            "/v1/code-review-credentials/:providerId",
            metadata: RouteMetadata(
                summary: "Get code-review credential status",
                description: "Reports whether a provider credential is stored without returning its value",
                tags: ["Code Review"]
            )
        ) { request in
            let providerID = request.pathParam("providerId") ?? ""
            return CoreRouter.encodable(
                status: HTTPStatus.ok,
                payload: await service.codeReviewCredentialStatus(providerID: providerID)
            )
        }

        router.put(
            "/v1/code-review-credentials/:providerId",
            metadata: RouteMetadata(
                summary: "Save code-review credential",
                description: "Stores a provider credential in the local system Keychain",
                tags: ["Code Review"]
            )
        ) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: CodeReviewCredentialRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_credential_payload"])
            }
            let providerID = request.pathParam("providerId") ?? ""
            do {
                try await service.saveCodeReviewCredential(providerID: providerID, token: payload.token)
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: await service.codeReviewCredentialStatus(providerID: providerID)
                )
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "credential_save_failed"])
            }
        }

        router.delete(
            "/v1/code-review-credentials/:providerId",
            metadata: RouteMetadata(
                summary: "Delete code-review credential",
                description: "Removes a provider credential from the local system Keychain",
                tags: ["Code Review"]
            )
        ) { request in
            let providerID = request.pathParam("providerId") ?? ""
            do {
                try await service.deleteCodeReviewCredential(providerID: providerID)
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: await service.codeReviewCredentialStatus(providerID: providerID)
                )
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "credential_delete_failed"])
            }
        }
    }
}
