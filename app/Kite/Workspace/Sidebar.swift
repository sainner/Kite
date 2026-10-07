import SwiftUI

/// 侧边栏里的一行，一个工作区。没有自己的底色，选中时垫一层。
/// 检出行（根工作区）主文字是目录名，账号下有几台机器时行尾附上所属机器；独立工作区前面是分支图标。完整路径在悬停提示里。
struct WorkspaceRow: View {
    let workspace: WorkArea
    let current: Bool
    /// 分离成了独立窗口（Mac）。
    var detached = false
    var height: CGFloat = InputMode.current.rowHeight

    @Environment(AppModel.self) private var model
    private var isRoot: Bool { workspace.remote?.workspace.kind == .root }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isRoot ? "folder" : "arrow.triangle.branch")
                .font(Theme.secondary).foregroundStyle(.secondary)
                .frame(width: InputMode.current.labelExtent)
            Text(workspace.title).font(Theme.body).lineLimit(1).truncationMode(.middle)
            if !workspace.isSample && !model.isConnected(workspace) {
                Text("离线").font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRoot, model.showsMachineNames, let machine = workspace.remote?.machine.name {
                Text(machine).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if detached {
                Image(systemName: "macwindow").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(current ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .help(workspace.remote.map { "\($0.machine.name) · \($0.workspace.cwd)" } ?? workspace.title)
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

    var workspaces: [WorkArea] { checkouts.flatMap { [$0.root].compactMap { $0 } + $0.workspaces } }
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

    /// 工作区分布在不止一台机器上时，检出行才标出机器。
    var showsMachineNames: Bool { Set(workspaces.compactMap { $0.remote?.machine.id }).count > 1 }
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
                    Text(title).font(Theme.secondary.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: headerHeight)
                        .padding(.top, group.id == groups.first?.id ? 0 : 12)
                }
                ForEach(group.checkouts) { checkout in
                    if let root = checkout.root { row(root).contextMenu { WorkspaceGitActions(workspace: root) } }
                    ForEach(checkout.workspaces) { workspace in
                        row(workspace).padding(.leading, 16).contextMenu { WorkspaceGitActions(workspace: workspace) }
                    }
                }
            }
        }
    }
}

/// 一级导航的各栏。没接通的置灰，不能选。
enum SidebarSection: CaseIterable, Identifiable {
    case workspaces, drive, extensions, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .workspaces: "工作区"
        case .drive: "文件"
        case .extensions: "扩展"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "square.stack"
        case .drive: "externaldrive"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }

    var available: Bool { self != .drive }
    /// 设置不在一级导航里，从用户栏的头像进入。
    var navigable: Bool { self != .settings }

    /// 导航行尾的数字：工作区数量，文件一栏是在线的机器数。
    @MainActor func count(in model: AppModel) -> Int? {
        switch self {
        case .workspaces: model.workspaces.count
        case .drive: model.availableWorkers.count
        case .extensions, .settings: nil
        }
    }
}

/// 一级栏里的一页：侧栏里一行，内容区一张卡片。
protocol SidebarPage: Hashable, Identifiable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    var symbol: String { get }
    var available: Bool { get }
}

/// 侧栏里的一行入口，与工作区行同高、同样左对齐图标列；一级导航的悬停、按下和选中共用胶囊轮廓。
private struct SidebarRowStyle: ButtonStyle {
    var selected = false
    var capsule = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlight = Color.gray.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.2 : hovered ? 0.1 : 0)
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: InputMode.current.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if capsule {
                    Capsule().fill(selected ? Color.accentColor : highlight)
                        .overlay {
                            Capsule().fill(Color.black.opacity(!selected ? 0 : configuration.isPressed ? 0.12 : hovered ? 0.06 : 0))
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(highlight)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .clickPointer()
    }
}

/// 一行入口的内容：图标列、标题，没接通的在行尾注明。
private struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    var note: String?
    /// 选中时图标换实心，白字配合主题色胶囊。
    var selected = false
    var weight: Font.Weight = .regular

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(Theme.secondary.weight(weight))
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: InputMode.current.labelExtent)
            Text(title).font(Theme.body.weight(weight)).lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
    }
}

/// 一级导航：标志栏下面一列全宽按钮，选中项用主题色胶囊配白字；没接通的置灰。两端相同，iPhone 放在侧栏抽屉顶部。
/// 设置不在这里，入口是用户栏的头像。
/// 收起的侧栏里只留图标竖着排。
struct SidebarNavigation: View {
    /// 收起的图标栏里只要图标。
    var iconsOnly = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: iconsOnly ? 8 : 0) {
            ForEach(SidebarSection.allCases.filter(\.navigable)) { section in
                let selected = model.sidebarSection == section
                let button = Button {
                    withAnimation(.snappy) { model.sidebarSection = section }
                } label: {
                    if iconsOnly {
                        Image(systemName: section.symbol)
                            .font(Theme.body)
                            .symbolVariant(selected ? .fill : .none)
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                            .background(selected ? Color.accentColor : .clear, in: Capsule())
                            .contentShape(Rectangle())
                            .opacity(section.available ? 1 : 0.45)
                    } else {
                        SidebarRowLabel(title: section.title, systemImage: section.symbol, note: section.count(in: model).map(String.init),
                                        selected: selected, weight: .semibold)
                    }
                }
                .disabled(!section.available)
                .help(section.available ? section.title : "\(section.title)（尚未接通）")
                .accessibilityAddTraits(selected ? .isSelected : [])
                if iconsOnly { button.buttonStyle(.pointingPlain) }
                else { button.buttonStyle(SidebarRowStyle(selected: selected, capsule: true)) }
            }
        }
    }
}

