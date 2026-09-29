import Foundation
import SloppyMigration

struct MigrationsAPIRouter: APIRouter {
    let service: CoreService
    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/migrations/sources", metadata: .init(summary: "Discover migration sources", description: "Checks known agent directories on the Core machine without scanning their contents.", tags: ["Migrations"])) { _ in
            CoreRouter.encodable(status: HTTPStatus.ok, payload: await service.discoverMigrationSources())
        }
        router.post("/v1/migrations/scan", metadata: .init(summary: "Analyze selected migration sources", description: "Reads selected sources on the Core machine without changing them.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationScanRequest.self) { try await service.scanMigrationSources($0) }
        }
        router.post("/v1/migrations/preview", metadata: .init(summary: "Preview migration", description: "Validates selection and reports duplicate objects, conflicts and limitations.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationSelection.self) { try await service.previewMigration($0) }
        }
        router.post("/v1/migrations/import", metadata: .init(summary: "Import selected Core source data", description: "Starts a durable background migration of reviewed data.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationSelection.self) { try await service.importMigration($0) }
        }
        router.post("/v1/migrations", metadata: .init(summary: "Create migration upload", description: "Pins destination and manifest checksum for resumable local-client uploads.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationCreateRequest.self) { try await service.createMigration($0) }
        }
        router.get("/v1/migrations", metadata: .init(summary: "List migrations", description: "Returns durable progress and migration history.", tags: ["Migrations"])) { _ in
            await respond { try await service.migrationJobs() }
        }
        router.get("/v1/migrations/:jobId", metadata: .init(summary: "Migration progress", description: "Returns acknowledged transfer offset and confirmed item outcomes.", tags: ["Migrations"])) { request in
            await respond { try await service.migrationJob(request.pathParam("jobId") ?? "") }
        }
        router.post("/v1/migrations/:jobId/chunks", metadata: .init(summary: "Upload migration chunk", description: "Accepts integrity-checked retryable chunks up to 1 MB.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationUploadChunk.self) { try await service.uploadMigration(request.pathParam("jobId") ?? "", chunk: $0) }
        }
        for action in ["start", "resume", "cancel"] {
            router.post("/v1/migrations/:jobId/" + action, metadata: .init(summary: action.capitalized + " migration", description: "Controls the durable job without deleting already imported data.", tags: ["Migrations"])) { request in
                await respond {
                    let id = request.pathParam("jobId") ?? ""
                    if action == "cancel" { return try await service.cancelMigration(id) }
                    if action == "resume" { return try await service.resumeMigration(id) }
                    return try await service.startMigration(id)
                }
            }
        }
        router.post("/v1/migrations/:jobId/enable-mcp", metadata: .init(summary: "Check and enable imported MCP servers", description: "Explicitly enables only selected imported servers on this Core and returns their connection status.", tags: ["Migrations"])) { request in
            await decode(request, as: MigrationMCPEnableRequest.self) { try await service.enableMigrationMCP(request.pathParam("jobId") ?? "", ids: $0.ids) }
        }
    }
    private func decode<T: Decodable, R: Encodable & Sendable>(_ request: HTTPRequest, as type: T.Type, action: (T) async throws -> R) async -> CoreRouterResponse {
        guard let body = request.body, let payload = CoreRouter.decode(body, as: type) else { return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": ErrorCode.invalidBody]) }
        return await respond { try await action(payload) }
    }
    private func respond<T: Encodable & Sendable>(_ action: () async throws -> T) async -> CoreRouterResponse {
        do { return CoreRouter.encodable(status: HTTPStatus.ok, payload: try await action()) }
        catch MigrationError.missing { return CoreRouter.json(status: HTTPStatus.notFound, payload: ["error": "migration_not_found"]) }
        catch let error as MigrationError { return CoreRouter.json(status: HTTPStatus.badRequest, payload: ["error": "invalid_migration", "message": error.localizedDescription]) }
        catch { return CoreRouter.json(status: HTTPStatus.internalServerError, payload: ["error": "migration_failed", "message": error.localizedDescription]) }
    }
}

struct MigrationMCPEnableRequest: Codable, Sendable { var ids: [String] }
