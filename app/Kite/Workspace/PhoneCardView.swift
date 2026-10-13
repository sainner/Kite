#if os(iOS)
import SwiftUI
import UIKit

/// 原生台面（PhoneStageView）上的一张卡片，合起 SwiftUI 版 CardSlot、PaneCard、WindowSurface 的职责，外观和行为照它们，结构照 Mac 的 CardView：
/// 外框和最小化色、点阵层、窗口正文、头像、头像描边、标题栏一层（拖动区、窗口按钮）。视图铺满台面，各层按台面坐标摆；
/// 铺满台面的几层（外框、点阵、头像、描边）都不接点按，只有正文和标题栏一层接。
/// 终点由台面按 CardPresentation 算好交过来，交给 WindowMotion。排布动画开始计时时整段交给 Core Animation（flightStarted），
/// 跟手拖动由台面的显示链接逐帧取样（applyPresentation），都只改图层。外框、遮罩用图层的圆角（continuous，同 SwiftUI 的 RoundedRectangle）
/// 和大小，Core Animation 自己插值，不用路径。
/// 正文按停着的样子排一次，飞行中只改外层图层的变换和遮罩（PhoneContentContainer）：会话窗口是原生外框（PhoneThreadWindowView），
/// 别的窗口是岛；点阵、头像、窗口按钮各是一个岛。标题栏一层按停着的外框摆，飞行中看不见也不接输入，同 WindowSurface.headerLayer。
final class PhoneCardView: UIView {
    /// 台面这一轮给这张卡片的：终点、停靠格、在不在退出、家族格、侧栏入口给不给它、是不是被停靠栏展开的面板压暗、接不接输入。
    struct Arrangement {
        let placed: CardPresentation.Placement
        let dockFrame: CGRect?
        let closing: Bool
        let family: String?
        let openSidebar: (@MainActor () -> Void)?
        let dimmed: Bool
        let acceptsInput: Bool
        /// 拖缝调整大小时点阵也收起。
        let dotsHidden: Bool
        let dragged: Bool
        let hasThread: Bool
        let fixed: Bool
        /// 标题栏一层这一轮怎么摆，在台面的观察里读，见 headerState。
        let header: HeaderState
    }

    /// 标题栏一层要读的卡片状态：正文报的标题栏高、右边菜单宽、窗口按钮的尺寸、挖空的范围，和窗口按钮露不露。
    /// 台面在观察里读它们，变了重排一轮；摆放在观察之外，见 placeHeader。
    struct HeaderState {
        let height: CGFloat
        let menuWidth: CGFloat
        let controlsSize: CGSize
        let excluded: [CGRect]
        let buttonsShown: Bool
    }

    func headerState(layout: WindowLayout, minimized: Bool, width: CGFloat, hasThread: Bool) -> HeaderState {
        let controls = PaneHeaderControls(header: header, layout: layout, minimized: minimized, width: width, hasThread: hasThread)
        return HeaderState(height: header.height, menuWidth: header.menuWidth, controlsSize: header.controlsSize,
                           excluded: headerRegions.settled, buttonsShown: controls.shown)
    }

    let pane: Pane
    private weak var stage: PhoneStageView?
    let presentation = CardPresentation()
    let header = PaneCardHeader()
    let headerRegions = HeaderRegions()
    let bodyReports = PaneCardBodyReports()
    private let carrier = DotCarrier()
    private let scope = DotScope()
    private let presence = PanePresence()
    private let content = CardContentState()
    private let link = HostedContentLink()
    /// 正文里的会话窗口桥接上来时建的原生外框，见 ThreadPaneBridge。
    private let threadSlot = ThreadWindowSlot()
    private var threadWindow: PhoneThreadWindowView?

    private let fill = CardFillLayers()
    private var backdrop: HostIsland?
    private var container: PhoneContentContainer?
    /// 头像随外框平移的那一层，铺满台面：点按和读屏都穿过去。
    private let iconMover = PassThroughView()
    private let icon = HostIsland()
    private let ring = CALayer()
    private let headerView = CardHeaderView()
    private let buttons = HostIsland(sizing: [.intrinsicContentSize])

    private var placed: CardPresentation.Placement?
    private var arrangement: Arrangement?
    private(set) var closing = false
    private var hovered = false
    private var acceptsInput = false
    private var dimmed = false
    private var raised = false
    private var dotsShown = false
    private var lastMoving = false
    private var notedSettling = false
    private let motionTracking = ModelTracking()
    /// 头像的描边颜色，由头像报上来，画在外框上。
    private var ringColor: Color?
    /// 头像里放的东西，变了才换岛的 rootView。
    private var iconKey: IconKey?
    private var installed = false

    var motionMoving: Bool { placed?.motion.moving ?? false }

    /// 要台面的显示链接逐帧取样：只有跟手拖动（手指一动整条轨迹跟着平移，不能整段预先交出去）。
    var needsFrames: Bool { guard let motion = placed?.motion else { return false }; return motion.moving && motion.tracking }
    /// 这一段已经交给 Core Animation。
    private var flying = false

