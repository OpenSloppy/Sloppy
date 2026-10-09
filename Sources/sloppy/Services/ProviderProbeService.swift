import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginSDK
import Protocols

struct ProviderProbeService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private enum ProviderProbeError: Error, LocalizedError {
        case httpFailure(statusCode: Int, body: String)

        var isAccessTokenScopeInsufficient: Bool {
            switch self {
            case .httpFailure(_, let body):
                return body.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
                    || body.localizedCaseInsensitiveContains("insufficient authentication scopes")
            }
        }

        var errorDescription: String? {
            switch self {
            case .httpFailure(let statusCode, let body):
                if body.isEmpty {
                    return "provider returned HTTP \(statusCode)"
                }
                return "provider returned HTTP \(statusCode): \(body)"
            }
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
        }

        let data: [ModelItem]
    }

    private struct OllamaTagsResponse: Decodable {
        struct ModelItem: Decodable {
            let name: String
        }

        let models: [ModelItem]
    }

    private let environmentLookup: @Sendable (String) -> String?
    private let transport: Transport
    private let claudeSettingsProvider: @Sendable () -> ClaudeSettingsEnvironment
    private let geminiOAuthCredentialsProvider: @Sendable () -> GeminiOAuthCredentials?

    init(
        environmentLookup: @escaping @Sendable (String) -> String? = { key in
            ProcessInfo.processInfo.environment[key]
        },
        transport: Transport? = nil,
        claudeSettingsProvider: @escaping @Sendable () -> ClaudeSettingsEnvironment = {
            ClaudeSettingsEnvironment.load()
        },
        geminiOAuthCredentialsProvider: @escaping @Sendable () -> GeminiOAuthCredentials? = {
            GeminiOAuthCredentials.load()
        }
    ) {
        self.environmentLookup = environmentLookup
        self.claudeSettingsProvider = claudeSettingsProvider
        self.geminiOAuthCredentialsProvider = geminiOAuthCredentialsProvider
        self.transport = transport ?? { request in
            let (data, response) = try await SloppyURLSessionFactory.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        }
    }

    private static func sanitizedPayloadSnippet(_ data: Data, limit: Int = 512) -> String {
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return text.replacingOccurrences(
            of: #"(?i)(access_token|refresh_token|id_token|api_key|key|authorization)"\s*:\s*"[^"]*""#,
            with: #"$1":"[REDACTED]""#,
            options: .regularExpression
        )
    }

    func probe(config: CoreConfig, request: ProviderProbeRequest) async -> ProviderProbeResponse {
        switch request.providerId {
        case .sloppy:
            return await probeSloppy(config: config, request: request)
        case .openAIAPI:
            return await probeOpenAI(config: config, request: request, authMethod: .apiKey)
        case .openAIOAuth:
            return await probeOpenAI(config: config, request: request, authMethod: .deeplink)
        case .openRouter:
            return await probeOpenRouter(config: config, request: request)
        case .ollama:
            return await probeOllama(config: config, request: request)
        case .gemini:
            return await probeGemini(config: config, request: request)
        case .anthropic:
            return await probeAnthropic(config: config, request: request)
        case .claudeCode:
            do {
                guard (request.apiKey ?? "").isEmpty, (request.apiUrl ?? "").isEmpty else { throw ClaudeCodeError.invalidConfiguration }
                var environment = ProcessInfo.processInfo.environment
                for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_FOUNDRY_API_KEY",
                            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                            "SLOPPY_CLAUDE_CODE_COMMAND", "SLOPPY_CLAUDE_CODE_CONFIG_DIR"] {
                    environment[key] = environmentLookup(key)
                }
                try await ClaudeCodeTransport(environment: environment, proxy: config.proxy).status()
                return .init(providerId: .claudeCode, ok: true, usedEnvironmentKey: false,
                    message: "Claude Code is signed in. Showing CLI model aliases; no generation was requested.", models: ClaudeCodeTransport.modelCatalog)
            } catch {
                return .init(providerId: .claudeCode, ok: false, usedEnvironmentKey: false, message: error.localizedDescription, models: [])
            }
        case .anthropicOAuth:
            return ProviderProbeResponse(
                providerId: .anthropicOAuth,
                ok: true,
                usedEnvironmentKey: false,
                message: "Anthropic uses sign-in; showing built-in model catalog.",
                models: Self.anthropicModelCatalog
            )
        }
    }

    private func probeSloppy(config: CoreConfig, request: ProviderProbeRequest) async -> ProviderProbeResponse {
        do {
            let entry = config.models.first { !$0.disabled && $0.providerCatalogId == "sloppy" }
            let base = request.apiUrl ?? entry?.apiUrl ?? ""
            // An explicitly supplied URL must never inherit a different server's saved token.
            let token = (request.apiKey ?? (request.apiUrl == nil ? entry?.apiKey : nil) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var httpRequest = URLRequest(url: try SloppyRemoteEndpoint.url(base: base, path: "providers/models"))
            httpRequest.timeoutInterval = 30
            if !token.isEmpty { httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await transport(httpRequest)
            guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
            let models = try JSONDecoder().decode([ProviderModelOption].self, from: data)
                .filter { !$0.id.hasPrefix("sloppy:") }
            return ProviderProbeResponse(providerId: .sloppy, ok: true, usedEnvironmentKey: false,
                                         message: "Loaded \(models.count) models from Sloppy.", models: models)
        } catch {
            return ProviderProbeResponse(providerId: .sloppy, ok: false, usedEnvironmentKey: false,
                                         message: error.localizedDescription, models: [])
        }
    }

    private func probeOpenRouter(
        config: CoreConfig,
        request: ProviderProbeRequest
    ) async -> ProviderProbeResponse {
        let primaryConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openrouter:") == true
        }

        let apiURL = CoreModelProviderFactory.parseURL(request.apiUrl)
            ?? CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
            ?? OpenRouterLanguageModelSupport.defaultBaseURL

        let envKey = environmentLookup("OPENROUTER_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let resolvedKey: String
        let usedEnvironmentKey: Bool
        if !requestKey.isEmpty {
            resolvedKey = requestKey
            usedEnvironmentKey = false
        } else if !configuredKey.isEmpty {
            resolvedKey = configuredKey
            usedEnvironmentKey = false
        } else if !envKey.isEmpty {
            resolvedKey = envKey
            usedEnvironmentKey = true
        } else {
            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: false,
                usedEnvironmentKey: false,
                message: "OpenRouter API key is missing. Provide a key or set OPENROUTER_API_KEY.",
                models: []
            )
        }

        do {
            let models = try await fetchOpenRouterModels(apiKey: resolvedKey, baseURL: apiURL)
            guard !models.isEmpty else {
                return ProviderProbeResponse(
                    providerId: request.providerId,
                    ok: false,
                    usedEnvironmentKey: usedEnvironmentKey,
                    message: "OpenRouter responded successfully, but no models were returned.",
                    models: []
                )
            }

            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: true,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Connected to OpenRouter. Loaded \(models.count) models.",
                models: models
            )
        } catch {
            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Failed to connect to OpenRouter: \(error.localizedDescription)",
                models: []
            )
        }
    }

    private func fetchOpenRouterModels(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = OpenAICompatibleCatalogEndpoint.modelsListURL(baseURL: baseURL)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let title = environmentLookup("OPENROUTER_APP_TITLE")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        urlRequest.setValue(title.isEmpty ? "Sloppy" : title, forHTTPHeaderField: "X-OpenRouter-Title")
        let referer = environmentLookup("OPENROUTER_HTTP_REFERER")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !referer.isEmpty {
            urlRequest.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }

        let (data, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
            .map { id in
                ProviderModelOption(id: id, title: id, capabilities: ["tools"])
            }
    }

    private func probeOpenAI(
        config: CoreConfig,
        request: ProviderProbeRequest,
        authMethod: ProviderAuthMethod
    ) async -> ProviderProbeResponse {
        let primaryOpenAIConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("openai-api:") == true
        }

        let apiURL = CoreModelProviderFactory.parseURL(request.apiUrl)
            ?? CoreModelProviderFactory.parseURL(primaryOpenAIConfig?.apiUrl)
            ?? URL(string: "https://api.openai.com/v1")

        guard let apiURL else {
            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: false,
                usedEnvironmentKey: false,
                message: "OpenAI API URL is invalid.",
                models: []
            )
        }

        let allowKeylessLAN = OpenAICompatibleCatalogEndpoint.hostAllowsKeylessOpenAIProbe(host: apiURL.host)

        let configuredKey = (primaryOpenAIConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentKey = environmentLookup("OPENAI_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let resolvedKey: String
        let usedEnvironmentKey: Bool
        switch authMethod {
        case .apiKey:
            if !requestKey.isEmpty {
                resolvedKey = requestKey
                usedEnvironmentKey = false
            } else if !configuredKey.isEmpty {
                resolvedKey = configuredKey
                usedEnvironmentKey = false
            } else if !environmentKey.isEmpty {
                resolvedKey = environmentKey
                usedEnvironmentKey = true
            } else if allowKeylessLAN {
                resolvedKey = ""
                usedEnvironmentKey = false
            } else {
                return ProviderProbeResponse(
                    providerId: request.providerId,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "OpenAI API key is missing. Provide a key or set OPENAI_API_KEY.",
                    models: []
                )
            }
        case .deeplink:
            guard !environmentKey.isEmpty else {
                return ProviderProbeResponse(
                    providerId: request.providerId,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "OpenAI web login does not authorize sloppy by itself. Set OPENAI_API_KEY for sloppy and try again.",
                    models: []
                )
            }
            resolvedKey = environmentKey
            usedEnvironmentKey = true
        }

        do {
            let models = try await fetchOpenAIModels(apiKey: resolvedKey, baseURL: apiURL)
            guard !models.isEmpty else {
                return ProviderProbeResponse(
                    providerId: request.providerId,
                    ok: false,
                    usedEnvironmentKey: usedEnvironmentKey,
                    message: "OpenAI responded successfully, but no models were returned.",
                    models: []
                )
            }

            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: true,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Connected to OpenAI. Loaded \(models.count) models.",
                models: models
            )
        } catch {
            return ProviderProbeResponse(
                providerId: request.providerId,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Failed to connect to OpenAI: \(error.localizedDescription)",
                models: []
            )
        }
    }

    private func probeOllama(
        config: CoreConfig,
        request: ProviderProbeRequest
    ) async -> ProviderProbeResponse {
        let primaryOllamaConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("ollama:") == true
        }

        guard let baseURL = CoreModelProviderFactory.parseURL(request.apiUrl)
            ?? CoreModelProviderFactory.parseURL(primaryOllamaConfig?.apiUrl)
            ?? URL(string: "http://127.0.0.1:11434")
        else {
            return ProviderProbeResponse(
                providerId: .ollama,
                ok: false,
                usedEnvironmentKey: false,
                message: "Ollama API URL is invalid.",
                models: []
            )
        }

        do {
            let models = try await fetchOllamaModels(baseURL: baseURL)
            guard !models.isEmpty else {
                return ProviderProbeResponse(
                    providerId: .ollama,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "Connected to Ollama, but no local models were found.",
                    models: []
                )
            }

            return ProviderProbeResponse(
                providerId: .ollama,
                ok: true,
                usedEnvironmentKey: false,
                message: "Connected to Ollama. Loaded \(models.count) models.",
                models: models
            )
        } catch {
            return ProviderProbeResponse(
                providerId: .ollama,
                ok: false,
                usedEnvironmentKey: false,
                message: """
                Failed to connect to Ollama: \(error.localizedDescription). \
                LM Studio and many local servers use OpenAI-compatible HTTP (GET /v1/models), not Ollama’s /api/tags — add an OpenAI API provider with base URL http://…:port/v1 (API key can be empty on local networks).
                """,
                models: []
            )
        }
    }

    private func fetchOpenAIModels(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = OpenAICompatibleCatalogEndpoint.modelsListURL(baseURL: baseURL)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted()
            .map(enrichedOpenAIModelOption)
    }

    private func fetchOllamaModels(baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = ollamaTagsURL(baseURL: baseURL)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models
            .map(\.name)
            .filter { !$0.isEmpty }
            .sorted()
            .map { name in
                ProviderModelOption(
                    id: name,
                    title: humanReadableOllamaModelTitle(name: name)
                )
            }
    }

    private func ollamaTagsURL(baseURL: URL) -> URL {
        if baseURL.path.isEmpty || baseURL.path == "/" {
            return baseURL.appendingPathComponent("api").appendingPathComponent("tags")
        }

        let normalizedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        if normalizedPath.hasSuffix("/api/tags") {
            return baseURL
        }
        if normalizedPath.hasSuffix("/api") {
            return baseURL.appendingPathComponent("tags")
        }

        return baseURL.appendingPathComponent("api").appendingPathComponent("tags")
    }

    private struct GeminiModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let name: String
            let displayName: String?
        }

        let models: [ModelItem]
    }

    private struct AntigravityModelsResponse: Decodable {
        struct ModelInfo: Decodable {
            struct QuotaInfo: Decodable {
                let remainingFraction: Double?
                let resetTime: String?
                let isExhausted: Bool?
            }

            let displayName: String?
            let model: String?
            let quotaInfo: QuotaInfo?
            let isInternal: Bool?
        }

        let models: [String: ModelInfo]?
    }

    private func probeGemini(
        config: CoreConfig,
        request: ProviderProbeRequest
    ) async -> ProviderProbeResponse {
        let primaryConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("gemini:") == true
        }

        let envKey = [
            ("GEMINI_API_KEY", environmentLookup("GEMINI_API_KEY")),
            ("GOOGLE_API_KEY", environmentLookup("GOOGLE_API_KEY")),
        ]
            .compactMap { name, value -> (name: String, value: String)? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : (name, trimmed)
            }
            .first
        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let credential: GeminiAuthCredential
        let usedEnvironmentKey: Bool
        let authSource: String
        if !requestKey.isEmpty {
            credential = .apiKey(requestKey)
            usedEnvironmentKey = false
            authSource = "API key"
        } else if !configuredKey.isEmpty {
            credential = .apiKey(configuredKey)
            usedEnvironmentKey = false
            authSource = "API key"
        } else if let envKey {
            credential = .apiKey(envKey.value)
            usedEnvironmentKey = true
            authSource = envKey.name
        } else if let oauthCredentials = geminiOAuthCredentialsProvider() {
            guard oauthCredentials.isUsableForAntigravityCLI else {
                return ProviderProbeResponse(
                    providerId: .gemini,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "Antigravity CLI OAuth credentials are missing the required scope \(GeminiOAuthCredentials.requiredAntigravityScope). Current scopes: \(oauthCredentials.antigravityScopeDescription). Provide a Gemini API key or re-authenticate Antigravity CLI OAuth.",
                    models: []
                )
            }
            do {
                let refreshed = try await oauthCredentials.refreshedIfNeeded()
                guard refreshed.isUsableForAntigravityCLI else {
                    return ProviderProbeResponse(
                        providerId: .gemini,
                        ok: false,
                        usedEnvironmentKey: false,
                        message: "Antigravity CLI OAuth credentials are missing the required scope \(GeminiOAuthCredentials.requiredAntigravityScope). Current scopes: \(refreshed.antigravityScopeDescription). Provide a Gemini API key or re-authenticate Antigravity CLI OAuth.",
                        models: []
                    )
                }
                credential = .oauth(refreshed)
            } catch {
                return ProviderProbeResponse(
                    providerId: .gemini,
                    ok: false,
                    usedEnvironmentKey: false,
                    message: "Antigravity CLI OAuth credentials could not be refreshed: \(error.localizedDescription)",
                    models: []
                )
            }
            usedEnvironmentKey = false
            authSource = "Antigravity CLI OAuth"
        } else {
            return ProviderProbeResponse(
                providerId: .gemini,
                ok: false,
                usedEnvironmentKey: false,
                message: "Gemini credentials are missing. Provide a key, set GEMINI_API_KEY or GOOGLE_API_KEY, or use Antigravity CLI OAuth credentials that include \(GeminiOAuthCredentials.requiredAntigravityScope).",
                models: []
            )
        }

        let baseURL = CoreModelProviderFactory.parseURL(request.apiUrl)
            ?? CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
            ?? URL(string: "https://generativelanguage.googleapis.com")

        guard let baseURL else {
            return ProviderProbeResponse(
                providerId: .gemini,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Gemini API URL is invalid.",
                models: []
            )
        }

        do {
            let userProject = environmentLookup("GOOGLE_CLOUD_PROJECT")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? environmentLookup("GOOGLE_CLOUD_PROJECT_ID")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            let models = try await fetchGeminiModels(
                credential: credential,
                baseURL: baseURL,
                userProject: userProject
            )
            guard !models.isEmpty else {
                return ProviderProbeResponse(
                    providerId: .gemini,
                    ok: false,
                    usedEnvironmentKey: usedEnvironmentKey,
                    message: "Connected to Gemini, but no models were returned.",
                    models: []
                )
            }

            return ProviderProbeResponse(
                providerId: .gemini,
                ok: true,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Connected to Gemini with \(authSource). Loaded \(models.count) models.",
                models: models
            )
        } catch {
            if case .oauth = credential,
               let providerError = error as? ProviderProbeError,
               providerError.isAccessTokenScopeInsufficient {
                return ProviderProbeResponse(
                    providerId: .gemini,
                    ok: false,
                    usedEnvironmentKey: usedEnvironmentKey,
                    message: "Antigravity CLI OAuth token was rejected for insufficient scopes. Provide a Gemini API key or re-authenticate Antigravity CLI OAuth with \(GeminiOAuthCredentials.requiredAntigravityScope).",
                    models: []
                )
            }
            return ProviderProbeResponse(
                providerId: .gemini,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Failed to connect to Gemini: \(error.localizedDescription)",
                models: []
            )
        }
    }

    private func fetchGeminiModels(
        credential: GeminiAuthCredential,
        baseURL: URL,
        userProject: String?
    ) async throws -> [ProviderModelOption] {
        if case .oauth(let credentials) = credential {
            return try await fetchAntigravityModels(credentials: credentials, userProject: userProject)
        }

        let endpoint = baseURL
            .appendingPathComponent("v1beta")
            .appendingPathComponent("models")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if case .apiKey(let apiKey) = credential {
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .oauth(let credentials) = credential {
            urlRequest.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
            if let userProject, !userProject.isEmpty {
                urlRequest.setValue(userProject, forHTTPHeaderField: "x-goog-user-project")
            }
        }

        let (data, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderProbeError.httpFailure(statusCode: response.statusCode, body: Self.sanitizedPayloadSnippet(data))
        }

        let decoded = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        return decoded.models
            .map { item in
                let modelId = item.name.hasPrefix("models/") ? String(item.name.dropFirst(7)) : item.name
                return ProviderModelOption(
                    id: modelId,
                    title: item.displayName ?? modelId,
                    contextWindow: geminiContextWindow(for: modelId),
                    capabilities: geminiCapabilities(for: modelId)
                )
            }
            .filter { $0.id.contains("gemini") }
            .sorted { $0.id < $1.id }
    }

    private func fetchAntigravityModels(
        credentials: GeminiOAuthCredentials,
        userProject: String?
    ) async throws -> [ProviderModelOption] {
        let companionProjectID = try await GeminiCodeAssistProjectResolver.resolve(
            credentials: credentials,
            preferredProjectID: userProject,
            transport: transport
        )
        let endpoint = GeminiCodeAssistProjectResolver.defaultBaseURL
            .appendingPathComponent("v1internal:fetchAvailableModels")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        GeminiCodeAssistProjectResolver.applyHeaders(
            to: &urlRequest,
            authorizationHeaderValue: credentials.authorizationHeaderValue,
            accept: "application/json"
        )

        let project = companionProjectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload: [String: String] = project.isEmpty ? [:] : ["project": project]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderProbeError.httpFailure(statusCode: response.statusCode, body: Self.sanitizedPayloadSnippet(data))
        }

        let decoded = try JSONDecoder().decode(AntigravityModelsResponse.self, from: data)
        return (decoded.models ?? [:])
            .compactMap { key, info -> ProviderModelOption? in
                guard info.isInternal != true else { return nil }
                let modelId = (info.model ?? key).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelId.isEmpty else { return nil }
                let displayName = info.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard displayName?.isEmpty != true else { return nil }
                return ProviderModelOption(
                    id: modelId,
                    title: displayName ?? modelId,
                    contextWindow: geminiContextWindow(for: modelId),
                    capabilities: geminiCapabilities(for: modelId)
                )
            }
            .filter { $0.id.contains("gemini") }
            .sorted { $0.id < $1.id }
    }

    private func geminiContextWindow(for modelId: String) -> String? {
        let id = modelId.lowercased()
        if id.contains("2.5") || id.contains("2.0") { return "1.0M" }
        if id.contains("1.5-pro") { return "2.0M" }
        if id.contains("1.5-flash") { return "1.0M" }
        return nil
    }

    private func geminiCapabilities(for modelId: String) -> [String] {
        let id = modelId.lowercased()
        var caps: [String] = ["tools"]
        if id.contains("thinking") || id.contains("2.5") { caps.append("reasoning") }
        return caps
    }

    static let anthropicModelCatalog: [ProviderModelOption] = [
        ProviderModelOption(id: "claude-sonnet-4-6", title: "Claude Sonnet 4.6", contextWindow: "1M", capabilities: ["tools", "reasoning"]),
        ProviderModelOption(id: "claude-opus-4-7", title: "Claude Opus 4.7", contextWindow: "1M", capabilities: ["tools", "reasoning"]),
        ProviderModelOption(id: "claude-3-7-sonnet-20250219", title: "Claude 3.7 Sonnet", contextWindow: "200K", capabilities: ["tools", "reasoning"]),
        ProviderModelOption(id: "claude-3-5-sonnet-20241022", title: "Claude 3.5 Sonnet", contextWindow: "200K", capabilities: ["tools"]),
        ProviderModelOption(id: "claude-3-5-haiku-20241022", title: "Claude 3.5 Haiku", contextWindow: "200K", capabilities: ["tools"]),
        ProviderModelOption(id: "claude-3-opus-20240229", title: "Claude 3 Opus", contextWindow: "200K", capabilities: ["tools"]),
    ]

    private func probeAnthropic(
        config: CoreConfig,
        request: ProviderProbeRequest
    ) async -> ProviderProbeResponse {
        let primaryConfig = config.models.first {
            CoreModelProviderFactory.resolvedIdentifier(for: $0)?.hasPrefix("anthropic:") == true
        }

        let envKey = environmentLookup("ANTHROPIC_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let envAuthToken = environmentLookup("ANTHROPIC_AUTH_TOKEN")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let claudeSettings = claudeSettingsProvider()
        let settingsAuthToken = claudeSettings.authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuredKey = (primaryConfig?.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let resolvedKey: String
        let usedEnvironmentKey: Bool
        if !requestKey.isEmpty {
            resolvedKey = requestKey
            usedEnvironmentKey = false
        } else if !configuredKey.isEmpty {
            resolvedKey = configuredKey
            usedEnvironmentKey = false
        } else if !envKey.isEmpty {
            resolvedKey = envKey
            usedEnvironmentKey = true
        } else if !envAuthToken.isEmpty {
            resolvedKey = envAuthToken
            usedEnvironmentKey = true
        } else if !settingsAuthToken.isEmpty {
            resolvedKey = settingsAuthToken
            usedEnvironmentKey = true
        } else {
            return ProviderProbeResponse(
                providerId: .anthropic,
                ok: false,
                usedEnvironmentKey: false,
                message: "Anthropic API key is missing. Provide a key, set ANTHROPIC_API_KEY, or add ANTHROPIC_AUTH_TOKEN to .claude/settings.json.",
                models: []
            )
        }

        let baseURL = CoreModelProviderFactory.parseURL(request.apiUrl)
            ?? CoreModelProviderFactory.parseURL(primaryConfig?.apiUrl)
            ?? claudeSettings.baseURL
            ?? URL(string: "https://api.anthropic.com")

        guard let baseURL else {
            return ProviderProbeResponse(
                providerId: .anthropic,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Anthropic API URL is invalid.",
                models: []
            )
        }

        do {
            let models = try await verifyAnthropicKey(apiKey: resolvedKey, baseURL: baseURL)
            return ProviderProbeResponse(
                providerId: .anthropic,
                ok: true,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Connected to Anthropic. \(models.count) models available.",
                models: models
            )
        } catch {
            return ProviderProbeResponse(
                providerId: .anthropic,
                ok: false,
                usedEnvironmentKey: usedEnvironmentKey,
                message: "Failed to verify Anthropic API key: \(error.localizedDescription)",
                models: []
            )
        }
    }

    private func verifyAnthropicKey(apiKey: String, baseURL: URL) async throws -> [ProviderModelOption] {
        let endpoint = baseURL.appendingPathComponent("v1/models")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        let authHeaders = OAuthAnthropicAuthHeaders.authenticationHeaders(
            apiKey: apiKey,
            baseURL: baseURL,
            additionalBetas: nil
        )
        for (field, value) in authHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let (_, response) = try await transport(urlRequest)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 429 else {
            throw URLError(.userAuthenticationRequired)
        }

        return Self.anthropicModelCatalog
    }

    private func enrichedOpenAIModelOption(id: String) -> ProviderModelOption {
        let lowered = id.lowercased()
        var contextWindow: String?
        var capabilities: [String] = []

        if lowered.hasPrefix("gpt-5.4") {
            contextWindow = "1.0M"
            capabilities.append("tools")
        } else if lowered.hasPrefix("gpt-4o") {
            contextWindow = "128K"
            capabilities.append("tools")
        } else if lowered.hasPrefix("o4") || lowered.hasPrefix("o3") {
            contextWindow = "200K"
            capabilities.append(contentsOf: ["reasoning", "tools"])
        } else if lowered.hasPrefix("o1") {
            contextWindow = "128K"
            capabilities.append(contentsOf: ["reasoning", "tools"])
        }

        return ProviderModelOption(
            id: id,
            title: humanReadableOpenAIModelTitle(id: id),
            contextWindow: contextWindow,
            capabilities: capabilities
        )
    }

    private func humanReadableOpenAIModelTitle(id: String) -> String {
        let lower = id.lowercased()
        if lower.hasPrefix("gpt-5.4") {
            let suffix = lower.replacingOccurrences(of: "gpt-5.4", with: "")
            return "gpt-5.4" + titleSuffix(from: suffix)
        }
        if lower.hasPrefix("gpt-4o") {
            let suffix = lower.replacingOccurrences(of: "gpt-4o", with: "")
            return "GPT-4o" + titleSuffix(from: suffix)
        }
        return id
    }

    private func humanReadableOllamaModelTitle(name: String) -> String {
        name.replacingOccurrences(of: ":latest", with: "")
    }

    private func titleSuffix(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        guard !trimmed.isEmpty else {
            return ""
        }

        let parts = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.capitalized }
        guard !parts.isEmpty else {
            return ""
        }
        return " " + parts.joined(separator: " ")
    }
}
