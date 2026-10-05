import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureProjects
import SloppyFeatureSettings
import SloppyFeatureSites

@MainActor
extension MainView {
    func presentMobileTabsOverviewAnimated() {
        guard idiom == .phone,
              viewModel.selectedTabID != nil,
              mobileTabsContentFrame != .zero else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                mobileTabsOverviewProgress = 1
                viewModel.presentMobileTabsOverview()
            }
            return
        }

        Task {
            beginMobileTabsOverviewGesture()
            await animateMobileTabsOverviewProgress(to: 1, dismissOnCompletion: false)
        }
    }

    func createMobileTabAnimated() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
            viewModel.createBlankChatTab()
            openMobileComposerWorkspace()
        }
    }

    func updatePagerPosition(_ progress: CGFloat) {
        guard progress.isFinite, !viewModel.tabs.isEmpty else { return }
        let index = min(max(Int(progress.rounded()), 0), viewModel.tabs.count - 1)
        viewModel.selectTab(viewModel.tabs[index].id)
    }

    var mobileComposer: some View {
        ChatComposerOverlay(
            viewModel: activeChatViewModel ?? viewModel.chatViewModel,
            contentWidth: ChatComposerView.panelWidth,
            composerBottomInset: theme.spacing.s,
            tabs: viewModel.tabs,
            tabActions: ChatComposerTabActions(
                tabProgress: updatePagerPosition,
                showOverview: presentMobileTabsOverviewAnimated,
                beginOverviewGesture: beginMobileTabsOverviewGesture,
                updateOverviewGesture: { updateMobileTabsOverviewGesture(progress: $0) },
                endOverviewGesture: { endMobileTabsOverviewGesture(progress: $0, upwardVelocity: $1) },
                createTab: createMobileTabAnimated,
                selectAdjacentTab: {
                    viewModel.selectAdjacentTab(offset: $0)
                    openMobileComposerWorkspace()
                }
            )
        )
        .environment(\.chatComposerConnectionActions, ChatComposerConnectionActions(
            instances: viewModel.settings.discoveredInstances,
            selectInstance: { instance in
                if viewModel.settings.requiresConsoleVerification(instance) {
                    viewModel.onOpenWorkspace()
                    return
                }
                guard instance.endpoint != (activeChatViewModel ?? viewModel.chatViewModel).sessionEndpoint else { return }
                viewModel.createBlankChatTab(on: instance)
                openMobileComposerWorkspace()
                viewModel.requestSelectedComposerFocus()
            },
            didSubmit: viewModel.openSubmittedChat
        ))
        .id(ObjectIdentifier(activeChatViewModel ?? viewModel.chatViewModel))
        .opacity(shouldHidePhoneComposer ? 0.0 : 1.0)
        .allowsHitTesting(!viewModel.isMobileTabsOverviewPresented)
    }

    func openMobileComposerWorkspace() {
        viewModel.selectAppSection(.chats)
        viewModel.sessionDeepLinkNavigationSerial += 1
    }

    func updateMobileTabPagingDirection(from oldValue: WorkspaceTab.ID?, to newValue: WorkspaceTab.ID?) {
        guard let oldValue,
              let newValue,
              let oldIndex = viewModel.tabs.firstIndex(where: { $0.id == oldValue }),
              let newIndex = viewModel.tabs.firstIndex(where: { $0.id == newValue }),
              oldIndex != newIndex else {
            return
        }
        mobileTabPagingDirection = newIndex > oldIndex ? 1 : -1
    }

    func shouldHidePhoneContent(for tabID: WorkspaceTab.ID?) -> Bool {
        guard idiom == .phone,
              let tabID,
              let hiddenTabID = mobileTabsHiddenSourceTabID,
              mobileTabsSnapshotImage != nil else {
            return false
        }
        return tabID == hiddenTabID
    }

    var shouldHidePhoneComposer: Bool {
        idiom == .phone && mobileTabsHiddenSourceTabID != nil && mobileTabsSnapshotImage != nil
    }

    var shouldHidePhoneBackground: Bool {
        idiom == .phone && mobileTabsHiddenSourceTabID != nil && mobileTabsSnapshotImage != nil
    }

    var mobileTabsOverviewAppearanceProgress: CGFloat {
        clamp(mobileTabsOverviewProgress)
    }

    var hiddenThumbnailTabIDForOverview: WorkspaceTab.ID? {
        guard mobileTabsHeroOverlay != nil else {
            return nil
        }
        return mobileTabsSnapshotImage != nil ? mobileTabsHiddenThumbnailTabID : nil
    }

    var shouldCaptureLiveSnapshotForCache: Bool {
        guard idiom == .phone else {
            return false
        }
        return !viewModel.isMobileTabsOverviewPresented
        && !isMobileTabsOverviewGestureActive
        && mobileTabsHeroOverlay == nil
    }

    @ViewBuilder
    func mobileTabsHeroOverlayView(rootFrame: CGRect) -> some View {
        if let hero = mobileTabsHeroOverlay {
            let localFrame = hero.frame.offsetBy(dx: -rootFrame.minX, dy: -rootFrame.minY)

            Group {
                if let mobileTabsSnapshotImage {
#if canImport(UIKit)
                    Image(uiImage: mobileTabsSnapshotImage)
                        .resizable()
                        .interpolation(.high)
#elseif canImport(AppKit)
                    Image(nsImage: mobileTabsSnapshotImage)
                        .resizable()
                        .interpolation(.high)
#endif
                } else if let tab = viewModel.tabs.first(where: { $0.id == hero.tabID }) {
                    liveHeroFallbackContent(for: tab)
                }
            }
            .frame(width: max(localFrame.width, 1), height: max(localFrame.height, 1))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: hero.cornerRadius,
                    style: .continuous
                )
            )
            .opacity(hero.opacity)
            .position(x: localFrame.midX, y: localFrame.midY)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func snapshotCaptureContent(for tab: WorkspaceTab) -> some View {
        uncachedContentView(for: tab)
            .frame(width: mobileTabsContentFrame.width, height: mobileTabsContentFrame.height)
            .clipped()
    }

    @ViewBuilder
    func liveHeroFallbackContent(for tab: WorkspaceTab) -> some View {
        uncachedContentView(for: tab)
    }

    @ViewBuilder
    func uncachedContentView(for tab: WorkspaceTab) -> some View {
        if let content = uncachedContent(for: tab) {
            content
        } else {
            DesktopTabPlaceholderView(
                title: tab.title,
                detail: "Tab state is unavailable."
            )
        }
    }

    var phoneWorkspaceBackground: some View {
        theme.colors.background
    }

    func beginMobileTabsOverviewGesture() {
        guard idiom == .phone,
              let selectedTabID = viewModel.selectedTabID,
              mobileTabsContentFrame != .zero else {
            return
        }

        mobileTabsSnapshotImage = captureMobileTabsSnapshot(for: selectedTabID, storeInCache: true)
        isMobileTabsOverviewGestureActive = true
        mobileTabsHiddenSourceTabID = selectedTabID
        mobileTabsHiddenThumbnailTabID = selectedTabID
        if mobileTabsHeroOverlay?.tabID != selectedTabID {
            mobileTabsHeroOverlay = MobileTabsHeroOverlayState(
                tabID: selectedTabID,
                frame: mobileTabsContentFrame,
                opacity: 1,
                cornerRadius: 0
            )
        }
        mobileTabsOverviewProgress = max(mobileTabsOverviewProgress, 0.001)
        syncMobileTabsOverviewHero()
    }

    func updateMobileTabsOverviewGesture(progress: CGFloat) {
        guard viewModel.isMobileTabsOverviewPresented || isMobileTabsOverviewGestureActive else {
            return
        }

        mobileTabsOverviewProgress = clamp(progress)
        syncMobileTabsOverviewHero()
    }

    func endMobileTabsOverviewGesture(progress: CGFloat, upwardVelocity: CGFloat) {
        let clampedProgress = clamp(progress)
        mobileTabsOverviewProgress = clampedProgress
        syncMobileTabsOverviewHero()

        let shouldComplete = clampedProgress >= mobileTabsOverviewCommitThreshold || upwardVelocity >= mobileTabsOverviewVelocityThreshold
        Task {
            await animateMobileTabsOverviewProgress(
                to: shouldComplete ? 1 : 0,
                dismissOnCompletion: !shouldComplete
            )
        }
    }

    func syncMobileTabsOverviewHero() {
        guard idiom == .phone,
              let selectedTabID = viewModel.selectedTabID,
              mobileTabsContentFrame != .zero else {
            return
        }

        let progress = clamp(mobileTabsOverviewProgress)
        let sourceFrame = mobileTabsContentFrame
        let targetFrame = mobileTabsThumbnailFrames[selectedTabID] ?? sourceFrame

        mobileTabsHiddenSourceTabID = selectedTabID
        mobileTabsHiddenThumbnailTabID = selectedTabID
        mobileTabsHeroOverlay = MobileTabsHeroOverlayState(
            tabID: selectedTabID,
            frame: interpolatedRect(from: sourceFrame, to: targetFrame, progress: progress),
            opacity: 1,
            cornerRadius: mobileTabsHeroThumbnailCornerRadius * progress
        )
    }

    func dismissMobileTabsOverviewAnimated() async {
        guard viewModel.selectedTabID != nil,
              mobileTabsContentFrame != .zero else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                viewModel.dismissMobileTabsOverview()
            }
            clearMobileTabsHeroState()
            return
        }

        mobileTabsOverviewProgress = 1
        syncMobileTabsOverviewHero()
        await animateMobileTabsOverviewProgress(to: 0, dismissOnCompletion: true)
    }

    func handleMobileTabsOverviewSelection(_ tabID: WorkspaceTab.ID) async {
        guard let selectedTabID = viewModel.selectedTabID else {
            return
        }

        guard tabID != selectedTabID else {
            openMobileComposerWorkspace()
            await dismissMobileTabsOverviewAnimated()
            return
        }

        if mobileTabsHeroOverlay == nil,
           let currentFrame = mobileTabsThumbnailFrames[selectedTabID] {
            mobileTabsHeroOverlay = MobileTabsHeroOverlayState(
                tabID: selectedTabID,
                frame: currentFrame,
                opacity: 1,
                cornerRadius: mobileTabsHeroThumbnailCornerRadius
            )
        }

        mobileTabsHiddenThumbnailTabID = selectedTabID
        withAnimation(.easeInOut(duration: mobileTabsHeroFadeDuration)) {
            mobileTabsHeroOverlay?.opacity = 0
        }
        try? await Task.sleep(for: .seconds(mobileTabsHeroFadeDuration))

        guard let nextFrame = mobileTabsThumbnailFrames[tabID] else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                viewModel.selectTab(tabID)
                openMobileComposerWorkspace()
                viewModel.dismissMobileTabsOverview()
            }
            clearMobileTabsHeroState()
            return
        }

        viewModel.selectTab(tabID)
        openMobileComposerWorkspace()
        mobileTabsHiddenSourceTabID = tabID
        mobileTabsHiddenThumbnailTabID = tabID
        mobileTabsHeroOverlay = MobileTabsHeroOverlayState(
            tabID: tabID,
            frame: nextFrame,
            opacity: 1,
            cornerRadius: mobileTabsHeroThumbnailCornerRadius
        )

        withAnimation(.spring(response: mobileTabsHeroDuration, dampingFraction: 0.86)) {
            mobileTabsHeroOverlay?.frame = mobileTabsContentFrame
            mobileTabsHeroOverlay?.cornerRadius = 0
            viewModel.dismissMobileTabsOverview()
        }

        try? await Task.sleep(for: .seconds(mobileTabsHeroDuration))
        clearMobileTabsHeroState()
    }

    func clearMobileTabsHeroState() {
        mobileTabsHeroOverlay = nil
        mobileTabsSnapshotImage = nil
        mobileTabsHiddenSourceTabID = nil
        mobileTabsHiddenThumbnailTabID = nil
        mobileTabsOverviewProgress = 0
        isMobileTabsOverviewGestureActive = false
    }

    func animateMobileTabsOverviewProgress(to targetProgress: CGFloat, dismissOnCompletion: Bool) async {
        await MainActor.run {
            withAnimation(.spring(response: mobileTabsHeroDuration, dampingFraction: 0.86)) {
                mobileTabsOverviewProgress = targetProgress
                syncMobileTabsOverviewHero()
            }
        }

        try? await Task.sleep(for: .seconds(mobileTabsHeroDuration))

        await MainActor.run {
            if dismissOnCompletion {
                if viewModel.isMobileTabsOverviewPresented {
                    viewModel.dismissMobileTabsOverview()
                }
                clearMobileTabsHeroState()
            } else {
                if !viewModel.isMobileTabsOverviewPresented {
                    viewModel.presentMobileTabsOverview()
                }
                mobileTabsOverviewProgress = 1
                isMobileTabsOverviewGestureActive = false
                mobileTabsHeroOverlay = nil
                mobileTabsSnapshotImage = nil
            }
        }
    }

    func interpolatedRect(from source: CGRect, to target: CGRect, progress: CGFloat) -> CGRect {
        let clampedProgress = clamp(progress)
        return CGRect(
            x: source.minX + ((target.minX - source.minX) * clampedProgress),
            y: source.minY + ((target.minY - source.minY) * clampedProgress),
            width: source.width + ((target.width - source.width) * clampedProgress),
            height: source.height + ((target.height - source.height) * clampedProgress)
        )
    }

    func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    @discardableResult
    func captureMobileTabsSnapshot(for tabID: WorkspaceTab.ID, storeInCache: Bool) -> MobileTabsSnapshotImage? {
        guard mobileTabsContentFrame.width > 0,
              mobileTabsContentFrame.height > 0 else {
            return nil
        }

#if canImport(UIKit)
        let image = captureWindowSnapshot()
#else
        let image: MobileTabsSnapshotImage? = nil
#endif
        if storeInCache, let image {
            mobileTabsSnapshotCache[tabID] = image
        }
        return image
    }

#if canImport(UIKit)
    func captureWindowSnapshot() -> UIImage? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first else {
            return nil
        }

        let frameInWindow = window.convert(mobileTabsContentFrame, from: nil)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let fullImage = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        guard let cgImage = fullImage.cgImage else {
            return nil
        }

        let scale = fullImage.scale
        let cropRect = CGRect(
            x: frameInWindow.minX * scale,
            y: frameInWindow.minY * scale,
            width: frameInWindow.width * scale,
            height: frameInWindow.height * scale
        ).integral

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }
#endif

    func mobileTabPagingTransition(for tab: WorkspaceTab) -> AnyTransition {
        let insertionEdge: Edge = mobileTabPagingDirection >= 0 ? .trailing : .leading
        let removalEdge: Edge = mobileTabPagingDirection >= 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }
}

