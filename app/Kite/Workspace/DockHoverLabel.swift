import SwiftUI

/// 停靠栏浮出的一个标签：悬停的那一格，或按住 ⌘ 时各格一起（见 ShortcutHint）。
nonisolated struct DockHoverTip: Equatable, Identifiable {
    /// 对着的那一格。
    let id: String
    let text: String
    let frame: CGRect
    /// ⌘数字打开这一格的编号，标在尾部；没有为 nil。
    var number: Int?
    /// 只标编号、不浮标签：小头像排得密，标签会叠在一起，编号标在头像上（frame 是头像）。
    var badge = false
}

private struct DockHoverAnchor {
    let tips: [DockHoverTip]
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
    func dockHoverSource(_ tips: [DockHoverTip]) -> some View {
        anchorPreference(key: DockHoverPreference.self, value: .bounds) { bounds in
            tips.isEmpty ? nil : DockHoverAnchor(tips: tips, bounds: bounds)
        }
    }

    /// 放在内容过渡遮罩外，提示可以伸进窗口留白，且不截获鼠标事件。
    func dockHoverHost() -> some View {
        overlayPreferenceValue(DockHoverPreference.self) { value in
            GeometryReader { proxy in
                if let value {
                    let origin = proxy[value.bounds].origin
                    ForEach(value.tips) { tip in
                        let frame = tip.frame.offsetBy(dx: origin.x, dy: origin.y)
                        if tip.badge, let number = tip.number { DockNumberBadge(number: number, frame: frame) }
                        else { DockHoverLabel(text: tip.text, number: tip.number, frame: frame) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: value?.tips)
            .allowsHitTesting(false)
        }
    }
}

/// Mac 悬停时浮在格子左边的名字与状态；按住 ⌘ 时尾部的编号圈在和胶囊右端同心的圆里。
struct DockHoverLabel: View {
    let text: String
    var number: Int?
    let frame: CGRect

    var body: some View {
        let width: CGFloat = 280
        Group {
            if let number {
                TrailingCircle(spacing: 2) {
                    Text(text).lineLimit(1).padding(.leading, 10).padding(.vertical, 5)
                    ShortcutNumber(number: number)
                }
            } else {
                Text(text).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .font(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        .frame(width: width, alignment: .trailing)
        .position(x: frame.minX - Metrics.gap / 2 - width / 2, y: frame.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// 前一个子视图照常排，后一个按自己的大小居中放在右端一块边长等于整行高的方块里：放在胶囊里就和胶囊右端的半圆同心。
private struct TrailingCircle: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews[0].sizeThatFits(.unspecified).height
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0 - spacing - height, 0) }, height: height))
        return CGSize(width: text.width + spacing + height, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = bounds.height
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: max(bounds.width - spacing - height, 0), height: height))
        subviews[1].place(at: CGPoint(x: bounds.maxX - height / 2, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

/// 按住 ⌘ 时标在小头像上的编号，样子同标签。
private struct DockNumberBadge: View {
    let number: Int
    let frame: CGRect

    var body: some View {
        Text("\(number)")
            .font(Theme.caption)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
