import AnyLanguageModel
import Foundation
import Protocols
import SloppyRuntime

struct ImagesInspectTool: CoreTool {
    let name = "images.inspect"
    let domain = "images"
    let title = "Inspect image"
    let status = "fully_functional"
    let description = "Inspect a local PNG/JPEG/WebP image with the active model and answer a question about its visible content. Use this for image paths; files.read only reads text."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "path", description: "Readable image path.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "question", description: "What to inspect, transcribe or explain.", schema: DynamicGenerationSchema(type: String.self)),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let path = arguments["path"]?.asString, !path.isEmpty,
              let question = arguments["question"]?.asString, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "path and question are required.", retryable: false,
                hint: "Supply a local image path and the question to answer.", argumentRecovery: .init(invalidFields: ["path", "question"]))
        }
        guard let url = context.resolveReadablePath(path) else {
            return toolFailure(tool: name, code: "path_not_allowed", message: "Image path is outside allowed roots.", retryable: false)
        }
        guard let mimeType = SessionImageLoader.mimeType(for: url) else {
            return toolFailure(tool: name, code: "unsupported_image", message: "Use a PNG, JPEG or WebP image.", retryable: false,
                hint: "Use files.read for text files.", argumentRecovery: .init(invalidFields: ["path"]))
        }
        do {
            let image = try SessionImageLoader.load(url: url, mimeType: mimeType)
            guard let answer = await context.runtime.generateText(
                prompt: question, model: nil, maxTokens: 2048,
                channelId: context.channelID ?? sessionChannelID(agentID: context.agentID, sessionID: context.sessionID),
                images: [image]) else {
                return toolFailure(tool: name, code: "image_inspection_failed", message: "The model could not inspect the image.", retryable: false,
                    hint: "A vision-capable model is required. Report that visual content is unavailable; do not invent it.")
            }
            return toolSuccess(tool: name, data: .object(["path": .string(url.path), "answer": .string(answer)]))
        } catch {
            return toolFailure(tool: name, code: "image_unavailable", message: String(describing: error), retryable: false,
                hint: "Check the image path and format, then correct path before calling again.", argumentRecovery: .init(invalidFields: ["path"]))
        }
    }
}
