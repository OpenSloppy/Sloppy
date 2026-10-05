import SwiftUI
import SloppyClientCore

public typealias ChatFileOpenHandler = @MainActor @Sendable (SourceFileReference, ChatScreenViewModel) -> Void

public extension EnvironmentValues {
    @Entry var chatFileOpenHandler: ChatFileOpenHandler? = nil
}

struct ChatFileLinkModifier: ViewModifier {
    let viewModel: ChatScreenViewModel
    @Environment(\.chatFileOpenHandler) private var handler

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let reference = SourceFileReference(url: url) else {
                let isLocalLink = url.isFileURL || url.scheme == nil
                    || (url.scheme?.contains(".") == true && !url.absoluteString.contains("://"))
                return isLocalLink ? .discarded : .systemAction
            }
            guard let handler else { return .discarded }
            handler(reference, viewModel)
            return .handled
        })
    }
}
