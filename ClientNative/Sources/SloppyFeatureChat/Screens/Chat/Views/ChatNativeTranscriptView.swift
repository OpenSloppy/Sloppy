import Foundation
import SwiftUI
import SloppyClientCore

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ChatTranscriptNativeItem: Identifiable, Equatable {
    enum Content: Equatable {
        case revealEarlier(count: Int)
        case historyLoading(isLoading: Bool, error: String?)
        case dateSeparator(Date)
        case entry(
            ChatTranscriptEntry,
            bottomSpacing: CGFloat,
            activeMessageIDs: Set<ChatMessage.ID>,
            providerRecoveryMessageIDs: Set<ChatMessage.ID>
        )
        case changeSummary(ProjectWorkingTreeSourceControlResponse)
        case thinking(label: String, details: String?)
        case inputRequest(
            request: ChatPlanInputRequest,
            isSubmitting: Bool,
            errorMessage: String?
        )
    }

    let id: String
    let content: Content
}

@MainActor
struct ChatNativeTranscriptView: View {
    let items: [ChatTranscriptNativeItem]
    let contentWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let scrollToEndRequest: Int
    let autoFollowAppendedItems: Bool
    let autoFollowChangingTail: Bool
    let scrollTarget: ChatTranscriptScrollTarget?
    let renderRevision: UInt
    var presentationRevision: UInt = 0
    let reduceMotion: Bool
    let onVisibleItemChange: @MainActor (String?) -> Void
    var onReachedTop: @MainActor () -> Void = {}
    let renderer: @MainActor (ChatTranscriptNativeItem) -> AnyView

    var body: some View {
        #if os(macOS)
        AppKitChatTranscriptCollection(
            items: items,
            contentWidth: contentWidth,
            topInset: topInset,
            bottomInset: bottomInset,
            scrollToEndRequest: scrollToEndRequest,
            autoFollowAppendedItems: autoFollowAppendedItems,
            autoFollowChangingTail: autoFollowChangingTail,
            scrollTarget: scrollTarget,
            renderRevision: renderRevision,
            presentationRevision: presentationRevision,
            reduceMotion: reduceMotion,
            onVisibleItemChange: onVisibleItemChange,
            onReachedTop: onReachedTop,
            renderer: renderer
        )
        #else
        UIKitChatTranscriptCollection(
            items: items,
            contentWidth: contentWidth,
            topInset: topInset,
            bottomInset: bottomInset,
            scrollToEndRequest: scrollToEndRequest,
            scrollTarget: scrollTarget,
            renderRevision: renderRevision,
            reduceMotion: reduceMotion,
            onVisibleItemChange: onVisibleItemChange,
            onReachedTop: onReachedTop,
            renderer: renderer
        )
        #endif
    }
}

/// Layout and programmatic scrolling must never trigger history downloads.
struct ChatHistoryScrollTrigger {
    private var didTrigger = false

    mutating func didScroll(distanceFromTop: CGFloat, isUserInitiated: Bool) -> Bool {
        if distanceFromTop > 120 { didTrigger = false }
        guard isUserInitiated, distanceFromTop <= 80, !didTrigger else { return false }
        didTrigger = true
        return true
    }
}

#if canImport(UIKit) && !os(macOS)
private struct UIKitChatTranscriptCollection: UIViewRepresentable {
    let items: [ChatTranscriptNativeItem]
    let contentWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let scrollToEndRequest: Int
    let scrollTarget: ChatTranscriptScrollTarget?
    let renderRevision: UInt
    let reduceMotion: Bool
    let onVisibleItemChange: @MainActor (String?) -> Void
    let onReachedTop: @MainActor () -> Void
    let renderer: @MainActor (ChatTranscriptNativeItem) -> AnyView

    init(
        items: [ChatTranscriptNativeItem],
        contentWidth: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        scrollToEndRequest: Int,
        scrollTarget: ChatTranscriptScrollTarget? = nil,
        renderRevision: UInt,
        reduceMotion: Bool,
        onVisibleItemChange: @escaping @MainActor (String?) -> Void = { _ in },
        onReachedTop: @escaping @MainActor () -> Void = {},
        renderer: @escaping @MainActor (ChatTranscriptNativeItem) -> AnyView
    ) {
        self.items = items
        self.contentWidth = contentWidth
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.scrollToEndRequest = scrollToEndRequest
        self.scrollTarget = scrollTarget
        self.renderRevision = renderRevision
        self.reduceMotion = reduceMotion
        self.onVisibleItemChange = onVisibleItemChange
        self.onReachedTop = onReachedTop
        self.renderer = renderer
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(100)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        #if !os(visionOS)
        collectionView.keyboardDismissMode = .interactive
        #endif
        collectionView.showsVerticalScrollIndicator = true
        collectionView.delegate = context.coordinator
        context.coordinator.installDataSource(on: collectionView)
        context.coordinator.update(parent: self, collectionView: collectionView, initial: true)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(parent: self, collectionView: collectionView, initial: false)
    }

