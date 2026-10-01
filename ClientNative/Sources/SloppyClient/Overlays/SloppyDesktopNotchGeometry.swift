#if os(macOS)
import AppKit

/// Keeps controls in the two unobscured areas beside a display's camera housing.
struct SloppyDesktopNotchGeometry: Equatable {
    var hardwareWidth: CGFloat = 0
    var hardwareHeight: CGFloat = 0

    init(hardwareWidth: CGFloat = 0, hardwareHeight: CGFloat = 0) {
        self.hardwareWidth = max(0, hardwareWidth)
        self.hardwareHeight = max(0, hardwareHeight)
    }

    @MainActor
    init(screen: NSScreen) {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.width > 0, right.width > 0 else {
            self.init()
            return
        }
        self.init(
            hardwareWidth: screen.frame.width - left.width - right.width,
            hardwareHeight: screen.safeAreaInsets.top
        )
    }

    var reservedCenterWidth: CGFloat { hardwareWidth > 0 ? hardwareWidth + 16 : 0 }

    var collapsedSize: CGSize {
        guard hardwareWidth > 0 else { return CGSize(width: 340, height: 28) }
        return CGSize(width: max(340, reservedCenterWidth + 128), height: max(28, hardwareHeight + 4))
    }

    var expandedWidth: CGFloat { max(480, reservedCenterWidth + 256) }
    var expandedHeaderHeight: CGFloat { max(32, hardwareHeight + 4) }
    var headerSideWidth: CGFloat { (expandedWidth - reservedCenterWidth - 24) / 2 }
}
#endif
