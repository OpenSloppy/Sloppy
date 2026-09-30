import Foundation
import Observation
import SloppyClientCore

@Observable
@MainActor
public final class ChatLaunchViewModel {
    public private(set) var state: LaunchSessionState?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public private(set) var simulators: [LaunchSimulator] = []
    public var showsSimulatorPicker = false
    public var showsLogs = false
    @ObservationIgnored private let apiClient: SloppyAPIClient
    @ObservationIgnored private var agentID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var requestedRunID: String?
    @ObservationIgnored private var operationRevision = 0
    @ObservationIgnored private var previewRunID: String?
#if canImport(Network)
    @ObservationIgnored private var previewTunnel: LaunchPreviewTunnel?
#endif
    @ObservationIgnored public var onOpenPreview: (@MainActor (URL) -> Void)?

    public init(apiClient: SloppyAPIClient) { self.apiClient = apiClient }
    public var selected: LaunchConfiguration? { state?.selectedConfiguration }
    public var run: LaunchRun? { state?.runs.first { $0.configurationID == selected?.id } }
    public var title: String {
        guard let selected else { return "Prepare launch" }
        return "\(selected.request.name) · \(selected.request.platform.displayName)"
    }

    /// SwiftUI owns this polling task; closing the chat stops polling without stopping Core execution.
    public func observe(agentID: String?, sessionID: String?) async {
        if self.agentID != agentID || self.sessionID != sessionID {
            state = nil; errorMessage = nil; requestedRunID = nil; previewRunID = nil
            simulators = []; showsSimulatorPicker = false; showsLogs = false
#if canImport(Network)
            previewTunnel?.stop(); previewTunnel = nil
#endif
        }
        self.agentID = agentID; self.sessionID = sessionID
        guard agentID != nil, sessionID != nil else { return }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    public func refresh() async {
        guard let agentID, let sessionID, !isBusy else { return }
        let revision = operationRevision
        do {
            let next = try await apiClient.fetchLaunchState(agentID: agentID, sessionID: sessionID)
            guard self.agentID == agentID, self.sessionID == sessionID, !Task.isCancelled, revision == operationRevision, !isBusy else { return }
            state = next; errorMessage = nil
            if let run, run.id == requestedRunID, run.status == .running, run.launchSucceeded,
               run.configuration.request.platform == .web, previewRunID != run.id {
                await openPreview(run)
            }
#if canImport(Network)
            if let previewRunID, !next.runs.contains(where: { $0.id == previewRunID && $0.status.isActive }) {
                previewTunnel?.stop(); previewTunnel = nil; self.previewRunID = nil
            }
#endif
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID, !Task.isCancelled, revision == operationRevision, !isBusy else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func select(_ configuration: LaunchConfiguration, simulatorID: String? = nil) async {
        guard let agentID, let sessionID, !isBusy else { return }
        operationRevision += 1
        isBusy = true; defer { isBusy = false }
        do {
            let next = try await apiClient.selectLaunch(agentID: agentID, sessionID: sessionID,
                                                       request: .init(configurationID: configuration.id, simulatorID: simulatorID))
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            state = next; errorMessage = nil
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func chooseSimulator() async {
        guard let agentID, let sessionID, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let available = try await apiClient.fetchLaunchSimulators(agentID: agentID, sessionID: sessionID)
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            simulators = available; showsSimulatorPicker = true; errorMessage = nil
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func play(restart: Bool = false) async {
        guard let agentID, let sessionID, let selected, !isBusy else { return }
        operationRevision += 1
        isBusy = true; defer { isBusy = false }
        do {
            if selected.request.platform == .iOSSimulator, selected.request.simulatorID == nil {
                simulators = try await apiClient.fetchLaunchSimulators(agentID: agentID, sessionID: sessionID)
                showsSimulatorPicker = true
                return
            }
            if restart, let run, run.status.isActive {
                _ = try await apiClient.stopLaunch(agentID: agentID, sessionID: sessionID, runID: run.id)
            }
            let launched = try await apiClient.startLaunch(agentID: agentID, sessionID: sessionID, configurationID: selected.id)
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            requestedRunID = launched.id; showsLogs = true; errorMessage = nil
            state?.runs.insert(launched, at: 0)
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription; showsLogs = true
        }
    }

    public func stop() async {
        guard let agentID, let sessionID, let run, !isBusy else { return }
        operationRevision += 1
        isBusy = true; defer { isBusy = false }
        do {
            let next = try await apiClient.stopLaunch(agentID: agentID, sessionID: sessionID, runID: run.id)
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            state = next; errorMessage = nil
#if canImport(Network)
            previewTunnel?.stop(); previewTunnel = nil; previewRunID = nil
#endif
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func removeSelected() async {
        guard let agentID, let sessionID, let selected, !isBusy else { return }
        operationRevision += 1
        isBusy = true; defer { isBusy = false }
        do {
            let next = try await apiClient.removeLaunch(agentID: agentID, sessionID: sessionID, configurationID: selected.id)
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            state = next; errorMessage = nil
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func openPreview(_ run: LaunchRun) async {
        guard let agentID, let sessionID else { return }
#if canImport(Network)
        do {
            let tunnel = LaunchPreviewTunnel(apiClient: apiClient)
            let url = try await tunnel.open(agentID: agentID, sessionID: sessionID, run: run)
            guard self.agentID == agentID, self.sessionID == sessionID, !Task.isCancelled else { tunnel.stop(); return }
            previewTunnel?.stop(); previewTunnel = tunnel; previewRunID = run.id
            onOpenPreview?(url)
        } catch {
            guard self.agentID == agentID, self.sessionID == sessionID, !Task.isCancelled else { return }
            errorMessage = "Preview: \(error.localizedDescription)"
        }
#endif
    }
}

extension LaunchPlatform {
    public var displayName: String {
        switch self { case .web: "Web"; case .macOS: "macOS"; case .iOSSimulator: "iOS Simulator" }
    }
}