    static func dismantleUIView(_ collectionView: UICollectionView, coordinator: Coordinator) {
        collectionView.delegate = nil
        coordinator.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: UIKitChatTranscriptCollection
        var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var itemByID: [String: ChatTranscriptNativeItem] = [:]
        private var previousItems: [ChatTranscriptNativeItem] = []
        private var previousContentWidth: CGFloat = 0
        private var previousTopInset: CGFloat = 0
        private var previousBottomInset: CGFloat = 0
        private var previousScrollRequest: Int?
        private var previousScrollTarget: ChatTranscriptScrollTarget?
        private var previousRenderRevision: UInt?
        private var cellRegistration: UICollectionView.CellRegistration<UICollectionViewCell, String>?
        private var visibleItemID: String?
        private var historyScrollTrigger = ChatHistoryScrollTrigger()

        init(parent: UIKitChatTranscriptCollection) {
            self.parent = parent
        }

        func installDataSource(on collectionView: UICollectionView) {
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> {
                [weak self] cell, _, itemID in
                guard let self, let item = self.itemByID[itemID] else { return }
                cell.backgroundColor = .clear
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        self.parent.renderer(item)
                            .frame(width: self.parent.contentWidth)
                        Spacer(minLength: 0)
                    }
                }
                .margins(.all, 0)
            }
            cellRegistration = registration
            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
                collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: registration,
                    for: indexPath,
                    item: itemID
                )
            }
        }

        func update(
            parent: UIKitChatTranscriptCollection,
            collectionView: UICollectionView,
            initial: Bool
        ) {
            let wasNearBottom = isNearBottom(collectionView)
            let oldContentHeight = collectionView.contentSize.height
            let oldOffset = collectionView.contentOffset
            let oldTopInset = previousTopInset
            let viewportAnchor = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (id: String, offset: CGFloat, y: CGFloat)? in
                guard let id = dataSource?.itemIdentifier(for: indexPath), id.hasPrefix("entry:"),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
                return (id, attributes.frame.minY - oldOffset.y, attributes.frame.minY)
            }.min { $0.y < $1.y }
            let didPrepend = didPrependItems(from: previousItems, to: parent.items)
            let explicitScroll = previousScrollRequest != parent.scrollToEndRequest
            let targetedScroll = previousScrollTarget != parent.scrollTarget
            let contentChanged = previousRenderRevision != parent.renderRevision
            let widthChanged = abs(previousContentWidth - parent.contentWidth) > 0.5
            let bottomInsetChanged = abs(previousBottomInset - parent.bottomInset) > 0.5

            self.parent = parent
            itemByID = Dictionary(uniqueKeysWithValues: parent.items.map { ($0.id, $0) })
            collectionView.contentInset = UIEdgeInsets(
                top: parent.topInset,
                left: 0,
                bottom: parent.bottomInset,
                right: 0
            )
            collectionView.verticalScrollIndicatorInsets = collectionView.contentInset

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(parent.items.map(\.id), toSection: 0)
            if !initial {
                let oldByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
                let changedIDs = parent.items.compactMap { item -> String? in
                    guard let oldItem = oldByID[item.id], oldItem != item else { return nil }
                    return item.id
                }
                var reloadableIDs = Set(changedIDs.filter { snapshot.indexOfItem($0) != nil })
                if widthChanged {
                    reloadableIDs.formUnion(parent.items.map(\.id))
                }
                if !reloadableIDs.isEmpty {
                    snapshot.reconfigureItems(Array(reloadableIDs))
                }
            }

            dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                collectionView.layoutIfNeeded()
                if didPrepend {
                    if let viewportAnchor,
                       let indexPath = self.dataSource?.indexPath(for: viewportAnchor.id),
                       let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                        collectionView.contentOffset = CGPoint(x: oldOffset.x, y: attributes.frame.minY - viewportAnchor.offset)
                    } else {
                        let delta = collectionView.contentSize.height - oldContentHeight
                        let topInsetDelta = parent.topInset - oldTopInset
                        collectionView.contentOffset = CGPoint(x: oldOffset.x, y: oldOffset.y + delta + topInsetDelta)
                    }
                } else if targetedScroll, let target = parent.scrollTarget {
                    self.scroll(to: target.itemID, in: collectionView, animated: !parent.reduceMotion)
                } else if explicitScroll || (wasNearBottom && (contentChanged || bottomInsetChanged)) || initial {
                    self.scrollToBottom(
                        collectionView,
                        animated: explicitScroll && !initial && !parent.reduceMotion
                    )
                }
                self.updateVisibleItem(in: collectionView)
            }

            previousItems = parent.items
            previousContentWidth = parent.contentWidth
            previousTopInset = parent.topInset
            previousBottomInset = parent.bottomInset
            previousScrollRequest = parent.scrollToEndRequest
            previousScrollTarget = parent.scrollTarget
            previousRenderRevision = parent.renderRevision
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            updateVisibleItem(in: collectionView)
            if historyScrollTrigger.didScroll(
                distanceFromTop: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
                isUserInitiated: scrollView.isDragging || scrollView.isDecelerating
            ) {
                parent.onReachedTop()
            }
        }

        private func didPrependItems(
            from oldItems: [ChatTranscriptNativeItem],
            to newItems: [ChatTranscriptNativeItem]
        ) -> Bool {
            guard let oldFirst = oldItems.first(where: { $0.id.hasPrefix("entry:") }),
                  let oldIndex = oldItems.firstIndex(where: { $0.id == oldFirst.id }),
                  let newIndex = newItems.firstIndex(where: { $0.id == oldFirst.id }) else {
                return false
            }
            return newIndex > oldIndex
        }

        private func isNearBottom(_ collectionView: UICollectionView) -> Bool {
            guard collectionView.contentSize.height > 0 else { return true }
            let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height
            let contentBottom = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            return visibleBottom >= contentBottom - 44
        }

        private func scrollToBottom(_ collectionView: UICollectionView, animated: Bool) {
            collectionView.layoutIfNeeded()
            let y = max(
                -collectionView.adjustedContentInset.top,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }

        private func scroll(to itemID: String, in collectionView: UICollectionView, animated: Bool) {
            guard let indexPath = dataSource?.indexPath(for: itemID) else { return }
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
        }

        private func updateVisibleItem(in collectionView: UICollectionView) {
            let focusY = collectionView.contentOffset.y + min(collectionView.bounds.height * 0.25, 120)
            let visible = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (String, CGFloat)? in
                guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
                return (itemID, abs(attributes.frame.midY - focusY))
            }
            let nextID = visible.min { $0.1 < $1.1 }?.0
            guard nextID != visibleItemID else { return }
            visibleItemID = nextID
            parent.onVisibleItemChange(nextID)
        }
    }
}
#endif

