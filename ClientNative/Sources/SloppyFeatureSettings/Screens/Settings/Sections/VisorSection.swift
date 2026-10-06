import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

struct VisorSection: View {
    let config: SloppyConfig
    let onSave: (SloppyConfig) -> Void

    @State private var schedulerEnabled: Bool
    @State private var schedulerInterval: String
    @State private var tickInterval: String
    @State private var branchTimeout: String
    @State private var idleThreshold: String
    @State private var mergeEnabled: Bool

    init(config: SloppyConfig, onSave: @escaping (SloppyConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let v = config.visor
        self._schedulerEnabled = State(initialValue: v.scheduler.enabled)
        self._schedulerInterval = State(initialValue: String(v.scheduler.intervalSeconds))
        self._tickInterval = State(initialValue: String(v.tickIntervalSeconds))
        self._branchTimeout = State(initialValue: String(v.branchTimeoutSeconds))
        self._idleThreshold = State(initialValue: String(v.idleThresholdSeconds))
        self._mergeEnabled = State(initialValue: v.mergeEnabled)
    }

    private var hasChanges: Bool {
        let v = config.visor
        return schedulerEnabled != v.scheduler.enabled ||
            schedulerInterval != String(v.scheduler.intervalSeconds) ||
            tickInterval != String(v.tickIntervalSeconds) ||
            branchTimeout != String(v.branchTimeoutSeconds) ||
            idleThreshold != String(v.idleThresholdSeconds) ||
            mergeEnabled != v.mergeEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionCard("Scheduler") {
                SettingsToggleRow(label: "Enabled", value: schedulerEnabled) {
                    schedulerEnabled.toggle()
                }
                SettingsDivider()
                SettingsFieldRow("Interval (seconds)", hint: "How often the scheduler runs", text: $schedulerInterval)
            }

            SettingsSectionCard("Timeouts") {
                SettingsFieldRow("Tick Interval (s)", text: $tickInterval)
                SettingsDivider()
                SettingsFieldRow("Branch Timeout (s)", text: $branchTimeout)
                SettingsDivider()
                SettingsFieldRow("Idle Threshold (s)", text: $idleThreshold)
            }

            SettingsSectionCard("Memory Merge") {
                SettingsToggleRow(label: "Merge Enabled", value: mergeEnabled) {
                    mergeEnabled.toggle()
                }
            }

            SettingsSaveBar(
                hasChanges: hasChanges,
                statusText: hasChanges ? "Unsaved changes" : "Saved",
                onSave: { save() },
                onCancel: { reset() }
            )
        }
    }

    private func reset() {
        let v = config.visor
        schedulerEnabled = v.scheduler.enabled
        schedulerInterval = String(v.scheduler.intervalSeconds)
        tickInterval = String(v.tickIntervalSeconds)
        branchTimeout = String(v.branchTimeoutSeconds)
        idleThreshold = String(v.idleThresholdSeconds)
        mergeEnabled = v.mergeEnabled
    }

    private func save() {
        var updated = config
        updated.visor.scheduler.enabled = schedulerEnabled
        updated.visor.scheduler.intervalSeconds = Int(schedulerInterval) ?? config.visor.scheduler.intervalSeconds
        updated.visor.tickIntervalSeconds = Int(tickInterval) ?? config.visor.tickIntervalSeconds
        updated.visor.branchTimeoutSeconds = Int(branchTimeout) ?? config.visor.branchTimeoutSeconds
        updated.visor.idleThresholdSeconds = Int(idleThreshold) ?? config.visor.idleThresholdSeconds
        updated.visor.mergeEnabled = mergeEnabled
        onSave(updated)
    }
}
