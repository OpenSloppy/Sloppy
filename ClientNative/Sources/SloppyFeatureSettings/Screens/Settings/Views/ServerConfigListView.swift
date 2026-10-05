import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

enum ConfigSection: String, CaseIterable, Hashable {
    case providers
    case searchTools
    case channels
    case plugins
    case nodeHost
    case visor
    case acp
    case proxy
    case gitSync
    case rawConfig

    var title: String {
        switch self {
        case .providers: "Providers"
        case .searchTools: "Search Tools"
        case .channels: "Channels"
        case .plugins: "Agent Plugins"
        case .nodeHost: "Node Host"
        case .visor: "Visor"
        case .acp: "ACP"
        case .proxy: "Proxy"
        case .gitSync: "Git Sync"
        case .rawConfig: "Raw Config"
        }
    }

    var iconName: String {
        switch self {
        case .providers: "sparkles"
        case .searchTools: "magnifyingglass"
        case .channels: "message"
        case .plugins: "puzzlepiece.extension"
        case .nodeHost: "network"
        case .visor: "eye"
        case .acp: "cpu"
        case .proxy: "lock.shield"
        case .gitSync: "arrow.triangle.2.circlepath"
        case .rawConfig: "doc.text"
        }
    }

    var group: ConfigSectionGroup {
        switch self {
        case .providers, .searchTools:
            .modelsAndTools
        case .channels, .plugins:
            .integrations
        case .nodeHost, .visor, .acp, .proxy, .gitSync:
            .runtime
        case .rawConfig:
            .advanced
        }
    }
}

enum ConfigSectionGroup: String, CaseIterable {
    case modelsAndTools
    case integrations
    case runtime
    case advanced

    var title: String {
        switch self {
        case .modelsAndTools: "Models & Tools"
        case .integrations: "Integrations"
        case .runtime: "Runtime"
        case .advanced: "Advanced"
        }
    }
}

struct ServerConfigListView: View {
    let config: SloppyConfig
    let apiClient: SloppyAPIClient
    let onSave: (SloppyConfig) -> Void

    @State private var selectedSection: ConfigSection? = .providers
    @Environment(\.userInterfaceIdiom) private var idiom

    init(
        config: SloppyConfig,
        apiClient: SloppyAPIClient = SloppyAPIClient(),
        onSave: @escaping (SloppyConfig) -> Void
    ) {
        self.config = config
        self.apiClient = apiClient
        self.onSave = onSave
    }

    var body: some View {
        Group {
            if idiom == .phone {
                phoneLayout
            } else {
                desktopLayout
            }
        }
        .mobileScreenBackground()
        .navigationTitle("Sloppy Config")
    }

    private var phoneLayout: some View {
        NavigationStack {
            List {
                ForEach(ConfigSectionGroup.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(sections(in: group), id: \.self) { section in
                            NavigationLink(value: section) {
                                Label(section.title, systemImage: section.iconName)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .navigationDestination(for: ConfigSection.self) { section in
                configForm(section)
                    .mobileScreenBackground()
                    .navigationTitle(section.title)
            }
        }
    }

    private var desktopLayout: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(ConfigSectionGroup.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(sections(in: group), id: \.self) { section in
                            Label(section.title, systemImage: section.iconName)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let section = selectedSection {
                configForm(section)
                    .mobileScreenBackground()
                    .navigationTitle(section.title)
            } else {
                ContentUnavailableView(
                    "Select a Section",
                    systemImage: "sidebar.left",
                    description: Text("Choose a configuration category in the sidebar.")
                )
            }
        }
    }

    private func configForm(_ section: ConfigSection) -> some View {
        Form {
            Section {
                configDetailView(section)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private func sections(in group: ConfigSectionGroup) -> [ConfigSection] {
        ConfigSection.allCases.filter { $0.group == group }
    }

    @ViewBuilder
    private func configDetailView(_ section: ConfigSection) -> some View {
        switch section {
        case .providers:
            ProvidersSection(config: config, apiClient: apiClient, onSave: onSave)
        case .searchTools:
            SearchToolsSection(config: config, onSave: onSave)
        case .channels:
            ChannelsSection(config: config, onSave: onSave)
        case .plugins:
            PluginsSection(config: config, apiClient: apiClient, onSave: onSave)
        case .nodeHost:
            NodeHostSection(config: config, onSave: onSave)
        case .visor:
            VisorSection(config: config, onSave: onSave)
        case .acp:
            ACPSection(config: config, onSave: onSave)
        case .proxy:
            ProxySection(config: config, onSave: onSave)
        case .gitSync:
            GitSyncSection(config: config, onSave: onSave)
        case .rawConfig:
            RawConfigSection(config: config)
        }
    }
}