    /// 读屏排序用：停着时的外框。
    var accessibilityOrder: CGRect { placed?.target.frame ?? .zero }

    init(pane: Pane, stage: PhoneStageView) {
        self.pane = pane
        self.stage = stage
        super.init(frame: .zero)
        #if DEBUG
        PhoneStageView.alive.add(self)
        #endif
        header.layout = stage.group.layout
        link.onHover = { _ in }
        layer.addSublayer(fill.base)
        layer.addSublayer(fill.minimized)
        iconMover.addSubview(icon)
        icon.isUserInteractionEnabled = false
        ring.borderWidth = DockFace.ringWidth
        ring.cornerCurve = .continuous
        for layer in [ring, fill.base, fill.minimized] { layer.actions = Self.noActions }
        headerView.addSubview(buttons)
        threadSlot.attach = { [weak self] thread, pane, environment in self?.attachThread(thread, pane: pane, environment: environment) }
        threadSlot.detach = { [weak self] pane in self?.detachThread(pane) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull(),
                                                        "opacity": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
                                                        "hidden": NSNull()]

    /// 第一次排布时 motion 才有，正文、点阵等这时建：叠放从下到上是外框、点阵、正文、头像、描边、标题栏一层，同 WindowSurface。
    private func install(motion: WindowMotion) {
        guard let stage else { return }
        let backdrop = HostIsland()
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        backdrop.alpha = 0
        backdrop.layer.mask = dotsMask
        dotsMask.backgroundColor = UIColor.black.cgColor
        dotsMask.cornerCurve = .continuous
        dotsMask.actions = Self.noActions
        let container = PhoneContentContainer(motion: motion)
        link.container = container
        self.backdrop = backdrop
        self.container = container
        addSubview(backdrop)
        addSubview(container)
        addSubview(iconMover)
        layer.addSublayer(ring)
        addSubview(headerView)
        // 描边在头像上面、标题栏下面
        ring.zPosition = 0
        let pane = pane
        headerView.dragged = { [weak stage] state, location in
            switch state {
            case .began, .changed: stage?.drag(pane, to: location)
            case .ended: stage?.drop()
            default: stage?.cancelDrag()
            }
        }
        headerView.tapped = { [weak self] in self?.click() }
        headerView.buildMenu = { [weak self] in self?.menu() }
        motion.onStart = { [weak self] motion in self?.flightStarted(motion) }
        environmentChanged()
        trackMotion()
    }

    /// 外观类的环境变了，或窗口组换了一项（资源库同一类里换角色、模板）：各个岛重新交环境，正文按新的一项重建。
    func environmentChanged() {
        guard let stage, let motion = placed?.motion, let container, let backdrop else { return }
        installed = true
        let group = stage.group
        header.layout = group.layout
        content.environment += 1
        container.island.rootView = stage.rooted(CardContent(
            group: group, pane: pane, state: content, header: header, headerRegions: headerRegions, presence: presence, motion: motion,
            reports: bodyReports, link: link, carrier: carrier, scope: scope, threadSlot: Self.nativeThreads ? threadSlot : nil))
        backdrop.rootView = stage.rooted(CardDots(reports: bodyReports, carrier: carrier, scope: scope, motion: motion))
        buttons.rootView = stage.rooted(CardButtons(group: group, pane: pane, header: header, state: content, motion: motion))
        iconKey = nil
        updateIcon()
        updateColors()
    }

    /// 会话窗口的外框是原生的；Debug 带 --swiftui-thread-window 时照旧是 SwiftUI 的 ThreadPane，同一个构建对照新旧两版。
    private static var nativeThreads: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--swiftui-thread-window")
        #else
        true
        #endif
    }

    /// 拆掉：不再跟模型，收掉闭包和岛里的东西，原生外框一起拆。
    func dismantle() {
        motionTracking.cancel()
        threadWindow?.dismantle()
        threadWindow = nil
        threadSlot.attach = nil
        threadSlot.detach = nil
        container?.native = nil
        placed?.motion.onStart = nil
        presentation.motion?.onStart = nil
        headerView.dragged = nil
        headerView.tapped = nil
        headerView.buildMenu = nil
        container?.island.rootView = AnyView(EmptyView())
        backdrop?.rootView = AnyView(EmptyView())
        icon.rootView = AnyView(EmptyView())
        buttons.rootView = AnyView(EmptyView())
        link.container = nil
    }

    // MARK: - 会话窗口的原生外框

    /// 正文里的会话窗口桥接上来（或它的环境变了）：建原生外框，岛里的正文从此不跟着改尺寸（见 placeContent）。
    private func attachThread(_ thread: WorkThread, pane threadPane: ThreadPaneModel, environment: EnvironmentValues) {
        guard let stage, let motion = placed?.motion, let container else { return }
        if let threadWindow, threadWindow.thread === thread, threadWindow.pane === threadPane {
            threadWindow.environmentChanged(environment, group: stage.group)
            return
        }
        threadWindow?.dismantle()
        let window = PhoneThreadWindowView(thread: thread, pane: threadPane, environment: environment, group: stage.group, paneID: pane,
                                           model: stage.model, header: header, regions: headerRegions, reports: bodyReports, motion: motion)
        threadWindow = window
        container.native = window
        if !content.nativeThread { content.nativeThread = true }
        stage.setNeedsLayout()
    }

