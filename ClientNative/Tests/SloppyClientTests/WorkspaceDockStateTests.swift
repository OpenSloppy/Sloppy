import Foundation
import SloppyClientCore
import Testing
@testable import SloppyClient

@Suite("Workspace dock state")
@MainActor
struct WorkspaceDockStateTests {
    @Test func browserTabTitleFollowsThePageAndResetsForBlankPages() {
        let dock = WorkspaceDockState()
        let tab = dock.open(.browser)
        #expect(tab.title == "New tab")
        tab.browser?.currentURL = URL(string: "https://example.com/docs")
        #expect(tab.title == "example.com")
        tab.browser?.pageTitle = "Documentation"
        #expect(tab.title == "Documentation")
        tab.browser?.pageTitle = "  "
        tab.browser?.currentURL = URL(string: "about:blank")
        #expect(tab.title == "New tab")
        #expect(dock.open(.terminal).title == "Terminal")
    }

    @Test func matchesArcadiaReviewToCurrentShortBranch() {
        let matching = CodeReviewItem(
            id: "15674740",
            providerId: "arcadia-code-review",
            providerName: "Arcadia",
            repository: "arcadia",
            number: 15_674_740,
            title: "MOBILEDEV-88951: Test schema",
            url: "https://a.yandex-team.ru/review/15674740",
            author: "vlad-prusakov",
            state: .open,
            isDraft: false,
            roles: [.authored],
            reviewDecision: nil,
            checksStatus: nil,
            labels: [],
            createdAt: nil,
            updatedAt: nil,
            sourceBranch: "users/vlad-prusakov/MOBILEDEV-88951",
            targetBranch: "trunk"
        )

        #expect(WorkspacePanelViewModel.matchingCodeReview(
            in: [matching],
            branch: "MOBILEDEV-88951"
        )?.id == matching.id)
        #expect(WorkspacePanelViewModel.matchingCodeReview(
            in: [matching],
            branch: "MOBILEDEV-00000"
        ) == nil)
    }

    @Test func hideAndReopenPreservesTabsSelectionAndWidth() {
        let dock = WorkspaceDockState()
        let browser = dock.open(.browser)
        browser.browser?.addressText = "https://example.com"
        let terminal = dock.open(.terminal)
        let chat = dock.open(.sideChat)
        dock.preferredWidth = 730
        dock.select(terminal)
        dock.toggleVisibility()
        #expect(!dock.isPresented)
        dock.toggleVisibility()
        #expect(dock.tabs.map(\.id) == [browser.id, terminal.id, chat.id])
        #expect(dock.selectedID == terminal.id)
        #expect(dock.preferredWidth == 730)
        #expect(browser.browser?.addressText == "https://example.com")
    }

    @Test func projectsKeepIndependentStateAcrossNavigation() {
        let store = WorkspaceDockStore()
        let first = store.state(server: "local", projectID: "a", fallbackID: "1", context: nil)
        let browser = first.open(.browser)
        first.preferredWidth = 650
        first.hide()
        let second = store.state(server: "local", projectID: "b", fallbackID: "1", context: nil)
        second.open(.sideChat)
        let restored = store.state(server: "local", projectID: "a", fallbackID: "different-main-tab", context: nil)
        #expect(restored === first)
        #expect(restored.selectedID == browser.id)
        #expect(restored.preferredWidth == 650)
        #expect(!restored.isPresented)
        #expect(second.tabs.count == 1)
        #expect(store.state(server: "remote", projectID: "a", fallbackID: "1", context: nil) !== first)
    }

    @Test func multipleBrowsersKeepSeparatePagesAndAgentRevealReusesItsPage() {
        let dock = WorkspaceDockState()
        let first = dock.open(.browser)
        let second = dock.open(.browser)
        #expect(first.browser !== second.browser)
        first.browser?.addressText = "first.example"
        second.browser?.addressText = "second.example"
        let revealed = dock.open(.browser, browser: first.browser)
        #expect(revealed === first)
        #expect(dock.tabs.count == 2)
        #expect(dock.selectedID == first.id)
        #expect(second.browser?.addressText == "second.example")
    }

    @Test func closingOneTabSelectsNeighbourAndDoesNotCloseOthers() {
        let dock = WorkspaceDockState()
        let first = dock.open(.browser)
        let second = dock.open(.sideChat)
        let third = dock.open(.terminal)
        dock.select(second)
        dock.close(second.id)
        #expect(dock.selectedID == third.id)
        #expect(dock.tabs.map(\.id) == [first.id, third.id])
        dock.close(first.id)
        #expect(dock.selectedID == third.id)
    }

    @Test func closingSelectedSidePanelTabsLeavesThePickerVisible() {
        let dock = WorkspaceDockState()
        let first = dock.open(.browser)
        dock.open(.sideChat)

        dock.closeSelectedTabOrHide()
        #expect(dock.tabs.map(\.id) == [first.id])
        #expect(dock.selectedID == first.id)
        #expect(dock.isPresented)

        dock.closeSelectedTabOrHide()
        #expect(dock.tabs.isEmpty)
        #expect(dock.selectedID == nil)
        #expect(dock.isPresented)

        dock.closeSelectedTabOrHide()
        #expect(!dock.isPresented)
    }

    @Test func widthCanGrowBeyondOldLimitAndFitsSmallWindows() {
        #expect(WorkspaceDockState.visibleWidth(preferred: 900, available: 1600) == 900)
        #expect(WorkspaceDockState.visibleWidth(preferred: 900, available: 700) < 700)
        #expect(WorkspaceDockState.visibleWidth(preferred: 200, available: 1600) == 240)
        #expect(WorkspaceDockState.visibleWidth(preferred: 900, available: 0) == 0)
    }
}