#if os(macOS)
struct AppKitChatTranscriptCollection: NSViewRepresentable {
    let items: [ChatTranscriptNativeItem]
    let contentWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let scrollToEndRequest: Int
    let autoFollowAppendedItems: Bool
    let autoFollowChangingTail: Bool
    let scrollTarget: ChatTranscriptScrollTarget?
    let renderRevision: UInt
    let presentationRevision: UInt
    let reduceMotion: Bool
    let onVisibleItemChange: @MainActor (String?) -> Void
    let onReachedTop: @MainActor () -> Void
    let renderer: @MainActor (ChatTranscriptNativeItem) -> AnyView

    init(
        items: [ChatTranscriptNativeItem],
        contentWidth: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        scrollToEndRequest: Int,
        autoFollowAppendedItems: Bool = true,
        autoFollowChangingTail: Bool = true,
        scrollTarget: ChatTranscriptScrollTarget? = nil,
        renderRevision: UInt,
        presentationRevision: UInt = 0,
        reduceMotion: Bool,
        onVisibleItemChange: @escaping @MainActor (String?) -> Void = { _ in },
        onReachedTop: @escaping @MainActor () -> Void = {},
        renderer: @escaping @MainActor (ChatTranscriptNativeItem) -> AnyView
    ) {
        self.items = items
        self.contentWidth = contentWidth
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.scrollToEndRequest = scrollToEndRequest
        self.autoFollowAppendedItems = autoFollowAppendedItems
        self.autoFollowChangingTail = autoFollowChangingTail
        self.scrollTarget = scrollTarget
        self.renderRevision = renderRevision
        self.presentationRevision = presentationRevision
        self.reduceMotion = reduceMotion
        self.onVisibleItemChange = onVisibleItemChange
        self.onReachedTop = onReachedTop
        self.renderer = renderer
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = AppKitChatTranscriptLayout()
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(
            AppKitHostedTranscriptItem.self,
            forItemWithIdentifier: AppKitHostedTranscriptItem.identifier
        )

        let scrollView = AppKitChatTranscriptScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateCollectionWidth()
        }