    /// 桥不在了（窗口不再是会话）：收掉原生外框，正文回到岛里。
    private func detachThread(_ threadPane: ThreadPaneModel) {
        guard let threadWindow, threadWindow.pane === threadPane else { return }
        threadWindow.dismantle()
        self.threadWindow = nil
        container?.native = nil
        if content.nativeThread { content.nativeThread = false }
        bodyReports.threadSlots = []
        stage?.setNeedsLayout()
    }

    // MARK: - 排布

    /// 台面这一轮排布（在台面的观察之外调）：记下终点和状态，摆好不随时钟走的各层，再由台面把终点交给 motion（见 move）。
    func arrange(_ arrangement: Arrangement) {
        let placed = arrangement.placed
        let first = self.placed == nil
        self.placed = placed
        self.arrangement = arrangement
        if first { install(motion: placed.motion) }
        closing = arrangement.closing
        acceptsInput = arrangement.acceptsInput
        let target = placed.target, minimized = placed.minimized

        if content.minimized != minimized { content.minimized = minimized }
        if (content.openSidebar == nil) != (arrangement.openSidebar == nil) { content.openSidebar = arrangement.openSidebar }
        if presence.onScreen != !minimized { presence.onScreen = !minimized }
        // 正文标题栏按这几项算给窗口按钮让出多少，见 PaneHeaderControlsSpace
        let headerPlacement = HeaderPlacement(minimized: minimized, width: target.frame.width, hasThread: arrangement.hasThread)
        if header.placement != headerPlacement { header.placement = headerPlacement }

        placeContent(target: target, contentSize: placed.contentSize)
        placeHeader(target: target, minimized: minimized, fixed: arrangement.fixed, state: arrangement.header)
        container?.accessibilityElementsHidden = minimized
        updateIcon()
        updateColors()
        setDimmed(arrangement.dimmed)
        if !acceptsInput { setHovered(false) }
    }

    /// 把终点交给 motion，当场按这一刻的样子摆一次：停着的直接到终点；刚开始动的停在起点，等这次排版交上去再计时（见 WindowMotion.move）。
    func move(to target: WindowPose, kind: WindowMotionKind) {
        guard let motion = placed?.motion else { return }
        let before = motion.target
        motion.move(to: target, kind: kind)
        // 中途换了终点：交给 Core Animation 的那一段作废，从这一刻的样子接着走（WindowMotion 从当时的呈现取起点）
        if flying, motion.target != before {
            flying = false
            stopFlight()
        }
        motionChanged()
        if !flying { applyPresentation(at: .now) }
    }

