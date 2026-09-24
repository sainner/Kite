#if os(macOS)
import AppKit
import SwiftUI

/// 一个会话的窗口组，放在内容区或独立窗口里。
struct SessionContent: View {
    let session: Session

    var body: some View {
        TilesLayer()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.workspace.area = $0 }
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

    var body: some View {
        if let session = model.session(id) {
            VStack(spacing: 0) {
                SessionTitle(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Metrics.trafficLights)
                .frame(height: Metrics.windowHeader)
                SessionContent(session: session)
                    .padding([.horizontal, .bottom], Metrics.padding)
            }
            .frame(minWidth: 600, minHeight: 400)
            .background(Theme.background)
            .ignoresSafeArea()
            .background(WindowPlacer(frame: model.placements[id]) { model.placements[id] = nil })
            .onAppear { model.detached.insert(id) }
            .onDisappear { model.detached.remove(id) }
        }
    }
}

/// 把窗口放到指定位置（屏幕坐标，左下角是原点）。SwiftUI 打开窗口时只能按默认规则摆，分离时要放在松手的地方。
private struct WindowPlacer: NSViewRepresentable {
    let frame: CGRect?
    let onPlaced: () -> Void

    func makeNSView(context: Context) -> PlacerView {
        let view = PlacerView()
        view.frameToApply = frame
        view.onPlaced = onPlaced
        return view
    }

    func updateNSView(_ view: PlacerView, context: Context) {}

    final class PlacerView: NSView {
        var frameToApply: CGRect?
        var onPlaced: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frame = frameToApply else { return }
            frameToApply = nil
            window.setFrame(frame, display: true)
            // SwiftUI 显示窗口时可能再摆一次，下一轮再设一遍
            DispatchQueue.main.async {
                window.setFrame(frame, display: true)
                self.onPlaced?()
            }
        }
    }
}
#endif
