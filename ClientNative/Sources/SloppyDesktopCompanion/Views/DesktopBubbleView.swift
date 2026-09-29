import SwiftUI
import SloppyClientCore

struct DesktopBubbleView: View {
    @Bindable var model: DesktopCompanionModel
    var toggle: () -> Void
    var hide: () -> Void
    var settings: () -> Void
    var captureRegion: () -> Void
    @FocusState private var composerFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                if model.showsResponsePanel {
                    DesktopResponseView(model: model)
                        .modifier(DesktopBubblePopModifier(presentationID: model.responsePresentationID, above: true))
                        .padding(.bottom, DesktopCompanionLayout.responseSpacing)
                }
                orb
                Group {
                    if model.expanded { composer }
                    else { compactToolbar }
                }
                .padding(.top, DesktopCompanionLayout.inputSpacing)
            }
            .padding(DesktopCompanionLayout.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onChange(of: model.showsResponsePanel) { _, _ in model.onLayoutChanged?() }
        .onChange(of: model.showHistory) { _, _ in model.onLayoutChanged?() }
    }

    private var orb: some View {
        DesktopOrbView(activity: model.orbActivity, audioLevel: model.audioLevel, isVisible: model.panelVisible)
            .contentShape(Circle())
            .onTapGesture(perform: toggle)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .help("Click to open chat · Drag to move")
            .accessibilityElement()
            .accessibilityLabel("Sloppy Pointer")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggle)
            .accessibilityIdentifier("pointer.orb")
            .contextMenu {
                Button(model.expanded ? "Collapse Composer" : "Open Composer", action: toggle)
                Button("Action Ring (⌥ Space)", systemImage: "circle.grid.2x2") { model.onActionRingRequested?() }
                Button(model.showHistory ? "Hide History" : "Show History") { model.showHistory.toggle() }
                Button("Open in Sloppy", systemImage: "arrow.up.forward.app") { model.openDesktop(preferSession: true) }
                    .accessibilityIdentifier("pointer.open-sloppy")
                Divider()
                Button("Stop Agent", systemImage: "stop.fill") { Task { await model.stop() } }
                    .disabled(!model.canStop || model.isStopping)
                Button("Settings…", action: settings)
                Button("Hide", action: hide)
            }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button("Select an area", systemImage: "plus", action: captureRegion)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Select an area")
                .accessibilityIdentifier("pointer.capture-region")
            TextField("", text: $model.draft, axis: .vertical)
                .font(.system(size: 15))
                .focused($composerFocused)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(model.isSending)
                .onSubmit { composerFocused = false; Task { await model.send() } }
                .accessibilityLabel("Message")
                .accessibilityIdentifier("pointer.composer")
            composerAction
        }
        .padding(8)
        .frame(width: DesktopCompanionLayout.contentWidth)
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if model.composerPanelHeight != height { model.composerPanelHeight = height; model.onLayoutChanged?() }
        }
        .modifier(DesktopBubblePopModifier(presentationID: model.chatPresentationID, above: false))
        .onAppear { composerFocused = true }
        .onDisappear { composerFocused = false }
        .onKeyPress(.escape) {
            if model.isRecording { Task { await model.cancelRecording() } }
            else { toggle() }
            return .handled
        }
    }

    @ViewBuilder
    private var composerAction: some View {
        if model.composerAction == .send {
            actionButton.buttonStyle(.glassProminent).tint(.accentColor)
        } else {
            actionButton.buttonStyle(.glass)
                .foregroundStyle(model.isRecording ? Color.red : .primary)
        }
    }

    private var actionButton: some View {
        Button(model.composerAction.title, systemImage: model.composerAction.symbol) {
            if model.composerAction == .send { composerFocused = false }
            Task { await model.performComposerAction() }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(model.composerAction == .finishRecording ? "Finish recording" : model.composerAction.title)
        .disabled(!model.canPerformComposerAction)
        .accessibilityIdentifier("pointer.send")
    }

    private var compactToolbar: some View {
        HStack(spacing: 0) {
            Button("Write", systemImage: "square.and.pencil", action: toggle)
                .help("Open composer")
                .accessibilityIdentifier("pointer.compose")
            toolbarDivider
            Button(model.isRecording ? "Finish recording" : "Voice",
                   systemImage: model.isRecording ? "stop.circle.fill" : "waveform") {
                model.onPanelChanged?()
                Task {
                    if model.isRecording { await model.finishRecording() }
                    else { await model.startRecording() }
                }
            }
            .disabled(!model.isRecording && (model.isWorking || model.isSending || model.isStopping || model.isTranscribing))
            .help(model.isRecording ? "Finish recording" : "Voice")
            .accessibilityIdentifier("pointer.voice")
            toolbarDivider
            Button("Action Ring", systemImage: "circle.grid.2x2") { model.onActionRingRequested?() }
                .help("Open action ring (⌥ Space)")
                .accessibilityIdentifier("pointer.actions")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(DesktopToolbarButtonStyle())
        .padding(4)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pointer.toolbar")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 20)
    }
}

private struct DesktopToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .frame(width: 38, height: 32)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct DesktopBubblePopModifier: ViewModifier {
    var presentationID: UUID
    var above: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || isPresented ? 1 : 0.84,
                         anchor: UnitPoint(x: 0.5, y: above ? 1 : 0))
            .offset(y: reduceMotion || isPresented ? 0 : (above ? 8 : -8))
            .opacity(isPresented ? 1 : 0)
            .allowsHitTesting(isPresented)
            .task(id: presentationID) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isPresented = false }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.24)) {
                    isPresented = true
                }
            }
    }
}
