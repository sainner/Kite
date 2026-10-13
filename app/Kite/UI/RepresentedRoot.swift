#if os(macOS)
import AppKit

/// 放进 SwiftUI（NSViewRepresentable）的原生视图的根，里面还托管着 SwiftUI（NSHostingView）时用：里面的托管视图每次更新都要
/// 「更新约束」，AppKit 沿父视图一路往上报，报到 representable 的宿主（SwiftUI 的 AppKitPlatformViewHost）时 SwiftUI 把外面
/// 那张图的排版作废重排一轮，里面的托管视图要等这一轮才更新（2026-10-14 实测，外面是窗口根时每次约 0.7 ms；
/// 空画板、停靠栏头像动着时每帧一次，打字时每键一次）。
/// 这里截住不往上报，在下一次排版里自己把子树的约束更新掉，托管视图照常按帧更新。这个视图的大小不随里面变（由外面给，
/// 或者变了由子类自己让 SwiftUI 重新量），宿主不用重新量。拦的是 NSView 没公开的 _informContainerThatSubviewsNeedUpdateConstraints，
/// 系统改了名字时只是退回原样（照常往上报）。
class RepresentedRoot: NSView {
    /// 更新约束放在它的排版里：只标它要排版，这个视图自己（子类的排版往往很重）不跟着排。它是第一个子视图，先于托管视图排。
    private let pump = ConstraintPump()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(pump)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func _informContainerThatSubviewsNeedUpdateConstraints() {
        pump.needsLayout = true
    }
}

/// 排版时把上一层的子树的约束更新掉，见 RepresentedRoot。不占地方、不接点击、读屏看不见。
private final class ConstraintPump: NSView {
    override func layout() {
        super.layout()
        superview?.updateConstraintsForSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
#endif
