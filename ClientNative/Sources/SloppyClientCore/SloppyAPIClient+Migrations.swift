import Foundation
@_exported import SloppyMigration

extension SloppyAPIClient {
    public func fetchMigrations() async throws -> [MigrationJob] { try await http.get("/v1/migrations") }
    public func fetchMigration(_ id: String) async throws -> MigrationJob { try await http.get("/v1/migrations/" + id) }
    public func previewMigration(_ selection: MigrationSelection) async throws -> MigrationPreview { try await http.post("/v1/migrations/preview", body: selection) }
    public func createMigration(_ request: MigrationCreateRequest) async throws -> MigrationJob { try await http.post("/v1/migrations", body: request) }
    public func uploadMigration(_ id: String, chunk: MigrationUploadChunk) async throws -> MigrationJob { try await http.post("/v1/migrations/\(id)/chunks", body: chunk) }
    public func controlMigration(_ id: String, action: String) async throws -> MigrationJob {
        guard ["start", "resume", "cancel"].contains(action) else { throw MigrationError.invalid("Invalid migration action.") }
        return try await http.post("/v1/migrations/\(id)/\(action)", body: [String: String]())
    }
    public func enableMigrationMCP(_ id: String, ids: [String]) async throws -> [MigrationMCPStatus] { try await http.post("/v1/migrations/\(id)/enable-mcp", body: ["ids": ids]) }
}
public struct MigrationMCPStatus: Codable, Sendable {
    public var id: String
    public var connected: Bool?
    public var error: String?
}