    /// 这一段开始计时（这次排版已经交上去）：按 WindowMotion 的曲线每 1/120 秒取一帧，外框、最小化色、描边、头像、正文的变换和遮罩、
    /// 标题两侧整段交给 Core Animation，模型值停在终点。取样和逐帧驱动用的是同一个 presentation，飞出来一样。
    private func flightStarted(_ motion: WindowMotion) {
        guard motion === placed?.motion, !motion.tracking, let flight = motion.flight, let placed else { return }
        let steps = max(Int((flight.duration * 120).rounded(.up)), 1)
        let poses = (0...steps).map { motion.presentation(at: flight.start.addingTimeInterval(flight.duration * Double($0) / Double(steps))) }
        flying = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.animate(poses, duration: flight.duration)
        if ringColor != nil { RingGeometry.animate(ring, poses, duration: flight.duration) }
        let size = iconSize
        let transforms = poses.map { NSValue(caTransform3D: iconTransform($0, size: size)) }
        iconMover.layer.sublayerTransform = iconTransform(poses[poses.count - 1], size: size)
        iconMover.alpha = poses[poses.count - 1].iconOpacity
        iconMover.layer.add(StageKeyframes.make("sublayerTransform", transforms, duration: flight.duration), forKey: "flight")
        iconMover.layer.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: flight.duration), forKey: "flight-opacity")
        if let container {
            let destination = placed.target.contentOrigin(size: placed.contentSize)
            let area = container.frame
            link.animate(poses.map { HostedContentFrame(pose: $0, target: placed.target, destination: destination, area: area,
                                                         contentSize: placed.contentSize) }, duration: flight.duration)
        }
        CATransaction.commit()
        stage?.updateDisplayLink()
    }

    /// 收掉交给 Core Animation 的那一段（换终点、停下）。
    private func stopFlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.stopAnimations()
        ring.removeAnimation(forKey: "flight")
        iconMover.layer.removeAnimation(forKey: "flight")
        iconMover.layer.removeAnimation(forKey: "flight-opacity")
        CATransaction.commit()
    }

    private func iconTransform(_ pose: WindowPose, size: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(pose.frame.midX - size / 2, pose.frame.midY - size / 2, 0)
    }

    /// 正文的范围：正文的排版框加上停着时的外框；岛的原点对齐窗口原点，同 WindowSurface.hostedPlacement。
    private func placeContent(target: WindowPose, contentSize: CGSize) {
        guard let stage, let container else { return }
        let destination = target.contentOrigin(size: contentSize)
        let area = CGRect(origin: destination, size: contentSize).union(target.frame)
        let origin = stage.origin
        if threadWindow != nil {
            // 原生外框：岛里的正文只剩桥，不跟着改尺寸；外框按正文停着的位置摆在这一层里
            let placement = HostedPlacementValue()
            if link.placement.value != placement { link.placement.value = placement }
            container.nativeFrame = CGRect(x: destination.x - area.minX, y: destination.y - area.minY,
                                           width: contentSize.width, height: contentSize.height)
        } else {
            let placement = HostedPlacementValue(origin: CGPoint(x: origin.x + area.minX, y: origin.y + area.minY),
                                                 contentSize: contentSize,
                                                 offset: CGPoint(x: origin.x + destination.x, y: origin.y + destination.y),
                                                 extent: CGSize(width: max(origin.x + area.maxX, 0), height: max(origin.y + area.maxY, 0)))
            if link.placement.value != placement { link.placement.value = placement }
        }
        container.origin = CGPoint(x: origin.x + area.minX, y: origin.y + area.minY)
        if container.frame != area { container.frame = area }
        // 点阵层按台面全幅铺，遮罩按外框
        if let backdrop, backdrop.frame != bounds { backdrop.frame = bounds }
        if iconMover.frame != bounds { iconMover.frame = bounds }
        // 摆在卡片上的图形按停着的位置落到点阵上，同 PaneCard.updateDots
        let rest = DotCarrier.Mapping(origin: CGPoint(x: origin.x + destination.x, y: origin.y + destination.y), scale: target.scale)
        if carrier.rest != rest { carrier.rest = rest }
        scope.frame = target.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 标题栏一层按停着的外框摆：拖动区让开右边的菜单和窗口按钮，挖掉标题栏里可点的控件（动画停下才换，见 HeaderRegions），
    /// 缩成停靠形状时整个外框都是拖动区。固定排布没有拖动区和窗口按钮。
    private func placeHeader(target: WindowPose, minimized: Bool, fixed: Bool, state: HeaderState) {
        let frame = target.frame
        let height = minimized ? frame.height : state.height
        let headerFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
        if headerView.frame != headerFrame { headerView.frame = headerFrame }
        headerView.clip = CGRect(origin: .zero, size: frame.size)
        headerView.radius = target.radius
        let drag = headerView.drag
        drag.isHidden = fixed
        let shown = state.buttonsShown
        if content.buttonsShown != shown { content.buttonsShown = shown }
        let menu = state.menuWidth
        let trailing = minimized ? 0 : menu + (shown ? state.controlsSize.width + Metrics.paneButtonGap : 0) + Metrics.paneMargin
        let dragFrame = CGRect(x: 0, y: 0, width: max(frame.width - trailing, 0), height: height)
        if drag.frame != dragFrame { drag.frame = dragFrame }
        drag.threshold = minimized ? Metrics.dragThreshold : max(state.height, Metrics.dragThreshold)
        drag.excluded = minimized ? [] : state.excluded
        // 窗口按钮组让开正文的菜单，在标题栏里竖着居中
        buttons.isHidden = minimized || fixed
        let size = state.controlsSize == .zero ? buttons.idealSize : state.controlsSize
        let x = frame.width - Metrics.paneMargin - (menu > 0 ? menu + Metrics.paneButtonGap : 0) - size.width
        let buttonsFrame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
        if buttons.frame != buttonsFrame { buttons.frame = buttonsFrame }
    }

    // MARK: - 逐帧

    /// 这一刻的样子：外框、最小化色、描边、头像、点阵遮罩和正文的变换，都只改图层，同 WindowSurface 里按同一次取样交上去的几层。
    func applyPresentation(at date: Date) {
        guard let placed else { return }
        let pose = placed.motion.presentation(at: date)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.apply(pose)
        if ringColor != nil { RingGeometry.apply(ring, pose) }
        iconMover.layer.sublayerTransform = iconTransform(pose, size: iconSize)
        iconMover.alpha = pose.iconOpacity
        if dotsShown { maskDots(pose) }
        if let container {
            let destination = placed.target.contentOrigin(size: placed.contentSize)
            let frame = HostedContentFrame(pose: pose, target: placed.target, destination: destination, area: container.frame,
                                           contentSize: placed.contentSize)
            if link.frame != frame { link.apply(frame) }
        }
        CATransaction.commit()
    }

    private var iconSize: CGFloat { min(placed?.target.frame.width ?? Metrics.dragBubble, Metrics.dragBubble) }

    /// 只看 moving：开始、停下时更新叠放、命中、点阵和报给排布的 settling；通知在属性改之前，下一拍再读。
    private func trackMotion() {
        guard let motion = placed?.motion else { return }
        motionTracking.track({ _ = motion.moving }) { [weak self] in
            Task { @MainActor in
                self?.motionChanged()
                self?.trackMotion()
            }
        }
    }

    /// 动画开始、停下：开始时收起悬停；停下时摆到终点、交出标题栏挖空的范围、按指针现在的位置重算悬停，退出的卡片拿掉。
    func motionChanged() {
        guard let placed, let stage else { return }
        let motion = placed.motion
        let moving = motion.moving
        if moving != lastMoving {
            lastMoving = moving
            if moving {
                setHovered(false)
            } else {
                if headerRegions.settled != headerRegions.rects { headerRegions.settled = headerRegions.rects }
                if flying {
                    // Core Animation 那一段已经走完，模型值就是终点；正文按终点交一次（飞行中一直显示着，缩进停靠栏的这时藏起来）
                    flying = false
                    stopFlight()
                    link.settle()
                }
                applyPresentation(at: .now)
                stage.refreshHover()
            }
        }
        // 报给排布：排布动画进行中（不含跟手拖动），过渡中所有窗口不接输入。改模型放到这一轮之后
        let settling = motion.settling
        if settling != notedSettling {
            notedSettling = settling
            let layout = stage.group.layout, pane = pane
            Task { @MainActor in layout.noteSettling(pane, settling) }
        }
        // 拖着、关闭、在停靠栏和台面之间飞的卡片压在别的窗口上面，同 CardMotionState
        let raised = arrangement?.dragged == true || closing || motion.changingForm
        if raised != self.raised {
            self.raised = raised
            layer.zPosition = raised ? 1 : 0
        }
        updateDots()
        stage.updateDisplayLink()
        if closing && !moving && !retiring {
            retiring = true
            Task { @MainActor [weak self, weak stage] in
                guard let self else { return }
                retiring = false
                stage?.retire(self)
            }
        }
    }

    private var retiring = false

    // MARK: - 点阵

    private let dotsMask = CALayer()

    /// 点阵不参与过渡：卡片在动、拖缝调整大小时收起；停下后淡入 0.25 秒，同 WindowDots。
    private func updateDots() {
        guard let backdrop, let placed else { return }
        let shown = !(arrangement?.dotsHidden ?? false) && !placed.motion.moving
        guard shown != dotsShown else { return }
        dotsShown = shown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.alpha = shown ? 1 : 0
        if shown {
            maskDots(placed.motion.presentation(at: .now))
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.layer.add(fade, forKey: "fade")
        } else {
            // 收起要当场收：淡入还在走的话图层动画会盖过新的透明度
            backdrop.layer.removeAnimation(forKey: "fade")
        }
        CATransaction.commit()
    }

    private func maskDots(_ pose: WindowPose) {
        dotsMask.frame = pose.frame
        dotsMask.cornerRadius = pose.radius
        dotsMask.opacity = Float(pose.contentOpacity)
    }

    // MARK: - 头像、颜色

    private struct IconKey: Equatable {
        let isAgent: Bool
        let icon: String
        let instance: String?
        let size: CGFloat
    }

    private func updateIcon() {
        guard let stage, let placed, installed else { return }
        let size = iconSize
        let instance = presentation.instance
        let key = IconKey(isAgent: placed.appearance.isAgent, icon: placed.appearance.icon, instance: instance?.id, size: size)
        guard key != iconKey else { return }
        iconKey = key
        icon.rootView = stage.rooted(CardIcon(appearance: placed.appearance, area: stage.group.workspace, instance: instance, pane: pane,
                                               size: size) { [weak self] color in self?.ringChanged(color) })
        icon.frame = CGRect(x: 0, y: 0, width: size, height: size)
    }

    private func ringChanged(_ color: Color?) {
        guard color != ringColor else { return }
        ringColor = color
        updateColors()
        // 交给 Core Animation 的那一段还在走时不重摆，停下时按终点摆（见 motionChanged）
        if !flying { applyPresentation(at: .now) }
    }

    /// 底色是卡片色；最小化色代理用卡片色、工具用它的颜色；描边是头像报来的颜色。按这个视图的外观解析成 SwiftUI 里同样的值。
    private func updateColors() {
        guard let stage, let placed else { return }
        let environment = stage.environment
        func color(_ color: Color) -> CGColor { resolved(color, traits: traitCollection, in: environment).cgColor }
        fill.base.backgroundColor = color(Theme.card)
        fill.minimized.backgroundColor = color(placed.appearance.isAgent ? Theme.card : placed.appearance.tint)
        ring.borderColor = ringColor.map(color)
        ring.isHidden = ringColor == nil
    }

    // MARK: - 压暗

    /// 停靠栏展开着面板时，缩在停靠栏里的卡片模糊 4、透明 0.3，同 DockDimmed；跟着展开收起的 snappy 走。
    private func setDimmed(_ dimmed: Bool) {
        guard dimmed != self.dimmed else { return }
        self.dimmed = dimmed
        let reduceMotion = stage?.look?.reduceMotion ?? false
        let opacity: Float = dimmed ? 0.3 : 1, radius: CGFloat = dimmed ? 4 : 0
        let from = layer.presentation()?.opacity ?? layer.opacity
        let fromRadius = (layer.presentation()?.value(forKeyPath: "filters.blur.inputRadius") as? CGFloat) ?? (dimmed ? 0 : 4)
        if layer.filters?.isEmpty ?? true, let blur = LayerBlur.filter(name: "blur") { layer.filters = [blur] }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 不压暗了：动画走完把模糊拿掉，不让它一直挂在卡片的图层上
        if !dimmed {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.dimmed else { return }
                layer.filters = nil
            }
        }
        layer.opacity = opacity
        if layer.filters?.isEmpty == false { layer.setValue(radius, forKeyPath: "filters.blur.inputRadius") }
        if !reduceMotion {
            layer.add(StageAnimation.spring("opacity", from: Double(from), to: Double(opacity), spring: .snappy), forKey: "dim")
            if layer.filters?.isEmpty == false {
                layer.add(StageAnimation.spring("filters.blur.inputRadius", from: Double(fromRadius), to: Double(radius), spring: .snappy),
                          forKey: "dim-blur")
            }
        }
        CATransaction.commit()
    }

    // MARK: - 悬停与点按

    /// 指针在不在这张卡片上（台面统一跟踪，见 PhoneStageView.refreshHover）：停着时按外框（缩成停靠形状时是圆或圆角方）算。
    func contains(_ point: CGPoint) -> Bool {
        guard let placed, acceptsInput, !placed.motion.moving else { return false }
        let target = placed.target
        return UIBezierPath(roundedRect: target.frame, cornerRadius: target.radius).contains(point)
    }

    /// 悬停：缩成停靠形状停着时浮出停靠栏的名字，同 CardSlot 的 onHover；窗口按钮触屏一直露。
    func setHovered(_ hovered: Bool) {
        guard hovered != self.hovered else { return }
        self.hovered = hovered
        if header.hovered != hovered { header.hovered = hovered }
        guard let stage, let placed, let area = stage.group.workspace else { return }
        let layout = stage.group.layout
        area.setDockHover(DockEntry.pane(pane).id, frame: arrangement?.dockFrame ?? placed.target.frame,
                          hovering: hovered && placed.minimized && !placed.motion.moving && layout.drag == nil && layout.resizing == nil)
    }

    func resetHover() {
        hovered = true
        setHovered(false)
    }

    private func click() {
        guard let placed, let stage else { return }
        if placed.minimized { stage.activate(pane, family: arrangement?.family) }
        else { stage.group.layout.focus(pane) }
    }

    /// 长按（指针右键）菜单：缩成停靠形状时先写名字与状态，再是实例操作和关闭窗口，同 PaneCard 的 contextMenu。
    private func menu() -> UIMenu? {
        guard let stage, let placed, let area = stage.group.workspace,
              let target = area.windows.first(where: { $0.id == pane.id })?.target,
              let instance = area.instances.first(where: { $0.id == target.instanceId }) else { return nil }
        var items: [UIMenuElement] = []
        if placed.minimized {
            items.append(UIAction(title: area.dockLabel(.pane(pane)), attributes: .disabled) { _ in })
        }
        let model = stage.model
        for action in InstanceAction.all(for: instance, in: area, model: model) {
            var attributes: UIMenuElement.Attributes = []
            if !action.enabled { attributes.insert(.disabled) }
            if action.destructive { attributes.insert(.destructive) }
            let perform = action.perform
            items.append(UIAction(title: action.title, attributes: attributes) { _ in perform() })
        }
        let pane = pane
        items.append(UIAction(title: "关闭窗口") { _ in model.closeWindow(pane, in: area) })
        return UIMenu(children: items)
    }

    // MARK: - 命中与读屏

    /// 卡片铺满台面，自己不接点按，只有里面的正文和标题栏一层接；不接输入时（过渡中、退出、拖缝、被压暗）整张都不接。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard acceptsInput else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override var accessibilityLabel: String? {
        get { placed?.appearance.name }
        set {}
    }

    /// 缩成停靠形状时整张是一个按钮（点了展开），正文对读屏隐藏；停着时读正文和窗口按钮。
    override var isAccessibilityElement: Bool {
        get { placed?.minimized == true }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { placed?.minimized == true ? .button : [] }
        set {}
    }

    override var accessibilityFrame: CGRect {
        get { placed.map { UIAccessibility.convertToScreenCoordinates($0.target.frame, in: self) } ?? .zero }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard placed?.minimized == true, acceptsInput else { return false }
        click()
        return true
    }

    override var accessibilityElements: [Any]? {
        get {
            guard let placed, !placed.minimized else { return nil }
            return [container, buttons].compactMap { $0 }
        }
        set {}
    }

    /// 读屏的动作：缩小、展开、关闭窗口；缩在停靠栏里时展开窗口，同 PaneCard 的 accessibilityActions。
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let placed, let stage, !closing else { return nil }
            let layout = stage.group.layout, pane = pane, family = arrangement?.family
            if placed.minimized {
                return [UIAccessibilityCustomAction(name: "展开窗口") { [weak stage] _ in stage?.activate(pane, family: family); return true }]
            }
            guard let area = stage.group.workspace else { return nil }
            var actions = [UIAccessibilityCustomAction(name: "缩小窗口") { _ in layout.minimize(pane); return true }]
            if (layout.shown?.panes.count ?? 0) > 1 {
                actions.append(UIAccessibilityCustomAction(name: "展开窗口") { _ in layout.expand(pane); return true })
            }
            let model = stage.model
            actions.append(UIAccessibilityCustomAction(name: "关闭窗口") { _ in model.closeWindow(pane, in: area); return true })
            return actions
        }
        set {}
    }
}

