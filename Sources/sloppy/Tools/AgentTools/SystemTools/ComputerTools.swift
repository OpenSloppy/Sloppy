import AnyLanguageModel
import Foundation
import Protocols
import SloppyComputerControl

struct ComputerClickTool: CoreTool {
    let domain = "computer"
    let title = "Click screen"
    let status = "preview"
    let name = "computer.click"
    let description = "Click an absolute screen point, or the center of a provided rectangle, using the local SloppyNode executor."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "x", description: "Absolute screen x coordinate in physical pixels.", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "y", description: "Absolute screen y coordinate in physical pixels.", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "width", description: "Optional rectangle width. When set, clicks the rectangle center.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "height", description: "Optional rectangle height. When set, clicks the rectangle center.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        guard let x = arguments["x"]?.asNumber, let y = arguments["y"]?.asNumber else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`x` and `y` are required.", retryable: false)
        }
        let payload = ComputerClickPayload(
            x: x,
            y: y,
            width: arguments["width"]?.asNumber,
            height: arguments["height"]?.asNumber
        )
        return await invokeSloppyNode(action: .computerClick, payload: payload, tool: name, context: context)
    }
}

struct ComputerTypeTool: CoreTool {
    let domain = "computer"
    let title = "Type text"
    let status = "preview"
    let name = "computer.type"
    let description = "Type text into the active app using the local SloppyNode executor."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "text", description: "Text to type into the active focused control.", schema: DynamicGenerationSchema(type: String.self))
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let text = arguments["text"]?.asString ?? ""
        guard !text.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`text` is required.", retryable: false)
        }
        return await invokeSloppyNode(action: .computerTypeText, payload: ComputerTypeTextPayload(text: text), tool: name, context: context)
    }
}

struct ComputerKeyTool: CoreTool {
    let domain = "computer"
    let title = "Press key"
    let status = "preview"
    let name = "computer.key"
    let description = "Press one key, optionally with modifiers, using the local SloppyNode executor."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "key", description: "Key name, such as enter, escape, tab, left, right, up, down, or a single printable key.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "modifiers", description: "Optional modifiers: command/cmd/meta, control/ctrl, option/alt, shift.", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let key = arguments["key"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`key` is required.", retryable: false)
        }
        let modifiers = arguments["modifiers"]?.asArray?.compactMap(\.asString) ?? []
        return await invokeSloppyNode(action: .computerKey, payload: ComputerKeyPayload(key: key, modifiers: modifiers), tool: name, context: context)
    }
}

struct ComputerScreenshotTool: CoreTool {
    let domain = "computer"
    let title = "Take screenshot"
    let status = "preview"
    let name = "computer.screenshot"
    let description = "Capture the primary display with the local SloppyNode executor, return the image file path, and return `verificationEvidence.id` for `session.complete`."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "outputPath", description: "Optional output file path. Defaults to a temporary file.", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let payload = ComputerScreenshotPayload(outputPath: arguments["outputPath"]?.asString)
        return await invokeSloppyNode(action: .computerScreenshot, payload: payload, tool: name, context: context)
    }
}

private func invokeSloppyNode<T: Encodable>(
    action: NodeAction,
    payload: T,
    tool: String,
    context: ToolContext
) async -> ToolInvocationResult {
    if await context.desktopComputerBridge.isAssigned(agentID: context.agentID, sessionID: context.sessionID) {
        do {
            var data = try await context.desktopComputerBridge.run(
                agentID: context.agentID, sessionID: context.sessionID, name: tool, input: try JSONValueCoder.encode(payload)
            )
            if action == .computerScreenshot, var object = data.asObject,
               let base64 = object.removeValue(forKey: "imageBase64")?.asString,
               let image = Data(base64Encoded: base64) {
                let directory = context.workspaceRootURL.appendingPathComponent("desktop-captures")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(UUID().uuidString + ".png")
                try image.write(to: file, options: .atomic)
                object["path"] = .string(file.path)
                object["mediaType"] = .string("image/png")
                data = .object(object)
            }
            return toolSuccess(tool: tool, data: data)
        } catch {
            return toolFailure(tool: tool, code: "desktop_companion_unavailable", message: error.localizedDescription, retryable: false)
        }
    }
    if ProcessInfo.processInfo.environment["SLOPPY_NODE_PATH"] != nil {
        return await invokeExternalSloppyNode(action: action, payload: payload, tool: tool, context: context)
    }

    return await invokeLocalComputerController(action: action, payload: payload, tool: tool, context: context)
}

