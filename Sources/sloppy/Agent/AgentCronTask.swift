import Foundation

public struct AgentCronTask: Codable, Sendable {
    public var id: String
    public var agentId: String
    public var channelId: String
    public var schedule: String
    public var command: String
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        agentId: String,
        channelId: String,
        schedule: String,
        command: String,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.channelId = channelId
        self.schedule = schedule
        self.command = command
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentCronTaskCreateRequest: Codable, Sendable {
    public var channelId: String
    public var schedule: String
    public var command: String
    public var enabled: Bool?
    
    public init(channelId: String = "main", schedule: String, command: String, enabled: Bool? = nil) {
        self.channelId = channelId
        self.schedule = schedule
        self.command = command
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case channelId, schedule, command, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId) ?? "main"
        schedule = try container.decode(String.self, forKey: .schedule)
        command = try container.decode(String.self, forKey: .command)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}

public struct AgentCronTaskUpdateRequest: Codable, Sendable {
    public var channelId: String?
    public var schedule: String?
    public var command: String?
    public var enabled: Bool?
    
    public init(channelId: String? = nil, schedule: String? = nil, command: String? = nil, enabled: Bool? = nil) {
        self.channelId = channelId
        self.schedule = schedule
        self.command = command
        self.enabled = enabled
    }
}
