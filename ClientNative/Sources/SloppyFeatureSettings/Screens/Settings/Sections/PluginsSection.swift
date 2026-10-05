import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import SloppyClientCore
import SloppyClientUI

private enum AgentPluginsTab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case store = "Store"
    case registries = "Registries"
    var id: String { rawValue }
}

private struct AgentPluginInstallDraft: Identifiable {
    let id = UUID()
    var source: ClientAgentPluginSource
    var title: String
}

@MainActor @Observable
private final class AgentPluginsSettingsModel {
    var installed: [ClientInstalledAgentPlugin] = []
    var registries: [ClientAgentPluginRegistry] = []
    var catalog: [ClientAgentPluginCatalogItem] = []
    var catalogWarnings: [String] = []
    var search = ""
    var selectedRegistryID: String?
    var status = ""
    var isLoading = false
    var presentedInstall: AgentPluginInstallDraft?
    var uninstallTarget: ClientInstalledAgentPlugin?

    let api: SloppyAPIClient

    init(api: SloppyAPIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let plugins = api.fetchAgentPlugins()
            async let configuredRegistries = api.fetchAgentPluginRegistries()
            installed = try await plugins
            registries = try await configuredRegistries
            status = ""
            await searchCatalog()
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription
        }
    }

    func searchCatalog() async {
        do {
            let response = try await api.searchAgentPluginCatalog(query: search, registryId: selectedRegistryID)
            guard !Task.isCancelled else { return }
            catalog = response.packages
            catalogWarnings = response.warnings
        } catch is CancellationError {
            return
        } catch {
            catalog = []
            catalogWarnings = [error.localizedDescription]
        }
    }

    func prepareZIP(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            status = "Uploading \(url.lastPathComponent)…"
            let upload = try await api.uploadAgentPluginZIP(Data(contentsOf: url))
            presentedInstall = AgentPluginInstallDraft(source: .init(kind: "upload", uploadId: upload.id), title: url.lastPathComponent)
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    func uninstall(_ plugin: ClientInstalledAgentPlugin, force: Bool) async {
        do {
            _ = try await api.uninstallAgentPlugin(id: plugin.id, forceModifiedComponents: force)
            uninstallTarget = nil
            await load()
        } catch {
            status = error.localizedDescription
        }
    }

    func prepareUpdate(_ plugin: ClientInstalledAgentPlugin) async {
        guard plugin.source.kind == "registry", let registryId = plugin.source.registryId else {
            status = "Updates for URL or uploaded packages require selecting a new ZIP."
            return
        }
        do {
            let response = try await api.searchAgentPluginCatalog(query: plugin.id, registryId: registryId)
            guard let item = response.packages.first(where: { $0.id == plugin.id }) else {
                status = "No registry release found for \(plugin.id)."
                return
            }
            presentedInstall = .init(
                source: .init(kind: "registry", registryId: registryId, packageId: plugin.id, version: item.latestVersion),
                title: "Update \(plugin.name)"
            )
        } catch { status = error.localizedDescription }
    }
}

struct PluginsSection: View {
    let config: SloppyConfig
    let onSave: (SloppyConfig) -> Void

    @State private var model: AgentPluginsSettingsModel
    @State private var tab: AgentPluginsTab = .installed
    @State private var isImportingZIP = false
    @State private var downloadURL = ""
    @State private var registryName = ""
    @State private var registryURL = ""