/// 外框底色和最小化色：两层同一个外框，底色按 min(正文 + 头像, 1)、最小化色按头像的透明度，同 WindowSurface。
private final class CardFillLayers {
    let base = CALayer()
    let minimized = CALayer()

    init() {
        for layer in [base, minimized] { layer.cornerCurve = .continuous }
    }

    func apply(_ pose: WindowPose) {
        stopAnimations()
        for layer in [base, minimized] { RingGeometry.place(layer, frame: pose.frame, radius: pose.radius) }
        base.opacity = baseOpacity(pose)
        minimized.opacity = Float(pose.iconOpacity)
    }

    private func baseOpacity(_ pose: WindowPose) -> Float { Float(min(pose.contentOpacity + pose.iconOpacity, 1)) }

    /// 整段交给 Core Animation：位置、大小、圆角、透明度按每一帧走，模型值停在最后一帧。
    func animate(_ poses: [WindowPose], duration: TimeInterval) {
        guard let last = poses.last else { return }
        apply(last)
        for layer in [base, minimized] { RingGeometry.animateFrame(layer, poses.map { ($0.frame, $0.radius) }, duration: duration) }
        base.add(StageKeyframes.make("opacity", poses.map(baseOpacity), duration: duration), forKey: "flight-opacity")
        minimized.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration), forKey: "flight-opacity")
    }

    func stopAnimations() {
        for layer in [base, minimized] {
            layer.removeAnimation(forKey: "flight")
            layer.removeAnimation(forKey: "flight-opacity")
        }
    }
}

