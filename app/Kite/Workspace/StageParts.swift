import SwiftUI

/// 原生台面（Mac 的 StageView、iPad 的 PhoneStageView）两端共用的部分：往上报的几项、台面几何、图层动画的曲线，
/// 和放进托管视图的几块 SwiftUI（停靠栏、能展开的格子、停靠栏上面那一层、空画板、卡片里的正文、点阵、头像、窗口按钮）。

/// 原生台面报给 SwiftUI 的几项，由台面外面的 SwiftUI 薄壳发成偏好：有没有窗口开点阵（App 背景让出静息点）、
/// 摆在点阵上的图形（换栏目时收回）、停靠栏悬停浮出的标签。
@MainActor @Observable final class StageReports {
    var usesDots = false
    var dotSlots: Set<String> = []
    var hoverTips: [DockHoverTip] = []
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
/// 关闭途中、停靠栏里那一格先不显示的实例，和抬到卡片上面的格子。停靠栏、空画板的托管视图读它，铺到 bounds 的右下角，自己从排布模型算停靠栏各格：
/// 排布的改动在 SwiftUI 的事务里，岛自己读模型才接得到同一个动画（见 StagePlan.dock）；原生层不把算好的格子推进去。
@MainActor @Observable final class StageGeometry {
    var bounds: CGRect = .zero
    var retiring: Set<String> = []
    /// 抬到卡片上面的格子：展开着和正收回的家族格、「更多」，见 DockUnfold。
    var lifted: Set<String> = []
}

/// 侧栏收起、展开时空画板从原来的地方排到终点。台面一下子换了大小（见 TilesLayer），卡片交给 Core Animation 飞；
/// 空画板是 SwiftUI，摆在上面的点阵图形按它的排版走，所以由台面的显示链接按窗口的曲线和时长每帧排一次，和卡片、侧栏一起到。
struct WindowlessFlight {
    var from: CGRect
    let to: CGRect
    /// 头一帧的显示时刻，同卡片等这次排版交上去再计时（见 WindowMotion.move）。
    private var start: CFTimeInterval?

    init(from: CGRect, to: CGRect) {
        self.from = from
        self.to = to
    }

    /// 显示时刻 time 这一帧排在哪；走完返回 nil。
    mutating func frame(at time: CFTimeInterval) -> CGRect? {
        let start = start ?? time
        self.start = start
        let fraction = (time - start) / WindowMotionKind.settle.duration
        guard fraction < 1 else { return nil }
        let p = CGFloat(WindowMotionKind.curve.value(at: fraction))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
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
            let bounds = geometry.bounds
            let dock = StagePlan.dock(layout: layout, area: area, bounds: bounds).dock
            DockRail(geometry: dock, hiddenInstances: geometry.retiring) { pane in StagePlan.show(pane, layout: layout, in: bounds) }
                .environment(area)
                .modifier(PausedInTransition(layout: layout))
                .frame(width: geometry.bounds.maxX, height: geometry.bounds.maxY, alignment: .topLeading)
                .coordinateSpace(.named(DockSpace.name))
                .environment(\.dockCardsDrawPanes, true)
                .modifier(StageIslandFill())
        }
    }
}

/// 停靠栏里能展开的一格单独一层，见 DockUnfold；lift 把这一层抬到卡片上面或放回去。
/// 点了里面开着窗口的代理：在台面上就聚焦，否则放上台面。
struct StageDockUnfold: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry
    let id: String
    /// 台面排好以后才有的格子，见 DockUnfold.shown。
    let appearing: Bool
    let lift: (Bool) -> Void

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            let (regions, dock) = StagePlan.dock(layout: layout, area: area, bounds: bounds)
            DockUnfold(geometry: dock, regions: regions, id: id, hiddenInstances: geometry.retiring, appearing: appearing, lift: lift) { pane in
                StagePlan.show(pane, layout: layout, in: bounds)
            }
            .environment(area)
            .modifier(PausedInTransition(layout: layout))
            .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
            .coordinateSpace(.named(DockSpace.name))
            .modifier(StageIslandFill())
        }
    }
}

