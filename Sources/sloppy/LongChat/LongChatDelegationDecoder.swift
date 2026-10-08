import Foundation
import Protocols

enum LongChatDelegationDecoder {
    struct ValidationError: Error {
        let message: String
        let hint: String
    }

    static func decode(_ value: JSONValue?) throws -> LongChatDelegationRequest {
        let data: Data
        switch value {
        case .object:
            data = try JSONEncoder().encode(value)
        case .string(let raw):
            // Keep older clients and restored tool calls compatible.
            data = Data(raw.utf8)
        default:
            throw ValidationError(
                message: "assignment must be an object.",
                hint: "Call long_chat.delegate with assignment: {requestKey: string, title: string, acceptanceCriteria: string, tasks: array}. Correct the arguments; no worker was started.")
        }
        return try JSONDecoder().decode(LongChatDelegationRequest.self, from: data)
    }
}
