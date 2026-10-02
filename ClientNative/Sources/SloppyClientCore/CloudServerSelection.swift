import Foundation
import SloppyConsoleProtocol

public enum CloudServerSelection {
    public static func activeInstances(_ instances: [InstanceBinding]) -> [InstanceBinding] {
        instances.filter { $0.status == .active }
    }

    public static func orderedInstances(_ instances: [InstanceBinding], preferredHostID: UUID?) -> [InstanceBinding] {
        let active = activeInstances(instances)
        guard let preferredHostID else { return active }
        return active.filter { $0.hostDeviceID == preferredHostID }
            + active.filter { $0.hostDeviceID != preferredHostID }
    }
}
