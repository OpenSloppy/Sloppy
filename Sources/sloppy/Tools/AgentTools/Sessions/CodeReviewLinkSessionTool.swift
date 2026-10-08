import AnyLanguageModel
import Foundation
import Protocols

struct CodeReviewLinkSessionTool: CoreTool {
    let domain = "session"
    let title = "Link pull request to chat"
    let status = "fully_functional"
    let name = "code_review.link_session"
    let description = "After creating or discovering a pull request for your task, call this tool with its provider ID and provider-scoped review ID to link your current working chat to the PR. Its task chats and child sessions will also be discoverable from the PR. Do not infer identity from titles."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "providerId", description: "Code-review provider ID, e.g. github or arcadia-code-review", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "reviewId", description: "Exact provider-scoped PR ID, e.g. github:owner/repo#42", schema: DynamicGenerationSchema(type: String.self)),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let providerID = arguments["providerId"]?.asString, !providerID.isEmpty,
              let reviewID = arguments["reviewId"]?.asString, !reviewID.isEmpty,
              let service = context.sessionService else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "providerId, reviewId and an active session service are required.", retryable: false)
        }
        do {
            let summary = try await service.linkCurrentSessionToCodeReview(
                providerID: providerID, reviewID: reviewID, agentID: context.agentID, sessionID: context.sessionID
            )
            return toolSuccess(tool: name, data: encodeJSONValue(summary))
        } catch {
            return toolFailure(tool: name, code: "code_review_link_failed", message: error.localizedDescription, retryable: true)
        }
    }
}
