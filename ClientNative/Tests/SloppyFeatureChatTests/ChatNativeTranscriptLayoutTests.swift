#if os(macOS)
import AppKit
import SwiftUI
import Testing
import SloppyUITestSupport
import SloppyClientCore
import SloppyClientUI
@testable import SloppyFeatureChat

@Suite("Native transcript layout", .serialized, .appKitUI, .appKitIsolation)
@MainActor
struct ChatNativeTranscriptLayoutTests {
    @Test("upper-edge loading ignores positioning and prepending preserves the visible message")
    func historyLoadingKeepsViewport() async throws {
        _ = NSApplication.shared
        var requests = 0
        func transcript(_ range: Range<Int>) -> AppKitChatTranscriptCollection {
            let items = [ChatTranscriptNativeItem(id: "reveal-earlier", content: .historyLoading(isLoading: false, error: nil))]
                + range.map { index in
                    ChatTranscriptNativeItem(id: "entry:msg-\(index)", content: .entry(
                        .message(ChatMessage(id: "msg-\(index)", role: .user,
                                             segments: [.init(kind: .text, text: "\(index)")])),
                        bottomSpacing: 0, activeMessageIDs: [], providerRecoveryMessageIDs: []
                    ))
                }
            return AppKitChatTranscriptCollection(
                items: items, contentWidth: 400, topInset: 0, bottomInset: 0,
                scrollToEndRequest: 0, renderRevision: UInt(range.count), reduceMotion: true,
                onReachedTop: { requests += 1 },
                renderer: { item in
                    AnyView(Text(item.id).frame(height: item.id == "reveal-earlier" ? 32 : 70))
                }
            )
        }
        let host = NSHostingView(rootView: transcript(0..<64))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: host))
        let collection = try #require(scroll.documentView as? NSCollectionView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(30))
        #expect(requests == 0)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(30))
        #expect(requests == 1)
        let before = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame.minY
            - scroll.contentView.bounds.minY
        host.rootView = transcript(-64..<64)
        try await Task.sleep(for: .milliseconds(150))
        let after = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 65, section: 0))).frame.minY
            - scroll.contentView.bounds.minY
        #expect(abs(after - before) <= 1)
        #expect(requests == 1)
    }

    @Test("preferred height follows content growth and shrinkage")
    func preferredHeightFollowsContent() {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 480, height: 100)

        for height: CGFloat in [40, 360, 80] {
            item.configure(rootView: AnyView(Color.clear.frame(width: 480, height: height)))
            let fitted = item.preferredLayoutAttributesFitting(attributes)
            #expect(abs(fitted.size.height - height) <= 1)
            #expect(fitted.size.width == 480)
            #expect(attributes.size.height == 100)
        }
    }

    @Test("stable transcript rows reuse their measured height")
    func stableTranscriptRowsReuseMeasuredHeight() {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 480, height: 100)

        item.configure(
            rootView: AnyView(Color.clear.frame(width: 480, height: 120)),
            measurementKey: "message-1"
        )
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height == 120)
        #expect(item.synchronousMeasurementPasses == 1)

        for _ in 0..<5 {
            #expect(item.preferredLayoutAttributesFitting(attributes).size.height == 120)
        }
        #expect(item.synchronousMeasurementPasses == 1)

        item.configure(
            rootView: AnyView(Color.clear.frame(width: 480, height: 80)),
            measurementKey: "message-2"
        )
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height == 80)
        #expect(item.synchronousMeasurementPasses == 2)
    }

    @Test("streaming updates preserve the hosting view")
    func streamingPreservesHostingView() throws {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        item.configure(rootView: AnyView(Text("First").frame(width: 400)))
        let original = try #require(item.view.subviews.first)
        for count in 1...100 {
            item.configure(rootView: AnyView(Text(String(repeating: "More text ", count: count)).frame(width: 400)))
        }
        #expect(item.view.subviews.count == 1)
        #expect(item.view.subviews.first === original)
    }

    @Test("agent tint arriving later refreshes an unchanged user message")
    func lateAgentTintRefreshesUserMessage() async throws {
        _ = NSApplication.shared
        let message = ChatMessage(id: "user", role: .user,
                                  segments: [.init(kind: .text, text: "Привет, как ты?")])
        var renderCount = 0
        func parent(paletteID: String?, revision: UInt, presentationRevision: UInt) -> AppKitChatTranscriptCollection {
            AppKitChatTranscriptCollection(
                items: [.init(id: "entry:user", content: .entry(
                    .message(message), bottomSpacing: 0,
                    activeMessageIDs: [], providerRecoveryMessageIDs: []
                ))],
                contentWidth: 400, topInset: 0, bottomInset: 0,
                scrollToEndRequest: 0, renderRevision: revision,
                presentationRevision: presentationRevision, reduceMotion: true
            ) { _ in
                renderCount += 1
                return AnyView(ChatBubbleView(
                    message: message,
                    userBubbleTint: paletteID.map {
                        Color.fromHex(AgentBotIdentity.palette(for: "agent", paletteID: $0).body)
                    }
                ))
            }
        }
        let initial = parent(paletteID: nil, revision: 1, presentationRevision: 0)
        let coordinator = initial.makeCoordinator()
        let collection = NSCollectionView()
        collection.collectionViewLayout = AppKitChatTranscriptLayout()
        collection.register(AppKitHostedTranscriptItem.self,
                            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = collection
        scroll.hasVerticalScroller = false
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        coordinator.collectionView = collection
        coordinator.scrollView = scroll
        coordinator.installDataSource(on: collection)
        coordinator.update(parent: initial, initial: true)
        for _ in 0..<6 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        coordinator.updateCollectionWidth()
        let path = IndexPath(item: 0, section: 0)
        let row = try #require(collection.item(at: path))
        let hostingView = try #require(row.view.subviews.first)
        let initialRenderCount = renderCount

        // A stream/status revision alone must leave this unchanged row alone.
        coordinator.update(parent: parent(paletteID: nil, revision: 2, presentationRevision: 0), initial: false)
        #expect(renderCount == initialRenderCount)

        for (index, palette) in ["lime", "violet"].enumerated() {
            coordinator.update(parent: parent(paletteID: palette, revision: 2,
                                              presentationRevision: UInt(index + 1)), initial: false)
            for _ in 0..<6 {
                await Task.yield()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            #expect(renderCount == initialRenderCount + index + 1)
            #expect(collection.item(at: path) === row)
            #expect(row.view.subviews.first === hostingView)
            if let output = ProcessInfo.processInfo.environment["SLOPPY_AGENT_BUBBLE_PROOF_DIR"] {
                let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("bubble-\(palette).png"))
            }
        }
    }

    enum WorkerCardPresentation: String, CaseIterable {
        case transcript, notch, standalone
    }

    @Test("worker cards receive the model across native hosting boundaries", arguments: WorkerCardPresentation.allCases)
    func workerCardsReceiveModel(presentation: WorkerCardPresentation) async throws {
        AppKitTestAccessibility.enable()
        let api = SloppyAPIClient(baseURL: try #require(URL(string: "https://worker-cards.invalid")),
                                  authSessionStore: AuthSessionStore(persistence: .memory))
        let model = ChatScreenViewModel(
            apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
            settings: ClientSettings(), connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
            restoresLastSession: false, responseNotificationScheduler: WorkerCardTestNotifications(),
            onOpenSettings: { _ in }
        )
        var attempt = LongChatAttempt(number: 1)
        attempt.sessionId = "worker-session"
        attempt.status = .running
        let task = LongChatTask(id: "delegated-task", key: "task", title: "Inspect the project",
                                objective: "Inspect", projectId: nil, resourceKeys: [],
                                dependsOn: [], attempts: [attempt])
        var taskMessage = ChatMessage(id: "task-event", role: .system, segments: [])
        taskMessage.longChatTask = .init(assignmentId: "assignment", task: task, reason: "started")
        var workerMessage = ChatMessage(id: "worker-event", role: .system, segments: [])
        workerMessage.workerSession = .init(childSessionId: "child-session", title: "Parallel inspection")
        model.transcript.replaceAll([taskMessage, workerMessage])
        let pane = ChatTranscriptPane(
            viewModel: model, transcript: model.transcript, isLoadingTranscript: false,
            scrollToEndRequest: 0, contentWidth: 560, messagesTopInset: 0, composerScrollInset: 0,
            showsThinkingIndicator: false, isRunActive: false, runStatusLabel: "", runStatusDetails: nil,
            workingTreeSourceControl: nil, inputRequest: nil, isSubmittingInputResponse: false,
            inputRequestErrorMessage: nil, providerSettingsRecoveryMessageIDs: [],
            onSubmitInputResponse: { _ in }, onCancelInputRequest: {},
            onForkFromMessage: { _ in }, onOpenProviderSettings: {}
        )
        let content: AnyView
        switch presentation {
        case .transcript:
            content = AnyView(pane)
        case .notch:
            content = AnyView(NotchChatView(viewModel: model, agentID: "agent", agentName: "Agent", isPresented: false))
        case .standalone:
            let event = try #require(taskMessage.longChatTask)
            let child = try #require(workerMessage.workerSession)
            content = AnyView(VStack {
                LongChatWorkerCard(event: event, viewModel: model)
                ChatWorkerSessionCard(child: child, viewModel: model)
                ChatWorkerActivityCard(viewModel: model)
            })
        }
        // These standalone roots deliberately have no observable model in their
        // environment. Worker cards must receive the owning model explicitly.
        let host = NSHostingView(rootView: content
            .environment(\.theme, .sloppyDark).background(Theme.sloppyDark.colors.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        #expect(AppKitTestAccessibility.element(in: host, identifier: "long-chat.task.delegated-task") != nil)
        #expect(AppKitTestAccessibility.element(in: host, identifier: "chat.worker.child-session") != nil)
        if let output = ProcessInfo.processInfo.environment["SLOPPY_WORKER_CARD_PROOF_DIR"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(presentation.rawValue)-workers.png"))
        }
    }

    @Test("collection updates keep row identity and lay out growing rows without overlap")
    func collectionStreamingLayout() async throws {
        _ = NSApplication.shared
        func parent(height: Int, revision: UInt) -> AppKitChatTranscriptCollection {
            AppKitChatTranscriptCollection(
                items: [
                    ChatTranscriptNativeItem(id: "first", content: .revealEarlier(count: height)),
                    ChatTranscriptNativeItem(id: "second", content: .revealEarlier(count: 60)),
                ],
                contentWidth: 400, topInset: 0, bottomInset: 0,
                scrollToEndRequest: 0, renderRevision: revision, reduceMotion: true
            ) { item in
                if case .revealEarlier(let height) = item.content {
                    return AnyView(Color.clear.frame(height: CGFloat(height)))
                }
                return AnyView(EmptyView())
            }
        }
        let initial = parent(height: 80, revision: 1)
        let coordinator = initial.makeCoordinator()
        let layout = AppKitChatTranscriptLayout()
        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.register(AppKitHostedTranscriptItem.self,
                            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        scroll.documentView = collection
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        coordinator.collectionView = collection
        coordinator.scrollView = scroll
        coordinator.installDataSource(on: collection)
        coordinator.update(parent: initial, initial: true)
        for _ in 0..<4 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let firstPath = IndexPath(item: 0, section: 0)
        let secondPath = IndexPath(item: 1, section: 0)
        let first = try #require(collection.item(at: firstPath))
        coordinator.update(parent: parent(height: 300, revision: 2), initial: false)
        for _ in 0..<4 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(collection.item(at: firstPath) === first)
        let firstFrame = try #require(layout.layoutAttributesForItem(at: firstPath)).frame
        let secondFrame = try #require(layout.layoutAttributesForItem(at: secondPath)).frame
        #expect(firstFrame.height >= 300)
        #expect(secondFrame.minY >= firstFrame.maxY - 0.5)
    }

    @Test("streaming growth preserves the reader's visible row")
    func streamingGrowthPreservesVisibleRow() async throws {
        _ = NSApplication.shared
        func parent(firstHeight: Int, revision: UInt) -> AppKitChatTranscriptCollection {
            AppKitChatTranscriptCollection(
                items: [firstHeight, 200, 200, 200].enumerated().map { index, height in
                    ChatTranscriptNativeItem(id: "row-\(index)", content: .revealEarlier(count: height))
                },
                contentWidth: 400, topInset: 0, bottomInset: 0,
                scrollToEndRequest: 0, renderRevision: revision, reduceMotion: true
            ) { item in
                guard case .revealEarlier(let height) = item.content else { return AnyView(EmptyView()) }
                return AnyView(Color.clear.frame(height: CGFloat(height)))
            }
        }

        let initial = parent(firstHeight: 200, revision: 1)
        let coordinator = initial.makeCoordinator()
        let layout = AppKitChatTranscriptLayout()
        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.register(AppKitHostedTranscriptItem.self,
                            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = collection
        scroll.contentView.postsBoundsChangedNotifications = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer {
            coordinator.stopObservingScroll()
            window.contentView = nil
        }
        coordinator.collectionView = collection
        coordinator.scrollView = scroll
        coordinator.installDataSource(on: collection)
        coordinator.startObservingScroll()
        coordinator.update(parent: initial, initial: true)
        for _ in 0..<6 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        await Task.yield()
        let secondPath = IndexPath(item: 1, section: 0)
        let oldFrame = try #require(layout.layoutAttributesForItem(at: secondPath)).frame
        let oldOffset = oldFrame.minY - scroll.contentView.bounds.minY

        coordinator.update(parent: parent(firstHeight: 400, revision: 2), initial: false)
        for _ in 0..<8 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        let newFrame = try #require(layout.layoutAttributesForItem(at: secondPath)).frame
        let newOffset = newFrame.minY - scroll.contentView.bounds.minY
        #expect(abs(newOffset - oldOffset) <= 1)
    }

    @Test("opening history holds its position while a live reply follows the bottom", arguments: [false, true])
    func automaticBottomFollowRequiresLiveReply(followsLiveTail: Bool) async throws {
        _ = NSApplication.shared
        func parent(lastHeight: Int, revision: UInt) -> AppKitChatTranscriptCollection {
            AppKitChatTranscriptCollection(
                items: [200, 200, lastHeight].enumerated().map { index, height in
                    ChatTranscriptNativeItem(id: "row-\(index)", content: .revealEarlier(count: height))
                },
                contentWidth: 400, topInset: 0, bottomInset: 80,
                scrollToEndRequest: 0,
                autoFollowChangingTail: followsLiveTail,
                renderRevision: revision, reduceMotion: true
            ) { item in
                guard case .revealEarlier(let height) = item.content else { return AnyView(EmptyView()) }
                return AnyView(Color.clear.frame(height: CGFloat(height)))
            }
        }

        let initial = parent(lastHeight: 100, revision: 1)
        let coordinator = initial.makeCoordinator()
        let layout = AppKitChatTranscriptLayout()
        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.register(AppKitHostedTranscriptItem.self,
                            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = collection
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        coordinator.collectionView = collection
        coordinator.scrollView = scroll
        coordinator.installDataSource(on: collection)
        coordinator.update(parent: initial, initial: true)
        for _ in 0..<6 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let initialOrigin = scroll.contentView.bounds.minY

        coordinator.update(parent: parent(lastHeight: 260, revision: 2), initial: false)
        coordinator.update(parent: parent(lastHeight: 520, revision: 3), initial: false)
        for _ in 0..<10 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        let contentHeight = layout.collectionViewContentSize.height
        let bottomGap = contentHeight + 80 - scroll.contentView.bounds.maxY
        if followsLiveTail {
            #expect(abs(bottomGap) <= 1)
            let lastFrame = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame
            #expect(lastFrame.height >= 520)
        } else {
            #expect(abs(scroll.contentView.bounds.minY - initialOrigin) <= 1)
            #expect(bottomGap > 100)
        }
    }

    @Test("streamed markdown and code blocks grow without retaining the previous height")
    func markdownGrowth() async {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 400, height: 100)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = item.view
        defer { window.contentView = nil }
        var heights: [CGFloat] = []
        for count in [1, 20, 40] {
            let text = "## Response\n\n" + String(repeating: "A paragraph of **streaming** text.\n\n", count: count)
                + "```swift\nlet answer = 42\n```"
            let message = ChatMessage(id: "streaming-assistant-test", role: .assistant,
                                      segments: [ChatMessageSegment(kind: .text, text: text)])
            item.configure(rootView: AnyView(ChatBubbleView(message: message)
                .frame(width: 400).fixedSize(horizontal: false, vertical: true)))
            // Textual publishes parsed markdown asynchronously after the view mounts.
            for _ in 0..<30 {
                item.view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            heights.append(item.preferredLayoutAttributesFitting(attributes).size.height)
        }
        #expect(heights[1] > heights[0])
        #expect(heights[2] > heights[1])
    }

    @Test("history with a message taller than the viewport can scroll in both directions")
    func oversizedMessageScrolls() async throws {
        _ = NSApplication.shared
        let transcript = AppKitChatTranscriptCollection(
            items: [
                ChatTranscriptNativeItem(id: "first", content: .revealEarlier(count: 100)),
                ChatTranscriptNativeItem(id: "long", content: .revealEarlier(count: 1800)),
                ChatTranscriptNativeItem(id: "last", content: .revealEarlier(count: 100)),
            ],
            contentWidth: 400, topInset: 24, bottomInset: 120,
            scrollToEndRequest: 0, renderRevision: 1, reduceMotion: true
        ) { item in
            guard case .revealEarlier(let height) = item.content else { return AnyView(EmptyView()) }
            return AnyView(Text("Message").frame(height: CGFloat(height)))
        }
        let host = NSHostingView(rootView: transcript)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<10 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView as? NSCollectionView)
        #expect(scroll.bounds.height <= 400)
        #expect(document.frame.height >= 2000)
        #expect(scroll.contentView.bounds.maxY - scroll.contentInsets.bottom >= document.frame.height - 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY >= 590)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.contentView.bounds.minY) <= 1)

        host.frame.size.width = 620
        for _ in 0..<6 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        #expect(abs(document.frame.width - scroll.contentSize.width) <= 1)
        #expect(document.frame.height >= 2000)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY >= 590)
    }

    @Test("final assistant has readable content before background Markdown parsing")
    func finalAssistantFirstLayout() {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let text = String(repeating: "A complete paragraph in the final response.\n\n", count: 10)
        let message = ChatMessage(id: "final-answer", role: .assistant,
                                  segments: [ChatMessageSegment(kind: .text, text: text)])
        item.configure(rootView: AnyView(ChatBubbleView(message: message)
            .frame(width: 400).fixedSize(horizontal: false, vertical: true)))
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 400, height: 100)
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height > 180)
    }

    @Test("final assistant Markdown is visible after streaming ends", arguments: [0, 40], [false, true])
    func finalAssistantMarkdownIsVisible(historyCount: Int, includesActivity: Bool) async throws {
        _ = NSApplication.shared
        let text = """
        Закрепил в постоянной памяти проекта **Promozavr**:

        > Каждая новая задача из канбана выполняется в отдельном WT. До начала изменений создаём или безопасно переиспользуем worktree этой задачи; все изменения и проверки выполняем внутри него.

        Здесь используется **Arcadia worktree через `ya tool kek wt`**, не Git worktree. Требование буду включать в описания новых задач и инструкции исполнителям.

        Текущие задачи задним числом не переносим. Это сохранённое правило работы, не автоматическая блокировка со стороны канбана.
        """
        func transcript(final: Bool) -> AppKitChatTranscriptCollection {
            let message = ChatMessage(
                id: final ? "final-answer" : "streaming-assistant-answer",
                role: .assistant,
                segments: [ChatMessageSegment(kind: .text, text: final ? text : "Закрепил")]
            )
            let activityItems: [ChatTranscriptNativeItem] = final && includesActivity ? [
                .init(id: "activity", content: .entry(.systemGroup([
                    .init(id: "thinking", role: .assistant, segments: [.init(kind: .thinking, text: "Reasoning")]),
                ]), bottomSpacing: 24, activeMessageIDs: [], providerRecoveryMessageIDs: [])),
            ] : []
            return AppKitChatTranscriptCollection(
                items: (0..<historyCount).map { index in
                    let prior = ChatMessage(id: "history-\(index)", role: .assistant,
                                            segments: [ChatMessageSegment(kind: .text, text: text)])
                    return ChatTranscriptNativeItem(
                        id: prior.id, content: .entry(.message(prior), bottomSpacing: 24,
                                                     activeMessageIDs: [], providerRecoveryMessageIDs: [])
                    )
                } + activityItems + [ChatTranscriptNativeItem(
                    id: message.id,
                    content: .entry(.message(message), bottomSpacing: 0,
                                    activeMessageIDs: [], providerRecoveryMessageIDs: [])
                )],
                contentWidth: 600, topInset: 0, bottomInset: 0,
                scrollToEndRequest: 0, renderRevision: final ? 2 : 1, reduceMotion: true
            ) { item in
                switch item.content {
                case .entry(.message(let message), _, _, _):
                    return AnyView(ChatBubbleView(message: message))
                case .entry(.systemGroup(let messages), _, _, _):
                    return AnyView(ChatSystemMessageGroupView(messages: messages))
                default:
                    return AnyView(EmptyView())
                }
            }
        }
        let host = NSHostingView(rootView: transcript(final: false))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        host.rootView = transcript(final: true)
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        func collection(in view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let collection = try #require(collection(in: host))
        let attributes = try #require(collection.collectionViewLayout?.layoutAttributesForItem(
            at: IndexPath(item: historyCount + (includesActivity ? 1 : 0), section: 0)
        ))
        // The full response needs multiple paragraphs; an actions-only row is ~40pt.
        #expect(attributes.size.height > 180)
    }

    @Test("wrapped text reports its full height")
    func wrappedTextHeight() {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 300, height: 100)
        item.configure(rootView: AnyView(Text("Short").frame(width: 300).fixedSize(horizontal: false, vertical: true)))
        let shortHeight = item.preferredLayoutAttributesFitting(attributes).size.height
        item.configure(rootView: AnyView(Text(String(repeating: "A line of streamed text.\n", count: 40))
            .frame(width: 300).fixedSize(horizontal: false, vertical: true)))
        let longHeight = item.preferredLayoutAttributesFitting(attributes).size.height
        #expect(longHeight > shortHeight * 20)
    }

    @Test("a changed message invalidates its cached height without replacing the hosting view")
    func changedMessageRemeasuresHeight() throws {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 400, height: 100)
        item.configure(rootView: AnyView(Color.clear.frame(height: 80)), measurementKey: "message")
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height == 80)
        let original = try #require(item.view.subviews.first)

        item.configure(
            rootView: AnyView(Color.clear.frame(height: 320)),
            measurementKey: "message", requiresMeasurement: true
        )
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height == 320)
        #expect(item.synchronousMeasurementPasses == 2)
        #expect(item.view.subviews.first === original)
    }

    @Test("a changed proposal width remeasures wrapped text")
    func changedWidthRemeasuresHeight() {
        let item = AppKitHostedTranscriptItem()
        item.loadView()
        item.configure(
            rootView: AnyView(Text(String(repeating: "Wrapped transcript text. ", count: 20))
                .fixedSize(horizontal: false, vertical: true)),
            measurementKey: "message"
        )
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.size = NSSize(width: 400, height: 100)
        let wideHeight = item.preferredLayoutAttributesFitting(attributes).size.height
        attributes.size.width = 160
        let narrowHeight = item.preferredLayoutAttributesFitting(attributes).size.height
        #expect(narrowHeight > wideHeight)
        #expect(item.synchronousMeasurementPasses == 2)
        #expect(item.preferredLayoutAttributesFitting(attributes).size.height == narrowHeight)
        #expect(item.synchronousMeasurementPasses == 2)
    }

    @Test("returning to measured history does not synchronously measure recycled rows again")
    func recycledRowsReuseTranscriptMeasurements() async throws {
        let fixture = TranscriptFixture(heights: Array(repeating: 140, count: 40))
        defer { fixture.close() }
        await fixture.settle()
        let last = IndexPath(item: 39, section: 0)
        #expect(fixture.collection.item(at: last) != nil)

        fixture.collection.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
        await fixture.settle()
        let measurementsBeforeReturn = fixture.collection.measurementPasses
        fixture.collection.scrollToItems(at: [last], scrollPosition: .bottom)
        await fixture.settle()

        #expect(fixture.collection.item(at: last) != nil)
        #expect(fixture.collection.measurementPasses == measurementsBeforeReturn)
        #expect(fixture.layout.layoutAttributesForItem(at: last)?.size.height == 140)
    }

    @Test("height notifications coalesce and invalidate only affected rows")
    func heightUpdatesInvalidateOnlyAffectedRows() async throws {
        let fixture = TranscriptFixture(heights: [80, 80, 80])
        defer { fixture.close() }
        await fixture.settle()
        let first = try #require(fixture.collection.item(at: IndexPath(item: 0, section: 0))
            as? AppKitHostedTranscriptItem)
        let second = try #require(fixture.collection.item(at: IndexPath(item: 1, section: 0))
            as? AppKitHostedTranscriptItem)
        let third = try #require(fixture.collection.item(at: IndexPath(item: 2, section: 0))
            as? AppKitHostedTranscriptItem)
        let unchangedMeasurements = third.synchronousMeasurementPasses
        fixture.layout.rowInvalidations.removeAll()
        first.onHeightChange?()
        first.onHeightChange?()
        second.onHeightChange?()
        await fixture.settle()

        #expect(fixture.layout.rowInvalidations.first ==
            [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)])
        #expect(third.synchronousMeasurementPasses == unchangedMeasurements)
    }

    @Test("a reader's live scroll cancels pending initial positioning")
    func readerScrollCancelsInitialPositioning() async {
        let fixture = TranscriptFixture(heights: Array(repeating: 140, count: 40))
        defer { fixture.close() }
        fixture.coordinator.startObservingScroll()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        fixture.scroll.contentView.scroll(to: .zero)
        await fixture.settle()
        #expect(abs(fixture.scroll.contentView.bounds.minY) <= 1)
    }
}

