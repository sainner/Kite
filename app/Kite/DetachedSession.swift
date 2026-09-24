#if os(macOS)
import AppKit
import SwiftUI

/// 一个会话的窗口组，放在主窗口的内容区或独立窗口里。
struct SessionContent: View {
    let session: Session

    var body: some View {
        TilesLayer()
            .environment(session)
            .environment(session.workspace)
            .focusedSceneValue(session.workspace)
            .id(session.id)
    }
}

/// 从侧边栏分离出来的会话：没有侧边栏，顶上一条是会话的标题和信息，红绿灯在它左边，拖这一条移动窗口。
/// 卡片从这一条下面开始，不会伸进系统当作标题栏的区域。关掉窗口，会话回到主窗口。
struct DetachedSession: View {
    let id: Int
    @Environment(AppModel.self) private var model
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        if let session = model.session(id) {
            let minimum = Self.windowSize(content: session.workspace.root.minimumSize, chrome: chrome)
            VStack(spacing: 0) {
                HeaderLine(header: session.header)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, chrome.leading)
                    .frame(height: chrome.top)
                SessionContent(session: session)
                    .padding([.horizontal, .bottom], Metrics.padding)
            }
            .frame(minWidth: minimum.width, minHeight: minimum.height)
            .background(Theme.background)
            .ignoresSafeArea()
            .background(WindowPlacer(frame: model.pendingPlacement))
            .onAppear {
                model.detached.insert(id)
                model.pendingPlacement = nil
            }
            .onDisappear { model.detached.remove(id) }
        }
    }

    /// 卡片区域是 content 大小时窗口有多大：四周的边距，顶上换成标题那一条（和红绿灯按钮那一条一样高）。
    static func windowSize(content: CGSize, chrome: WindowChrome) -> CGSize {
        CGSize(width: content.width + 2 * Metrics.padding, height: content.height + chrome.top + Metrics.padding)
    }
}
/// 把新开的窗口放到指定位置（左上角和大小，屏幕坐标，左上角是原点）。不用 SwiftUI 的 defaultWindowPlacement：
/// 同一组里已经有窗口时，系统会把新窗口错开层叠，给的位置被忽略（实测第二个窗口落在第一个右下 29pt 处）。
private struct WindowPlacer: NSViewRepresentable {
    let frame: CGRect?

    func makeNSView(context: Context) -> PlacerView {
        let view = PlacerView()
        view.frameToApply = frame
        return view
    }

    func updateNSView(_ view: PlacerView, context: Context) {}

    final class PlacerView: NSView {
        var frameToApply: CGRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frame = frameToApply else { return }
            frameToApply = nil
            // AppKit 的屏幕坐标左下角是原点，按主屏的高度翻过来
            let height = NSScreen.screens.first?.frame.height ?? 0
            let target = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
            window.setFrame(target, display: true)
            // 系统显示窗口时会再按层叠规则摆一次，下一轮再设一遍
            DispatchQueue.main.async { window.setFrame(target, display: true) }
        }
    }
}
#endif
