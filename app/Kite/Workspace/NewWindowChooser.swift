import SwiftUI

/// 新建实例的选择页（见 WorkArea.chooserPane）：台面空着时垫底，也由停靠栏的加号打开。代理按角色列出，工具、项目的预览目标各一组，
/// 每项一个圆形头像，同停靠栏的格子。点一项，这一格原地变成它（ID 与位置不换）：角色起这个角色的新代理草稿，
/// 目标起以它运行的预览，装到组标题旁边选的设备上。打开时重新读一次定义、角色、目标与设备候选，别处新装的插件、新加的角色与目标、
/// 刚配对的设备也能列出；读不到的报在信息区，上次创建没成功时标题栏有重试。工作区还没打开（正在准备、准备失败、已归档、流转中）时
/// 不能新建，各项变灰，信息区说明原因，预览目标不去读（工作机只给打开着的工作区列目标）。
/// 宽排（垫底或宽卡片）各组居中，整块在页面里上下居中；窄排各组靠左、从顶上排起。两种排法是同一份内容。
struct NewWindowChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.narrowPane) private var narrow
    @State private var error: String?
    @State private var targets: [String] = []
    @State private var devices: [DeviceCandidate] = []
    /// 目标装到哪台设备；没选时由目标自己定（用到模拟器的用默认型号）。
    @State private var device: DeviceCandidate?

    /// 宽排时各组最宽多少：Mac 一行七个头像，触屏六个。
    private static let wideColumn: CGFloat = 640

    var body: some View {
        // 监视只由代理或 Line 开启，工作机不接受从界面新建；预览按目标起，列在自己那一组
        let definitions = area.definitions.filter { $0.id != AppModel.monitorDefinition && $0.id != AppModel.previewDefinition }
        let agents = definitions.filter { $0.agent != nil }
        // 工作机自带的定义没有 runtime，排在插件包前面
        let tools = definitions.filter { $0.agent == nil && $0.runtime == nil } + definitions.filter { $0.agent == nil && $0.runtime != nil }
        let notice = error.map(PaneNotice.failure) ?? area.closedReason.map { PaneNotice.info($0) }
        PaneWindow(header: PaneHeader(title: "新建窗口"), notice: notice, actions: actions) {
            ScrollView {
                VStack(alignment: narrow ? .leading : .center, spacing: narrow ? 20 : 32) {
                    if !agents.isEmpty {
                        group("代理") { agentTiles(agents) }
                    }
                    if !tools.isEmpty {
                        group("工具") { ForEach(tools, content: toolTile) }
                    }
                    if !targets.isEmpty {
                        group("预览", accessory: { deviceMenu }) { ForEach(targets, id: \.self, content: targetTile) }
                    }
                }
                .disabled(!area.canAddWindows(connected: model.isConnected(area)))
                .frame(maxWidth: narrow ? .infinity : Self.wideColumn, alignment: narrow ? .leading : .center)
                .padding(.horizontal, Metrics.padding)
                .padding(.vertical, narrow ? Metrics.padding : CardMetrics.inset)
                .frame(maxWidth: .infinity, alignment: narrow ? .leading : .center)
                .separateScrollPocket()
            }
            .scrollBounceBehavior(.basedOnSize)
            // 宽排时比滚动区矮的内容放在正中
            .defaultScrollAnchor(narrow ? .top : .center, for: .alignment)
        } controls: { _ in
            EmptyView()
        }
        // 工作区打开以后再读一次，预览目标这时才读得到
        .task(id: area.remote.workspace.status == .open) { await load() }
    }

    /// 一组：小标题（预览的旁边是设备），下面一排头像，放不下换行。
    private func group(_ title: String, @ViewBuilder accessory: () -> some View = { EmptyView() },
                       @ViewBuilder tiles: () -> some View) -> some View {
        VStack(alignment: narrow ? .leading : .center, spacing: 4) {
            HStack(spacing: 4) {
                CardLabel(title)
                if narrow { Spacer(minLength: 0) }
                accessory()
            }
            FlowLayout(spacing: 8, rowSpacing: 4, alignment: narrow ? .topLeading : .top) { tiles() }
        }
    }

    /// 代理按角色列，默认角色在前；角色目录还没读到时只有一个默认的入口，选了用默认角色。
    @ViewBuilder private func agentTiles(_ agents: [RemotePluginDefinition]) -> some View {
        if let catalog = model.roles(in: area), !catalog.roles.isEmpty, let agent = agents.first {
            let first = catalog.defaultRole
            let roles = (first.map { [$0] } ?? []) + catalog.roles.filter { $0.id != first?.id }
            ForEach(roles) { role in
                AvatarTile(title: role.role.title, large: !narrow) { start(agent, role: role) } face: {
                    // 同一角色每次打开姿态一样，按角色取
                    DockFace(look: .agent(instance: role.id, design: role.emblem?.design))
                }
            }
        } else {
            ForEach(agents) { definition in
                AvatarTile(title: definition.title, large: !narrow) { start(definition, role: nil) } face: {
                    DockFace(look: .agent(instance: definition.id, design: nil))
                }
            }
        }
    }

    private func toolTile(_ definition: RemotePluginDefinition) -> some View {
        // 只在后台的插件不开窗口，选了放进停靠栏
        AvatarTile(title: definition.title, detail: definition.views.isEmpty ? "后台运行" : nil, large: !narrow) { model.choose(definition, in: area) } face: {
            ToolFace(appearance: .definition(definition))
        }
        .help(definition.description ?? definition.title)
    }

    private func targetTile(_ name: String) -> some View {
        let spec = PreviewSpec(target: name, device: device?.device)
        let running = area.preview(for: spec)?.state?.terminal?.running == true
        return AvatarTile(title: name, detail: running ? "运行中" : nil, large: !narrow) {
            model.choosePreview(spec, deviceTitle: device?.title, in: area)
        } face: {
            ToolFace(appearance: .renderer("preview"))
        }
        .help(running ? "运行中，打开它的预览" : "运行并预览")
    }

    /// 选了一个角色：这一格原地变成新代理的草稿；已有草稿时调出那份（见 WorkArea.chooseAgent）。角色同草稿现在的不一样就换上，
    /// 同标题栏的角色菜单，在旧角色上改过的参数清掉；正在发出的草稿不换。
    private func start(_ definition: RemotePluginDefinition, role: AgentRole?) {
        model.choose(definition, in: area)
        let draft = area.draftThread
        guard let role, area.creatingInstance != draft.id, model.newThreadRole(for: draft, in: area)?.id != role.id else { return }
        draft.draftChoice = DraftAgentChoice()
        draft.agentCapabilities = draft.agentOptions?.capabilities(for: role.id)
        draft.role = role
    }

    /// 定义、角色和目标同时取，哪个没取到都报在信息区。工作区没打开时不读目标：工作机会拒绝，这不算失败，原因由信息区说明。
    private func load() async {
        let opened = area.remote.workspace.status == .open
        async let listed: PreviewTargets? = opened ? model.previewTargets(in: area) : nil
        async let roles: Void = model.ensureRoles(in: area)
        var failure: String?
        do { try await model.refreshDefinitions(model.activeClient(in: area)) } catch { failure = error.localizedDescription }
        do { try await roles } catch { failure = failure ?? error.localizedDescription }
        do {
            if let result = try await listed {
                targets = result.targets
                devices = result.devices
                // 在 iPhone、iPad 上默认选中手上这台：按硬件型号对配对过、够得着的真机，同型号不止一台时不猜
                if device == nil, let model = AppModel.deviceModel {
                    let matches = devices.filter { $0.kind == .physical && $0.model == model && $0.connected == true }
                    if matches.count == 1 { device = matches[0] }
                }
            } else {
                targets = []
                devices = []
            }
        } catch {
            failure = failure ?? error.localizedDescription
        }
        error = failure
    }

    /// 预览组标题旁边的设备：一枚次级按钮样子的小胶囊，点开是候选菜单；说明放在悬停提示里。
    private var deviceMenu: some View {
        Menu { deviceItems } label: {
            HStack(spacing: 4) {
                Text(device.map(deviceTitle) ?? "目标自己定").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(Theme.caption)
        }
        .menuStyle(.button)
        .buttonStyle(PaneButtonStyle(text: true, secondary: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(device.map(deviceDetail) ?? "目标自己定：用到模拟器的装到默认型号")
    }

    /// 设备候选：目标自己定，或模拟器型号（按 iPhone、iPad 分组）、配对过的真机；够不着的真机选不了。
    @ViewBuilder private var deviceItems: some View {
        Button { device = nil } label: { checked("目标自己定", device == nil) }
        let physical = devices.filter { $0.kind == .physical }
        if !physical.isEmpty {
            Section("真机（只装包）") {
                ForEach(physical) { candidate in
                    Button { device = candidate } label: { checked("\(candidate.title)（\(candidate.marketingName ?? candidate.model)）", device == candidate) }
                        .disabled(candidate.connected != true)
                }
            }
        }
        ForEach(["iPhone", "iPad"], id: \.self) { family in
            let simulators = devices.filter { $0.kind == .simulator && $0.family == family }
            if !simulators.isEmpty {
                Menu("\(family) 模拟器") {
                    ForEach(simulators) { candidate in
                        Button { device = candidate } label: { checked(candidate.model, device == candidate) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func deviceTitle(_ candidate: DeviceCandidate) -> String {
        candidate.kind == .physical ? "真机 \(candidate.title)" : "\(candidate.model) 模拟器"
    }

    private func deviceDetail(_ candidate: DeviceCandidate) -> String {
        candidate.kind == .physical ? "装到真机 \(candidate.title)，没有画面，装好后拿起来用" : "装到 \(candidate.model) 模拟器"
    }

    private var actions: PaneHeaderActions {
        guard !area.failedInstanceRequests.isEmpty else { return PaneHeaderActions() }
        return PaneHeaderActions(groups: [[PaneHeaderAction(title: "重试创建", systemImage: "arrow.clockwise") { model.retryRequests(in: area) }]])
    }
}

/// 工具的圆形头像：停靠栏里工具格的样子（中性色底、类别图标）裁成圆。
private struct ToolFace: View {
    let appearance: WindowAppearance

    var body: some View {
        DockFace(look: .tool(appearance)).clipShape(Circle())
    }
}

extension WorkArea {
    /// 工作区在线且未归档时才能新建实例；别的请求还在路上不妨碍。
    func canAddWindows(connected: Bool) -> Bool {
        connected && remote.workspace.status == .open
    }

    /// 工作区不是打开着的时候不能新建的原因，新建页的信息区写它；措辞同会话标题栏的状态（见 WorkThread.statusLabel）。
    var closedReason: String? {
        switch remote.workspace.status {
        case .open: nil
        case .preparing: "正在准备工作区，准备好以后才能新建"
        case .failed: "工作区准备失败，不能新建"
        case .archived: "工作区已归档，不能新建"
        case .handingOff: "正在交给另一台工作机，不能新建"
        case .transferred: "已流转到另一台工作机，不能新建"
        }
    }
}
