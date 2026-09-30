import SwiftUI
import SloppyClientCore

@MainActor
public struct ChatLaunchControls: View {
    private let viewModel: ChatScreenViewModel
    private let onOpenPreview: @MainActor (URL) -> Void
    public init(viewModel: ChatScreenViewModel, onOpenPreview: @escaping @MainActor (URL) -> Void) {
        self.viewModel = viewModel; self.onOpenPreview = onOpenPreview
    }

    private func selectionTitle(_ configuration: LaunchConfiguration) -> String {
        let request = configuration.request
        let root = URL(fileURLWithPath: request.checkoutPath).lastPathComponent
        let location = request.workingDirectory == "." ? root : root + "/" + request.workingDirectory
        return "\(request.name) · \(request.platform.displayName) · \(request.target) — \(location)"
    }

    public var body: some View {
        @Bindable var launch = viewModel.launch
        HStack(spacing: 4) {
            Button {
                if launch.selected == nil { viewModel.prepareLaunch() }
                else { Task { await launch.play() } }
            } label: {
                Label(launch.title, systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .help(launch.selected?.request.checkoutPath ?? "Ask the agent to prepare a runnable target")
            .accessibilityIdentifier("chat.launch.play")
            .disabled(viewModel.selectedSessionId == nil || launch.state?.isArchived == true || launch.isBusy || launch.run?.status.isActive == true
                      || (launch.selected == nil && (viewModel.isSending || viewModel.isAwaitingAgentResponse)))
            Menu {
                ForEach(launch.state?.configurations ?? []) { configuration in
                    Button {
                        Task { await launch.select(configuration) }
                    } label: {
                        Label(selectionTitle(configuration),
                              systemImage: configuration.id == launch.selected?.id ? "checkmark" : "app")
                    }
                }
                if launch.selected != nil {
                    Divider()
                    Button("Show logs", systemImage: "text.alignleft") { launch.showsLogs = true }
                    if launch.selected?.request.platform == .iOSSimulator {
                        Button("Run on Simulator…", systemImage: "iphone") { Task { await launch.chooseSimulator() } }
                            .disabled(launch.isBusy || launch.run?.status.isActive == true)
                    }
                    Button("Restart", systemImage: "arrow.clockwise") { Task { await launch.play(restart: true) } }
                        .disabled(launch.isBusy)
                    if launch.run?.status.isActive == true {
                        Button("Stop", systemImage: "stop.fill") { Task { await launch.stop() } }
                    }
                    Button("Remove launch configuration", systemImage: "trash") { Task { await launch.removeSelected() } }
                }
                if let error = launch.errorMessage { Text(error) }
                Button("Prepare launch with agent", systemImage: "wand.and.stars") { viewModel.prepareLaunch() }
                    .disabled(viewModel.isSending || viewModel.isAwaitingAgentResponse || viewModel.selectedSessionId == nil)
            } label: { Image(systemName: "chevron.down") }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("chat.launch.targets")
            if launch.run?.status.isActive == true {
                Button { Task { await launch.stop() } } label: { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop launch")
                    .disabled(launch.isBusy)
            }
        }
        .task(id: "\(ObjectIdentifier(viewModel)):\(viewModel.selectedAgent?.id ?? ""):\(viewModel.selectedSessionId ?? "")") {
            launch.onOpenPreview = onOpenPreview
            await launch.observe(agentID: viewModel.selectedAgent?.id, sessionID: viewModel.selectedSessionId)
        }
        .popover(isPresented: $launch.showsLogs) { ChatLaunchLogs(viewModel: launch) }
        .popover(isPresented: $launch.showsSimulatorPicker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Simulator on \(launch.selected?.hostName ?? "execution host")").font(.headline)
                if launch.simulators.isEmpty { Text("No available Simulators. Install a Simulator runtime on this Mac.") }
                ForEach(launch.simulators) { simulator in
                    Button("\(simulator.name) · \(simulator.state)") {
                        guard let selected = launch.selected else { return }
                        Task {
                            await launch.select(selected, simulatorID: simulator.id)
                            guard launch.selected?.request.simulatorID == simulator.id else { return }
                            launch.showsSimulatorPicker = false
                            await launch.play()
                        }
                    }
                }
            }.padding().frame(minWidth: 280)
        }
    }
}

@MainActor
private struct ChatLaunchLogs: View {
    let viewModel: ChatLaunchViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.title).font(.headline)
                Spacer()
                if viewModel.run?.status.isActive == true {
                    Button("Stop") { Task { await viewModel.stop() } }.disabled(viewModel.isBusy)
                }
                Button("Restart") { Task { await viewModel.play(restart: true) } }.disabled(viewModel.isBusy)
            }
            if let configuration = viewModel.selected {
                Text("\(configuration.hostName) · \(configuration.request.checkoutPath)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let run = viewModel.run {
                HStack {
                    Text(run.status.rawValue.capitalized)
                    Spacer()
                    Text("Build: \(run.configuration.request.build.isEmpty ? "not required" : (run.buildSucceeded ? "succeeded" : (run.status == .failed ? "failed" : "pending"))) · Launch: \(run.launchSucceeded ? "succeeded" : (run.status == .failed ? "not started" : "pending"))")
                }.font(.caption)
                if run.status == .running, run.configuration.request.platform == .web {
                    Button("Open preview") { Task { await viewModel.openPreview(run) } }
                }
                if let error = run.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                ScrollView {
                    Text(run.logs.isEmpty ? "Waiting for output…" : run.logs)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding().frame(width: 620, height: 380)
    }
}