/// 图层按外框摆：位置、大小、圆角（continuous），和整段交给 Core Animation 的关键帧。
enum RingGeometry {
    static func place(_ layer: CALayer, frame: CGRect, radius: CGFloat) {
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = min(radius, min(frame.width, frame.height) / 2)
    }

    static func animateFrame(_ layer: CALayer, _ frames: [(frame: CGRect, radius: CGFloat)], duration: TimeInterval) {
        let group = CAAnimationGroup()
        group.animations = [
            StageKeyframes.make("bounds", frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) }, duration: duration),
            StageKeyframes.make("position", frames.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, duration: duration),
            StageKeyframes.make("cornerRadius", frames.map { min($0.radius, min($0.frame.width, $0.frame.height) / 2) }, duration: duration),
        ]
        group.duration = duration
        layer.add(group, forKey: "flight")
    }

    /// 头像的描边压在外框上，随头像淡入：边框画在外框里面、外缘与外框贴合，同 WindowSurface.outlineRing。
    static func apply(_ ring: CALayer, _ pose: WindowPose) {
        ring.removeAnimation(forKey: "flight")
        place(ring, frame: pose.frame, radius: pose.radius)
        ring.opacity = Float(pose.iconOpacity)
    }

    static func animate(_ ring: CALayer, _ poses: [WindowPose], duration: TimeInterval) {
        guard let last = poses.last else { return }
        apply(ring, last)
        let group = CAAnimationGroup()
        group.animations = [
            StageKeyframes.make("bounds", poses.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) }, duration: duration),
            StageKeyframes.make("position", poses.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, duration: duration),
            StageKeyframes.make("cornerRadius", poses.map { min($0.radius, min($0.frame.width, $0.frame.height) / 2) }, duration: duration),
            StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration),
        ]
        group.duration = duration
        ring.add(group, forKey: "flight")
    }
}

