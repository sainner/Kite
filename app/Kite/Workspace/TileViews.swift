import SwiftUI

/// 宽屏的台面：各张卡片、空画板、卡片之间的缝和停靠栏按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// Mac 是原生的 StageView，iPad 是原生的 PhoneStageView。
/// 台面的大小、位置不跟 SwiftUI 的动画逐帧变：侧栏收起、展开时它一下子换到终点，窗口由台面按终点排一次、交给 Core Animation 飞过去
/// （见 StageView.layout）。逐帧改的话每一帧台面上的窗口都要改大小，正文跟着重排（2026-10-20 Mac 实测，收起、展开一次 0.8 秒里
/// 主线程约 660 毫秒、掉 30 多帧）。
struct TilesLayer: View {
    let group: PaneGroup

    var body: some View {
        Group {
            #if os(macOS)
            StageHost(group: group)
            #else
            PhoneStageHost(group: group)
            #endif
        }
        .transaction { $0.animation = nil }
    }
}

/// 过渡中（见 WindowLayout.transitioning）停靠栏、缝不接点击和悬停。
/// 过渡状态在这一层读：开始、结束过渡只更新这一层，摆卡片的整层不跟着重算。
struct PausedInTransition: ViewModifier {
    let layout: WindowLayout
    /// 拖缝调整大小也算。正拖着的缝自己不算，照常接。
    var whileResizing = true

    func body(content: Content) -> some View {
        content.allowsHitTesting(!(whileResizing ? layout.transitioning : layout.blocksInput))
    }
}

extension View {
    /// 按 rect 定大小和位置，坐标是所在容器的。
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

extension AnyTransition {
    /// placed(rect) 摆的视图进出时以 rect 的中心缩放。placed 的视图铺满整个容器，.scale 的 anchor 按容器算，
    /// 不是按 rect：锚在中心就成了容器中心，格子会从台面中间斜着飞过来。所以以容器原点为锚缩放，再挪回 rect 的中心。
    static func scale(_ scale: CGFloat, placedIn rect: CGRect) -> AnyTransition {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return .modifier(active: PlacedScale(scale: scale, point: point), identity: PlacedScale(scale: 1, point: point))
    }
}

private struct PlacedScale: ViewModifier {
    let scale: CGFloat
    let point: CGPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: (1 - scale) * point.x, y: (1 - scale) * point.y)
    }
}

/// 正文只收内容身份和共享状态；卡片每次改尺寸时，不把包含整张卡片的偏好回调重新交给托管视图。
struct PaneCardBody: View {
    let group: PaneGroup
    let pane: Pane
    let minimized: Bool
    let header: PaneCardHeader
    let headerRegions: HeaderRegions
    let presence: PanePresence
    let motion: WindowMotion
    let reports: PaneCardBodyReports
    /// 标题栏在这里面：标题栏报的几项从这里接。Mac 宽屏的原生会话窗口（ThreadWindowView）的标题栏在它自己的托管视图里，从那边接。
    var reportsHeader = true

    var body: some View {
        PaneBody(group: group, pane: pane, retainForExit: true)
            .coordinateSpace(.named(DotCarrier.space))
            .paneFocus(pane, in: group.layout, enabled: !minimized)
            .modifier(PaneHeaderEnvironment(header: header, group: group, pane: pane))
            .environment(\.panePresence, presence)
            .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .modifier(WhileSettled(motion: motion, shown: !minimized, fades: false))
            .accessibilityHidden(minimized)
            // 托管正文报出的偏好在这里接；点阵两项再由外框转交给 App 背景和 DotsPresence。
            .onPreferenceChange(WindowDotsActive.self) { reports.usesDots = $0 }
            .onPreferenceChange(DotSlots.self) { reports.dotSlots = $0 }
            .modifier(PaneHeaderReports(header: header, regions: headerRegions, motion: motion, enabled: reportsHeader))
    }
}

/// 标题栏报上来的菜单宽、高度和可点控件的范围，交给卡片：拖动区按它们让位、挖空。
struct PaneHeaderReports: ViewModifier {
    let header: PaneCardHeader
    let regions: HeaderRegions
    let motion: WindowMotion
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .onPreferenceChange(PaneHeaderActionsWidth.self) { width in
                    if header.menuWidth != width { header.menuWidth = width }
                }
                .onPreferenceChange(PaneHeaderHeight.self) { height in
                    if header.height != height { header.height = height }
                }
                .onPreferenceChange(PaneHeaderInteractiveRects.self) { rects in
                    regions.rects = rects
                    if !motion.moving { regions.settled = rects }
                }
        } else {
            content
        }
    }
}

