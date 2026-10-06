#if os(macOS)
import AppKit
import SwiftUI

/// 窗口顶上被系统占着的地方：标题栏那一条多高，红绿灯按钮连同它右边的留白多宽。
/// 窗口去掉了标题栏，内容铺到最顶上，布局要自己让开这块。按 AppKit 的安全区读（macOS 26 起），不写死：
/// 全屏时标题栏收起、系统改了按钮的样子，都跟得上。默认值是 macOS 27 上实测的。
struct WindowChrome: Equatable {
    var top: CGFloat = 32
    var leading: CGFloat = 78
}

extension EnvironmentValues {
    @Entry var windowChrome = WindowChrome()
}

extension View {
    /// 读出所在窗口的 WindowChrome，放进环境给里面的视图用。
    func readsWindowChrome() -> some View {
        modifier(WindowChromeModifier())
    }
}

private struct WindowChromeModifier: ViewModifier {
    @State private var chrome = WindowChrome()

    func body(content: Content) -> some View {
        content
            .environment(\.windowChrome, chrome)
            .background(WindowChromeReader { chrome = $0 })
    }
}

private struct WindowChromeReader: NSViewRepresentable {
    let onRead: (WindowChrome) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onRead = onRead
    }

    final class ReaderView: NSView {
        var onRead: ((WindowChrome) -> Void)?
        private var last: WindowChrome?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            read()
        }

        // 窗口大小变了、进出全屏，这块跟着重新布局
        override func layout() {
            super.layout()
            read()
        }

        private func read() {
            guard let content = window?.contentView else { return }
            // 按角避让：左边让开红绿灯，上边是标题栏那一条
            let insets = content.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
            let chrome = WindowChrome(top: insets.top, leading: insets.left)
            guard chrome != last, let onRead else { return }
            last = chrome
            // 不在布局过程中改 SwiftUI 的状态
            Task { onRead(chrome) }
        }
    }
}
#endif