@MainActor
private final class TranscriptFixture {
    let collection = MeasuringTranscriptCollection()
    let layout = RecordingTranscriptLayout()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let window: NSWindow
    let coordinator: AppKitChatTranscriptCollection.Coordinator

    init(heights: [Int]) {
        _ = NSApplication.shared
        let transcript = AppKitChatTranscriptCollection(
            items: heights.enumerated().map { index, height in
                ChatTranscriptNativeItem(id: "row-\(index)", content: .revealEarlier(count: height))
            },
            contentWidth: 400, topInset: 0, bottomInset: 0,
            scrollToEndRequest: 0, autoFollowChangingTail: false,
            renderRevision: 1, reduceMotion: true
        ) { item in
            guard case .revealEarlier(let height) = item.content else { return AnyView(EmptyView()) }
            return AnyView(Color.clear.frame(height: CGFloat(height)))
        }
        coordinator = transcript.makeCoordinator()
        window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        collection.collectionViewLayout = layout
        collection.register(AppKitHostedTranscriptItem.self,
                            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier)
        scroll.documentView = collection
        window.contentView = scroll
        coordinator.collectionView = collection
        coordinator.scrollView = scroll
        coordinator.installDataSource(on: collection)
        coordinator.update(parent: transcript, initial: true)
    }

