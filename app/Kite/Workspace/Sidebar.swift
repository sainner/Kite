import SwiftUI

/// 侧边栏里的一行，一个工作区。没有自己的底色，选中时垫一层。
struct WorkspaceRow: View {
    let workspace: WorkArea
    let current: Bool
    /// 分离成了独立窗口（Mac）。
    var detached = false
    var height: CGFloat = 32

    @Environment(AppModel.self) private var model
    private var isRoot: Bool { workspace.remote?.workspace.kind == .root }
    private var title: String {
        guard isRoot, let remote = workspace.remote else { return workspace.title }
        return "\(remote.machine.name) · \(remote.checkout.path)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRoot { Image(systemName: "folder").foregroundStyle(.secondary) }
            Text(title).font(isRoot ? Theme.secondary : Theme.body).lineLimit(1).truncationMode(.middle)
            if !workspace.isSample && !model.isConnected(workspace) {
                Text("离线").font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if detached {
                Image(systemName: "macwindow").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(current ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 检出行直接打开根工作区，下面只列独立工作区。
struct WorkspaceGroup: Identifiable {
    struct Checkout: Identifiable {
        let id: String
        var root: WorkArea?
        var workspaces: [WorkArea]
    }
    let id: String
    let title: String?
    var checkouts: [Checkout]
}

extension AppModel {
    /// 沿用工作区列表的顺序，项目和检出排在其中第一个工作区出现的位置。草稿不是工作区，不列出。
    var workspaceGroups: [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        for area in workspaces {
            guard let remote = area.remote else { continue }
            if !groups.contains(where: { $0.id == remote.project.id }) {
                groups.append(.init(id: remote.project.id, title: projectLabel(remote.project), checkouts: []))
            }
            let group = groups.firstIndex { $0.id == remote.project.id }!
            if let checkout = groups[group].checkouts.firstIndex(where: { $0.id == remote.checkout.id }) {
                if remote.workspace.kind == .root { groups[group].checkouts[checkout].root = area }
                else { groups[group].checkouts[checkout].workspaces.append(area) }
            } else {
                groups[group].checkouts.append(.init(id: remote.checkout.id, root: remote.workspace.kind == .root ? area : nil, workspaces: remote.workspace.kind == .root ? [] : [area]))
            }
        }
        return groups
    }

    /// 收起的侧栏没有标题，按分组后的顺序排。
    var groupedWorkspaces: [WorkArea] { workspaceGroups.flatMap { $0.checkouts.flatMap { [$0.root].compactMap { $0 } + $0.workspaces } } }
}

/// 侧栏按项目分组；每个检出行进入根工作区，其他工作区缩进一级。
struct WorkspaceList<Row: View>: View {
    var headerHeight: CGFloat = 24
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.workspaceGroups
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups) { group in
                if let title = group.title {
                    Text(title).font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: headerHeight)
                        .padding(.top, group.id == groups.first?.id ? 0 : 8)
                }
                ForEach(group.checkouts) { checkout in
                    if let root = checkout.root { row(root) }
                    ForEach(checkout.workspaces) { workspace in
                        row(workspace).padding(.leading, 12)
                    }
                }
            }
        }
    }
}

/// action 区保持原来的按钮槽位与底部信息行，只把已接通的入口放进对应位置。
struct ActionArea: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            buttons(size: Metrics.actionButton)
            connection(size: Metrics.actionButton)
        }
        #else
        if compact {
            VStack(spacing: 8) {
                buttons(size: 32)
                connection(size: 28).padding(.top, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: Metrics.actionSpacing) {
                HStack(spacing: 8) { buttons(size: Metrics.actionButton) }
                HStack(spacing: 10) {
                    Circle().fill(Theme.placeholder).frame(width: 28, height: 28)
                    Text("\(model.availableWorkers.count) 台工作机在线")
                        .font(Theme.secondary).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    connection(size: 28)
                }
                .frame(height: Metrics.accountRow)
            }
        }
        #endif
    }

    @ViewBuilder
    private func buttons(size: CGFloat) -> some View {
        Button { model.showNewWorkspace = true } label: {
            Image(systemName: "square.and.pencil")
                .font(Theme.body)
                .frame(width: size, height: size)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.pointingPlain)
        .help("新会话")
        .accessibilityLabel("新会话")
        .disabled(model.availableWorkers.isEmpty)
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder)
                .frame(width: size, height: size)
        }
    }

    private func connection(size: CGFloat) -> some View {
        Button { model.showConnection = true } label: {
            Image(systemName: "gearshape")
                .font(Theme.secondary)
                .frame(width: size, height: size)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.pointingPlain)
        .help("设置")
        .accessibilityLabel("设置")
    }
}

#if os(macOS)
/// Mac 的侧边栏。展开时上面是会话列表、底部是 action 区；收起时只留一列图标。
/// 一行就是一个会话和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        let current = model.current?.id
        Group {
            if model.sidebarCollapsed { rail(current) } else { expanded(current) }
        }
        // 只让开系统红绿灯按钮所在的区域。
        .padding(.top, chrome.top)
    }

    private func expanded(_ current: String?) -> some View {
        VStack(spacing: Metrics.gap) {
            ScrollView(.vertical, showsIndicators: false) {
                WorkspaceList { workspace in
                    WorkspaceRow(workspace: workspace, current: current == workspace.id, detached: model.detached.contains(workspace.id))
                        .overlay { source(workspace) }
                }
            }
            ActionArea()
        }
    }

    private func rail(_ current: String?) -> some View {
        VStack(spacing: Metrics.gap) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(model.groupedWorkspaces) { workspace in
                        // 已经分离成独立窗口的画淡一点
                        Circle().fill(workspace.tint).frame(width: 24, height: 24)
                            .opacity(model.detached.contains(workspace.id) ? 0.35 : 1)
                            .padding(6)
                            .background(current == workspace.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { source(workspace) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ActionArea(compact: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func source(_ workspace: WorkArea) -> some View {
        WorkspaceDragSource(tint: workspace.tint) {
            // 已经分离的，点一下把它的窗口提到前面
            if model.detached.contains(workspace.id) {
                openWindow(id: "workspace", value: workspace.id)
            } else {
                model.selected = workspace.id
            }
        } onDetach: { point in
            guard !workspace.isDraft, !model.detached.contains(workspace.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大；窗口左上角放在指针左上方，指针落在标题那一条上。AppKit 的屏幕坐标 y 朝上
            let size = DetachedWorkspace.windowSize(content: model.contentSize, chrome: chrome)
            model.pendingPlacement = CGRect(x: point.x - 60, y: point.y + 16 - size.height, width: size.width, height: size.height)
            openWindow(id: "workspace", value: workspace.id)
        }
    }
}
#endif
