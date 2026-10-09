import SwiftUI
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureOverview
import SloppyFeatureProjects
import SloppyFeatureSettings
import UserNotifications

#if os(macOS)
import AppKit

@MainActor
final class SloppyAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var onReopenMainWindow: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        SloppyUpdateController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let onReopenMainWindow else { return true }
        // Settings or a minimized window can make flag true while the main
        // window still needs to be restored.
        onReopenMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalBackendLauncher.shared.stop()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let deepLink = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: deepLink) else {
            return
        }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.toggleWorkspaceTerminal) private var toggleWorkspaceTerminal
    @FocusedValue(\.projectModeCommands) private var projectModeCommands

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Toggle Terminal") {
                toggleWorkspaceTerminal?()
            }
            .disabled(toggleWorkspaceTerminal == nil)
            Divider()
            ProjectModeSelectionButtons(context: projectModeCommands)
        }
    }
}

private struct MainWindowChromeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

@MainActor
private struct AuthenticationCommands: Commands {
    let viewModel: RootShellViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            #if canImport(Sparkle)
            Button("Check for Updates…") {
                SloppyUpdateController.shared.checkForUpdates()
            }
            Divider()
            #endif
            Button("Log Out") {
                viewModel.logout()
            }
        }
    }
}

@MainActor
private struct SloppyMenuBarView: View {
    let viewModel: RootShellViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Chat", systemImage: "square.and.pencil") {
            perform(.newChat)
        }
        .keyboardShortcut("n")

        Button("Scheduled Tasks", systemImage: "clock") {
            perform(.scheduledTasks)
        }

        Divider()

        Button("Open Sloppy", systemImage: "macwindow") {
            showMainWindow()
        }

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right") {
            viewModel.logout()
            showMainWindow()
        }

        Divider()

        Button("Quit Sloppy", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func perform(_ action: MenuBarQuickAction) {
        viewModel.requestMenuBarAction(action)
        showMainWindow()
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
#elseif os(iOS) || os(visionOS)
import UIKit

@MainActor
private final class SloppyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let deepLink = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: deepLink) else {
            return
        }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
    }
}
#endif

@main
struct SloppyClientApp: App {
    @State private var viewModel: RootShellViewModel
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SloppyAppDelegate.self) private var appDelegate
    #elseif os(iOS) || os(visionOS)
    @UIApplicationDelegateAdaptor(SloppyAppDelegate.self) private var appDelegate
    #endif

    init() {
        ClientLogging.bootstrap()
        _viewModel = State(initialValue: RootShellViewModel())
    }

    private var rootContent: some View {
        RootShellView(viewModel: viewModel)
            .onChange(of: scenePhase) { _, phase in
                viewModel.handleScenePhase(phase)
            }
        #if os(macOS)
            .frame(minWidth: 1120, minHeight: 760)
            .containerBackground(.clear, for: .window)
            .modifier(MainWindowChromeModifier())
            .onAppear {
                appDelegate.onReopenMainWindow = {
                    viewModel.presentMainWindow()
                }
            }
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
#if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--review-ui-fixture") || ProcessInfo.processInfo.arguments.contains("--composer-ui-fixture") {
            CodeReviewMobileFixture()
        } else {
            rootContent
        }
#else
        rootContent
#endif
    }

    var body: some Scene {
        #if os(macOS)
        Window("Sloppy", id: "main") {
            mainContent
        }
        .defaultSize(width: 1360, height: 880)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands()
            AuthenticationCommands(viewModel: viewModel)
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsScreen(
                settings: viewModel.settings,
                onChangeServer: viewModel.changeServer,
                onLogout: viewModel.logout
            )
                .frame(minWidth: 1120, minHeight: 760)
        }
        .defaultSize(width: 1360, height: 880)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Sloppy", image: "SloppyMenuBarIcon") {
            SloppyMenuBarView(viewModel: viewModel)
        }
        #else
        WindowGroup {
            mainContent
        }
        #endif
    }
}
