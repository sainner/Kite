import SwiftUI

extension View {
    /// 让所在滚动区的软边单独取样，加在 ScrollView 里面的内容上。
    ///
    /// Mac 上滚动区顶边伸进系统标题栏那一条时，AppKit 把它软边后面的 CABackdropLayer 都归进窗口标题栏的同一个取样组。
    /// 同组只取样一次，并排贴顶的几张卡片里，除了第一张，软边都取到窗口底色，不再模糊内容（macOS 27 实测）。
    /// 给每个滚动区设自己的标题栏组名，取样就各归各的。没有公开接口，用的是 NSView 的私有方法，系统去掉它时只是退回串色。
    /// iPhone 上不需要。
    func separateScrollPocket() -> some View {
        #if os(macOS)
        background(ScrollPocketSeparator())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct ScrollPocketSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> SeparatorView { SeparatorView() }
    func updateNSView(_ view: SeparatorView, context: Context) {}

    final class SeparatorView: NSView {
        private static let setGroupName = NSSelectorFromString("_setTitlebarGroupName:")

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView,
                  scrollView.responds(to: Self.setGroupName) else { return }
            let name = "KiteScrollPocket-\(ObjectIdentifier(scrollView).hashValue)"
            scrollView.perform(Self.setGroupName, with: name)
        }
    }
}

extension NSScrollView {
    /// 自己建的滚动视图接上窗口的滚动软边。SwiftUI 的滚动视图把系统标题栏和 safeAreaBar 给标题栏建的那一条容器登记成顶边的软边容器；
    /// 自己建的 NSScrollView 没人登记，内容直接压在标题上（2026-10-13 Mac 实测）。这里照它的样子登记：系统标题栏和贴着这里顶边的那条，
    /// 顶边用软边；底边不登记，同主对话的 scrollEdgeEffectHidden(true, for: .bottom)。取样另起一组，同 separateScrollPocket。
    /// 用的是 NSScrollView 没公开的 registerPocketContainer:onEdge:、setScrollPocketStyle:onEdge:，系统去掉它们时只是没有软边。
    /// 登记上了返回 true；还没进窗口、SwiftUI 还没建好那一条时返回 false，下次排版再试。
    func registerPanePockets() -> Bool {
        guard let window, let root = window.contentView?.superview else { return false }
        let mine = convert(bounds, to: nil)
        var containers: [NSView] = []
        func visit(_ view: NSView) {
            if String(describing: type(of: view)) == "NSTitlebarContainerView" {
                containers.append(view)
            } else if NSStringFromClass(type(of: view)).contains("AppKitPocketContainer") {
                let frame = view.convert(view.bounds, to: nil)
                // 窗口坐标原点在左下：贴着这里顶边、横向有重叠的那条
                if abs(frame.maxY - mine.maxY) < 2, frame.minX < mine.maxX - 1, frame.maxX > mine.minX + 1 { containers.append(view) }
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        guard containers.count > 1 else { return false }
        typealias Register = @convention(c) (AnyObject, Selector, NSView, Int) -> Void
        typealias Style = @convention(c) (AnyObject, Selector, Int, Int) -> Void
        let register = NSSelectorFromString("registerPocketContainer:onEdge:")
        let style = NSSelectorFromString("setScrollPocketStyle:onEdge:")
        guard responds(to: register), responds(to: style) else { return true }
        let call = unsafeBitCast(method(for: register), to: Register.self)
        // 边：0 顶边、1 底边；样式 1 是软边（和 SwiftUI 的滚动视图登记后的值一样）
        for view in containers { call(self, register, view, 0) }
        unsafeBitCast(method(for: style), to: Style.self)(self, style, 1, 0)
        let group = NSSelectorFromString("_setTitlebarGroupName:")
        if responds(to: group) { perform(group, with: "KiteScrollPocket-\(ObjectIdentifier(self).hashValue)") }
        return true
    }
}
#endif
