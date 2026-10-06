import Foundation
import SwiftUI

public struct NotificationBannerItem: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var message: String
    public var accentColor: Color

    public init(id: String, title: String, message: String, accentColor: Color) {
        self.id = id
        self.title = title
        self.message = message
        self.accentColor = accentColor
    }
}

public struct NotificationBanner: View {
    let item: NotificationBannerItem

    @Environment(\.theme) private var theme

    public init(item: NotificationBannerItem) {
        self.item = item
    }

    public var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let bo = theme.borders
        let ty = theme.typography

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: sp.xs) {
                Text(item.title.uppercased())
                    .font(.system(size: ty.caption))
                    .foregroundColor(item.accentColor)
                Text(item.message)
                    .font(.system(size: ty.body))
                    .foregroundColor(c.textPrimary)
                    .lineLimit(3)
            }
            .padding(sp.m)

            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(c.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(item.accentColor)
                .frame(width: bo.thick)
        }
        .border(item.accentColor, lineWidth: bo.thin)
    }
}
