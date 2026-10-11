import SwiftUI

nonisolated struct DockHoverTip: Equatable {
    let text: String
    let frame: CGRect
}

private struct DockHoverAnchor {
    let tip: DockHoverTip
    let bounds: Anchor<CGRect>
}

private struct DockHoverPreference: PreferenceKey {
    static var defaultValue: DockHoverAnchor? { nil }

    static func reduce(value: inout DockHoverAnchor?, nextValue: () -> DockHoverAnchor?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// 停靠栏只报告标签和本地坐标，提示由窗口外层绘制。
    func dockHoverSource(_ tip: DockHoverTip?) -> some View {
        anchorPreference(key: DockHoverPreference.self, value: .bounds) { bounds in
            tip.map { DockHoverAnchor(tip: $0, bounds: bounds) }
        }
    }

    /// 放在内容过渡遮罩外，提示可以伸进窗口留白，且不截获鼠标事件。
    func dockHoverHost() -> some View {
        overlayPreferenceValue(DockHoverPreference.self) { value in
            GeometryReader { proxy in
                if let value {
                    let origin = proxy[value.bounds].origin
                    DockHoverLabel(text: value.tip.text,
                                   frame: value.tip.frame.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
            .animation(.easeOut(duration: 0.12), value: value?.tip)
            .allowsHitTesting(false)
        }
    }
}

/// Mac 悬停时浮在格子左边的名字与状态。
struct DockHoverLabel: View {
    let text: String
    let frame: CGRect

    var body: some View {
        let width: CGFloat = 280
        Text(text)
            .font(Theme.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
            .frame(width: width, alignment: .trailing)
            .position(x: frame.minX - Metrics.gap / 2 - width / 2, y: frame.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
