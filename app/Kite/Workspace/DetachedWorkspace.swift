#if os(macOS)
import AppKit
import SwiftUI

/// 从侧边栏分离出来的工作区：没有侧边栏，顶上一条单行显示工作区名与项目，红绿灯在它左边，拖这一条移动窗口。
/// 卡片从这一条下面开始，不会伸进系统当作标题栏的区域。关掉窗口，工作区回到主窗口。
struct DetachedWorkspace: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        if let workspace = model.workspace(id) {
            let minimum = Self.windowSize(content: workspace.minimumSize, chrome: chrome)
            VStack(spacing: 0) {
                title(workspace)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, chrome.leading)
                    .frame(height: Self.titleHeight(chrome))
                WorkspaceContent(workspace: workspace)
                    .padding([.horizontal, .bottom], Metrics.padding)
            }
            .frame(minWidth: minimum.width, minHeight: minimum.height)
            .appDotBackground()
            .ignoresSafeArea()
            .resizesByModule()
            .background(WindowPlacer(frame: model.pendingPlacement))
            .onAppear {
                model.detached.insert(id)
                model.pendingPlacement = nil
            }
            .onDisappear { model.detached.remove(id) }
        }
    }

    /// 顶栏一行：工作区名，后面是所属项目。
    private func title(_ workspace: WorkArea) -> some View {
        HStack(spacing: 4) {
            Text(workspace.title)
            if let project = workspace.remote?.project.name {
                Text("/").foregroundStyle(.tertiary)
                Text(project).fontWeight(.regular).foregroundStyle(.secondary)
            }
        }
        .font(Theme.title.weight(.semibold))
        .lineLimit(1)
    }

    /// 卡片区域是 content 大小（取到模块）时窗口有多大：四周的边距，顶上换成标题那一条（和红绿灯按钮那一条一样高）。
    static func windowSize(content: CGSize, chrome: WindowChrome) -> CGSize {
        CGSize(width: DotMetrics.snap(content.width) + 2 * Metrics.padding,
               height: DotMetrics.snap(content.height) + titleHeight(chrome) + Metrics.padding)
    }

    /// 标题那一条向上取整到模块，卡片从模块线开始。
    static func titleHeight(_ chrome: WindowChrome) -> CGFloat {
        DotMetrics.snapUp(chrome.top)
    }
}
/// 把新开的窗口放到指定位置（AppKit 的屏幕坐标）。不用 SwiftUI 的 defaultWindowPlacement：
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
            window.setFrame(frame, display: true)
            // 系统显示窗口时会再按层叠规则摆一次，下一轮再设一遍
            DispatchQueue.main.async { window.setFrame(frame, display: true) }
        }
    }
}
#endif