    init(config: SloppyConfig, apiClient: SloppyAPIClient, onSave: @escaping (SloppyConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        _model = State(initialValue: AgentPluginsSettingsModel(api: apiClient))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Agent Plugins", selection: $tab) {
                ForEach(AgentPluginsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("agent-plugins-tabs")

            if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.red).font(.caption) }

            switch tab {
            case .installed: installedContent
            case .store: storeContent
            case .registries: registriesContent
            }
        }
        .task { await model.load() }
        .task(id: model.search) {
            guard tab == .store else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.searchCatalog()
        }
        .onChange(of: tab) { _, value in
            if value == .store { Task { await model.searchCatalog() } }
        }
        .onChange(of: model.selectedRegistryID) { _, _ in Task { await model.searchCatalog() } }
        .fileImporter(isPresented: $isImportingZIP, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { model.status = error.localizedDescription }
                return
            }
            Task { await model.prepareZIP(url) }
        }
        .sheet(item: $model.presentedInstall) { draft in
            AgentPluginInstallSheet(draft: draft, api: model.api) {
                model.presentedInstall = nil
                Task { await model.load() }
            }
        }
        .confirmationDialog(
            "Uninstall Agent Plugin?",
            isPresented: Binding(get: { model.uninstallTarget != nil }, set: { if !$0 { model.uninstallTarget = nil } }),
            presenting: model.uninstallTarget
        ) { plugin in
            Button("Uninstall", role: .destructive) { Task { await model.uninstall(plugin, force: false) } }
            Button("Remove Modified Components Too", role: .destructive) { Task { await model.uninstall(plugin, force: true) } }
        } message: { plugin in
            Text("Sloppy will remove the skills, MCP servers, source plugins, and declared software owned by \(plugin.name).")
        }
    }

    private var installedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Install ZIP") { isImportingZIP = true }
                    .accessibilityIdentifier("agent-plugins-install-zip")
                TextField("https://example.com/plugin.zip", text: $downloadURL)
                    .textFieldStyle(.roundedBorder)
                Button("Install from URL") {
                    let value = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    model.presentedInstall = .init(source: .init(kind: "url", url: value), title: value)
                }
                .disabled(downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            SettingsSectionCard("Installed packages") {
                if model.installed.isEmpty {
                    ContentUnavailableView("No Agent Plugins", systemImage: "shippingbox", description: Text("Install a ZIP, URL, or package from Store."))
                        .padding()
                } else {
                    ForEach(model.installed) { plugin in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.name).font(.headline)
                                Text("\(plugin.id) · \(plugin.version) · \(plugin.status)").font(.caption).foregroundStyle(.secondary)
                                Text("\(plugin.manifest.components.skills.count) skills · \(plugin.manifest.components.mcpServers.count) MCP · \(plugin.manifest.components.sloppyPlugins.count) Sloppy plugins")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let latest = model.catalog.first(where: { $0.id == plugin.id })?.latestVersion, latest != plugin.version {
                                    Text("Update available: \(latest)").font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            Spacer()
                            Button("Update") { Task { await model.prepareUpdate(plugin) } }
                            Button("Uninstall", role: .destructive) { model.uninstallTarget = plugin }
                        }
                        .padding()
                        Divider()
                    }
                }
            }

            DisclosureGroup("Legacy plugin connections") {
                LegacyPluginConnectionsSection(config: config, onSave: onSave)
                    .padding(.top, 10)
            }
        }
    }

    private var storeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search packages", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("agent-plugins-store-search")
                Picker("Registry", selection: $model.selectedRegistryID) {
                    Text("All Registries").tag(String?.none)
                    ForEach(model.registries.filter(\.enabled)) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 220)
            }
            ForEach(model.catalogWarnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            SettingsSectionCard("Available packages") {
                if model.catalog.isEmpty {
                    ContentUnavailableView("No packages", systemImage: "storefront", description: Text("Try another query or check Registries."))
                        .padding()
                } else {
                    ForEach(model.catalog) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text(item.description ?? item.id).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(item.id) · \(item.latestVersion)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install") {
                                model.presentedInstall = .init(
                                    source: .init(kind: "registry", registryId: item.registryId, packageId: item.id, version: item.latestVersion),
                                    title: item.name
                                )
                            }
                        }
                        .padding()
                        Divider()
                    }
                }
            }
        }
    }

    private var registriesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionCard("Configured registries") {
                ForEach(model.registries) { registry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(registry.name).font(.headline)
                            Text(registry.baseURL).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if registry.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        Toggle("Enabled", isOn: Binding(
                            get: { registry.enabled },
                            set: { enabled in
                                Task {
                                    _ = try? await model.api.saveAgentPluginRegistry(
                                        id: registry.id,
                                        request: .init(name: registry.name, baseURL: registry.baseURL, enabled: enabled, isDefault: registry.isDefault)
                                    )
                                    await model.load()
                                }
                            }
                        )).labelsHidden()
                        Button(role: .destructive) {
                            Task {
                                do { try await model.api.deleteAgentPluginRegistry(id: registry.id); await model.load() }
                                catch { model.status = error.localizedDescription }
                            }
                        } label: { Image(systemName: "trash") }
                        .disabled(registry.id == "sloppy-official")
                    }
                    .padding()
                    Divider()
                }
            }
            SettingsSectionCard("Add registry") {
                SettingsFieldRow("Name", text: $registryName)
                SettingsDivider()
                SettingsFieldRow("HTTPS URL", text: $registryURL)
                HStack {
                    Spacer()
                    Button("Add Registry") {
                        Task {
                            do {
                                _ = try await model.api.saveAgentPluginRegistry(request: .init(name: registryName, baseURL: registryURL))
                                registryName = ""; registryURL = ""
                                await model.load()
                            } catch { model.status = error.localizedDescription }
                        }
                    }
                    .disabled(registryName.isEmpty || registryURL.isEmpty)
                    .padding()
                }
            }
        }
    }
}

