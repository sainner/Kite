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
#endif