/// 窗口正文的容器，同 Mac 的 HostedContentContainer：正文按停着的样子排一次（岛从窗口原点铺起，里面的 .global 和窗口坐标对得上），
/// 飞行中只改里面一层的 sublayerTransform 和这一层的遮罩（图层圆角 continuous，同外框）。外层图层的变换 UIKit 不知道：
/// 飞行中按停着时的位置命中，所以只在停着、看得见时接点按；收成停靠形状停着时整块隐藏。
final class PhoneContentContainer: UIView, HostedContentSurface {
    let island = HostIsland()
    private weak var motion: WindowMotion?
    /// 正文在窗口里的左上角：岛从窗口原点铺到这一层的右下角。
    var origin = CGPoint.zero {
        didSet { if origin != oldValue { setNeedsLayout() } }
    }
    /// 原生的正文（会话窗口的外框，见 PhoneThreadWindowView）：有它时岛只留一点、不跟着改尺寸，正文按 nativeFrame 摆。
    var native: UIView? {
        didSet {
            guard native !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let native { mover.addSubview(native) }
            setNeedsLayout()
        }
    }
    var nativeFrame = CGRect.zero {
        didSet { if nativeFrame != oldValue { setNeedsLayout() } }
    }
    private let mover = UIView()
    private let clip = CALayer()
    private var frameState = HostedContentFrame()
    /// 交给 Core Animation 的那一段还在走，正文一直显示着（见 animate）。
    private var flying = false

