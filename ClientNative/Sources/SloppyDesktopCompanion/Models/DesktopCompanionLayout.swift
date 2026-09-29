import Foundation

struct DesktopCompanionLayout: Equatable, Sendable {
    static let contentWidth: CGFloat = 336
    static let toolbarWidth: CGFloat = 124
    static let toolbarHeight: CGFloat = 40
    static let orbDiameter: CGFloat = 68
    static let padding: CGFloat = 6
    static let inputSpacing: CGFloat = 12
    static let responseSpacing: CGFloat = 24

    var expanded: Bool
    var showsResponse: Bool
    var composerHeight: CGFloat
    var responseHeight: CGFloat

    var inputHeight: CGFloat { expanded ? max(44, composerHeight) : Self.toolbarHeight }

    var size: CGSize {
        let width = expanded || showsResponse ? Self.contentWidth : Self.toolbarWidth
        let above = showsResponse ? max(56, responseHeight) + Self.responseSpacing : 0
        return CGSize(width: width + Self.padding * 2,
                      height: above + Self.orbDiameter + Self.inputSpacing + inputHeight + Self.padding * 2)
    }

    var orbOffset: CGPoint {
        CGPoint(x: size.width / 2,
                y: Self.padding + inputHeight + Self.inputSpacing + Self.orbDiameter / 2)
    }
}