    func settle() async {
        for _ in 0..<12 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func close() {
        coordinator.stopObservingScroll()
        window.contentView = nil
    }
}

@MainActor
private final class MeasuringTranscriptCollection: NSCollectionView {
    private var hostedItems: [ObjectIdentifier: AppKitHostedTranscriptItem] = [:]

    var measurementPasses: Int {
        hostedItems.values.reduce(0) { $0 + $1.synchronousMeasurementPasses }
    }

    override func makeItem(withIdentifier identifier: NSUserInterfaceItemIdentifier, for indexPath: IndexPath)
        -> NSCollectionViewItem {
        let item = super.makeItem(withIdentifier: identifier, for: indexPath)
        if let hosted = item as? AppKitHostedTranscriptItem {
            hostedItems[ObjectIdentifier(hosted)] = hosted
        }
        return item
    }
}

@MainActor
private final class RecordingTranscriptLayout: AppKitChatTranscriptLayout {
    var rowInvalidations: [Set<IndexPath>] = []

    override func invalidateLayout(with context: NSCollectionViewLayoutInvalidationContext) {
        if let paths = context.invalidatedItemIndexPaths, !paths.isEmpty {
            rowInvalidations.append(paths)
        }
        super.invalidateLayout(with: context)
    }
}
@MainActor
private final class WorkerCardTestNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
#endif
