import SwiftUI
import SloppyClientCore

public struct ChatComposerConnectionActions {
    public let instances: [SloppyInstance]
    public var didSubmit: @MainActor (ChatScreenViewModel) -> Void = { _ in }
    public let selectInstance: @MainActor (SloppyInstance) -> Void

    public init(instances: [SloppyInstance], selectInstance: @escaping @MainActor (SloppyInstance) -> Void,
                didSubmit: @escaping @MainActor (ChatScreenViewModel) -> Void = { _ in }) {
        self.instances = instances
        self.selectInstance = selectInstance
        self.didSubmit = didSubmit
    }
}

public extension EnvironmentValues {
    @Entry var chatComposerConnectionActions: ChatComposerConnectionActions? = nil
}