/// 侧栏底部的用户栏：左边邮箱和各订阅账号的剩余周额度，右边头像，点头像进入设置。
struct SidebarUserBar: View {
    @Environment(AppModel.self) private var model

    private var user: AccountUser? { model.account.user ?? (SampleWorkspace.enabled ? SampleWorkspace.user : nil) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(user?.email ?? "未登录")
                    .font(Theme.body).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if model.subscriptionQuotas.isEmpty {
                        chip { Text("无账号") }
                            .help("没有关联的模型订阅账号")
                    } else {
                        ForEach(model.subscriptionQuotas) { quota($0) }
                    }
                }
            }
            Spacer(minLength: 0)
            SidebarAvatar()
        }
        // 左边略留空隙，右边和底边贴着侧栏边缘，底边与旁边窗口的底边对齐
        .padding(.leading, 4)
        .padding(.top, 10)
    }

    /// 圆环是本周剩余的比例，不到两成时换成警示色。
    private func quota(_ quota: SubscriptionQuota) -> some View {
        let percent = quota.remaining.formatted(.percent.precision(.fractionLength(0)))
        let tint = quota.remaining < 0.2 ? Theme.warning : Color.accentColor
        return chip {
            ZStack {
                Circle().stroke(Theme.rule, lineWidth: 1.5)
                Circle().trim(from: 0, to: quota.remaining)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 8, height: 8)
            Text(quota.provider)
        }
        .help("\(quota.provider) 账号本周剩余 \(percent)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quota.provider) 本周剩余 \(percent)")
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 3) { content() }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Theme.selection, in: Capsule())
    }
}

/// 用户头像，邮箱首字母；点一下进入设置。收起的侧栏里放在图标栏底部。
struct SidebarAvatar: View {
    @Environment(AppModel.self) private var model

    private var user: AccountUser? { model.account.user ?? (SampleWorkspace.enabled ? SampleWorkspace.user : nil) }

    var body: some View {
        Button { withAnimation(.snappy) { model.openSettings() } } label: {
            Text(user?.email.first.map { String($0).uppercased() } ?? "?")
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Metrics.paneHeaderButton, height: Metrics.paneHeaderButton)
                .background(Color.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pointingPlain)
        .help("设置")
        .accessibilityLabel("设置")
        .accessibilityAddTraits(model.sidebarSection == .settings ? .isSelected : [])
    }
}

/// 一级栏的侧栏：各页一行，选中的一页在内容区打开；没接通的置灰。
struct SidebarPageList<Page: SidebarPage>: View {
    @Binding var selection: Page
    /// 选了一页之后；紧凑布局用它收起侧栏。
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Page.allCases) { page in
                Button {
                    selection = page
                    onSelect()
                } label: {
                    SidebarRowLabel(title: page.title, systemImage: page.symbol, note: page.available ? nil : "尚未接通")
                }
                .disabled(!page.available)
                .background(selection == page ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(SidebarRowStyle())
    }
}

/// 一级栏的侧栏内容：工作区以外的栏列出各页。
struct SectionPages: View {
    var onSelect: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.sidebarSection {
        case .extensions: SidebarPageList(selection: $model.extensionPage, onSelect: onSelect)
        case .settings: SidebarPageList(selection: $model.settingsPage, onSelect: onSelect)
        case .workspaces, .drive: EmptyView()
        }
    }
}

/// 工作区以外的栏在内容区显示侧栏选中的那一页。
struct SectionContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.sidebarSection {
        case .extensions: ExtensionContent()
        case .settings: SettingsContent()
        case .workspaces, .drive: EmptyView()
        }
    }
}

/// 扩展一栏的内容区：侧栏选中的那一页。
struct ExtensionContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.extensionPage {
            case .plugins: PluginLibrary()
            case .contexts: ContextTemplateLibrary()
            case .skills: EmptyView()
            }
        }
        .id("\(model.extensionPage.rawValue):\(model.connectionRevision)")
    }
}

/// 扩展一栏里的各页。
nonisolated enum ExtensionLibrary: String, SidebarPage {
    case plugins, contexts, skills

    var id: Self { self }

    var title: String {
        switch self {
        case .plugins: "插件"
        case .contexts: "上下文模板"
        case .skills: "Skill"
        }
    }

    var symbol: String {
        switch self {
        case .plugins: "puzzlepiece.extension"
        case .contexts: "text.document"
        case .skills: "sparkles"
        }
    }

    var available: Bool { self != .skills }
}

