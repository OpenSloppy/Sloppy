import Foundation
import Protocols

protocol MCPToolDiscovering: Sendable {
    func dynamicTools() async -> [MCPDynamicTool]
    func dynamicToolIDs() async -> Set<String>
}

enum ToolCatalog {
    /// Tool catalog entries auto-generated from the ToolRegistry.
    static let builtInEntries: [AgentToolCatalogEntry] = ToolRegistry.makeDefault().catalogEntries

    static func entries(mcpRegistry: (any MCPToolDiscovering)?) async -> [AgentToolCatalogEntry] {
        guard let mcpRegistry else {
            return builtInEntries
        }
        let dynamicEntries = await mcpRegistry.dynamicTools().map { tool in
            AgentToolCatalogEntry(
                id: tool.id,
                domain: "mcp",
                title: tool.title,
                status: "fully_functional",
                description: tool.description
            )
        }
        return (builtInEntries + dynamicEntries).sorted { $0.id < $1.id }
    }

    static func knownToolIDs(mcpRegistry: (any MCPToolDiscovering)?) async -> Set<String> {
        guard let mcpRegistry else {
            return knownToolIDs
        }
        return knownToolIDs.union(await mcpRegistry.dynamicToolIDs())
    }

    static func listToolsPayload(mcpRegistry: (any MCPToolDiscovering)?) async -> [JSONValue] {
        let catalogEntries = await entries(mcpRegistry: mcpRegistry)
        let dynamicTools = Dictionary(uniqueKeysWithValues: await (mcpRegistry?.dynamicTools() ?? []).map { ($0.id, $0) })

        return catalogEntries.map { entry in
            let parameters = dynamicTools[entry.id]?.inputSchema ?? parameterSchema(for: entry.id)
            return .object([
                "name": .string(entry.id),
                "title": .string(entry.title),
                "domain": .string(entry.domain),
                "status": .string(entry.status),
                "description": .string(entry.description),
                "parameters": parameters
            ])
        }
    }

    static let knownToolIDs: Set<String> = ToolRegistry.makeDefault().knownToolIDs

    private static func parameterSchema(for toolID: String) -> JSONValue {
        if toolID == "long_chat.delegate", let data = try? JSONEncoder().encode(LongChatTool(action: "delegate").parameters),
           let schema = try? JSONDecoder().decode(JSONValue.self, from: data) { return schema }
        return parameterSchemas[toolID] ?? .object(["type": .string("object")])
    }

