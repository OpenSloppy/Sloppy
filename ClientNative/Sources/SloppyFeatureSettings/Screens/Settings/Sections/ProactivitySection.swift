import Foundation
import SwiftUI
import SloppyClientCore
import SloppyFeatureAgents

struct ProactivitySection: View {
    let apiClient: SloppyAPIClient
    @State private var agents: [APIAgentRecord] = []
    @State private var selectedAgent = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Agent", selection: $selectedAgent) {
                Text("Choose an agent").tag("")
                ForEach(agents) { agent in Text(agent.displayName).tag(agent.id) }
            }.padding(.horizontal).accessibilityIdentifier("proactivity.agent")
            if let error { Text(error).foregroundStyle(.red).padding() }
            if !selectedAgent.isEmpty {
                AgentProactivityScreen(agentID: selectedAgent, apiClient: apiClient).id(selectedAgent)
            } else {
                ContentUnavailableView("Choose an agent", systemImage: "bell.badge", description: Text("Configure background checks and see findings that need your attention."))
            }
        }
        .task {
            do { agents = try await apiClient.fetchAgents(); selectedAgent = agents.first?.id ?? "" }
            catch { self.error = error.localizedDescription }
        }
    }
}