        context.coordinator.collectionView = collectionView
        context.coordinator.scrollView = scrollView
        context.coordinator.installDataSource(on: collectionView)
        context.coordinator.startObservingScroll()
        context.coordinator.update(parent: self, initial: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self, initial: false)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingScroll()
        coordinator.dataSource = nil
        (scrollView as? AppKitChatTranscriptScrollView)?.onLayout = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: AppKitChatTranscriptCollection
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?
        var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var itemByID: [String: ChatTranscriptNativeItem] = [:]
        private var previousItems: [ChatTranscriptNativeItem] = []
        private var previousPresentationRevision: UInt?
        private var previousContentWidth: CGFloat = 0
        private var previousViewportWidth: CGFloat = 0
        private var previousTopInset: CGFloat = 0
        private var previousBottomInset: CGFloat = 0
        private var previousScrollRequest: Int?
        private var previousScrollTarget: ChatTranscriptScrollTarget?
        private var scrollObserver: NSObjectProtocol?
        private var liveScrollObserver: NSObjectProtocol?
        private var isNearBottom = true
        private var previousLayoutHeight: CGFloat = 0
        private var pendingScrollToEnd = false
        private var scrollToEndScheduled = false
        private var heightUpdateScheduled = false
        private var heightUpdateFollowsBottom = false
        private var pendingHeightUpdateIDs: Set<String> = []
        private var measuredRows: [String: MeasuredRow] = [:]
        private var parentUpdateGeneration: UInt = 0
        private var visibleItemID: String?
        private var historyScrollTrigger = ChatHistoryScrollTrigger()
        private var isUserScrolling = false
        private var liveScrollEndObserver: NSObjectProtocol?

        private struct MeasuredRow {
            let item: ChatTranscriptNativeItem
            let contentWidth: CGFloat
            let height: CGFloat
        }

        private struct ViewportAnchor {
            let followsBottom: Bool
            let itemID: String?
            let itemOffset: CGFloat
            let fallbackOrigin: NSPoint
        }

        init(parent: AppKitChatTranscriptCollection) {
            self.parent = parent
        }

