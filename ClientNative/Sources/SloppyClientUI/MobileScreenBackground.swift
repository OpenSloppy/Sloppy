import SwiftUI

public extension View {
    /// Uses the Inbox canvas behind mobile screens, lists, and presentations.
    func mobileScreenBackground() -> some View {
        modifier(MobileScreenBackground())
    }
}

private struct MobileScreenBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .scrollContentBackground(.hidden)
            .background(theme.colors.background.ignoresSafeArea())
            .presentationBackground(theme.colors.background)
        #else
        content
        #endif
    }
}