@Observable final class PaneCardBodyReports {
    var usesDots = false
    var dotSlots: Set<String> = []
    /// Mac 原生会话窗口外框里铺满窗口的那个托管视图报的（空会话的签名、录音的那一带），见 ThreadWindowView。
    var threadSlots: Set<String> = []
}

@MainActor func paneWindowActions(group: PaneGroup, pane: Pane, model: AppModel) -> PaneWindowActions? {
    guard let area = group.workspace else { return nil }
    let layout = group.layout
    var close: (@MainActor () -> Void)?
    if area.hasClose(pane) { close = { model.close(pane, in: area) } }
    return PaneWindowActions(minimize: { layout.minimize(pane) }, expansion: layout.expansion(of: pane),
                             expand: { layout.expand(pane) }, collapse: { layout.collapse(pane) },
                             close: close, canClose: area.canClose(pane))
}

/// 卡片标题栏的悬停和几项实际尺寸，由外框、按钮组和正文报上来，只有读它们的几层随之更新。
/// 正文标题栏给窗口按钮让位也按它算（PaneHeaderControlsSpace），悬停一变只有标题栏读它的那一层更新。
@Observable final class PaneCardHeader: PaneHeaderControlsSpace {
    var hovered = false
    /// 正文标题栏右侧菜单的宽度。改了宽，右组正在伸缩，见 actionsResizing。
    var menuWidth: CGFloat = 0 {
        didSet { if oldValue > 0, menuWidth != oldValue { resizeActions() } }
    }
    /// 右组正在伸缩（浏览的侧栏开关伸成搜索框）：报上来的已是终点宽度，窗口按钮这时露出来会先跳过去。
    /// 藏到右组按 Animation.paneHeaderActions 伸缩完，同窗口在动时不接悬停；给它们留的地方照留，标题不跟着来回让。
    private(set) var actionsResizing = false
    @ObservationIgnored private var actionsSettle: Task<Void, Never>?
    /// 窗口按钮组（缩小、展开、关闭）的实际尺寸。
    var controlsSize = CGSize.zero
    /// 正文标题栏的实际高度。
    var height: CGFloat = 0
    /// 卡片报来的几项，正文标题栏按它们算让出多少（见 PaneHeaderControlsSpace）。
    var placement = HeaderPlacement()
    @ObservationIgnored weak var layout: WindowLayout?

    var inset: CGFloat {
        guard let layout else { return 0 }
        let controls = PaneHeaderControls(header: self, layout: layout, minimized: placement.minimized, width: placement.width,
                                          hasThread: placement.hasThread)
        return controls.revealed ? controlsSize.width + Metrics.paneButtonGap : 0
    }

    var minHeight: CGFloat { controlsSize.height }

    private func resizeActions() {
        actionsResizing = true
        actionsSettle?.cancel()
        actionsSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Animation.paneHeaderActionsDuration))
            guard !Task.isCancelled else { return }
            self?.actionsResizing = false
        }
    }
}

/// 窗口按钮放不放得下、该不该露出来要看的卡片状态。
struct HeaderPlacement: Equatable {
    var minimized = false
    var width: CGFloat = 0
    var hasThread = false
}

/// 窗口按钮放在哪：标题栏上露出来、藏着，还是收进正文的更多菜单。读 PaneCardHeader 的几层各自用它算。
struct PaneHeaderControls {
    let header: PaneCardHeader
    let layout: WindowLayout
    let minimized: Bool
    let width: CGFloat
    let hasThread: Bool

    /// 按完整控制组计算，不能随悬停显隐改变判断；圆环占一个按钮宽，标题至少保留两个按钮宽。
    var inMenu: Bool {
        guard !minimized, hasThread, header.menuWidth > 0 else { return false }
        let required = 2 * Metrics.paneMargin + header.menuWidth + header.controlsSize.width
            + 3 * Metrics.paneButtonGap + 3 * Metrics.paneHeaderButton
        return width < required
    }

