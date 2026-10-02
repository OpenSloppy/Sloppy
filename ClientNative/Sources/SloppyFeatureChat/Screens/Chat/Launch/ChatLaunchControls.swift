import SwiftUI
import SloppyClientCore

@MainActor
public struct ChatLaunchControls: View {
    private let viewModel: ChatScreenViewModel
    private let onOpenPreview: @MainActor (URL) -> Void
    @State private var showsLaunchOptions = false
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
        ChatLaunchButton(
            systemImage: launch.run?.status.isActive == true ? "stop.fill" : "play.fill",
            title: launch.run?.status.isActive == true ? "Stop launch" : "Run",
            canPerformAction: canPerformPrimaryAction,
            onAction: performPrimaryAction,
            onShowOptions: { showsLaunchOptions = true }
        )
        .disabled(viewModel.selectedSessionId == nil)
        .help("\(launch.title). Hold to choose how to run.")
        .contextMenu { launchOptions }
        .popover(isPresented: $showsLaunchOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                launchOptions
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(minWidth: 260, alignment: .leading)
            .accessibilityIdentifier("chat.launch.targets")
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

    private var canPrepareLaunch: Bool {
        viewModel.selectedSessionId != nil && !viewModel.isSending && !viewModel.isAwaitingAgentResponse
    }

    private var canPerformPrimaryAction: Bool {
        let launch = viewModel.launch
        return viewModel.selectedSessionId != nil && launch.state?.isArchived != true && !launch.isBusy
            && (launch.run?.status.isActive == true || launch.selected != nil || canPrepareLaunch)
    }

    private func performPrimaryAction() {
        guard canPerformPrimaryAction else { return }
        let launch = viewModel.launch
        if launch.run?.status.isActive == true {
            Task { await launch.stop() }
        } else if launch.selected != nil {
            Task { await launch.play() }
        } else {
            viewModel.prepareLaunch()
        }
    }

    @ViewBuilder
    private var launchOptions: some View {
        let launch = viewModel.launch
        ForEach(launch.state?.configurations ?? []) { configuration in
            Button {
                showsLaunchOptions = false
                Task { await launch.select(configuration) }
            } label: {
                Label(selectionTitle(configuration),
                      systemImage: configuration.id == launch.selected?.id ? "checkmark" : "app")
            }
            .disabled(launch.isBusy)
        }
        if launch.selected != nil {
            Divider()
            Button("Show logs", systemImage: "text.alignleft") {
                showsLaunchOptions = false
                launch.showsLogs = true
            }
            if launch.selected?.request.platform == .iOSSimulator {
                Button("Run on Simulator…", systemImage: "iphone") {
                    showsLaunchOptions = false
                    Task { await launch.chooseSimulator() }
                }
                .disabled(launch.isBusy || launch.run?.status.isActive == true)
            }
            Button("Restart", systemImage: "arrow.clockwise") {
                showsLaunchOptions = false
                Task { await launch.play(restart: true) }
            }
            .disabled(launch.isBusy)
            if launch.run?.status.isActive == true {
                Button("Stop", systemImage: "stop.fill") {
                    showsLaunchOptions = false
                    Task { await launch.stop() }
                }
                .disabled(launch.isBusy)
            }
            Button("Remove launch configuration", systemImage: "trash") {
                showsLaunchOptions = false
                Task { await launch.removeSelected() }
            }
            .disabled(launch.isBusy)
        }
        if let error = launch.errorMessage { Text(error) }
        Button("Prepare launch with agent", systemImage: "wand.and.stars") {
            showsLaunchOptions = false
            viewModel.prepareLaunch()
        }
        .disabled(!canPrepareLaunch)
    }
}

@MainActor
struct ChatLaunchButton: View {
    let systemImage: String
    let title: String
    let canPerformAction: Bool
    let onAction: () -> Void
    let onShowOptions: () -> Void

    var body: some View {
        Button(action: performAction) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .opacity(canPerformAction ? 1 : 0.5)
        }
#if os(macOS)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
#endif
        .accessibilityLabel(title)
        .accessibilityIdentifier("chat.launch.play")
        .accessibilityHint("Hold to choose how to run")
        .accessibilityAction(named: Text("Launch options"), onShowOptions)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5)
                .exclusively(before: TapGesture())
                .onEnded { gesture in
                    switch gesture {
                    case .first(true): onShowOptions()
                    case .second: performAction()
                    default: break
                    }
                }
        )
    }

    private func performAction() {
        guard canPerformAction else { return }
        onAction()
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
