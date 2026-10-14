import SwiftUI

/// 原生台面（Mac 的 StageView、iPad 的 PhoneStageView）两端共用的部分：往上报的几项、台面几何、图层动画的曲线，
/// 和放进托管视图的几块 SwiftUI（停靠栏、停靠栏上面那一层、空画板、卡片里的正文、点阵、头像、窗口按钮）。

/// 原生台面报给 SwiftUI 的几项，由台面外面的 SwiftUI 薄壳发成偏好：有没有窗口开点阵（App 背景让出静息点）、
/// 摆在点阵上的图形（换栏目时收回）、停靠栏悬停浮出的标签。
@MainActor @Observable final class StageReports {
    var usesDots = false
    var dotSlots: Set<String> = []
    var hoverTip: DockHoverTip?
}

/// 会影响托管视图外观的几项环境：变了才给各个托管视图重新交环境（rootView），其余时候托管视图自己读模型更新。
struct StageAppearance: Equatable {
    var colorScheme: ColorScheme
    #if os(macOS)
    var activeState: ControlActiveState
    #else
    var typeSize: DynamicTypeSize
    #endif
    var reduceMotion: Bool
    var displayScale: CGFloat
    var isEnabled: Bool
    var dotStage: ObjectIdentifier?
}

/// 看得见的台面（台面自己的坐标；Mac 拖侧栏改宽时左边让出被侧栏盖住的一段，见 StageView.stageRect），
/// 和关闭途中、停靠栏里那一格先不显示的实例。停靠栏、空画板的托管视图读它，铺到 bounds 的右下角，自己从排布模型算停靠栏各格：
/// 排布的改动在 SwiftUI 的事务里，岛自己读模型才接得到同一个动画（见 StagePlan.dock）；原生层不把算好的格子推进去。
@MainActor @Observable final class StageGeometry {
    var bounds: CGRect = .zero
    var retiring: Set<String> = []
}

/// 台面上的图层动画：曲线与时长同 WindowMotionKind（cubic-bezier(0.2, 0, 0, 1)）；SwiftUI 的弹簧按同样的参数逐帧取样成关键帧。
enum StageAnimation {
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)

    static func spring(_ keyPath: String, from: Double, to: Double, spring: Spring) -> CAKeyframeAnimation {
        let duration = spring.settlingDuration
        let steps = max(Int(duration * 120), 1)
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...steps).map { step in
            from + (to - from) * spring.value(target: 1.0, time: duration * Double(step) / Double(steps))
        }
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }

    static func basic(_ keyPath: String, from: Any, to: Any, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        return animation
    }
}

/// 台面合起来往上报点阵用量（各张卡片、空画板），见 StageIslandReports。
@MainActor protocol StageDotsReporting: AnyObject {
    func reportDots()
}

/// 托管视图报上来的点阵用量。
@MainActor final class StageIslandReports {
    private weak var stage: (any StageDotsReporting)?
    private(set) var usesDots = false
    private(set) var slots: Set<String> = []

    init(stage: any StageDotsReporting) { self.stage = stage }

    func update(uses: Bool? = nil, slots: Set<String>? = nil) {
        if let uses { usesDots = uses }
        if let slots { self.slots = slots }
        stage?.reportDots()
    }
}

// MARK: - 台面上的托管视图

/// 停靠栏：自己从排布模型算停靠栏各格（不读拖缝的比例），排布改动的动画照常落在格子上。
struct StageDockRail: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let dock = StagePlan.dock(layout: layout, area: area, bounds: geometry.bounds).dock
            DockRail(geometry: dock, hiddenInstances: geometry.retiring)
                .environment(area)
                .modifier(PausedInTransition(layout: layout))
                .frame(width: geometry.bounds.maxX, height: geometry.bounds.maxY, alignment: .topLeading)
                .coordinateSpace(.named(DockSpace.name))
                .environment(\.dockCardsDrawPanes, true)
        }
    }
}

/// 停靠栏上面那一层：最小化窗口的脉冲、展开的面板。点了面板里父代理的窗口：在台面上就聚焦，否则放上台面。
struct StageDockOverlay: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            let (regions, dock) = StagePlan.dock(layout: layout, area: area, bounds: bounds)
            DockOverlay(geometry: dock, bounds: bounds, regions: regions) { pane in
                if layout.shown?.panes.contains(pane) == true { layout.focus(pane) }
                else { layout.restore(pane, in: bounds) }
            }
            .environment(area)
            .modifier(PausedInTransition(layout: layout))
            .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
            .coordinateSpace(.named(DockSpace.name))
            .environment(\.dockCardsDrawPanes, true)
        }
    }
}

/// 空台面的画板：台面上没有窗口、也没在拖窗口时出现。它报的偏好传不出托管视图，交给台面合起来往上报。
struct StageWindowless: View {
    let layout: WindowLayout
    let geometry: StageGeometry
    let reports: StageIslandReports

    var body: some View {
        let canvas = layout.regions(in: geometry.bounds).canvas
        SettledWindowlessStage(layout: layout, canvas: canvas, wanted: (layout.shown?.panes.isEmpty ?? true) && layout.drag == nil)
            .frame(width: geometry.bounds.maxX, height: geometry.bounds.maxY, alignment: .topLeading)
            // 隔一拍交出去：托管视图可能在台面这次排版当中更新
            .onPreferenceChange(WindowDotsActive.self) { uses in Task { @MainActor in reports.update(uses: uses) } }
            .onPreferenceChange(DotSlots.self) { slots in Task { @MainActor in reports.update(slots: slots) } }
    }
}