/// 侧栏列表滚动时，上方或下方还有内容的那一头渐隐；滚到头的那一头不淡。
private struct ScrollEdgeFade: ViewModifier {
    @State private var above = false
    @State private var below = false
    private static let length: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                [geometry.visibleRect.minY > 0.5, geometry.visibleRect.maxY < geometry.contentSize.height - 0.5]
            } action: { _, edges in
                withAnimation(.easeOut(duration: 0.15)) {
                    above = edges[0]
                    below = edges[1]
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.length)
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

/// 标志栏：Kite 字标，右端一组标题栏玻璃按钮，搜索在前，宽屏后面跟侧边栏按钮。字标与侧栏行的文字左对齐，与按钮底对齐。
/// 两端都有，iPhone 放在侧栏抽屉顶部。搜索尚未接通，先置灰。
struct SidebarLogoBar<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons

    var body: some View {
        // Mac 上字标与按钮底部对齐，iPhone 上垂直居中
        #if os(iOS)
        let alignment = VerticalAlignment.center
        #else
        let alignment = VerticalAlignment.bottom
        #endif
        return HStack(alignment: alignment, spacing: Metrics.paneButtonGap) {
            Text("Kite").font(Theme.wordmark)
            Spacer(minLength: 0)
            PaneHeaderButtonGroup {
                Button {} label: { PaneHeaderButtonLabel("搜索", systemImage: "magnifyingglass") }
                    .disabled(true)
                    .help("搜索（尚未接通）")
                buttons
            }
        }
        .padding(.leading, 10)
        .frame(height: Metrics.paneHeaderButton)
    }
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
        if model.sidebarCollapsed { rail(current) } else { expanded(current) }
    }

    private func expanded(_ current: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoBar.padding(.bottom, Metrics.gap)
            // 标志栏下面是一级导航，再下面是当前一栏的列表
            SidebarNavigation()
                .padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                switch model.sidebarSection {
                case .workspaces, .drive:
                    WorkspaceList { workspace in
                        WorkspaceRow(workspace: workspace, current: current == workspace.id, detached: model.detached.contains(workspace.id))
                            .overlay { source(workspace) }
                    }
                case .extensions, .settings:
                    SectionPages()
                }
            }
            .fadesScrollEdges()
            SidebarUserBar()
        }
    }

    /// 顶部标志栏与卡片标题栏同高同位：卡片在内容区顶边留白之下再留卡片边距。避开上方的红绿灯按钮。
    private var logoBar: some View {
        SidebarLogoBar { sidebarToggle }
        .padding(.top, Metrics.padding + Metrics.paneMargin)
        #if os(macOS)
        // 整条连同上方留白都可以拖动窗口，按钮仍接自己的点击
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        #endif
    }

    /// 收起时侧栏按钮移到第一个窗口的标题栏，见 PaneHeaderBar。列出当前一栏的图标：工作区按项目分组，组间隔一道短线；底部是头像。
    private func rail(_ current: String?) -> some View {
        @Bindable var model = model
        return VStack(spacing: Metrics.gap) {
            SidebarNavigation(iconsOnly: true)
            Capsule().fill(Theme.rule).frame(width: 16, height: 2)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch model.sidebarSection {
                    case .extensions: railPages(selection: $model.extensionPage)
                    case .settings: railPages(selection: $model.settingsPage)
                    case .workspaces, .drive: EmptyView()
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
                                .background(current == workspace.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay { source(workspace) }
                                .help(workspace.title)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .fadesScrollEdges()
            // 设置的入口，底边与旁边窗口的底边对齐
            SidebarAvatar()
        }
        .frame(maxWidth: .infinity)
        // 只让开系统红绿灯按钮所在的区域。
        #if os(macOS)
        .padding(.top, chrome.top)
        #else
        .padding(.top, Metrics.padding)
        #endif
    }

    /// 收起时工作区以外的栏只列各页图标，点一下切页。
    private func railPages<Page: SidebarPage>(selection: Binding<Page>) -> some View {
        ForEach(Page.allCases.filter(\.available)) { page in
            Button { selection.wrappedValue = page } label: {
                Image(systemName: page.symbol)
                    .font(Theme.body)
                    .foregroundStyle(selection.wrappedValue == page ? Color.accentColor : Color.secondary)
                    .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                    .background(selection.wrappedValue == page ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            .help(page.title)
        }
    }

    private var sidebarToggle: some View {
        let title = model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏"
        return Button {
            withAnimation(.snappy) { model.sidebarCollapsed.toggle() }
        } label: {
            PaneHeaderButtonLabel(title, systemImage: "sidebar.left")
        }
        .help(title)
    }

    private func source(_ workspace: WorkArea) -> some View {
        #if os(macOS)
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
        #else
        Color.clear.contentShape(Rectangle())
            .onTapGesture { model.selected = workspace.id }
        #endif
    }
}