    /// 按悬停该露出来；标题栏按它给窗口按钮留地方。右组正在伸缩时先藏着（shown），见 PaneCardHeader.actionsResizing。
    var revealed: Bool {
        !layout.isFixed && !inMenu && InputMode.current.revealsControls(hovered: header.hovered) && !minimized
            && layout.drag == nil && layout.resizing == nil
    }

    var shown: Bool { revealed && !header.actionsResizing }
}

/// 正文标题栏按窗口按钮让位（见 PaneHeaderControlsSpace）、收进菜单；在正文的托管视图里读，卡片不跟着重算。
/// 卡片窄于 narrowPaneWidth 时正文按窄排（narrowTile）；缩在停靠栏里不算，免得缩小时正文跟着换排法。
struct PaneHeaderEnvironment: ViewModifier {
    let header: PaneCardHeader
    let group: PaneGroup
    let pane: Pane
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let placement = header.placement
        let controls = PaneHeaderControls(header: header, layout: group.layout, minimized: placement.minimized,
                                          width: placement.width, hasThread: placement.hasThread)
        content
            .environment(\.paneOverflowActions, controls.inMenu ? paneWindowActions(group: group, pane: pane, model: model) : nil)
            .environment(\.paneHeaderControlsSpace, header)
            .environment(\.narrowTile, !placement.minimized && placement.width > 0 && placement.width < WorkspacePresentation.narrowPaneWidth)
    }
}

/// 命中区域在动画完成时交给原生拖动层，避免标题逐帧补位引起整段正文重算。
@Observable final class HeaderRegions {
    /// 正文最新报上来的。
    @ObservationIgnored var rects: [CGRect] = []
    /// 拖动区挖掉的：停着时跟着 rects，动画中保持动画开始前的，停下再换。
    var settled: [CGRect] = []
}

/// 窗口在动时看不见、不接输入（shown 为 false 时一直这样）。动画开始、结束只更新这一层。
struct WhileSettled: ViewModifier {
    let motion: WindowMotion
    let shown: Bool
    var fades = true

    func body(content: Content) -> some View {
        let active = shown && !motion.moving
        content
            .opacity(fades && !active ? 0 : 1)
            .allowsHitTesting(active)
    }
}

/// 网格固定在屏幕上，静息的网点不随卡片走。窗口在动时整层收起（见 CardView），卡片上的图形也不逐帧跟随。
struct WindowSurfaceDots: View {
    let enabled: Bool

    var body: some View {
        if enabled { DotCanvas() }
    }
}

