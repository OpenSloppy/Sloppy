#if os(macOS)
import AppKit
import Testing
@testable import SloppyClient

@Suite("Desktop notch screen geometry")
struct DesktopNotchGeometryTests {
    @Test func displayWithoutCameraHousingUsesTheWiderCompactSize() {
        let geometry = SloppyDesktopNotchGeometry()
        #expect(geometry.collapsedSize == CGSize(width: 340, height: 28))
        #expect(geometry.reservedCenterWidth == 0)
        #expect(geometry.expandedWidth == 480)
    }

    @Test(arguments: [CGFloat(160), 200, 280, 320])
    func collapsedControlsFitOutsideCameraHousing(hardwareWidth: CGFloat) {
        let geometry = SloppyDesktopNotchGeometry(hardwareWidth: hardwareWidth, hardwareHeight: 32)
        let cameraLeft = (geometry.collapsedSize.width - hardwareWidth) / 2
        let cameraRight = cameraLeft + hardwareWidth
        // The mascot occupies 18pt after 8pt padding; the right-side activity
        // and expand controls occupy at most 35pt before the same padding.
        #expect(8 + 18 < cameraLeft)
        #expect(geometry.collapsedSize.width - 8 - 35 > cameraRight)
        #expect(geometry.collapsedSize.height > geometry.hardwareHeight)
        #expect(geometry.reservedCenterWidth > hardwareWidth)
    }

    @Test(arguments: [CGFloat(160), 200, 280, 320])
    func expandedTabsAndUtilitiesStayInTheUnobscuredWings(hardwareWidth: CGFloat) {
        let geometry = SloppyDesktopNotchGeometry(hardwareWidth: hardwareWidth, hardwareHeight: 32)
        let cameraLeft = (geometry.expandedWidth - hardwareWidth) / 2
        let leftWingEnd = 12 + geometry.headerSideWidth
        let rightWingStart = leftWingEnd + geometry.reservedCenterWidth
        #expect(geometry.headerSideWidth >= 3 * 36 + 2 * 4)
        #expect(leftWingEnd <= cameraLeft - 8)
        #expect(rightWingStart >= cameraLeft + hardwareWidth + 8)
        #expect(geometry.expandedWidth >= geometry.collapsedSize.width)
        #expect(geometry.expandedHeaderHeight >= geometry.hardwareHeight)
    }

    @Test @MainActor func screenUsesTheActualAuxiliaryAreas() throws {
        let screen = try #require(NSScreen.main)
        let geometry = SloppyDesktopNotchGeometry(screen: screen)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0 {
            #expect(abs(geometry.hardwareWidth - (screen.frame.width
                         - left.width - right.width)) < 0.5)
        } else {
            #expect(geometry.hardwareWidth == 0)
        }
        print("Notch screen geometry: cutout=\(geometry.hardwareWidth)x\(geometry.hardwareHeight), collapsed=\(geometry.collapsedSize)")
    }
}
#endif