/// 停靠栏上面那一层：最小化窗口的脉冲、悬停标签。
struct StageDockOverlay: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            let dock = StagePlan.dock(layout: layout, area: area, bounds: bounds).dock
            DockOverlay(geometry: dock, bounds: bounds, lifted: geometry.lifted)
            .environment(area)
            .modifier(PausedInTransition(layout: layout))
            .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
            .coordinateSpace(.named(DockSpace.name))
            .environment(\.dockCardsDrawPanes, true)
            .modifier(StageIslandFill())
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
            .modifier(StageIslandFill())
    }
}

/// 台面的托管视图比台面宽（右边多排一段，见 StageView.trailingOverflow），里面按台面大小排的内容贴左上角，不被摆到正中。
private struct StageIslandFill: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 卡片上的托管视图

/// 正文、窗口按钮读的卡片状态，建好不换：缩没缩成停靠形状、侧栏入口、窗口按钮露不露、是不是会话窗口（标题栏在原生外框里），
/// 变了只更新读它的那一层。
@MainActor @Observable final class CardContentState {
    var minimized = false
    var openSidebar: (@MainActor () -> Void)?
    var buttonsShown = false
    /// 窗口按钮组藏着时单独露出图钉，见 PaneHeaderControls.pinShown。
    var pinShown = false
    var pinned = false
    /// 窗口按钮里展开那一格是展开、还原还是没有。由卡片在动画停下时交（见 CardView.arrange、PhoneCardView.arrange）；没给时按排布现算。
    var expansion: PaneExpansion?
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

/// 窗口按钮（缩小、展开或还原、关闭、固定）：悬停卡片时露出来（触屏一直露），飞行中、拖动和拖缝时看不见也不接输入；
/// 固定的窗口不悬停时单独露出图钉。露不露由卡片算好放在状态里（见 PaneHeaderControls），实际尺寸报给标题栏让位。
struct CardButtons: View {
    let group: PaneGroup
    let pane: Pane
    let header: PaneCardHeader
    let state: CardContentState
    let motion: WindowMotion
    /// 露不露（state.buttonsShown、飞行中）由这里做；为 false 时卡片在原生那一层做（iPad 的 PhoneCardView），这里两样都不读，
    /// 缩小、恢复、拖动时这个托管视图不跟着更新（2026-10-14 iPad 实测，缩小、恢复的首帧里每个在动的窗口省约 1 毫秒）。
    var managesVisibility = true
    @Environment(AppModel.self) private var model

    var body: some View {
        if let area = group.workspace {
            let layout = group.layout
            let expansion = state.expansion ?? layout.expansion(of: pane)
            let pinned = state.pinned
            let buttons = PaneHeaderButtonGroup {
                button("缩小", icon: "minus") { layout.minimize(pane) }
                switch expansion {
                case .expand: button("展开", icon: "arrow.up.left.and.arrow.down.right") { layout.expand(pane) }
                case .restore: button("还原", icon: "arrow.down.right.and.arrow.up.left") { layout.collapse(pane) }
                case .unavailable: EmptyView()
                }
                button("关闭", icon: "xmark") { model.closeWindow(pane, in: area) }
                    .disabled(area.isOpening(pane) || area.creatingWindow == pane.id)
                pin(pinned, layout: layout)
            }
            // 缩小、恢复时台面上的窗口数变了，展开按钮出现消失不跟排布的动画走：飞行中按钮组本来看不见，
            // 带着动画这个托管视图每帧要重排几遍（2026-10-14 实测，一次缩小或恢复约 117 次、合计约 49 ms）
            .animation(nil, value: expansion)
            // 按系统控件的实际尺寸安排标题栏并避让拖动
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if header.controlsSize != size { header.controlsSize = size }
            }
            if managesVisibility {
                // 按钮组按整组的大小摆，单独的图钉贴在右边，和组里的图钉同一个位置
                ZStack(alignment: .trailing) {
                    buttons
                        .modifier(WhileSettled(motion: motion, shown: state.buttonsShown))
                        .accessibilityHidden(!state.buttonsShown)
                    if pinned {
                        PaneHeaderButtonGroup { pin(true, layout: layout) }
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                if header.pinSize != size { header.pinSize = size }
                            }
                            .modifier(WhileSettled(motion: motion, shown: state.pinShown))
                            .accessibilityHidden(true)
                    }
                }
            } else {
                buttons
            }
        }
    }

    private func pin(_ pinned: Bool, layout: WindowLayout) -> some View {
        button(pinned ? "取消固定" : "固定", icon: pinned ? "pin.fill" : "pin") { layout.togglePin(pane) }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}
