import SwiftUI

struct DesktopRegionSelectionView: View {
    var screenFrame: CGRect
    var onSelected: (CGRect) -> Void
    var onCancel: () -> Void
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
            if let start, let end {
                let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                Rectangle().fill(.white.opacity(0.08)).overlay(Rectangle().stroke(.cyan, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
            }
            Text("Select an area · Esc to cancel")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                .padding(12).background(.black.opacity(0.7), in: Capsule())
                .padding(.top, 45).frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if start == nil { start = value.startLocation }
            end = value.location
        }.onEnded { value in
            let start = start ?? value.startLocation
            let rect = CGRect(x: screenFrame.minX + min(start.x, value.location.x),
                              y: screenFrame.maxY - max(start.y, value.location.y),
                              width: abs(value.location.x - start.x), height: abs(value.location.y - start.y))
            onSelected(rect.intersection(screenFrame))
        })
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .accessibilityIdentifier("pointer.region-selection")
    }
}
