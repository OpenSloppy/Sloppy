import Foundation
import Protocols
import PluginSDK

struct ProvidersAPIRouter: APIRouter {
    private let service: CoreService

    init(service: CoreService) {
        self.service = service
    }

    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/models", metadata: RouteMetadata(summary: "OpenAI-compatible model catalog", description: "Models served by this Sloppy proxy, including configured relay models", tags: ["Providers"])) { request in
            guard await service.authorizeModelProxy(request) else { return CoreRouter.encodable(status: 401, payload: OpenAIModelProxyWire.error("Sloppy authorization is required.", type: "authentication_error")) }
            let models = await service.listAvailableProviderModels()
            let rows = models.map { model in
                JSONValue.object(["id": .string(model.id), "object": .string("model"), "created": .number(0), "owned_by": .string("sloppy")])
            }
            return CoreRouter.encodable(status: 200, payload: JSONValue.object(["object": .string("list"), "data": .array(rows)]))
        }

        router.post("/v1/chat/completions", metadata: RouteMetadata(summary: "OpenAI-compatible model proxy", description: "One generation with caller-owned tools, directly or through Sloppy relay", tags: ["Providers"])) { request in
            guard await service.authorizeModelProxy(request) else { return CoreRouter.encodable(status: 401, payload: OpenAIModelProxyWire.error("Sloppy authorization is required.", type: "authentication_error")) }
            guard let body = request.body, let payload = CoreRouter.decode(body, as: OpenAIModelProxyRequest.self) else {
                return CoreRouter.encodable(status: 400, payload: OpenAIModelProxyWire.error("invalid_request"))
            }
            do {
                let catalog = await service.listAvailableProviderModels()
                let id = CoreModelProviderFactory.resolveRequestedModel(payload.model, from: catalog.map(\.id))
                guard catalog.contains(where: { $0.id == id }) else { throw SloppyRemoteError.unknownModel }
                let scope = await service.modelProxyScope(request)
                let inference = await service.modelProxyRequest(try payload.inference(modelID: id), scope: scope)
                if payload.stream == true {
                    return .init(status: 200, body: Data(), contentType: "text/event-stream",
                                 sseStream: try await service.streamModelProxy(inference, displayModel: payload.model, scope: scope))
                }
                let result = try await service.modelProxyInference(inference, scope: scope)
                return CoreRouter.encodable(status: 200, payload: OpenAIModelProxyWire.response(result, model: payload.model,
                    id: "chatcmpl-" + UUID().uuidString.lowercased(), created: Int(Date().timeIntervalSince1970)))
            } catch SloppyRemoteError.unknownModel {
                return CoreRouter.encodable(status: 404, payload: OpenAIModelProxyWire.error("model_not_available"))
            } catch SloppyRemoteError.invalidURL {
                return CoreRouter.encodable(status: 400, payload: OpenAIModelProxyWire.error("invalid_messages_or_options"))
            } catch {
                return CoreRouter.encodable(status: 503, payload: OpenAIModelProxyWire.error("model_inference_unavailable", type: "server_error"))
            }
        }

        router.post("/v1/providers/inference", metadata: RouteMetadata(summary: "Generate with a local model", description: "Sloppy inference v1; tool calls are returned to the requesting server for execution", tags: ["Providers"])) { request in
            guard await service.authorizeModelProxy(request) else { return CoreRouter.json(status: 401, payload: ["error": "unauthorized"]) }
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: SloppyInferenceRequest.self) else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
            do {
                if payload.stream == true {
                    let stream = try await service.streamRemoteInference(payload)
                    return CoreRouterResponse(status: HTTPStatus.ok, body: Data(), contentType: "text/event-stream", sseStream: stream)
                }
                let result = try await service.remoteInference(payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: result)
            } catch SloppyRemoteError.unknownModel {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "remote_model_unavailable"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "remote_inference_failed"])
            }
        }

        router.get("/v1/providers/image-generation/status", metadata: RouteMetadata(summary: "Image generation status", description: "Returns image generation configuration, credentials status, and supported models", tags: ["Providers"])) { _ in
            let status = await service.imageGenerationStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.get("/v1/providers/openai/status", metadata: RouteMetadata(summary: "OpenAI status", description: "Returns the current status of the OpenAI provider", tags: ["Providers"])) { _ in
            let status = await service.openAIProviderStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.get("/v1/providers/anthropic/status", metadata: RouteMetadata(summary: "Anthropic status", description: "Returns the current status of the Anthropic provider", tags: ["Providers"])) { _ in
            let status = await service.anthropicProviderStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.get("/v1/providers/gemini/status", metadata: RouteMetadata(summary: "Gemini status", description: "Returns the current status of the Gemini provider", tags: ["Providers"])) { _ in
            let status = await service.geminiProviderStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.get("/v1/providers/models", metadata: RouteMetadata(summary: "List available provider models", description: "Returns runtime-routable models for agent and channel model pickers", tags: ["Providers"])) { _ in
            let models = await service.listAvailableProviderModels()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: models)
        }

        router.post("/v1/providers/openai/oauth/start", metadata: RouteMetadata(summary: "Start OpenAI OAuth", description: "Creates an OpenAI OAuth authorization URL", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: OpenAIOAuthStartRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.startOpenAIOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }
        }

        router.post("/v1/providers/openai/oauth/complete", metadata: RouteMetadata(summary: "Complete OpenAI OAuth", description: "Exchanges the OpenAI OAuth authorization code for tokens", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: OpenAIOAuthCompleteRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.completeOpenAIOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: OpenAIOAuthCompleteResponse(
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/openai/oauth/device-code/start", metadata: RouteMetadata(summary: "Start device code flow", description: "Requests a device code for OpenAI OAuth device authorization", tags: ["Providers"])) { _ in
            do {
                let response = try await service.startOpenAIDeviceCode()
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.post("/v1/providers/openai/oauth/import-codex", metadata: RouteMetadata(summary: "Import Codex credentials", description: "Imports official Codex app or CLI credentials into Sloppy", tags: ["Providers"])) { _ in
            do {
                let response = try await service.importOpenAICodexCredentials()
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: OpenAIOAuthImportCodexResponse(
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/openai/oauth/device-code/poll", metadata: RouteMetadata(summary: "Poll device code", description: "Polls the device code authorization status", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: OpenAIDeviceCodePollRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.pollOpenAIDeviceCode(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: OpenAIDeviceCodePollResponse(
                        status: "error",
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/openai/oauth/disconnect", metadata: RouteMetadata(summary: "Disconnect OpenAI OAuth", description: "Removes stored OpenAI OAuth credentials", tags: ["Providers"])) { _ in
            do {
                try await service.disconnectOpenAIOAuth()
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.post("/v1/providers/anthropic/oauth/start", metadata: RouteMetadata(summary: "Start Anthropic OAuth", description: "Creates an Anthropic OAuth authorization URL", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AnthropicOAuthStartRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.startAnthropicOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.post("/v1/providers/anthropic/oauth/complete", metadata: RouteMetadata(summary: "Complete Anthropic OAuth", description: "Exchanges the Anthropic OAuth authorization code for tokens", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: AnthropicOAuthCompleteRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.completeAnthropicOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: AnthropicOAuthCompleteResponse(
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/anthropic/oauth/import-claude", metadata: RouteMetadata(summary: "Import Claude Code credentials", description: "Imports refreshable Claude Code credentials into Sloppy", tags: ["Providers"])) { _ in
            do {
                let response = try await service.importAnthropicClaudeCredentials()
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: AnthropicOAuthImportClaudeResponse(
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/anthropic/oauth/disconnect", metadata: RouteMetadata(summary: "Disconnect Anthropic OAuth", description: "Removes stored Anthropic OAuth credentials", tags: ["Providers"])) { _ in
            do {
                try await service.disconnectAnthropicOAuth()
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.post("/v1/providers/gemini/oauth/start", metadata: RouteMetadata(summary: "Start Gemini OAuth", description: "Creates a Google OAuth authorization URL for Gemini", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: GeminiOAuthStartRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.startGeminiOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.post("/v1/providers/gemini/oauth/complete", metadata: RouteMetadata(summary: "Complete Gemini OAuth", description: "Exchanges the Google OAuth authorization code for Gemini tokens", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: GeminiOAuthCompleteRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            do {
                let response = try await service.completeGeminiOAuth(request: payload)
                return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
            } catch {
                return CoreRouter.encodable(
                    status: HTTPStatus.ok,
                    payload: GeminiOAuthCompleteResponse(
                        ok: false,
                        message: error.localizedDescription
                    )
                )
            }
        }

        router.post("/v1/providers/gemini/oauth/disconnect", metadata: RouteMetadata(summary: "Disconnect Gemini OAuth", description: "Removes stored Gemini OAuth credentials", tags: ["Providers"])) { _ in
            do {
                try await service.disconnectGeminiOAuth()
                return CoreRouter.json(status: HTTPStatus.ok, payload: ["ok": "true"])
            } catch {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": error.localizedDescription])
            }
        }

        router.get("/v1/providers/search/status", metadata: RouteMetadata(summary: "Search status", description: "Returns the current status of the search provider", tags: ["Providers"])) { _ in
            let status = await service.searchProviderStatus()
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: status)
        }

        router.post("/v1/providers/probe", metadata: RouteMetadata(summary: "Probe provider", description: "Tests a specific provider configuration", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: ProviderProbeRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let response = await service.probeProvider(request: payload)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
        }

        router.post("/v1/providers/openai/models", metadata: RouteMetadata(summary: "List OpenAI models", description: "Returns a list of available models for OpenAI", tags: ["Providers"])) { request in
            guard let body = request.body,
                  let payload = CoreRouter.decode(body, as: OpenAIProviderModelsRequest.self)
            else {
                return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody])
            }

            let response = await service.listOpenAIModels(request: payload)
            return CoreRouter.encodable(status: HTTPStatus.ok, payload: response)
        }
    }
}
