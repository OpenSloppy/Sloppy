import SwiftUI
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import SloppyFeatureSettings
import SloppyFeatureAgents

@MainActor
struct RootShellView: View {
    @State var viewModel: RootShellViewModel
    #if os(macOS)
    @State private var migrationOffer = false
    @State private var offeredMigrationSources: [MigrationSource] = []
    @State private var backendInstallation = BackendInstallationModel()
    @Environment(\.openWindow) private var openWindow
    #endif

    #if os(macOS)
    private var migrationReady: Bool {
        if case .chat = viewModel.appState { return true }
        return false
    }
    #endif

    init() {
        self._viewModel = State(initialValue: RootShellViewModel())
    }

    init(viewModel: RootShellViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            #if os(macOS)
            if backendInstallation.blocksApp {
                BackendInstallationView(model: backendInstallation)
            } else {
                RootShellContent(viewModel: viewModel)
            }
            #else
            RootShellContent(viewModel: viewModel)
            #endif
        }
            .environment(viewModel)
            .mobileScreenBackground()
        #if os(visionOS)
            .theme(.sloppyDark)
            .preferredColorScheme(.dark)
        #else
            .theme(viewModel.settings.colorScheme.appTheme)
            .preferredColorScheme(viewModel.settings.colorScheme.systemColorScheme)
        #endif
            .injectSafeAreaInsets()
            .background {
                #if os(macOS)
                TransparentWindowConfigurationView { window in
                    viewModel.configureDesktopWindow(window)
                }
                #endif
            }
            .sheet(item: $viewModel.consoleConnectionCode) { code in
                ConsoleConnectionSetupView(settings: viewModel.settings, autoConnect: false, connectionCode: code, onConnected: { url in
                    viewModel.consoleConnectionCode = nil
                    viewModel.startCloudConnected(url: url)
                }, onSelfHosted: { viewModel.consoleConnectionCode = nil })
            }
            .onOpenURL { url in
                viewModel.handleDeepLink(url)
            }
            .task {
                await viewModel.observeAuthenticationRequirements()
            }
            #if os(macOS)
            .task(id: migrationReady) {
                guard migrationReady else { return }
                offeredMigrationSources = ClientMigrationController.newSources()
                migrationOffer = !offeredMigrationSources.isEmpty
                if migrationOffer { ClientMigrationController.markOffered(offeredMigrationSources) }
            }
            .alert("Bring your work to Sloppy", isPresented: $migrationOffer) {
                Button("Import data") {
                    ClientMigrationController.markOffered(offeredMigrationSources)
                    viewModel.presentSettings(.migrations)
                }
                Button("Later", role: .cancel) { ClientMigrationController.markOffered(offeredMigrationSources) }
            } message: {
                Text(offeredMigrationSources.contains(where: { !$0.readable }) ? "Import your previous assistant data by choosing its folder to allow access on this Mac." : "Found " + offeredMigrationSources.map { $0.kind.rawValue.capitalized }.joined(separator: ", ") + ". Import skills, MCP, conversations and memory from this Mac.")
            }
            .task {
                await ManagedRemoteHostManager.shared.startIfNeeded(
                    localCoreURL: viewModel.settings.baseURL
                )
            }
            #endif
            #if os(macOS)
            .task {
                viewModel.configureMainWindowOpener {
                    openWindow(id: "main")
                }
                backendInstallation.checkIfNeeded()
            }
            #endif
    }
}

@MainActor
private struct RootShellContent: View {
    @State var viewModel: RootShellViewModel
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var rootViewModel = viewModel

