import Foundation

struct DesktopComputerBinding: Codable, Sendable, Equatable {
    var connectionId: String
    var deviceId: String
    var agentId: String
    var sessionId: String
}

struct DesktopComputerCommand: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var text: String?
        var key: String?
        var modifiers: [String]?
    }
    var id: String
    var name: String
    var input: Input
    var expiresAt: Date
}

struct DesktopComputerCommands: Decodable, Sendable { var commands: [DesktopComputerCommand] }

struct DesktopComputerCompletion: Encodable, Sendable {
    struct Result: Encodable, Sendable {
        var width: Int?
        var height: Int?
        var displayId: String?
        var screenX: Double?
        var screenY: Double?
        var screenWidth: Double?
        var screenHeight: Double?
        var scaleX: Double?
        var scaleY: Double?
        var ok: Bool = true
    }
    var binding: DesktopComputerBinding
    var commandId: String
    var data: Result?
    var imageBase64: String?
    var error: String?
}