        func installDataSource(on collectionView: NSCollectionView) {
            dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
                [weak self] collectionView, indexPath, itemID in
                guard let self,
                      let item = self.itemByID[itemID],
                      let hostedItem = collectionView.makeItem(
                        withIdentifier: AppKitHostedTranscriptItem.identifier,
                        for: indexPath
                      ) as? AppKitHostedTranscriptItem else {
                    return nil
                }
                self.configure(hostedItem, with: item)
                return hostedItem
            }
            (collectionView.collectionViewLayout as? AppKitChatTranscriptLayout)?.heightForItem = {
                [weak self] indexPath in
                guard let self,
                      let id = self.dataSource?.itemIdentifier(for: indexPath),
                      let item = self.itemByID[id] else { return nil }
                return self.cachedHeight(for: item) ?? self.measuredRows[id]?.height
            }
        }

        private func cachedHeight(for item: ChatTranscriptNativeItem) -> CGFloat? {
            guard let row = measuredRows[item.id], row.item == item,
                  abs(row.contentWidth - parent.contentWidth) <= 0.5 else {
                return nil
            }
            return row.height
        }

        private func configure(_ hostedItem: AppKitHostedTranscriptItem, with item: ChatTranscriptNativeItem) {
            let contentWidth = parent.contentWidth
            let viewportWidth = max(scrollView?.contentSize.width ?? contentWidth, 1)
            let cachedHeight = cachedHeight(for: item)
            let isInitialMeasurement = measuredRows[item.id] == nil
            hostedItem.onHeightMeasured = { [weak self] height in
                guard let self, self.itemByID[item.id] == item,
                      abs(self.parent.contentWidth - contentWidth) <= 0.5 else {
                    return
                }
                let previousHeight = self.measuredRows[item.id]?.height
                self.measuredRows[item.id] = MeasuredRow(
                    item: item, contentWidth: contentWidth,
                    height: height
                )
                if isInitialMeasurement, previousHeight.map({ abs($0 - height) > 0.5 }) ?? true {
                    // Initial Markdown layout can settle after the tail is already
                    // visible. Preserve its position before the new height reaches AppKit.
                    self.scheduleHeightUpdate(for: item.id, preservesInitialBottom: true)
                }
                self.schedulePendingScrollToEnd()
            }
            hostedItem.onHeightChange = { [weak self] in
                self?.scheduleHeightUpdate(for: item.id, preservesInitialBottom: isInitialMeasurement)
            }
            hostedItem.configure(
                rootView: AnyView(
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        parent.renderer(item)
                            .frame(width: parent.contentWidth)
                        Spacer(minLength: 0)
                    }
                    .id(item.id)
                    .frame(width: viewportWidth)
                    .fixedSize(horizontal: false, vertical: true)
                ),
                measurementKey: item.id,
                cachedHeight: cachedHeight,
                requiresMeasurement: cachedHeight == nil
            )
        }

        private func trailingContentItem(in items: [ChatTranscriptNativeItem]) -> ChatTranscriptNativeItem? {
            items.last { item in
                if case .entry = item.content { return true }
                return false
            } ?? items.last
        }

        private func scheduleHeightUpdate(for itemID: String, preservesInitialBottom: Bool = false) {
            pendingHeightUpdateIDs.insert(itemID)
            let followsChangingTail = parent.autoFollowChangingTail
                && trailingContentItem(in: parent.items)?.id == itemID
            heightUpdateFollowsBottom = heightUpdateFollowsBottom
                || ((followsChangingTail || preservesInitialBottom) && isNearBottom)
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            let viewportAnchor = captureViewportAnchor(followsBottom: false)
            let positionsInitially = pendingScrollToEnd
            let generation = parentUpdateGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let followsBottom = self.heightUpdateFollowsBottom
                self.heightUpdateFollowsBottom = false
                self.heightUpdateScheduled = false
                let changedIDs = self.pendingHeightUpdateIDs
                self.pendingHeightUpdateIDs.removeAll(keepingCapacity: true)
                self.invalidateRows(changedIDs)
                // Let AppKit lay out the changed rows before restoring the viewport.
                // Forcing a subtree layout here can schedule another height update
                // while the current one is still draining the main queue.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parentUpdateGeneration == generation else { return }
                    if positionsInitially {
                        self.schedulePendingScrollToEnd()
                        return
                    }
                    if followsBottom {
                        self.scrollToBottom(animated: false)
                    } else {
                        self.restoreViewport(viewportAnchor)
                        self.updateNearBottom()
                    }
                    self.updateVisibleItem()
                }
            }
        }

        private func invalidateRows(_ itemIDs: some Sequence<String>) {
            guard let layout = collectionView?.collectionViewLayout else { return }
            let indexPaths = Set(itemIDs.compactMap { dataSource?.indexPath(for: $0) })
            guard !indexPaths.isEmpty else { return }
            let context = NSCollectionViewLayoutInvalidationContext()
            context.invalidateItems(at: indexPaths)
            layout.invalidateLayout(with: context)
        }

        private func schedulePendingScrollToEnd() {
            guard pendingScrollToEnd, !scrollToEndScheduled else { return }
            scrollToEndScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollToEndScheduled = false
                guard self.pendingScrollToEnd else { return }
                self.scrollToBottom(animated: false)
                self.updateVisibleItem()
            }
        }

        func startObservingScroll() {
            guard let scrollView else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateNearBottom(preservesLayoutPosition: true)
                    self?.updateVisibleItem()
                    self?.checkHistoryScroll()
                }
            }
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A reader's scroll takes precedence over initial positioning.
                    self?.pendingScrollToEnd = false
                    self?.isUserScrolling = true
                    self?.parentUpdateGeneration &+= 1
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isUserScrolling = false }
            }
        }

        private func checkHistoryScroll() {
            guard let scrollView else { return }
            if historyScrollTrigger.didScroll(
                distanceFromTop: scrollView.contentView.bounds.minY + parent.topInset,
                isUserInitiated: isUserScrolling
            ) {
                // Bounds notifications can arrive during a SwiftUI update.
                DispatchQueue.main.async { [weak self] in self?.parent.onReachedTop() }
            }
        }

        func stopObservingScroll() {
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
                self.liveScrollEndObserver = nil
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
                self.scrollObserver = nil
            }
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
                self.liveScrollObserver = nil
            }
        }

        func update(parent: AppKitChatTranscriptCollection, initial: Bool) {
            guard let collectionView, let scrollView else { return }
            let explicitScroll = previousScrollRequest != parent.scrollToEndRequest
            if initial || explicitScroll {
                pendingScrollToEnd = true
            }
            let targetedScroll = previousScrollTarget != parent.scrollTarget
            if targetedScroll, parent.scrollTarget != nil {
                pendingScrollToEnd = false
            }
            let widthChanged = abs(previousContentWidth - parent.contentWidth) > 0.5
            let bottomInsetChanged = abs(previousBottomInset - parent.bottomInset) > 0.5
            let identitiesChanged = previousItems.map(\.id) != parent.items.map(\.id)
            let presentationChanged = previousPresentationRevision != parent.presentationRevision
            let oldByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
            let changedIDs = parent.items.compactMap { item -> String? in
                // Agent colors can arrive after the messages. Refresh their hosting
                // views without treating every streaming delta as a style change.
                guard oldByID[item.id] != item || widthChanged || presentationChanged else { return nil }
                return item.id
            }
            let visibleChangedIDs = changedIDs.filter { id in
                guard let indexPath = dataSource?.indexPath(for: id) else { return false }
                return collectionView.item(at: indexPath) != nil
            }
            let oldTail = trailingContentItem(in: previousItems)
            let newTail = trailingContentItem(in: parent.items)
            let appendedContent: Bool
            if let oldTail, let newTail,
               let oldIndex = parent.items.firstIndex(where: { $0.id == oldTail.id }),
               let newIndex = parent.items.firstIndex(where: { $0.id == newTail.id }) {
                appendedContent = newIndex > oldIndex
            } else {
                appendedContent = false
            }
            let appendedLastItem = previousItems.last.map { last in
                parent.items.last?.id != last.id
                    && parent.items.contains(where: { $0.id == last.id })
            } ?? false
            let changedTail = newTail.flatMap { item in
                oldByID[item.id].map { $0 != item }
            } ?? false
            let oldEntryIDs = previousItems.compactMap { item -> String? in
                if case .entry = item.content { return item.id }
                return nil
            }
            let newEntryIDs = parent.items.compactMap { item -> String? in
                if case .entry = item.content { return item.id }
                return nil
            }
            let replacedTail = oldEntryIDs.last.map { oldTailID in
                oldEntryIDs.count <= newEntryIDs.count
                    && !newEntryIDs.contains(oldTailID)
                    && oldEntryIDs.dropLast().elementsEqual(newEntryIDs.prefix(oldEntryIDs.count - 1))
            } ?? false
            let followsExistingTail = (parent.autoFollowChangingTail && changedTail && !widthChanged)
                || replacedTail
            if replacedTail && isNearBottom {
                // Completion replaces the streaming row's identity. Keep the tail
                // visible until its new content has been measured.
                pendingScrollToEnd = true
            }
            let followsBottom = ((appendedContent || appendedLastItem) && parent.autoFollowAppendedItems)
                || followsExistingTail
            let requiresViewportUpdate = initial
                || targetedScroll
                || explicitScroll
                || bottomInsetChanged
                || widthChanged
                || identitiesChanged
                || !visibleChangedIDs.isEmpty
            let viewportAnchor = requiresViewportUpdate
                ? captureViewportAnchor(followsBottom: followsBottom)
                : nil

            self.parent = parent
            itemByID = Dictionary(uniqueKeysWithValues: parent.items.map { ($0.id, $0) })
            if identitiesChanged {
                measuredRows = measuredRows.filter { itemByID[$0.key] != nil }
            }
            // Changed rows reject their old measurement in cachedHeight, but retain
            // it as an estimate until measured again, including offscreen rows.
            scrollView.automaticallyAdjustsContentInsets = false
            if initial || previousTopInset != parent.topInset || bottomInsetChanged {
                scrollView.contentInsets = NSEdgeInsets(
                    top: parent.topInset,
                    left: 0,
                    bottom: parent.bottomInset,
                    right: 0
                )
            }
            updateCollectionWidth()

            if initial || identitiesChanged {
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(parent.items.map(\.id), toSection: 0)
                snapshot.reloadItems(changedIDs.filter { oldByID[$0] != nil })
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                    self?.schedulePendingScrollToEnd()
                }
            } else if !changedIDs.isEmpty {
                // Keep the hosting view and its local state alive during streaming.
                for id in visibleChangedIDs {
                    guard let indexPath = dataSource?.indexPath(for: id),
                          let hostedItem = collectionView.item(at: indexPath) as? AppKitHostedTranscriptItem,
                          let item = itemByID[id] else { continue }
                    configure(hostedItem, with: item)
                }
                if !visibleChangedIDs.isEmpty {
                    invalidateRows(visibleChangedIDs)
                }
            }

            if let viewportAnchor {
                parentUpdateGeneration &+= 1
                let generation = parentUpdateGeneration
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    guard let self, let collectionView,
                          self.parentUpdateGeneration == generation else { return }
                    collectionView.layoutSubtreeIfNeeded()
                    if targetedScroll, let target = parent.scrollTarget {
                        self.scroll(to: target.itemID, animated: !parent.reduceMotion)
                    } else if explicitScroll || initial {
                        self.scrollToBottom(animated: explicitScroll && !parent.reduceMotion)
                    } else {
                        self.restoreViewport(viewportAnchor)
                    }
                    if targetedScroll || (!explicitScroll && !initial && !viewportAnchor.followsBottom) {
                        self.updateNearBottom()
                    }
                    self.updateVisibleItem()
                }
            }

            previousItems = parent.items
            previousPresentationRevision = parent.presentationRevision
            previousContentWidth = parent.contentWidth
            previousTopInset = parent.topInset
            previousBottomInset = parent.bottomInset
            previousScrollRequest = parent.scrollToEndRequest
            previousScrollTarget = parent.scrollTarget
            schedulePendingScrollToEnd()
        }

        func updateCollectionWidth() {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout else { return }
            let width = max(scrollView.contentSize.width, 1)
            guard abs(previousViewportWidth - width) > 0.5 else { return }
            previousViewportWidth = width
            collectionView.setFrameSize(NSSize(width: width, height: collectionView.frame.height))
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let id = dataSource?.itemIdentifier(for: indexPath),
                      let item = itemByID[id],
                      let hostedItem = collectionView.item(at: indexPath) as? AppKitHostedTranscriptItem else { continue }
                configure(hostedItem, with: item)
            }
            layout.invalidateLayout()
        }

        private func captureViewportAnchor(followsBottom: Bool) -> ViewportAnchor {
            guard let collectionView, let scrollView else {
                return ViewportAnchor(
                    followsBottom: true,
                    itemID: nil,
                    itemOffset: 0,
                    fallbackOrigin: .zero
                )
            }
            let bounds = scrollView.contentView.bounds
            let anchor = collectionView.indexPathsForVisibleItems().compactMap {
                indexPath -> (id: String, frame: NSRect)? in
                guard let id = dataSource?.itemIdentifier(for: indexPath),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                    return nil
                }
                return (id, attributes.frame)
            }.filter { candidate in
                candidate.id != "reveal-earlier" && candidate.frame.maxY >= bounds.minY - 0.5
            }.min { lhs, rhs in
                lhs.frame.minY < rhs.frame.minY
            }
            return ViewportAnchor(
                followsBottom: isNearBottom && followsBottom,
                itemID: anchor?.id,
                itemOffset: (anchor?.frame.minY ?? bounds.minY) - bounds.minY,
                fallbackOrigin: bounds.origin
            )
        }

        private func restoreViewport(_ anchor: ViewportAnchor) {
            guard let collectionView, let scrollView else { return }
            if anchor.followsBottom {
                scrollToBottom(animated: false)
                return
            }

            var origin = anchor.fallbackOrigin
            if let itemID = anchor.itemID,
               let indexPath = dataSource?.indexPath(for: itemID),
               let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                origin.y = attributes.frame.minY - anchor.itemOffset
            }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func updateNearBottom(preservesLayoutPosition: Bool = false) {
            guard let collectionView, let scrollView else {
                isNearBottom = true
                return
            }
            let contentHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
            let heightChanged = abs(contentHeight - previousLayoutHeight) > 0.5
            previousLayoutHeight = contentHeight
            // A bounds notification can come from asynchronous row measurement,
            // before we restore the viewport. It is not a reader scrolling away.
            if preservesLayoutPosition && heightChanged && isNearBottom { return }
            let visibleBottom = scrollView.contentView.bounds.maxY
            isNearBottom = contentHeight <= scrollView.contentView.bounds.height
                || visibleBottom >= contentHeight + parent.bottomInset - 44
        }

        private func scrollToBottom(animated: Bool) {
            guard let collectionView, !parent.items.isEmpty else { return }
            let indexPath = IndexPath(item: parent.items.count - 1, section: 0)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    collectionView.animator().scrollToItems(at: [indexPath], scrollPosition: .bottom)
                }
            } else {
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .bottom)
            }
            // Track the requested position while asynchronous measurements settle.
            // A transient estimated content height must not cancel bottom following.
            isNearBottom = true
            // Self-sizing rows preceding the tail can move it after the first
            // scroll. Finish initial positioning once the tail is measured and
            // actually visible, without repeatedly following history updates.
            if measuredRows[parent.items[indexPath.item].id] != nil,
               collectionView.item(at: indexPath) != nil,
               let scrollView {
                let height = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
                if height <= scrollView.contentView.bounds.height
                    || scrollView.contentView.bounds.maxY >= height + parent.bottomInset - 1 {
                    pendingScrollToEnd = false
                }
            }
        }

        private func scroll(to itemID: String, animated: Bool) {
            guard let collectionView,
                  let indexPath = dataSource?.indexPath(for: itemID) else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    collectionView.animator().scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
                }
            } else {
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
            }
        }

        private func updateVisibleItem() {
            guard let collectionView, let scrollView else { return }
            let focusY = scrollView.contentView.bounds.minY
                + min(scrollView.contentView.bounds.height * 0.25, 120)
            let visible = collectionView.indexPathsForVisibleItems().compactMap { indexPath -> (String, CGFloat)? in
                guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
                return (itemID, abs(attributes.frame.midY - focusY))
            }
            let nextID = visible.min { $0.1 < $1.1 }?.0
            guard nextID != visibleItemID else { return }
            visibleItemID = nextID
            parent.onVisibleItemChange(nextID)
        }
    }
}

