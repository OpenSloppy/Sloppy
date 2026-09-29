import SwiftUI

struct DesktopActionWheelView: View {
    var selected: DesktopPointerAction?
    var choose: (DesktopPointerAction) -> Void
    var cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbExpanded = false
    @FocusState private var wheelFocused: Bool

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .black.opacity(0.25), location: 0.55),
                .init(color: .black.opacity(0.08), location: 0.82),
                .init(color: .clear, location: 1)
            ], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
            DesktopOrbView(activity: .idle, diameter: 300)
                .scaleEffect(orbExpanded ? 1 : 68.0 / 300)
                .opacity(orbExpanded ? 1 : 0.35)
            ForEach(Array(DesktopPointerAction.allCases.enumerated()), id: \.element.id) { index, action in
                let angle = Double(index) * .pi / 3
                let highlighted = selected == action
                Button { choose(action) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: action.symbol).font(.system(size: 20, weight: .medium))
                        Text(action.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .frame(width: 88, height: 58)
                    .foregroundStyle(highlighted ? Color.cyan : .white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .background(highlighted ? Color(white: 0.28).opacity(0.95) : .clear,
                                in: RoundedRectangle(cornerRadius: 15))
                    .shadow(color: .black.opacity(highlighted ? 0.4 : 0), radius: 8, y: 5)
                    .scaleEffect(highlighted && !reduceMotion ? 1.06 : 1)
                    .offset(y: highlighted && !reduceMotion ? -6 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.18, bounce: 0.18),
                               value: highlighted)
                }
                .buttonStyle(.plain)
                .offset(x: sin(angle) * 98, y: -cos(angle) * 98)
                .accessibilityIdentifier("pointer.wheel." + action.rawValue)
            }
        }
        .frame(width: 300, height: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($wheelFocused)
        .onKeyPress(.escape) { cancel(); return .handled }
        .onAppear {
            wheelFocused = true
            if reduceMotion { orbExpanded = true }
            else { withAnimation(.easeOut(duration: 0.14)) { orbExpanded = true } }
        }
    }
}
