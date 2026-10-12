#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// 让所在 App 窗口一直带着 Auto Layout 引擎。窗口里没有要用约束的视图时，AppKit 每次布局都先把整棵视图树走一遍，
    /// 找有没有视图要用约束（_findAnySubviewNeedingAutoLayoutEngine）；SwiftUI 的逐帧动画每帧都触发一次布局，
    /// 停靠栏里的窗口连同正文的文本视图一直挂在树上（空台面时约 1300 个视图，九成藏着），每帧都要走一遍。窗口有了引擎就不再找。
    /// 2026-10-12 Mac 实测（开优化，同一次启动前后对照）：空台面画板静息时主线程 28% → 17%，出现 26% → 16%，
    /// 恢复窗口时丢帧 11 → 1；窗口的位置、大小和最小、最大尺寸都没变。
    func keepsLayoutEngine() -> some View {
        background(LayoutEngineAnchor())
    }
}

/// 窗口出现时往内容视图里放一个 LayoutEngineAnchorView。不直接用它当 NSViewRepresentable：
/// 包在 SwiftUI 的平台视图宿主里时 AppKit 找不到它，窗口照样没有引擎（2026-10-12 实验）。
private struct LayoutEngineAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Installer { Installer() }

    func updateNSView(_ view: Installer, context: Context) {}

    final class Installer: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let content = window?.contentView, !content.subviews.contains(where: { $0 is LayoutEngineAnchorView }) else { return }
            content.addSubview(LayoutEngineAnchorView(frame: .zero))
        }
    }
}

/// 声明自己要用约束布局，所在窗口就建起引擎并一直留着；自己不加约束、不画、不接点击。
private final class LayoutEngineAnchorView: NSView {
    override class var requiresConstraintBasedLayout: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
}
#endif
