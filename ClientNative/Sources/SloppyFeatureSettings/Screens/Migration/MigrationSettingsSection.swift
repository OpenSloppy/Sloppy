#if os(macOS)
import SwiftUI
import SloppyClientCore
import SloppyClientUI

public struct MigrationSettingsSection: View {
    @State private var model: ClientMigrationController
    @Environment(\.openURL) private var openURL
    private let titles = ["Sources", "Data", "Agents & projects", "Preview", "Transfer", "Result"]
    public init(settings: ClientSettings) {
        _model = State(initialValue: ClientMigrationController(endpoint: settings.activeInstanceEndpoint, destinationKey: settings.instanceDirectoryKey))
    }
    public var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bring your work to Sloppy").font(.title2.bold())
                Text("Read agent data on this Mac. Source files are preserved.").foregroundStyle(.secondary)
                Text("Destination: \(model.destination)").font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        Text(title).font(.caption.weight(index == model.step ? .bold : .regular)).foregroundStyle(index == model.step ? Color.accentColor : .secondary)
                        if index < titles.count - 1 { Image(systemName: "chevron.right").font(.caption2) }
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if model.busy { ProgressView(model.step == 0 ? "Analyzing selected sources…" : "Preparing transfer…") }
                switch model.step {
                case 0: sources
                case 1: dataSelection
                case 2: mappings
                case 3: preview
                case 4: progress
                default: result
                }
                navigation
            }
            .padding(20)
        }
        .accessibilityIdentifier("migration.wizard")
        .task { await model.loadHistory() }
        .task(id: model.job?.id) {
            while !Task.isCancelled, model.job != nil {
                if model.step == 4 { await model.refresh() }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.sources) { source in
                Toggle(isOn: Binding(get: { model.selectedSources.contains(source.id) }, set: { value in
                    if value { model.selectedSources.insert(source.id) } else { model.selectedSources.remove(source.id) }
                })) {
                    VStack(alignment: .leading) { Text(source.kind.rawValue.capitalized); Text(source.path).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("For sandbox access or a custom location, choose an agent folder or your home folder.").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(MigrationSourceKind.allCases, id: \.self) { kind in
                    Button("Choose \(kind.rawValue.capitalized)…") { model.chooseFolder(kind: kind) }
                }
            }
            if !model.history.isEmpty {
                Divider(); Text("Previous transfers").font(.headline)
                ForEach(model.history.prefix(10)) { job in
                    HStack { Text("\(job.createdAt.formatted()) · \(job.status.rawValue)"); Spacer(); Button("Open / resume") { Task { await model.resume(job) } } }
                }
            }
        }
    }
    private var dataSelection: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(MigrationCategory.allCases, id: \.self) { category in
                let items = model.catalog.items.filter { $0.category == category }
                if !items.isEmpty {
                    Toggle("\(category.rawValue.capitalized) · \(items.count)", isOn: Binding(get: { items.allSatisfy { model.selectedItems.contains($0.id) } }, set: { on in
                        if on { model.selectedItems.formUnion(items.map(\.id)) } else { model.selectedItems.subtract(items.map(\.id)) }
                    })).font(.headline)
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { model.selectedItems.contains(item.id) }, set: { on in
                            if on { model.selectedItems.insert(item.id) } else { model.selectedItems.remove(item.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                Text("\(item.source.kind.rawValue) · \(item.profile) · \(ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                if let path = item.projectPath { Text(path).font(.caption2).foregroundStyle(.secondary) }
                                ForEach(item.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            }
                        }.padding(.leading, 16)
                    }
                }
            }
            ForEach(model.catalog.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if model.catalog.items.isEmpty { Text("No supported data found. Choose another source folder.") }
        }
    }
    private var mappings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            Text("Separate agent profiles preserve each assistant’s memory and instructions.").foregroundStyle(.secondary)
            ForEach(model.profiles, id: \.self) { key in
                let item = model.selection.items.first { $0.profileKey == key }
                Picker("\(item?.source.kind.rawValue.capitalized ?? "Agent") · \(item?.profile ?? "default")", selection: Binding(get: { model.agentMappings[key] ?? "" }, set: { value in
                    model.agentMappings[key] = value.isEmpty ? nil : value
                })) {
                    Text("Create separate profile").tag("")
                    ForEach(model.agents) { agent in Text(agent.displayName).tag(agent.id) }
                }
            }
            Divider()
            Text("Project folders on the destination Core").font(.headline)
            Text("Leave blank to import history and context without binding a folder. Project source files are excluded.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.projectPaths, id: \.self) { path in
                VStack(alignment: .leading) {
                    Text(path).font(.caption.monospaced())
                    TextField("Destination folder (optional)", text: Binding(get: { model.projectMappings[path] ?? "" }, set: { model.projectMappings[path] = $0 }))
                }
            }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = model.preview {
                Text("\(model.selection.items.count) objects · \(ByteCountFormatter.string(fromByteCount: Int64(preview.totalBytes), countStyle: .file))").font(.headline)
                Text("\(preview.duplicates.count) already imported · \(preview.conflicts.count) separate variants / instruction merges")
                Text("Selected data will be sent to \(model.destination). MCP environment and headers are included; provider credentials are excluded.")
                ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                Text("Existing data is preserved. MCP servers stay disabled until you choose to check and enable them.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = model.job {
                Text(job.stage.rawValue.capitalized).font(.headline)
                ProgressView(value: Double(job.uploadedBytes), total: Double(max(1, job.totalBytes)))
                Text("Transfer: \(job.uploadedBytes) / \(job.totalBytes) bytes").font(.caption)
                ProgressView(value: Double(job.outcomes.count), total: Double(max(1, job.totalItems)))
                Text("Imported / checked: \(job.outcomes.count) / \(job.totalItems)").font(.caption)
                ForEach(MigrationCategory.allCases, id: \.self) { category in
                    let outcomes = job.outcomes.filter { $0.category == category }
                    if !outcomes.isEmpty {
                        Text("\(category.rawValue): \(outcomes.filter { $0.status == "imported" }.count) imported · \(outcomes.filter { $0.status == "duplicate" }.count) already present · \(outcomes.filter { $0.status == "error" }.count) errors").font(.caption)
                    }
                }
                if job.memoryTotalUnits > 0 { Text("Memory: \(job.memoryCompletedUnits) / \(job.memoryTotalUnits) verified parts") }
                Button("Cancel remaining work") { Task { await model.cancel() } }
                if model.error != nil { Button("Resume") { Task { await model.resume(job) } } }
            }
        }
    }
    private var result: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let job = model.job {
                Text(job.status.rawValue).font(.headline)
                ForEach(job.outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(outcome.title) · \(outcome.status)")
                        if let message = outcome.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        if let agent = outcome.agentID, outcome.sessionID == nil, let url = URL(string: "/agents/\(agent)/chat", relativeTo: model.api.baseURL) {
                            Link("Open agent profile", destination: url)
                        }
                        if let agent = outcome.agentID, let session = outcome.sessionID {
                            Button("Open conversation") { if let url = DeepLink.session(agentId: agent, sessionId: session).url { openURL(url) } }
                        }
                        if let project = outcome.projectID { Button("Open project") { if let url = DeepLink.project(id: project).url { openURL(url) } } }
                    }
                }
                ForEach(job.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if job.outcomes.contains(where: { $0.mcpID != nil }) {
                    Button("Check and enable imported MCP servers") { Task { await model.enableMCP() } }
                    ForEach(model.mcpResults, id: \.id) { status in Text("\(status.id): \(status.error ?? (status.connected == true ? "Connected" : "Check MCP settings"))").font(.caption) }
                }
                if job.status != .completed { Button("Retry / resume") { Task { await model.resume(job) } } }
            }
        }
    }
    private var navigation: some View {
        HStack {
            if model.step > 0, model.step < 4 { Button("Back") { model.step -= 1 }.disabled(model.busy) }
            Spacer()
            switch model.step {
            case 0: Button("Analyze sources") { Task { await model.analyze() } }.disabled(model.busy || model.selectedSources.isEmpty)
            case 1: Button("Choose destinations") { model.step = 2 }.disabled(model.selectedItems.isEmpty)
            case 2: Button("Preview") { Task { await model.makePreview() } }.disabled(model.busy)
            case 3: Button("Transfer selected data") { Task { await model.begin() } }.disabled(model.busy).accessibilityIdentifier("migration.start")
            default: EmptyView()
            }
        }
    }
}
#endif