/// 新建实例的选择页（见 WorkArea.chooserPane）：台面空着时垫底，也由停靠栏的加号打开。内置插件两列卡片，项目的预览目标和自定义插件列在下面；
/// 点一项，这一格原地变成它（ID 与位置不换），目标变成以它起的预览，装到「设备」里选的那台。打开时重新读一次定义、目标与设备候选，
/// 别处新装的插件、工作区里新加的目标、刚配对的设备也能列出。上次创建没成功时标题栏有重试。
struct NewWindowChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var error: String?
    @State private var targets: [String] = []
    @State private var devices: [DeviceCandidate] = []
    /// 目标装到哪台设备；没选时由目标自己定（用到模拟器的用默认型号）。
    @State private var device: DeviceCandidate?

    var body: some View {
        // 监视只由代理或 Line 开启，工作机不接受从界面新建；预览按目标起，列在下面
        let definitions = area.definitions.filter { $0.id != AppModel.monitorDefinition && $0.id != AppModel.previewDefinition }
        // 工作机自带的定义没有 runtime，插件包是 bun
        let builtins = definitions.filter { $0.runtime == nil }, custom = definitions.filter { $0.runtime != nil }
        let canAdd = area.canAddWindows(connected: model.isConnected(area))
        PaneWindow(header: PaneHeader(title: "新建窗口", subtitle: "选择插件"), notice: error.map(PaneNotice.failure), actions: actions) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !builtins.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CardLabel("内置插件")
                            let tiles = builtins.flatMap(tiles(of:))
                            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { start in
                                    GridRow {
                                        ForEach(tiles[start..<min(start + 2, tiles.count)], id: \.title) { tile in
                                            CardTile(title: tile.title, detail: tile.detail, systemImage: tile.icon, action: tile.action)
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(!canAdd)
                    }
                    if !targets.isEmpty {
                        CardSection("预览目标") {
                            Menu { deviceMenu } label: {
                                rowLabel("设备", detail: device.map(deviceDetail) ?? "目标自己定：用到模拟器的装到默认型号", systemImage: "chevron.up.chevron.down")
                                    .contentShape(Rectangle())
                            }
                            .menuIndicator(.hidden)
                            .buttonStyle(.pointingPlain)
                            ForEach(targets, id: \.self) { name in
                                let spec = PreviewSpec(target: name, device: device?.device)
                                let running = area.preview(for: spec)?.state?.terminal?.running == true
                                row(name, detail: running ? "运行中，打开它的预览" : "运行并预览", systemImage: "play.fill") {
                                    model.choosePreview(spec, deviceTitle: device?.title, in: area)
                                }
                            }
                        }
                        .disabled(!canAdd)
                    }
                    if !custom.isEmpty {
                        CardSection("自定义插件") {
                            ForEach(custom) { definition in
                                row(definition.title, detail: views(of: definition), systemImage: "plus") { model.choose(definition, in: area) }
                            }
                        }
                        .disabled(!canAdd)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
        .task {
            // 定义和目标同时取，哪个没取到都报在提示里
            async let listed = model.previewTargets(in: area)
            do { try await model.refreshDefinitions(model.activeClient(in: area)); error = nil }
            catch { self.error = error.localizedDescription }
            do {
                let result = try await listed
                targets = result.targets
                devices = result.devices
                // 在 iPhone、iPad 上默认选中手上这台：按硬件型号对配对过、够得着的真机，同型号不止一台时不猜
                if device == nil, let model = AppModel.deviceModel {
                    let matches = devices.filter { $0.kind == .physical && $0.model == model && $0.connected == true }
                    if matches.count == 1 { device = matches[0] }
                }
            }
            catch { self.error = error.localizedDescription }
        }
    }

    /// 下面几节的一行：名字、一行说明，右边是点了做什么的图标。
    private func row(_ title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, detail: detail, systemImage: systemImage) }
    }

    private func rowLabel(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(Theme.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: systemImage).font(Theme.caption.weight(.semibold))
        }
    }

    /// 设备候选：目标自己定，或模拟器型号（按 iPhone、iPad 分组）、配对过的真机；够不着的真机选不了。
    @ViewBuilder private var deviceMenu: some View {
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

    private func deviceDetail(_ candidate: DeviceCandidate) -> String {
        candidate.kind == .physical ? "装到真机 \(candidate.title)，没有画面，装好后拿起来用" : "装到 \(candidate.model) 模拟器"
    }

    private var actions: PaneHeaderActions {
        guard !area.failedInstanceRequests.isEmpty else { return PaneHeaderActions() }
        return PaneHeaderActions(groups: [[PaneHeaderAction(title: "重试创建", systemImage: "arrow.clockwise") { model.retryRequests(in: area) }]])
    }

    private struct Tile {
        let title: String
        let detail: String
        let icon: String
        let action: () -> Void
    }

    /// 内置插件的格子：一个定义一格（预览按目标起，不在这里）。
    private func tiles(of definition: RemotePluginDefinition) -> [Tile] {
        [Tile(title: definition.title, detail: definition.description ?? views(of: definition),
              icon: WindowAppearance.definition(definition).icon) { model.choose(definition, in: area) }]
    }

    private func views(of definition: RemotePluginDefinition) -> String {
        definition.views.isEmpty ? "后台实例" : definition.views.map(\.title).joined(separator: "、")
    }
}

extension WorkArea {
    /// 工作区在线且未归档时才能新建实例；别的请求还在路上不妨碍。
    func canAddWindows(connected: Bool) -> Bool {
        connected && remote.workspace.status == .open
    }
}

/// 实例操作失败时的提示，可以重试。
struct WindowErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    func body(content: Content) -> some View {
        content
            .alert("窗口操作失败", isPresented: Binding(get: { area.windowError != nil }, set: { if !$0 { area.windowError = nil } })) {
                if !area.failedInstanceRequests.isEmpty {
                    Button("重试添加") { model.retryRequests(in: area) }
                }
                Button("好", role: .cancel) { area.windowError = nil }
            } message: { Text(area.windowError ?? "") }
    }
}