    static let parameterSchemas: [String: JSONValue] = [
        "system.list_tools": .object(["type": .string("object")]),
        "session.launch.configure": .object([
            "type": .string("object"),
            "properties": .object(["configuration": .object([
                "type": .string("string"),
                "description": .string("JSON LaunchConfigurationRequest with the exact checkout, target, build commands and web/app/simulator output.")
            ])]),
            "required": .array([.string("configuration")])
        ]),
        "session.complete": .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("completed"), .string("blocked"), .string("waiting_input")])
                ]),
                "summary": .object(["type": .string("string")]),
                "verification": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "verificationEvidenceIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "limitations": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("status"), .string("summary")])
        ]),
        "files.list": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "depth": .object(["type": .string("number")])
            ]),
            "required": .array([.string("path")])
        ]),
        "files.read": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "maxBytes": .object(["type": .string("number")]),
                "offset": .object(["type": .string("number")])
            ]),
            "required": .array([.string("path")])
        ]),
        "debug.read_logs": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "sessionId": .object(["type": .string("string")]),
                "maxBytes": .object(["type": .string("number")])
            ]),
            "required": .array([.string("path")])
        ]),
        "files.write": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "expectedContentHash": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "allowEmpty": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("path"), .string("content")])
        ]),
        "images.inspect": .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")]), "question": .object(["type": .string("string")])]),
            "required": .array([.string("path"), .string("question")])
        ]),
        "images.generate": .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("Detailed prompt describing the desired image or edit.")
                ]),
                "aspectRatio": .object([
                    "type": .string("string"),
                    "enum": .array([.string("landscape"), .string("square"), .string("portrait")])
                ]),
                "sourceImage": .object(["type": .string("string")]),
                "referenceImages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "maxItems": .number(16)
                ]),
                "seed": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("prompt")])
        ]),
        "artifacts.widget.generate": .object([
            "type": .string("object"),
            "properties": .object([
                "html": .object(["type": .string("string")]),
                "size": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "artifactId": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")])
            ]),
            "required": .array([.string("html"), .string("size"), .string("prompt")])
        ]),
        "artifacts.web.create": .object([
            "type": .string("object"),
            "properties": .object([
                "html": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")])
            ]),
            "required": .array([.string("html"), .string("title"), .string("summary")])
        ]),
        "files.edit": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "expectedContentHash": .object(["type": .string("string")]),
                "search": .object(["type": .string("string")]),
                "replace": .object(["type": .string("string")]),
                "all": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("path"), .string("search"), .string("replace")])
        ]),
        "runtime.exec": .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "arguments": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "cwd": .object(["type": .string("string")]),
                "timeoutMs": .object(["type": .string("number")])
            ]),
            "required": .array([.string("command")])
        ]),
        "runtime.process": .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
                "arguments": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "cwd": .object(["type": .string("string")]),
                "processId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action")])
        ]),
        "agent_delegate.finish": .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("completed"), .string("failed"), .string("blocked")]),
                ]),
                "summary": .object(["type": .string("string")]),
                "error": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("status"), .string("summary")])
        ]),
        "computer.click": .object([
            "type": .string("object"),
            "properties": .object([
                "x": .object(["type": .string("number")]),
                "y": .object(["type": .string("number")]),
                "width": .object(["type": .string("number")]),
                "height": .object(["type": .string("number")])
            ]),
            "required": .array([.string("x"), .string("y")])
        ]),
        "computer.type": .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string")])
            ]),
            "required": .array([.string("text")])
        ]),
        "computer.key": .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object(["type": .string("string")]),
                "modifiers": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("key")])
        ]),
        "computer.screenshot": .object([
            "type": .string("object"),
            "properties": .object([
                "outputPath": .object(["type": .string("string")])
            ])
        ]),
        "browser.open": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")])
            ])
        ]),
        "browser.navigate": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")]),
                "pageId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("url")])
        ]),
        "browser.click": .object([
            "type": .string("object"),
            "properties": .object([
                "selector": .object(["type": .string("string")]),
                "pageId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("selector")])
        ]),
        "browser.type": .object([
            "type": .string("object"),
            "properties": .object([
                "selector": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
                "pageId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("selector"), .string("text")])
        ]),
        "browser.screenshot": .object([
            "type": .string("object"),
            "properties": .object([
                "outputPath": .object(["type": .string("string")]),
                "pageId": .object(["type": .string("string")])
            ])
        ]),
        "browser.read": .object([
            "type": .string("object"),
            "properties": .object(["pageId": .object(["type": .string("string")])])
        ]),
        "browser.scroll": .object([
            "type": .string("object"),
            "properties": .object([
                "pageId": .object(["type": .string("string")]),
                "selector": .object(["type": .string("string")]),
                "x": .object(["type": .string("number")]),
                "y": .object(["type": .string("number")])
            ])
        ]),
        "browser.status": .object([
            "type": .string("object"),
            "properties": .object([:])
        ]),
        "browser.close": .object([
            "type": .string("object"),
            "properties": .object([
                "pageId": .object(["type": .string("string")])
            ])
        ]),
        "branches.spawn": .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")])
            ]),
            "required": .array([.string("prompt")])
        ]),
        "workers.spawn": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "objective": .object(["type": .string("string")]),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("fire_and_forget"), .string("interactive")])
                ]),
                "taskId": .object(["type": .string("string")]),
                "tools": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("objective")])
        ]),
        "agents.delegate_task": .object([
            "type": .string("object"),
            "properties": .object([
                "goal": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Single subagent task. Do not set `tasks` to a non-empty array in the same call."
                    ),
                ]),
                "context": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Optional shared preamble (paths, constraints, language). Not a substitute for `goal` / `tasks`."
                    ),
                ]),
                "toolsets": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional: terminal, file, web, skills, lsp, mcp, project, visor, system."
                    ),
                ]),
                "tasks": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "1–3 parallel goals (strings). Omit `goal` when using this. Mutually exclusive with `goal`."
                    ),
                ]),
            ]),
        ]),
        "workers.route": .object([
            "type": .string("object"),
            "properties": .object([
                "workerId": .object(["type": .string("string")]),
                "command": .object([
                    "type": .string("string"),
                    "enum": .array([.string("continue"), .string("complete"), .string("fail")])
                ]),
                "summary": .object(["type": .string("string")]),
                "error": .object(["type": .string("string")]),
                "report": .object(["type": .string("string")])
            ]),
            "required": .array([.string("workerId"), .string("command")])
        ]),
        "sessions.spawn": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "parentSessionId": .object(["type": .string("string")])
            ])
        ]),
        "sessions.list": .object([
            "type": .string("object"),
            "properties": .object([
                "scope": .object(["type": .string("string"), "enum": .array([.string("current"), .string("all")])]),
                "agentId": .object(["type": .string("string")]),
                "projectId": .object(["type": .string("string")]),
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
                "offset": .object(["type": .string("integer")]),
            ])
        ]),
        "sessions.history": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "agentId": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
                "beforeEventId": .object(["type": .string("string")])
            ])
        ]),
        "code_review.link_session": .object([
            "type": .string("object"),
            "properties": .object([
                "providerId": .object(["type": .string("string")]),
                "reviewId": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("providerId"), .string("reviewId")]),
        ]),
        "sessions.status": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "agentId": .object(["type": .string("string")])
            ])
        ]),
        "sessions.send": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "agentId": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "messageId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "messages.send": .object([
            "type": .string("object"),
            "properties": .object([
                "sessionId": .object(["type": .string("string")]),
                "agentId": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
                "messageId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "agents.list": .object(["type": .string("object")]),
        "channel.history": .object([
            "type": .string("object"),
            "properties": .object([
                "channel_id": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("channel_id")])
        ]),
        "memory.get": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
                "scope_type": .object(["type": .string("string")]),
                "scope_id": .object(["type": .string("string")]),
                "scope": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "id": .object(["type": .string("string")]),
                        "channel_id": .object(["type": .string("string")]),
                        "project_id": .object(["type": .string("string")]),
                        "agent_id": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("type"), .string("id")])
                ])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.recall": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")]),
                "scope_type": .object(["type": .string("string")]),
                "scope_id": .object(["type": .string("string")]),
                "scope": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "id": .object(["type": .string("string")]),
                        "channel_id": .object(["type": .string("string")]),
                        "project_id": .object(["type": .string("string")]),
                        "agent_id": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("type"), .string("id")])
                ])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.search": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "memory.save": .object([
            "type": .string("object"),
            "properties": .object([
                "note": .object(["type": .string("string")]),
                "scope_type": .object(["type": .string("string")]),
                "scope_id": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")]),
                "class": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")])
            ]),
            "required": .array([.string("note"), .string("scope_type"), .string("scope_id")])
        ]),
        "mcp.list_servers": .object(["type": .string("object")]),
        "mcp.list_tools": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "cursor": .object(["type": .string("string")])
            ]),
            "required": .array([.string("server")])
        ]),
        "mcp.call_tool": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "tool": .object(["type": .string("string")]),
                "arguments": .object(["type": .string("object")])
            ]),
            "required": .array([.string("server"), .string("tool")])
        ]),
        "mcp.list_resources": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "cursor": .object(["type": .string("string")])
            ]),
            "required": .array([.string("server")])
        ]),
        "mcp.read_resource": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "uri": .object(["type": .string("string")])
            ]),
            "required": .array([.string("server"), .string("uri")])
        ]),
        "mcp.list_prompts": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "cursor": .object(["type": .string("string")])
            ]),
            "required": .array([.string("server")])
        ]),
        "mcp.get_prompt": .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "arguments": .object(["type": .string("object")])
            ]),
            "required": .array([.string("server"), .string("name")])
        ]),
        "web.search": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "count": .object(["type": .string("number")])
            ]),
            "required": .array([.string("query")])
        ]),
        "web.fetch": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")])
            ]),
            "required": .array([.string("url")])
        ]),
        "web.request": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")]),
                "method": .object(["type": .string("string")]),
                "headers": .object(["type": .string("object")]),
                "body": .object(["type": .string("string")])
            ]),
            "required": .array([.string("url")])
        ]),
        "cron": .object([
            "type": .string("object"),
            "properties": .object([
                "schedule": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
                "channel_id": .object(["type": .string("string")])
            ]),
            "required": .array([.string("schedule"), .string("command")])
        ]),
        "tools.sleep": .object([
            "type": .string("object"),
            "properties": .object([
                "seconds": .object(["type": .string("number")])
            ]),
            "required": .array([.string("seconds")])
        ]),
        "project.list": .object(["type": .string("object")]),
        "project.current": .object([
            "type": .string("object"),
            "properties": .object([
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ])
        ]),
        "project.create": .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "idea": .object(["type": .string("string")]),
                "actors": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "teams": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "repoUrl": .object(["type": .string("string")]),
                "repoPath": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"), "enum": .array([.string("project"), .string("workspace")])]),
                "directoryPaths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("name")])
        ]),
        "project.update": .object([
            "type": .string("object"),
            "properties": .object([
                "projectId": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "icon": .object(["type": .string("string")]),
                "actors": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "teams": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "repoPath": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"), "enum": .array([.string("project"), .string("workspace")])]),
                "directoryPaths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("projectId")])
        ]),
        "project.delete": .object([
            "type": .string("object"),
            "properties": .object([
                "projectId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("projectId")])
        ]),
        "project.task_list": .object([
            "type": .string("object"),
            "properties": .object([
                "projectId": .object(["type": .string("string")]),
                "status": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ])
        ]),
        "project.task_create": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string")]),
                "status": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")]),
                "parentTaskId": .object(["type": .string("string")]),
                "dependsOnTaskIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "loopModeOverride": .object(["type": .string("string")]),
                "actorId": .object(["type": .string("string")]),
                "teamId": .object(["type": .string("string")]),
                "selectedModel": .object(["type": .string("string")]),
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "changedBy": .object(["type": .string("string")]),
                "projectId": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("title")])
        ]),
        "project.task_get": .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
                "reference": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")])
            ])
        ]),
        "project.task_update": .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
                "reference": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "description": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string")]),
                "status": .object(["type": .string("string")]),
                "completionConfidence": .object(["type": .string("string")]),
                "completionNote": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string")]),
                "loopModeOverride": .object(["type": .string("string")]),
                "actorId": .object(["type": .string("string")]),
                "teamId": .object(["type": .string("string")]),
                "parentTaskId": .object(["type": .string("string")]),
                "dependsOnTaskIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "selectedModel": .object(["type": .string("string")]),
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "projectId": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ])
        ]),
        "project.task_cancel": .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
                "reference": .object(["type": .string("string")]),
                "taskIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "references": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "reason": .object(["type": .string("string")]),
                "projectId": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ])
        ]),
        "project.task_delete": .object([
            "type": .string("object"),
            "properties": .object([
                "taskId": .object(["type": .string("string")]),
                "reference": .object(["type": .string("string")]),
                "taskIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "references": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ]),
                "projectId": .object(["type": .string("string")]),
                "channelId": .object(["type": .string("string")]),
                "topicId": .object(["type": .string("string")])
            ])
        ]),
        "project.escalate_to_user": .object([
            "type": .string("object"),
            "properties": .object([
                "reason": .object(["type": .string("string")]),
                "taskId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("reason")])
        ]),
        "actor.discuss_with_actor": .object([
            "type": .string("object"),
            "properties": .object([
                "actorId": .object(["type": .string("string")]),
                "topic": .object(["type": .string("string")]),
                "message": .object(["type": .string("string")])
            ]),
            "required": .array([.string("actorId")])
        ]),
        "actor.conclude_discussion": .object([
            "type": .string("object"),
            "properties": .object([
                "discussionId": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")])
            ]),
            "required": .array([.string("discussionId")])
        ]),
        "skills.search": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "sort": .object(["type": .string("string")]),
                "limit": .object(["type": .string("number")])
            ])
        ]),
        "skills.list": .object(["type": .string("object")]),
        "skills.install": .object([
            "type": .string("object"),
            "properties": .object([
                "owner": .object(["type": .string("string")]),
                "repo": .object(["type": .string("string")])
            ]),
            "required": .array([.string("owner"), .string("repo")])
        ]),
        "skills.uninstall": .object([
            "type": .string("object"),
            "properties": .object([
                "skillId": .object(["type": .string("string")])
            ]),
            "required": .array([.string("skillId")])
        ]),
        "lsp.query": .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object([
                    "type": .string("string"),
                    "enum": .array(LSPOperation.allCases.map { .string($0.rawValue) })
                ]),
                "filePath": .object(["type": .string("string")]),
                "line": .object(["type": .string("number")]),
                "character": .object(["type": .string("number")]),
                "query": .object(["type": .string("string")])
            ]),
            "required": .array([.string("operation")])
        ]),
        "visor.status": .object(["type": .string("object")]),
        "agent.documents.set_user_markdown": .object([
            "type": .string("object"),
            "properties": .object([
                "content": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "agent.documents.set_memory_markdown": .object([
            "type": .string("object"),
            "properties": .object([
                "content": .object(["type": .string("string")])
            ]),
            "required": .array([.string("content")])
        ]),
        "project.meta_memory_set": .object([
            "type": .string("object"),
            "properties": .object([
                "projectId": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")])
            ]),
            "required": .array([.string("projectId"), .string("content")])
        ])
    ]
}