    init(motion: WindowMotion) {
        self.motion = motion
        super.init(frame: .zero)
        mover.addSubview(island)
        addSubview(mover)
        clip.backgroundColor = UIColor.black.cgColor
        clip.cornerCurve = .continuous
        clip.actions = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull()]
        layer.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        mover.frame = bounds
        if let native {
            if island.frame != .zero { island.frame = .zero }
            if native.frame != nativeFrame { native.frame = nativeFrame }
        } else {
            let frame = CGRect(x: -origin.x, y: -origin.y, width: max(origin.x + bounds.width, 0), height: max(origin.y + bounds.height, 0))
            if island.frame != frame { island.frame = frame }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(frameState)
        CATransaction.commit()
    }

    /// 停着、看得见时才接点按：飞行中按停着时的位置命中，对不上。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let motion, !motion.moving, motion.target.contentOpacity > 0 else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === mover ? nil : hit
    }

    func apply(_ state: HostedContentFrame) {
        flying = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight")
        place(state)
        CATransaction.commit()
    }

    private func place(_ state: HostedContentFrame) {
        frameState = state
        let shown = state.shown || flying
        if isHidden == shown { isHidden = !shown }
        mover.layer.sublayerTransform = CATransform3DMakeAffineTransform(state.transform)
        RingGeometry.place(clip, frame: state.clip, radius: state.radius)
        clip.opacity = Float(state.opacity)
    }

    func animate(_ frames: [HostedContentFrame], duration: TimeInterval) {
        guard let last = frames.last else { return }
        apply(last)
        flying = frames.contains(where: \.shown)
        place(last)
        mover.layer.add(StageKeyframes.make("sublayerTransform", frames.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0.transform)) },
                                            duration: duration), forKey: "flight")
        let group = CAAnimationGroup()
        group.animations = [
            StageKeyframes.make("bounds", frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.clip.size)) }, duration: duration),
            StageKeyframes.make("position", frames.map { NSValue(cgPoint: CGPoint(x: $0.clip.midX, y: $0.clip.midY)) }, duration: duration),
            StageKeyframes.make("cornerRadius", frames.map { min($0.radius, min($0.clip.width, $0.clip.height) / 2) }, duration: duration),
            StageKeyframes.make("opacity", frames.map { Float($0.opacity) }, duration: duration),
        ]
        group.duration = duration
        clip.add(group, forKey: "flight")
    }
}

/// 标题栏一层：拖动区和窗口按钮，按停着的外框摆，命中按外框的圆角裁，同 WindowSurface.headerLayer 的 clipShape。
private final class CardHeaderView: UIView, UIContextMenuInteractionDelegate {
    let drag = CardDragArea()
    var dragged: ((UIGestureRecognizer.State, CGPoint) -> Void)?
    var tapped: (() -> Void)?
    var buildMenu: (() -> UIMenu?)?
    /// 外框在这一层里的范围和圆角。
    var clip = CGRect.zero
    var radius: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(drag)
        let pan = ThresholdDrag()
        pan.addTarget(self, action: #selector(panned(_:)))
        drag.addGestureRecognizer(pan)
        drag.pan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        drag.addGestureRecognizer(tap)
        drag.addInteraction(UIContextMenuInteraction(delegate: self))
        drag.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard UIBezierPath(roundedRect: clip, cornerRadius: radius).contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    @objc private func panned(_ recognizer: ThresholdDrag) {
        dragged?(recognizer.state, recognizer.location)
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { tapped?() }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = buildMenu?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

/// 标题栏空白处的拖动区：挖掉标题栏里可点的控件的范围（动画停下才换，见 HeaderRegions），点到那里落到下面的正文。
private final class CardDragArea: UIView {
    weak var pan: ThresholdDrag?
    var threshold: CGFloat {
        get { pan?.threshold ?? Metrics.dragThreshold }
        set { pan?.threshold = newValue }
    }
    var excluded: [CGRect] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && !excluded.contains { $0.contains(point) }
    }
}
#endif