// MARK: - 卡片上的托管视图

/// 正文、窗口按钮读的卡片状态，建好不换：缩没缩成停靠形状、侧栏入口、窗口按钮露不露、是不是会话窗口（标题栏在原生外框里），
/// 变了只更新读它的那一层。
@MainActor @Observable final class CardContentState {
    var minimized = false
    var openSidebar: (@MainActor () -> Void)?
    var buttonsShown = false
    /// 台面上不止一个窗口、窗口按钮里有「展开」。Mac 原生台面由卡片在动画停下时交（见 CardView.arrange）；没给时按排布现算。
    var expands: Bool?
    var nativeThread = false
    /// 卡片交给托管视图的环境换过几次，会话窗口的桥按它把新环境再交给原生外框。
    var environment = 0
}

/// 卡片的正文：托管视图里的 PaneCardBody 和它的环境。缩没缩成停靠形状、侧栏入口从卡片状态读，
/// 变了只更新这一层。
struct CardContent: View {
    let group: PaneGroup
    let pane: Pane
    let state: CardContentState
    let header: PaneCardHeader
    let headerRegions: HeaderRegions
    let presence: PanePresence
    let motion: WindowMotion
    let reports: PaneCardBodyReports
    let link: HostedContentLink
    let carrier: DotCarrier
    let scope: DotScope
    /// 会话窗口的原生外框接在哪。
    let threadSlot: ThreadWindowSlot

    var body: some View {
        HostedPlaced(content: PaneCardBody(group: group, pane: pane, minimized: state.minimized, header: header, headerRegions: headerRegions,
                                           presence: presence, motion: motion, reports: reports, reportsHeader: !state.nativeThread),
                     link: link)
            .environment(\.nativeThreadWindow, threadSlot)
            .environment(\.nativeThreadGeneration, state.environment)
            .environment(\.openSidebar, state.openSidebar)
            .environment(\.dotCarrier, carrier)
            .environment(\.dotScope, scope)
            .environment(\.windowMotion, motion)
    }
}

/// 点阵层：窗口开了点阵才画，网格固定在屏幕上，同 WindowSurfaceDots。
struct CardDots: View {
    let reports: PaneCardBodyReports
    let carrier: DotCarrier
    let scope: DotScope
    let motion: WindowMotion

    var body: some View {
        WindowSurfaceDots(enabled: reports.usesDots)
            .environment(\.dotCarrier, carrier)
            .environment(\.dotScope, scope)
            .environment(\.windowMotion, motion)
    }
}

/// 头像：代理是停靠栏的头像（不带脉冲、描边交给外框画），其余是图标。
struct CardIcon: View {
    let appearance: WindowAppearance
    let area: WorkArea?
    let instance: RemotePluginInstance?
    let pane: Pane
    let size: CGFloat
    let ring: @MainActor (Color?) -> Void

    var body: some View {
        Group {
            if appearance.isAgent, let area {
                DockEntryFace(subject: instance.map { .instance($0) } ?? .pane(pane), pulse: false, ring: false)
                    .environment(area)
            } else {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(Theme.ink)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        // 隔一拍交出去：托管视图可能在外面这次排版当中更新
        .onPreferenceChange(DockRingColor.self) { color in Task { @MainActor in ring(color) } }
    }
}

/// 窗口按钮（缩小、展开、关闭）：悬停卡片时露出来（触屏一直露），飞行中、拖动和拖缝时看不见也不接输入。
/// 露不露由卡片算好放在状态里（见 PaneHeaderControls），实际尺寸报给标题栏让位。
struct CardButtons: View {
    let group: PaneGroup
    let pane: Pane
    let header: PaneCardHeader
    let state: CardContentState
    let motion: WindowMotion
    @Environment(AppModel.self) private var model

    var body: some View {
        if let area = group.workspace {
            let layout = group.layout
            let expands = state.expands ?? ((layout.shown?.panes.count ?? 0) > 1)
            PaneHeaderButtonGroup {
                button("缩小", icon: "minus") { layout.minimize(pane) }
                if expands {
                    button("展开", icon: "arrow.up.left.and.arrow.down.right") { layout.expand(pane) }
                }
                button("关闭", icon: "xmark") { model.closeWindow(pane, in: area) }
                    .disabled(area.isDraft || area.changingWindows || area.creatingWindow == pane.id)
            }
            // 缩小、恢复时台面上的窗口数变了，展开按钮出现消失不跟排布的动画走：飞行中按钮组本来看不见，
            // 带着动画这个托管视图每帧要重排几遍（2026-10-14 实测，一次缩小或恢复约 117 次、合计约 49 ms）
            .animation(nil, value: expands)
            // 按系统控件的实际尺寸安排标题栏并避让拖动
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if header.controlsSize != size { header.controlsSize = size }
            }
            .modifier(WhileSettled(motion: motion, shown: state.buttonsShown))
            .accessibilityHidden(!state.buttonsShown)
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}
