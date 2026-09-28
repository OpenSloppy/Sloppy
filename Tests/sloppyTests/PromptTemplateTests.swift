import Foundation
import Protocols
import Testing
import SloppyRuntime
@testable import sloppy

@Test
func promptTemplateRendererReplacesNamedPlaceholders() throws {
    let renderer = PromptTemplateRenderer()
    let output = try renderer.render(
        template: "Hello {{ name }} from {{city}}.",
        values: [
            "name": "Sloppy",
            "city": "Moscow"
        ]
    )

    #expect(output == "Hello Sloppy from Moscow.")
}

@Test
func promptTemplateRendererThrowsForMissingPlaceholder() throws {
    let renderer = PromptTemplateRenderer()

    #expect(throws: PromptTemplateRenderer.RenderError.self) {
        _ = try renderer.render(
            template: "Hello {{ name }} from {{city}}.",
            values: ["name": "Sloppy"]
        )
    }
}

@Test
func promptTemplateLoaderUsesInjectedResolver() throws {
    let loader = PromptTemplateLoader(resolver: { relativePath in
        switch relativePath {
        case "agent_session_bootstrap.md":
            return "bootstrap"
        case "partials/runtime_rules.md":
            return "rules"
        default:
            throw PromptTemplateLoader.LoaderError.templateNotFound(relativePath)
        }
    })

    #expect(try loader.loadTemplate(for: .agentSessionBootstrap) == "bootstrap")
    #expect(try loader.loadPartial(named: "runtime_rules") == "rules")
}

@Test
func promptTemplateLoaderReadsInstalledPromptFromShareDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    let promptsDirectory = root.appendingPathComponent("share/sloppy/Prompts/en/partials", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)

    let runtimeRules = promptsDirectory.appendingPathComponent("runtime_rules.md")
    try "runtime-rules".write(to: runtimeRules, atomically: true, encoding: .utf8)

    let loader = PromptTemplateLoader(
        executablePath: binDirectory.appendingPathComponent("sloppy").path,
        currentDirectoryPath: root.path,
        sourceFilePath: root.appendingPathComponent("Missing/PromptTemplateLoader.swift").path
    )

    #expect(try loader.loadPartial(named: "runtime_rules") == "runtime-rules")
}

@Test
func promptTemplateLoaderReadsInstalledPromptViaSymlinkedBinary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let installRoot = root.appendingPathComponent("install", isDirectory: true)
    let linkRoot = root.appendingPathComponent("links", isDirectory: true)
    let binDirectory = installRoot.appendingPathComponent("bin", isDirectory: true)
    let promptsDirectory = installRoot.appendingPathComponent("share/sloppy/Prompts/en/partials", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)

    let realBinaryPath = binDirectory.appendingPathComponent("sloppy").path
    let symlinkPath = linkRoot.appendingPathComponent("sloppy").path
    FileManager.default.createFile(atPath: realBinaryPath, contents: Data(), attributes: nil)
    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realBinaryPath)

    let sessionCapabilities = promptsDirectory.appendingPathComponent("session_capabilities.md")
    try "session-capabilities".write(to: sessionCapabilities, atomically: true, encoding: .utf8)

    let loader = PromptTemplateLoader(
        executablePath: symlinkPath,
        currentDirectoryPath: root.path,
        sourceFilePath: root.appendingPathComponent("Missing/PromptTemplateLoader.swift").path
    )

    #expect(try loader.loadPartial(named: "session_capabilities") == "session-capabilities")
}

@Test
func promptTemplateLoaderFindsResourcesFromRuntimeSourceFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let promptsDirectory = root.appendingPathComponent("Sources/SloppyRuntime/Resources/Prompts/en/partials", isDirectory: true)
    try FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)

    let runtimeRules = promptsDirectory.appendingPathComponent("runtime_rules.md")
    try "runtime-rules".write(to: runtimeRules, atomically: true, encoding: .utf8)

    let loader = PromptTemplateLoader(
        executablePath: nil,
        currentDirectoryPath: root.appendingPathComponent("RuntimeCwd").path,
        sourceFilePath: root.appendingPathComponent("Sources/SloppyRuntime/AgentPromptComposer.swift").path
    )

    #expect(try loader.loadPartial(named: "runtime_rules") == "runtime-rules")
}

@Test
func completionReflectionTellsAgentToDecideInsteadOfAskingUser() throws {
    let prompt = try PromptTemplateLoader().loadPartial(named: "completion_reflection")

    #expect(prompt.contains("decide yourself"))
    #expect(!prompt.contains("close your final response with a brief question"))
    #expect(!prompt.contains("Ask in the user's language"))
}

@Test
func agentPromptComposerIncludesSharedMemoryRulesOnlyWhenEnabled() throws {
    let loader = PromptTemplateLoader(resolver: { relativePath in
        if relativePath.hasPrefix("partials/") {
            return "[\(relativePath)]"
        }
        return "[\(relativePath)]"
    })
    let composer = AgentPromptComposer(templateLoader: loader)
    let documents = AgentDocumentBundle(
        userMarkdown: "User",
        agentsMarkdown: "Agent",
        soulMarkdown: "Soul",
        identityMarkdown: "Identity"
    )

    let enabledPrompt = try composer.compose(
        context: .agentSessionBootstrap(
            agentID: "agent-a",
            sessionID: "session-a",
            bootstrapMarker: "BOOT",
            documents: documents,
            installedSkills: [],
            agentDirectoryPath: nil,
            sharedMemoryEnabled: true
        )
    ).description
    let disabledPrompt = try composer.compose(
        context: .agentSessionBootstrap(
            agentID: "agent-a",
            sessionID: "session-a",
            bootstrapMarker: "BOOT",
            documents: documents,
            installedSkills: [],
            agentDirectoryPath: nil,
            sharedMemoryEnabled: false
        )
    ).description

    #expect(enabledPrompt.contains("[Shared memory]"))
    #expect(enabledPrompt.contains("scope_id: shared"))
    #expect(!disabledPrompt.contains("[Shared memory]"))
    #expect(!disabledPrompt.contains("scope_id: shared"))
}
