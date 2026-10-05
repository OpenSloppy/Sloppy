import Protocols
import Testing
@testable import sloppy

@Test
func subagentEffectiveToolsAppliesDenylist() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = [
        "workers.spawn",
        "files.read",
        "memory.save",
        "agents.delegate_task",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil
    )
    #expect(!eff.contains("workers.spawn"))
    #expect(!eff.contains("memory.save"))
    #expect(!eff.contains("agents.delegate_task"))
    #expect(eff.contains("agent_delegate.finish"))
    #expect(eff.contains("files.read"))
}

@Test
func subagentEffectiveToolsIntersectsToolsets() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = ["files.read", "web.search", "workers.spawn", "runtime.process", "agent_delegate.finish"]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: ["file"]
    )
    #expect(eff == Set(["files.read", "agent_delegate.finish"]))
}

@Test
func subagentTerminalToolsetAllowsExecAndProcesses() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = ["runtime.exec", "runtime.process"]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: ["terminal"]
    )
    #expect(eff.contains("runtime.exec"))
    #expect(eff.contains("runtime.process"))
}

@Test
func subagentProjectTasksToolsetAllowsOnlyTaskLifecycleTools() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = [
        "project.current",
        "project.task_list",
        "project.task_create",
        "project.task_get",
        "project.task_update",
        "project.task_clarification_create",
        "project.delete",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: ["project_tasks"]
    )
    #expect(eff == Set([
        "project.current",
        "project.task_list",
        "project.task_create",
        "project.task_get",
        "project.task_update",
        "project.task_clarification_create",
        "agent_delegate.finish",
    ]))
}

@Test
func subagentWorkerToolsExpandAliasesAndKeepConcreteToolIDs() {
    let known: Set<String> = [
        "project.current",
        "project.task_list",
        "project.task_create",
        "project.task_get",
        "project.task_update",
        "project.task_clarification_create",
        "web.search",
        "web.fetch",
        "mcp.github.create_issue",
    ]

    let explicit = SubagentDelegation.explicitToolIDs(
        forWorkerTools: ["project_tasks", "web.search", "mcp.github.create_issue"],
        knownToolIDs: known
    )

    #expect(explicit.contains("project.task_update"))
    #expect(explicit.contains("project.task_get"))
    #expect(explicit.contains("web.search"))
    #expect(explicit.contains("mcp.github.create_issue"))
    #expect(!explicit.contains("project_tasks"))
}

@Test
func subagentEffectiveToolsAllowTaskClarificationFlow() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = [
        "project.task_clarification_create",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil
    )
    #expect(eff.contains("project.task_clarification_create"))
    #expect(eff.contains("agent_delegate.finish"))
}

@Test
func subagentRespectsParentDenyPolicy() {
    let policy = AgentToolsPolicy(
        defaultPolicy: .allow,
        tools: ["files.read": false, "web.search": true]
    )
    let known: Set<String> = ["files.read", "web.search"]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil
    )
    #expect(!eff.contains("files.read"))
    #expect(eff.contains("web.search"))
}

@Test
func subagentExplicitToolsRestrictAllowedSet() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = [
        "files.read",
        "files.write",
        "web.search",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil,
        explicitToolIDs: ["files.read", "web.search"]
    )
    #expect(eff == Set(["files.read", "web.search", "agent_delegate.finish"]))
}

@Test
func subagentExplicitToolsSupportMCPToolIDs() {
    let policy = AgentToolsPolicy(defaultPolicy: .allow, tools: [:])
    let known: Set<String> = [
        "mcp.github.create_issue",
        "mcp.figma.create_frame",
        "files.read",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil,
        explicitToolIDs: ["mcp.github.create_issue"]
    )
    #expect(eff == Set(["mcp.github.create_issue", "agent_delegate.finish"]))
}

@Test
func subagentExplicitToolsStillRespectPolicyAndHardDenylist() {
    let policy = AgentToolsPolicy(
        defaultPolicy: .allow,
        tools: ["files.write": false]
    )
    let known: Set<String> = [
        "files.read",
        "files.write",
        "runtime.exec", "workers.spawn",
        "agent_delegate.finish",
    ]
    let eff = SubagentDelegation.effectiveToolIDs(
        policy: policy,
        knownToolIDs: known,
        toolsetNames: nil,
        explicitToolIDs: ["files.read", "files.write", "runtime.exec", "workers.spawn"]
    )
    #expect(eff == Set(["files.read", "runtime.exec", "agent_delegate.finish"]))
}
