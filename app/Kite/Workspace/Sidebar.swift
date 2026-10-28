import SwiftUI

/// 侧栏的滚动区：顶部保持硬边，下方还有内容时底部渐隐；可见高告诉里面的列表（sidebarScrollHeight）。
private struct SidebarScrollArea: ViewModifier {
    @State private var below = false
    @State private var height: CGFloat = .infinity
    private static let length: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarScrollHeight, height)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY < geometry.contentSize.height - 0.5
            } action: { _, hasMoreBelow in
                withAnimation(.easeOut(duration: 0.15)) {
                    below = hasMoreBelow
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                self.height = height
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.length)
                }
            }
    }
}

extension View {
    func sidebarScrollArea() -> some View { modifier(SidebarScrollArea()) }
}

/// 宽屏侧边栏：顶部是标志栏，下面是一级导航，再往下是当前一栏的内容，底部是用户栏。
/// 收起是同一个侧栏的一种状态：仍按展开的宽排，只露出图标列（MainWindow 的 SidebarLiveWidth）。名字和行尾操作淡掉、
/// 被往里收的右边缘盖住，树状子项收成树干上的圆点；行的底色、分割线和设置按钮跟着右边缘收进来（sidebarTuck），字标挪到这一列正中。
/// 工作区一栏里一行就是一个工作区和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @Environment(\.windowChrome) private var chrome
    #endif

    var body: some View {
        let current = model.current?.id
        VStack(alignment: .leading, spacing: 0) {
            // 收起时只留字标，展开侧栏的按钮在第一个窗口的标题栏里（PaneHeaderBar）
            logoBar.padding(.bottom, Metrics.sidebarRuleGap)
            // 标志栏下面是一级导航，再下面是当前一栏的列表
            if model.sidebarSection != .settings {
                SidebarNavigation()
                    .padding(.bottom, Metrics.sidebarRuleGap)
                Rectangle().fill(Theme.rule).frame(height: 1)
                    .sidebarFullWidth()
                    .padding(.bottom, Metrics.sidebarRuleGap)
            }
            SidebarListHeader()
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch model.sidebarSection {
                    case .workspaces:
                        WorkspaceList { workspace in
                            WorkspaceRow(workspace: workspace, current: current == workspace.id, detached: model.detached.contains(workspace.id)) { rename in
                                source(workspace, rename: rename)
                            }
                        }
                    case .drive, .extensions, .settings:
                        SectionPages()
                    }
                }
                // 收起时行的底色往左多铺 railMargin（sidebarFullWidth）：滚动区连同渐隐往左让出这一段，不把它裁掉
                .padding(.leading, SidebarMetrics.railMargin)
            }
            .sidebarScrollArea()
            .padding(.leading, -SidebarMetrics.railMargin)
            // 同标志栏：底下再留卡片边距，设置按钮与旁边窗口里贴底的控件（输入区）底边对齐
            SidebarUserBar()
                .padding(.bottom, Metrics.paneMargin)
        }
        .modifier(SidebarScaledMetrics())
    }

    /// 顶部标志栏与卡片标题栏同高同位：卡片在内容区顶边留白之下再留卡片边距。避开上方的红绿灯按钮。
    /// Mac 上整条连同上方留白都能拖窗口、双击缩放：留白落在主窗口底下的拖窗口区上，栏里的空白处见 SidebarLogoBar。
    private var logoBar: some View {
        SidebarLogoBar { sidebarToggle }
        .padding(.top, Metrics.padding + Metrics.paneMargin)
    }

    private var sidebarToggle: some View {
        let title = model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏"
        return Button {
            model.setSidebarCollapsed(!model.sidebarCollapsed)
        } label: {
            PaneHeaderButtonLabel(title, systemImage: "sidebar.left")
        }
        .help(title)
    }

    /// rename 是双击进入改名，收起时树干上的圆点不给（WorkspaceRow 的 target）。
    private func source(_ workspace: WorkArea, rename: (() -> Void)? = nil) -> some View {
        #if os(macOS)
        WorkspaceDragSource(tint: workspace.tint) {
            // 已经分离的，点一下把它的窗口提到前面
            if model.detached.contains(workspace.id) {
                openWindow(id: "workspace", value: workspace.id)
            } else {
                model.selectWorkspace(workspace.id)
            }
        } onDoubleClick: {
            rename?()
        } onDetach: { point in
            guard !model.detached.contains(workspace.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大；窗口左上角放在指针左上方，指针落在标题那一条上。AppKit 的屏幕坐标 y 朝上
            let size = DetachedWorkspace.windowSize(content: model.contentSize, chrome: chrome)
            model.pendingPlacement = CGRect(x: point.x - 60, y: point.y + 16 - size.height, width: size.width, height: size.height)
            openWindow(id: "workspace", value: workspace.id)
        }
        #else
        // 双击不让单击等它：第一下照常选中，第二下改名
        Color.clear.contentShape(Rectangle())
            .onTapGesture { model.selectWorkspace(workspace.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { rename?() }, isEnabled: rename != nil)
        #endif
    }
}
