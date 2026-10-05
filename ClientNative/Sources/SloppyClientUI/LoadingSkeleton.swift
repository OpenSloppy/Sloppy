import SwiftUI

public struct LoadingSkeleton: View {
    public enum Style { case list, board, detail }
    let title: String
    let style: Style
    @Environment(\.theme) private var theme

    public init(_ title: String = "Loading…", style: Style = .list) {
        self.title = title
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if style == .board {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<max(1, min(3, Int(geometry.size.width / 240))), id: \.self) { _ in
                            VStack(spacing: 14) {
                                bar(height: 18)
                                card
                                card
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(theme.colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                        }
                    }
                    .accessibilityHidden(true)
                }
                .frame(height: 400)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<(style == .detail ? 3 : 5), id: \.self) { _ in card }
                }
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("loading-skeleton")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            bar(height: 16)
            bar(height: 12).padding(.trailing, 28)
            bar(height: 12).padding(.trailing, 54)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(theme.colors.textMuted.opacity(0.18))
            .frame(height: height)
    }
}
