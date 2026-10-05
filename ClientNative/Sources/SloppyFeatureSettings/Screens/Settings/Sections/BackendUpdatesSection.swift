import SwiftUI
import SloppyClientCore
import SloppyClientUI

public struct BackendUpdatesSection: View {
    @State private var model: BackendUpdateModel
    @State private var showsConfirmation = false

    public init(endpoint: SloppyInstanceEndpoint) {
        _model = State(initialValue: BackendUpdateModel(endpoint: endpoint))
    }

    public init(model: BackendUpdateModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sloppy Backend")
                .font(.title2.weight(.semibold))
            Text("Checks the backend connected to this client. Client app updates are managed separately.")
                .foregroundStyle(.secondary)
            if let status = model.status {
                LabeledContent("Running version", value: status.currentVersion)
                if let latest = status.latestVersion {
                    LabeledContent("Latest release", value: latest)
                }
                if let update = status.availableUpdate {
                    Label("Backend update available: \(update)", systemImage: "arrow.down.circle")
                        .font(.headline)
                } else if status.isReleaseBuild, status.latestVersion != nil {
                    Label("Backend is up to date", systemImage: "checkmark.circle")
                } else if status.updateKind == "git" {
                    Text("This backend was built from source. Update its checkout and rebuild on the host.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("The latest release could not be determined. Try checking again.")
                        .foregroundStyle(.secondary)
                }
                if let url = status.releaseURL {
                    Link("View release notes", destination: url)
                }
                if status.updateAvailable {
                    Divider()
                    if model.canInstall {
                        Text("The backend will restart after installation. Active work may be interrupted.")
                            .foregroundStyle(.secondary)
                        Button("Update Backend") { showsConfirmation = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isChecking || model.isInstalling)
                            .accessibilityIdentifier("backend.update.install")
                    } else {
                        Text(status.deploymentKind == "docker"
                             ? "Update the Docker deployment on the backend host, then reconnect."
                             : "Update this backend on its host using the original installation method, then reconnect.")
                            .foregroundStyle(.secondary)
                        if status.deploymentKind == "docker" {
                            Text("docker compose pull sloppy\ndocker compose up -d --force-recreate sloppy")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if model.isInstalling {
                ProgressView(model.installationDetail ?? "Updating backend")
                    .accessibilityIdentifier("backend.update.progress")
            } else if let detail = model.installationDetail {
                Text(detail).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("backend.update.error")
            }
            Button(model.isChecking ? "Checking…" : "Check for Backend Updates") {
                Task { await model.check(force: true) }
            }
            .disabled(model.isChecking || model.isInstalling)
            .accessibilityIdentifier("backend.update.check")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if model.status == nil { await model.check() } }
        .confirmationDialog("Update Sloppy backend?", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("Update and Restart Backend") {
                Task { await model.installUpdate() }
            }
        } message: {
            Text("The backend will restart. Active work may be interrupted.")
        }
    }
}

/// Appears only for a newer backend version; dismissing it leaves Updates in Settings available.
public struct BackendUpdateReminder: View {
    @State private var model: BackendUpdateModel
    @State private var showsUpdates = false
    @Environment(\.scenePhase) private var scenePhase

    public init(endpoint: SloppyInstanceEndpoint) {
        _model = State(initialValue: BackendUpdateModel(endpoint: endpoint))
    }

    public var body: some View {
        Group {
            if let version = model.reminderVersion {
                HStack(spacing: 12) {
                    Button { showsUpdates = true } label: {
                        Label("Backend update: \(version)", systemImage: "arrow.down.circle")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backend.update.available")
                    Spacer(minLength: 0)
                    Button { model.dismissReminder() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss backend update reminder")
                }
                .foregroundStyle(Color(red: 36 / 255, green: 37 / 255, blue: 33 / 255))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(red: 200 / 255, green: 226 / 255, blue: 174 / 255))
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.monitor()
        }
        .sheet(isPresented: $showsUpdates) {
            NavigationStack {
                ScrollView {
                    BackendUpdatesSection(model: model).padding(24)
                }
                .navigationTitle("Backend Updates")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsUpdates = false }
                            .disabled(model.isInstalling)
                    }
                }
            }
            .frame(minWidth: 320, minHeight: 360)
            .interactiveDismissDisabled(model.isInstalling)
        }
    }
}