// A single transcript column does not need estimated compositional groups.
// Rebuild inexpensive row positions from cached heights, rather than resetting
// already measured rows to estimates and asking their SwiftUI subtrees to fit again.
@MainActor
class AppKitChatTranscriptLayout: NSCollectionViewLayout {
    var heightForItem: (@MainActor (IndexPath) -> CGFloat?)?
    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var contentSize: NSSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(collectionView.bounds.width, 1)
        var originY: CGFloat = 0
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        attributes = (0..<count).map { index in
            let indexPath = IndexPath(item: index, section: 0)
            let height = heightForItem?(indexPath) ?? 100
            let item = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            item.frame = NSRect(x: 0, y: originY, width: width, height: height)
            originY += height
            return item
        }
        contentSize = NSSize(width: width, height: originY)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - contentSize.width) > 0.5
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: NSCollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: NSCollectionViewLayoutAttributes
    ) -> Bool {
        abs(preferredAttributes.size.height - originalAttributes.size.height) > 0.5
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: NSCollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutInvalidationContext {
        let context = NSCollectionViewLayoutInvalidationContext()
        // A height change also moves the rows below it, but their measurements
        // remain valid and come from heightForItem when preparing the new frames.
        guard let indexPath = preferredAttributes.indexPath else { return context }
        let index = indexPath.item
        guard index < attributes.count else {
            context.invalidateItems(at: [indexPath])
            return context
        }
        context.invalidateItems(at: Set((index..<attributes.count).map {
            IndexPath(item: $0, section: 0)
        }))
        return context
    }
}