        return ZStack(alignment: .topLeading) {
            #if os(macOS)
            AppAtmosphericBackground()
                .ignoresSafeArea()
            #else
            theme.colors.background
                .ignoresSafeArea()
            #endif

            switch rootViewModel.appState {
            case .splash:
                SplashScreen(settings: rootViewModel.settings) { result in
                    switch result {
                    case .connected(let url):
                        rootViewModel.connect(to: url)
                    case .managed:
                        rootViewModel.connectManagedRemote()
                    case .needsSetup:
                        rootViewModel.showConnectionSetup()
                        #if !os(macOS)
                        rootViewModel.autoConnectCloud = true
                        #endif
                    }
                }

            case .connectionSetup:
                ConnectionSetupView(
                    settings: rootViewModel.settings,
                    onConnected: { url in
                        rootViewModel.connect(to: url)
                    },
                    onScannedCode: rootViewModel.handleDeepLink,
                    onCloudConnected: rootViewModel.startCloudConnected,
                    autoConnectCloud: rootViewModel.autoConnectCloud
                )

            case .authentication(let url, let challenge, let message):
                AuthenticationScreen(
                    baseURL: url,
                    challenge: challenge,
                    initialMessage: message,
                    onAuthenticated: { authenticatedURL in
                        rootViewModel.startConnected(url: authenticatedURL)
                    },
                    onScannedCode: rootViewModel.handleDeepLink,
                    onChooseServer: {
                        rootViewModel.showConnectionSetup()
                    }
                )

            case .pairing:
                MainLoadingView()

            case .chat:
                MainView(
                    endpoint: rootViewModel.settings.activeInstanceEndpoint,
                    settings: rootViewModel.settings,
                    connectionMonitor: rootViewModel.connectionMonitor,
                    rootSafeAreaInsets: safeAreaInsets,
                    onOpenSettings: { destination in
                        rootViewModel.presentSettings(destination)
                    },
                    onOpenWorkspace: {
                        rootViewModel.showConnectionSetup()
                    },
                    menuBarQuickActionRequest: rootViewModel.menuBarQuickActionRequest,
                    onConsumeMenuBarQuickAction: rootViewModel.consumeMenuBarAction,
                    deepLinkRequest: rootViewModel.appDeepLinkRequest,
                    onConsumeDeepLink: rootViewModel.consumeDeepLink,
                    approvalRequiredSessionIDs: rootViewModel.pendingApprovalSessionIDs
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    BackendUpdateReminder(endpoint: rootViewModel.settings.activeInstanceEndpoint)
                        .id(rootViewModel.settings.activeInstanceEndpoint.cacheNamespace)
                }
                .id(rootViewModel.settings.instanceDirectoryKey)
            }

            if let banner = rootViewModel.activeBanner {
                NotificationBanner(item: banner)
                    .onTapGesture { rootViewModel.openActiveNotification() }
                    .frame(width: 320)
                    .padding(theme.spacing.m)
            }

            #if os(macOS)
            WindowDragHandleStrip(height: max(0, safeAreaInsets.top))
                .frame(height: max(0, safeAreaInsets.top))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            rootViewModel.startDesktopWindowIntegration()
        }
        .onChange(of: rootViewModel.settings.windowCloseBehavior) { _, _ in
            rootViewModel.applyDesktopWindowCloseBehavior()
        }
        #if os(iOS)
        .fullScreenCover(item: $rootViewModel.presentedSettings) { destination in
            settingsPresentation(for: destination, viewModel: rootViewModel)
        }
        #else
        .sheet(item: $rootViewModel.presentedSettings) { destination in
            settingsPresentation(for: destination, viewModel: rootViewModel)
        }
        #endif
        .sheet(item: $rootViewModel.presentedProactivity) { presentation in
            NavigationStack {
                AgentProactivityScreen(agentID: presentation.agentID, apiClient: SloppyAPIClient(baseURL: rootViewModel.settings.baseURL), initialFindingID: presentation.findingID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { rootViewModel.presentedProactivity = nil }
                        }
                    }
            }
            .frame(minWidth: 320, minHeight: 500)
        }
    }

    private func settingsPresentation(
        for destination: ClientSettingsDestination,
        viewModel: RootShellViewModel
    ) -> some View {
        SettingsScreen(
            settings: viewModel.settings,
            initialDestination: destination,
            onDismiss: {
                viewModel.dismissSettings()
            },
            onChangeServer: {
                viewModel.dismissSettings()
                viewModel.changeServer()
            },
            onLogout: {
                viewModel.dismissSettings()
                viewModel.logout()
            }
        )
    }
}

extension ClientColorScheme {
    fileprivate var appTheme: AppTheme {
        switch self {
        case .light:
            return .sloppyLight
        case .dark:
            return .sloppyDark
        }
    }

    fileprivate var systemColorScheme: ColorScheme {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

#Preview {
    @Previewable @State var viewModel = RootShellViewModel()
    return RootShellView(viewModel: viewModel)
//        .frame(width: 1024, height: 860)
}
