import SwiftUI

/// 原生台面（Mac 的 StageView、iPad 的 PhoneStageView）两端共用的部分：往上报的几项、台面几何、图层动画的曲线，
/// 和放进托管视图的几块 SwiftUI（停靠栏、停靠栏上面那一层、卡片里的正文、点阵、头像、窗口按钮）。

/// 原生台面报给 SwiftUI 的几项，由台面外面的 SwiftUI 薄壳发成偏好：有没有卡片开点阵（App 背景让出静息点）、
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

/// 看得见的台面（台面自己的坐标；Mac 拖侧栏改宽时左边让出被侧栏盖住的一段，见 StageView.stageRect），和停靠栏里各格这一刻该怎么画。
/// 停靠栏的托管视图读它，铺到 bounds 的右下角，自己从排布模型算停靠栏各格：排布的改动在 SwiftUI 的事务里，岛自己读模型才接得到同一个动画；
/// 原生层不把算好的格子推进去。
@MainActor @Observable final class StageGeometry {
    var bounds: CGRect = .zero
    /// 卡片自己画着头像的实例：缩成停靠形状在飞或拖着、刚从停靠栏飞出去还没停到台面上、关掉的新建页正飞进交给的实例那一格。
    /// 停靠栏里这一格不画，同一时刻只有一份头像（见 CardPresentation.Placement.facing）。
    var airborne: Set<String> = []
    /// 卡片停在台面上的实例：停靠栏里这一格画「看得到」的样子（头像模糊、指向台面的箭头）。
    var staged: Set<String> = []
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

/// 台面合起来往上报点阵用量（各张卡片）。
@MainActor protocol StageDotsReporting: AnyObject {
    func reportDots()
}

// MARK: - 台面上的托管视图

/// 停靠栏：竖排的 DockBand，摆在台面右边那一列；各格画成什么样按 StageGeometry（卡片在不在画头像、停没停在台面上）。
/// 拖着一张卡片的整个过程（从停靠栏拖出来、从台面拖起来）在它那一格描一圈虚线，标出它的位置：这时卡片自己画着头像，
/// 格子不画，不描的话那一格是个空洞；拖到停靠栏上松手就落回那里。虚线同那一格一样透明（堆叠渐隐）。
struct StageDockRail: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            let dock = layout.regions(in: bounds).dock
            ZStack(alignment: .topLeading) {
                DockBand(axis: .vertical) { pane in StagePlan.show(pane, layout: layout, in: bounds) }
                    .environment(\.dockOnStage, geometry.staged)
                    .environment(\.dockHidden, geometry.airborne)
                    .environment(\.dockStage, geometry)
                    .placed(dock)
                if let pane = layout.drag?.pane,
                   let slot = StagePlan.dock(layout: layout, area: area, bounds: bounds).dock.face(of: area.dockInstanceID(pane)) {
                    Circle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .opacity(slot.opacity)
                        .placed(slot.frame)
                        .allowsHitTesting(false)
                }
            }
            .environment(area)
            // 过渡中不接点击、悬停；从停靠栏拖出一格时拖动本身也是过渡，那一格的手势照常走完
            .allowsHitTesting(!layout.transitioning || layout.drag != nil)
            .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
            .coordinateSpace(.named(DockSpace.name))
            .modifier(StageIslandFill())
        }
    }
}

/// 停靠栏上面那一层：展开着家族格时铺满台面，点空白处收起，Esc 也收起。
struct StageDockOverlay: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            ZStack(alignment: .topLeading) {
                if !area.dockExpansion.isEmpty {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { area.collapseDock() }
                        .placed(bounds)
                    // Esc 收起
                    Button("收起") { area.collapseDock() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
            }
            .modifier(PausedInTransition(layout: layout))
            // 原生台面拖侧栏改宽时 bounds 左边让出一段（见 StageView.stageRect），这一层从台面原点铺到右下角
            .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
            .modifier(StageIslandFill())
        }
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

/// 窗口按钮（缩小、展开或还原，和按实例存续方式给的关闭）：悬停卡片时露出来（触屏一直露），飞行中、拖动和拖缝时看不见也不接输入。
/// 垫底的新建页没有（见 WorkArea.isFloor）。
/// persistent 的实例没有关闭，归档在实例操作的菜单里（见 InstanceAction.managing）。露不露由卡片算好放在状态里（见 PaneHeaderControls），实际尺寸报给标题栏让位。
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
            // 垫底的新建页没有窗口按钮：缩不小、展不开、关不掉；报上去的尺寸是零，标题栏不给它让地方
            let buttons = Group { if area.isFloor(pane) { Color.clear.frame(width: 0, height: 0) } else { PaneHeaderButtonGroup {
                button("缩小", icon: "minus") { layout.minimize(pane) }
                switch expansion {
                case .expand: button("展开", icon: "arrow.up.left.and.arrow.down.right") { layout.expand(pane) }
                case .restore: button("还原", icon: "arrow.down.right.and.arrow.up.left") { layout.collapse(pane) }
                case .unavailable: EmptyView()
                }
                if area.hasClose(pane) {
                    button("关闭", icon: "xmark") { model.close(pane, in: area) }
                        .disabled(!area.canClose(pane))
                }
            } } }
            // 缩小、恢复时台面上的窗口数变了，展开按钮出现消失不跟排布的动画走：飞行中按钮组本来看不见，
            // 带着动画这个托管视图每帧要重排几遍（2026-10-14 实测，一次缩小或恢复约 117 次、合计约 49 ms）
            .animation(nil, value: expansion)
            // 按系统控件的实际尺寸安排标题栏并避让拖动
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if header.controlsSize != size { header.controlsSize = size }
            }
            if managesVisibility {
                buttons
                    .modifier(WhileSettled(motion: motion, shown: state.buttonsShown))
                    .accessibilityHidden(!state.buttonsShown)
            } else {
                buttons
            }
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
