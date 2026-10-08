import SwiftUI
import SloppyClientCore
import SloppyClientUI
#if os(macOS)
import AppKit
#endif

@MainActor
struct DesktopWorkspaceTabStrip: View {
    @State var viewModel: MainViewModel

    private let stripHeight: CGFloat = 46
    private let minimumTabWidth: CGFloat = 120
    private var trailingControlWidth: CGFloat {
#if os(macOS)
        0
#else
        30
#endif
    }

    @State private var previousTabIDs: [WorkspaceTab.ID] = []
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let availableTabWidth = max(0, geometry.size.width - trailingControlWidth - 2)
            let tabWidth = tabWidth(for: availableTabWidth)

            dragProtectedStrip(tabWidth: tabWidth)
        }
        .frame(height: stripHeight)
        .padding(.horizontal, theme.spacing.s)
        .padding(.vertical, theme.spacing.s)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.tabs.map(\.id))
    }

    @ViewBuilder
    private func dragProtectedStrip(tabWidth: CGFloat) -> some View {
#if os(macOS)
//        WindowDragGestureShield {
            stripContent(tabWidth: tabWidth)
//        }
#else
        stripContent(tabWidth: tabWidth)
#endif
    }

    private func stripContent(tabWidth: CGFloat) -> some View {
        let spacing: CGFloat = {
#if os(visionOS)
            theme.spacing.m
#else
            theme.spacing.xs
#endif
        }()
        return HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(viewModel.tabs) { tab in
                            DesktopWorkspaceTabButton(
                                tab: tab,
                                isSelected: viewModel.selectedTabID == tab.id,
                                onSelect: {
                                    viewModel.selectTab(tab.id)
                                },
                                onClose: {
                                    viewModel.closeTab(tab.id)
                                }
                            )
                            .frame(width: tabWidth)
                            .contextMenu {
                                if let chat = viewModel.tabStates[tab.id]?.chatState?.viewModel,
                                   chat.selectedSessionId != nil {
                                    Button("Rename Chat…", systemImage: "pencil") {
                                        viewModel.selectTab(tab.id)
                                        chat.requestRenameActiveSession()
                                    }
                                }
                            }
                            .id(tab.id)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first,
                                      let sourceTabID = UUID(uuidString: raw),
                                      sourceTabID != tab.id else {
                                    return false
                                }

                                viewModel.beginDesktopSplit(source: sourceTabID, target: tab.id)
                                return true
                            }
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )

#if !os(visionOS)
                            if viewModel.tabs.last != tab {
                                Divider()
                                    .fixedSize()
                            }
#endif
                        }
                    }
                    .padding(.horizontal, 2)
#if !os(visionOS)
                    .background {
                        Capsule()
                            .fill(.gray.opacity(0.3))
                    }
#endif
                }
                .clipShape(Capsule())
                .onAppear {
                    previousTabIDs = viewModel.tabs.map(\.id)
                }
                .onChange(of: viewModel.tabs.map(\.id)) { _, newIDs in
                    let newTabIDs = newIDs.filter { !previousTabIDs.contains($0) }
                    previousTabIDs = newIDs

                    guard let tabID = newTabIDs.last else {
                        return
                    }

                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(tabID, anchor: .trailing)
                    }
                }
            }

#if !os(macOS)
            Button(action: { viewModel.selectNewChat() }) {
                Image(systemName: "plus")
                    .font(.system(size: theme.typography.caption, weight: .semibold))
                    .foregroundColor(theme.colors.textPrimary.opacity(0.94 as CGFloat))
                    .frame(width: 24, height: 24)
            }
    #if os(visionOS)
            .backportGlassEffect(.regular, in: .circle)
    #else
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
    #endif
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabWidth(for availableWidth: CGFloat) -> CGFloat {
        guard !viewModel.tabs.isEmpty else {
            return minimumTabWidth
        }

        let totalSpacing = theme.spacing.xs * CGFloat(max(0, viewModel.tabs.count - 1))
        let rawWidth = (availableWidth - totalSpacing - 4) / CGFloat(viewModel.tabs.count)
        return max(minimumTabWidth, rawWidth)
    }
}

#if os(macOS)
private struct WindowDragGestureShield<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> WindowDragGestureShieldNSView<Content> {
        WindowDragGestureShieldNSView(rootView: content)
    }

    func updateNSView(_ nsView: WindowDragGestureShieldNSView<Content>, context: Context) {
        nsView.update(rootView: content)
    }
}

private final class WindowDragGestureShieldNSView<Content: View>: NSView {
    private let hostingView: WindowDragGestureShieldHostingView<Content>

    override var mouseDownCanMoveWindow: Bool { false }

    init(rootView: Content) {
        hostingView = WindowDragGestureShieldHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(rootView: Content) {
        hostingView.rootView = rootView
    }
}

private final class WindowDragGestureShieldHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct MiddleClickCloseArea: NSViewRepresentable {
    let onMiddleClick: @MainActor () -> Void

    func makeNSView(context: Context) -> MiddleClickCloseNSView {
        let view = MiddleClickCloseNSView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCloseNSView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickCloseNSView: NSView {
    var onMiddleClick: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else {
            return nil
        }

        guard event.buttonNumber == 2 else { return nil }
        switch event.type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return self
        default:
            return nil
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }

        guard let onMiddleClick else {
            return
        }

        Task { @MainActor in
            onMiddleClick()
        }
    }
}
#endif

#Preview {
    @Previewable @State var viewModel = MainViewModel(
        endpoint: .direct(baseURL: .debugURL),
        settings: ClientSettings(),
        connectionMonitor: ConnectionMonitor(baseURL: .debugURL),
        onOpenSettings: { _ in },
        onOpenWorkspace: {}
    )

    viewModel.tabs = [
        .init(key: .chatSession(""), kind: .chat, title: "ewfe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewfwefqwef", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
        .init(key: .chatSession(""), kind: .chat, title: "ewqwefqweffe", payload: .chatSession(sessionID: "", title: "")),
    ]

    return DesktopWorkspaceTabStrip(
        viewModel: viewModel
    )
    .frame(width: 700)
#if os(visionOS)
    .backportGlassEffect(.regular, in: .rect)
#endif
}