private struct AgentPluginInstallSheet: View {
    let draft: AgentPluginInstallDraft
    let api: SloppyAPIClient
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inspection: ClientAgentPluginInspection?
    @State private var plan: ClientAgentPluginPlan?
    @State private var agents: [APIAgentRecord] = []
    @State private var selectedAgents = Set<String>()
    @State private var inputs: [String: String] = [:]
    @State private var trustConfirmed = false
    @State private var commandsApproved = false
    @State private var status = "Inspecting package…"
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                if let inspection {
                    Section("Package") {
                        LabeledContent("Name", value: inspection.manifest.name)
                        LabeledContent("ID", value: inspection.manifest.id)
                        LabeledContent("Version", value: inspection.manifest.version)
                        LabeledContent("SHA-256", value: String(inspection.sha256.prefix(16)) + "…")
                        LabeledContent("Trust", value: inspection.trust.replacingOccurrences(of: "_", with: " "))
                    }
                    if !inspection.manifest.components.skills.isEmpty {
                        Section("Agents") {
                            ForEach(agents) { agent in
                                Toggle(agent.displayName, isOn: Binding(
                                    get: { selectedAgents.contains(agent.id) },
                                    set: { isSelected in
                                        if isSelected { selectedAgents.insert(agent.id) }
                                        else { selectedAgents.remove(agent.id) }
                                    }
                                ))
                            }
                        }
                    }
                    if !inspection.manifest.inputs.isEmpty {
                        Section("Configuration") {
                            ForEach(inspection.manifest.inputs) { input in
                                if input.kind == "boolean" {
                                    Toggle(input.title, isOn: Binding(get: { inputs[input.id] == "true" }, set: { inputs[input.id] = $0 ? "true" : "false" }))
                                } else if input.kind == "choice" {
                                    Picker(input.title, selection: Binding(get: { inputs[input.id] ?? input.defaultValue ?? input.choices.first ?? "" }, set: { inputs[input.id] = $0 })) {
                                        ForEach(input.choices, id: \.self) { Text($0).tag($0) }
                                    }
                                } else if input.kind == "secret" {
                                    SecureField(input.title, text: Binding(get: { inputs[input.id] ?? "" }, set: { inputs[input.id] = $0 }))
                                } else {
                                    TextField(input.title, text: Binding(get: { inputs[input.id] ?? input.defaultValue ?? "" }, set: { inputs[input.id] = $0 }))
                                }
                            }
                        }
                    }
                    if let plan {
                        Section("Changes") {
                            ForEach(plan.changes) { change in
                                VStack(alignment: .leading) { Text(change.title); Text(change.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if !plan.commands.isEmpty {
                            Section("Commands requiring approval") {
                                ForEach(plan.commands) { command in
                                    Text(([command.executable] + command.arguments).joined(separator: " ")).font(.system(.caption, design: .monospaced))
                                }
                                Toggle("I approve these commands", isOn: $commandsApproved)
                            }
                        }
                        if plan.requiresTrustConfirmation { Toggle("I trust this unverified ZIP source", isOn: $trustConfirmed) }
                    }
                }
                if !status.isEmpty { Section { Text(status).font(.caption).foregroundColor(status.contains("failed") ? .red : .secondary) } }
            }
            .mobileScreenBackground()
            .navigationTitle(draft.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(plan == nil ? "Review" : "Install") { Task { await advance() } }
                        .disabled(isWorking || inspection == nil || (plan?.requiresTrustConfirmation == true && !trustConfirmed) || (plan?.requiresCommandApproval == true && !commandsApproved))
                }
            }
            .task { await inspect() }
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private func inspect() async {
        do {
            async let inspected = api.inspectAgentPlugin(source: draft.source)
            async let availableAgents = api.fetchAgents()
            let result = try await inspected
            inspection = result
            agents = (try await availableAgents).filter { $0.isSystem != true }
            inputs = Dictionary(uniqueKeysWithValues: result.manifest.inputs.compactMap { input in input.defaultValue.map { (input.id, $0) } })
            status = result.warnings.joined(separator: "\n")
        } catch { status = "Inspection failed: \(error.localizedDescription)" }
    }

    private func advance() async {
        guard let inspection else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if plan == nil {
                plan = try await api.planAgentPlugin(inspectionId: inspection.id, agentIds: Array(selectedAgents), inputs: inputs)
                status = "Review every change before installing."
            } else if let plan {
                let operation = try await api.installAgentPlugin(plan: plan, trustConfirmed: trustConfirmed, commandsApproved: commandsApproved)
                status = operation.message
                onFinished()
                dismiss()
            }
        } catch { status = "Install failed: \(error.localizedDescription)" }
    }
}

private struct LegacyPluginConnectionsSection: View {
    let config: SloppyConfig
    let onSave: (SloppyConfig) -> Void
    @State private var draft: [SloppyConfig.PluginConfig]
    @State private var selectedIndex = 0