@MainActor
private final class AppKitChatTranscriptScrollView: NSScrollView {
    var onLayout: (@MainActor () -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class AppKitHostedTranscriptItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("chat.native-transcript.hosted-item")
    private var hostingController: NSHostingController<AnyView>?
    private var hostingConstraints: [NSLayoutConstraint] = []
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat?
    private var measurementKey: String?
    private var measurementGeneration: UInt = 0
    private var needsSynchronousMeasurement = true
    private(set) var synchronousMeasurementPasses = 0
    var onHeightMeasured: (@MainActor (CGFloat) -> Void)?
    var onHeightChange: (@MainActor () -> Void)?

    override func loadView() {
        view = NSView()
    }

    func configure(
        rootView: AnyView,
        measurementKey: String? = nil,
        cachedHeight: CGFloat? = nil,
        requiresMeasurement: Bool = false
    ) {
        let changedItem = measurementKey != nil && measurementKey != self.measurementKey
        if measurementKey == nil || changedItem || requiresMeasurement {
            self.measurementKey = measurementKey
            if changedItem || measurementKey == nil { measuredHeight = 0 }
            measuredWidth = nil
            needsSynchronousMeasurement = true
        }
        if let cachedHeight, cachedHeight.isFinite, cachedHeight > 0 {
            measuredHeight = cachedHeight
            measuredWidth = nil
            needsSynchronousMeasurement = false
        }
        measurementGeneration &+= 1
        let generation = measurementGeneration
        let measuredRoot = AnyView(rootView.onGeometryChange(for: CGFloat.self) { geometry in
            ceil(geometry.size.height)
        } action: { [weak self] height in
            guard let self, self.measurementGeneration == generation,
                  height.isFinite, height > 0 else { return }
            self.needsSynchronousMeasurement = false
            let heightChanged = abs(self.measuredHeight - height) > 0.5
            self.measuredHeight = height
            self.onHeightMeasured?(height)
            guard heightChanged else { return }
            // Geometry callbacks run inside SwiftUI layout; invalidate on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.measurementGeneration == generation else { return }
                if let onHeightChange = self.onHeightChange {
                    onHeightChange()
                } else {
                    let context = NSCollectionViewLayoutInvalidationContext()
                    if let indexPath = self.collectionView?.indexPath(for: self) {
                        context.invalidateItems(at: [indexPath])
                        self.collectionView?.collectionViewLayout?.invalidateLayout(with: context)
                    }
                }
            }
        })
        if let hostingController, !changedItem {
            hostingController.rootView = measuredRoot
            return
        }
        if let hostingController {
            NSLayoutConstraint.deactivate(hostingConstraints)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        let hostingController = NSHostingController(rootView: measuredRoot)
        // The collection owns row sizing. Avoid an independent Auto Layout
        // intrinsic-size measurement on every SwiftUI geometry change.
        hostingController.sizingOptions = []
        addChild(hostingController)
        let hostingView = hostingController.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        hostingConstraints = [
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostingConstraints)
        self.hostingController = hostingController
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        guard let attributes = layoutAttributes.copy() as? NSCollectionViewLayoutAttributes else {
            return layoutAttributes
        }
        let widthChanged = measuredWidth.map { abs($0 - attributes.size.width) > 0.5 } ?? false
        if !needsSynchronousMeasurement, !widthChanged, measuredHeight > 0 {
            measuredWidth = attributes.size.width
            attributes.size.height = measuredHeight
            return attributes
        }
        guard let hostingController else { return layoutAttributes }
        synchronousMeasurementPasses += 1
        let height = ceil(hostingController.sizeThatFits(in: NSSize(
            width: max(attributes.size.width, 1), height: CGFloat.greatestFiniteMagnitude
        )).height)
        if height.isFinite && height > 0 {
            measuredHeight = height
            measuredWidth = attributes.size.width
            needsSynchronousMeasurement = false
            attributes.size.height = height
            onHeightMeasured?(height)
        }
        return attributes
    }
}
#endif
