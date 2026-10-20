import SwiftUI

/// 侧栏顶部保持硬边，下方还有内容时底部渐隐。
private struct ScrollEdgeFade: ViewModifier {
    @State private var below = false
    private static let length: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY < geometry.contentSize.height - 0.5
            } action: { _, hasMoreBelow in
                withAnimation(.easeOut(duration: 0.15)) {
                    below = hasMoreBelow
                }
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
    func fadesScrollEdges() -> some View { modifier(ScrollEdgeFade()) }
}

/// 宽屏侧边栏。展开时顶部是标志栏，下面是一级导航，再往下是当前一栏的内容，底部是用户栏；收起时只留一列图标。
/// 工作区一栏里一行就是一个工作区和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @Environment(\.windowChrome) private var chrome
    #endif

    var body: some View {
        let current = model.current?.id
        Group {
            if model.sidebarCollapsed { rail(current) } else { expanded(current) }
        }
        .modifier(SidebarScaledMetrics())
    }

    private func expanded(_ current: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoBar.padding(.bottom, Metrics.sidebarRuleGap)
            // 标志栏下面是一级导航，再下面是当前一栏的列表
            if model.sidebarSection != .settings {
                SidebarNavigation()
                    .padding(.bottom, Metrics.sidebarRuleGap)
                Rectangle().fill(Theme.rule).frame(height: 1)
                    .padding(.bottom, Metrics.sidebarRuleGap)
            }
            SidebarListHeader()
            ScrollView(.vertical, showsIndicators: false) {
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
            .fadesScrollEdges()
            SidebarUserBar()
        }
    }

    /// 顶部标志栏与卡片标题栏同高同位：卡片在内容区顶边留白之下再留卡片边距。避开上方的红绿灯按钮。
    /// Mac 上整条连同上方留白都能拖窗口、双击缩放：留白落在主窗口底下的拖窗口区上，栏里的空白处见 SidebarLogoBar。
    private var logoBar: some View {
        SidebarLogoBar { sidebarToggle }
        .padding(.top, Metrics.padding + Metrics.paneMargin)
    }

    /// 收起时侧栏按钮移到第一个窗口的标题栏，见 PaneHeaderBar。列出当前一栏的图标：工作区按项目分组，组间隔一道短线；底部是设置按钮。
    private func rail(_ current: String?) -> some View {
        @Bindable var model = model
        return VStack(spacing: Metrics.gap) {
            if model.sidebarSection != .settings {
                SidebarNavigation(iconsOnly: true)
                Capsule().fill(Theme.rule).frame(width: 16, height: 2)
                    .padding(.vertical, 4)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch model.sidebarSection {
                    case .drive: deviceRail
                    case .extensions: railPages(selection: $model.extensionPage)
                    case .settings: railPages(selection: $model.settingsPage)
                    case .workspaces: EmptyView()
                    }
                    ForEach(Array((model.sidebarSection == .workspaces ? model.workspaceGroups : []).enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Capsule().fill(Theme.rule).frame(width: 16, height: 2).padding(.vertical, 4)
                        }
                        ForEach(group.workspaces) { workspace in
                            // 已经分离成独立窗口的画淡一点
                            Circle().fill(workspace.tint).frame(width: 24, height: 24)
                                .opacity(model.detached.contains(workspace.id) ? 0.35 : 1)
                                .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                                .background(current == workspace.id ? Theme.selection : .clear, in: sidebarRowShape)
                                .overlay { source(workspace) }
                                .help(workspace.title)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .fadesScrollEdges()
            // 设置的入口，底边与旁边窗口的底边对齐
            SidebarSettingsButton()
        }
        .frame(maxWidth: .infinity)
        // 只让开系统红绿灯按钮所在的区域。
        #if os(macOS)
        .padding(.top, chrome.top)
        #else
        .padding(.top, Metrics.padding)
        #endif
    }

    private var deviceRail: some View {
        VStack(spacing: 8) {
            ForEach(model.accountWorkers) { connection in
                let selected = model.drivePage == .accounts && model.accountWorker?.id == connection.id
                Button {
                    model.accountMachineID = connection.id
                    model.drivePage = .accounts
                } label: {
                    Group {
                        if let device = model.account.devices.first(where: { $0.id == connection.deviceID }) {
                            DeviceStatusIcon(device: device, connection: connection)
                        } else { TablerIcon(.desktop, selected: selected) }
                    }
                        .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                        .background(selected ? Theme.selection : .clear, in: sidebarRowShape)
                }
                .buttonStyle(SidebarButtonStyle(foreground: selected ? .accentColor : .secondary))
                .help("\(connection.machine.name) · 账号")
                .accessibilityLabel("\(connection.machine.name) · 账号")
            }
        }
    }

    /// 收起时工作区以外的栏只列各页图标，点一下切页。
    private func railPages<Page: SidebarPage>(selection: Binding<Page>) -> some View {
        ForEach(Page.allCases.filter(\.available)) { page in
            Button { selection.wrappedValue = page } label: {
                TablerIcon(page.icon, selected: selection.wrappedValue == page)
                    .font(Theme.body)
                    .modifier(SidebarIconTint(foreground: selection.wrappedValue == page ? Color.accentColor : Color.secondary))
                    .opacity(0.65)
                    .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                    .background(selection.wrappedValue == page ? Theme.selection : .clear, in: sidebarRowShape)
                    .contentShape(sidebarRowShape)
            }
            .buttonStyle(SidebarButtonStyle())
            .help(page.title)
        }
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

    /// rename 是双击进入改名，收起时那一列圆点不给。
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