    init(config: SloppyConfig, onSave: @escaping (SloppyConfig) -> Void) {
        self.config = config; self.onSave = onSave; _draft = State(initialValue: config.plugins)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCollectionHeader(title: "Legacy connections", count: draft.count, actionTitle: "Add Connection") {
                draft.append(.init(title: "new-plugin", apiKey: "", apiUrl: "", plugin: "")); selectedIndex = draft.count - 1
            }
            ForEach(Array(draft.enumerated()), id: \.offset) { index, plugin in
                Button { selectedIndex = index } label: { LabeledContent(plugin.title.isEmpty ? "Untitled" : plugin.title, value: plugin.plugin) }
                    .buttonStyle(.plain).padding(.horizontal)
            }
            if draft.indices.contains(selectedIndex) {
                SettingsFieldRow("Title", text: Binding(get: { draft[selectedIndex].title }, set: { draft[selectedIndex].title = $0 }))
                SettingsFieldRow("Plugin ID", text: Binding(get: { draft[selectedIndex].plugin }, set: { draft[selectedIndex].plugin = $0 }))
                SettingsFieldRow("API URL", text: Binding(get: { draft[selectedIndex].apiUrl }, set: { draft[selectedIndex].apiUrl = $0 }))
                SettingsFieldRow("API Key", text: Binding(get: { draft[selectedIndex].apiKey }, set: { draft[selectedIndex].apiKey = $0 }), isSecure: true)
                HStack {
                    Button("Remove", role: .destructive) { draft.remove(at: selectedIndex); selectedIndex = max(0, selectedIndex - 1) }
                    Spacer()
                    Button("Save") { var updated = config; updated.plugins = draft; onSave(updated) }.buttonStyle(.borderedProminent)
                }.padding()
            }
        }
    }
}