private func invokeLocalComputerController<T: Encodable>(
    action: NodeAction,
    payload: T,
    tool: String,
    context: ToolContext
) async -> ToolInvocationResult {
    let controller = PlatformComputerController()
    do {
        switch action {
        case .computerClick:
            let data = try await controller.click(try reencode(payload, as: ComputerClickPayload.self))
            return toolSuccess(tool: tool, data: JSONValue(computerControlValue: data))
        case .computerTypeText:
            let data = try await controller.typeText(try reencode(payload, as: ComputerTypeTextPayload.self))
            return toolSuccess(tool: tool, data: JSONValue(computerControlValue: data))
        case .computerKey:
            let data = try await controller.key(try reencode(payload, as: ComputerKeyPayload.self))
            return toolSuccess(tool: tool, data: JSONValue(computerControlValue: data))
        case .computerScreenshot:
            let result = try await controller.screenshot(try reencode(payload, as: ComputerScreenshotPayload.self))
            return toolSuccess(tool: tool, data: try JSONValueCoder.encode(result))
        default:
            return toolFailure(tool: tool, code: "invalid_arguments", message: "Unsupported local computer action \(action.rawValue).", retryable: false)
        }
    } catch let error as ComputerControlError {
        return toolFailure(tool: tool, code: error.code, message: error.localizedDescription, retryable: false)
    } catch {
        context.logger.error("Local computer control failed", metadata: ["tool": .string(tool), "error": .string(String(describing: error))])
        return toolFailure(tool: tool, code: "computer_control_failed", message: error.localizedDescription, retryable: true)
    }
}

private func invokeExternalSloppyNode<T: Encodable>(
    action: NodeAction,
    payload: T,
    tool: String,
    context: ToolContext
) async -> ToolInvocationResult {
    do {
        let request = NodeActionRequest(action: action, payload: try JSONValueCoder.encode(payload))
        let input = try JSONEncoder().encode(request)
        let nodeCommand = ProcessInfo.processInfo.environment["SLOPPY_NODE_PATH"] ?? "sloppy-node"
        return try await invokeNodeProcess(
            nodeCommand: nodeCommand,
            input: input,
            action: action,
            tool: tool,
            context: context
        )
    } catch {
        context.logger.error("SloppyNode invocation failed", metadata: ["tool": .string(tool), "error": .string(String(describing: error))])
        return toolFailure(tool: tool, code: "node_unavailable", message: "Failed to invoke SloppyNode: \(error.localizedDescription)", retryable: true)
    }
}

private func invokeNodeProcess(
    nodeCommand: String,
    input: Data,
    action: NodeAction,
    tool: String,
    context: ToolContext
) async throws -> ToolInvocationResult {
    let processData = try await runForegroundProcess(
        command: nodeCommand,
        arguments: ["invoke", "--stdin"],
        cwd: context.currentDirectoryURL,
        timeoutMs: context.policy.guardrails.execTimeoutMs,
        maxOutputBytes: context.policy.guardrails.maxExecOutputBytes,
        standardInput: input
    )
    guard let stdout = processData.asObject?["stdout"]?.asString else {
        return toolFailure(tool: tool, code: "node_failed", message: "SloppyNode returned no stdout.", retryable: true)
    }
    guard let responseData = stdout.data(using: .utf8) else {
        return toolFailure(tool: tool, code: "node_failed", message: "SloppyNode returned invalid UTF-8.", retryable: true)
    }
    let response = try JSONDecoder().decode(NodeActionResponse.self, from: responseData)
    if response.ok {
        return toolSuccess(tool: tool, data: response.data ?? .object([:]))
    }
    let error = response.error ?? NodeActionError(code: "node_failed", message: "SloppyNode action failed.")
    return toolFailure(tool: tool, code: error.code, message: error.message, retryable: error.retryable)
}

private func reencode<T: Encodable, U: Decodable>(_ value: T, as _: U.Type) throws -> U {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(U.self, from: data)
}

private extension JSONValue {
    init(computerControlValue value: ComputerControlValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .number(let value):
            self = .number(value)
        case .string(let value):
            self = .string(value)
        case .array(let value):
            self = .array(value.map(JSONValue.init(computerControlValue:)))
        case .object(let value):
            self = .object(value.mapValues(JSONValue.init(computerControlValue:)))
        }
    }
}
