#if os(iOS)
import SwiftUI
import UIKit

/// 台面（PhoneStageView）上的一张卡片，外观、行为和结构照 Mac 的 CardView：
/// 外框和最小化色、点阵层、窗口正文、头像、描边、标题栏一层（拖动区、窗口按钮）。视图铺满台面，各层按台面坐标摆；
/// 铺满台面的几层（外框、点阵、头像、描边）都不接点按，只有正文和标题栏一层接。
/// 终点由台面按 CardPresentation 算好交过来，交给 WindowMotion。排布动画开始计时时整段交给 Core Animation（flightStarted），
/// 跟手拖动由台面的显示链接逐帧取样（applyPresentation），都只改图层。外框、遮罩用图层的圆角（continuous，同 SwiftUI 的 RoundedRectangle）
/// 和大小，Core Animation 自己插值，不用路径。
/// 正文按停着的样子排一次，飞行中只改外层图层的变换和遮罩（PhoneContentContainer）：会话窗口是原生外框（PhoneThreadWindowView），
/// 别的窗口是岛；点阵、头像、窗口按钮各是一个岛。标题栏一层按停着的外框摆，飞行中看不见也不接输入。
final class PhoneCardView: UIView {
    /// 台面这一轮给这张卡片的：终点、停靠格、在不在退出、侧栏入口给不给它、是不是被停靠栏展开的面板压暗、接不接输入。
    struct Arrangement {
        let placed: CardPresentation.Placement
        let dockFrame: CGRect?
        let closing: Bool
        let openSidebar: (@MainActor () -> Void)?
        let dimmed: Bool
        let acceptsInput: Bool
        /// 拖缝调整大小、拖侧栏改宽时点阵也收起。
        let dotsHidden: Bool
        let dragged: Bool
        let hasThread: Bool
        let fixed: Bool
        /// 标题栏一层这一轮怎么摆，在台面的观察里读，见 headerState。
        let header: HeaderState
        /// 窗口按钮里展开那一格是展开、还原还是没有。
        let expansion: PaneExpansion
        let pinned: Bool
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

    func headerState(layout: WindowLayout, minimized: Bool, width: CGFloat, hasThread: Bool, pinned: Bool) -> HeaderState {
        let controls = PaneHeaderControls(header: header, layout: layout, minimized: minimized, width: width, hasThread: hasThread,
                                          pinned: pinned)
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
    /// 展开时外框的描边，见 RingGeometry。
    private let edge = CALayer()
    private let ring = CALayer()
    private let headerView = CardHeaderView()
    private let buttons = HostIsland(sizing: [.intrinsicContentSize])

    private var placed: CardPresentation.Placement?
    private(set) var arrangement: Arrangement?
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
    /// 正文、点阵和窗口按钮还没建：头一次排布就收在停靠栏里的卡片先只有外框和头像，台面空闲时一张张补（见 PhoneStageView.warmUp），
    /// 要露出来时当场建（见 arrange）。同 Mac 的 CardView。
    private(set) var bodyDeferred = false

    var motionMoving: Bool { placed?.motion.moving ?? false }

    /// 要台面的显示链接逐帧取样：只有跟手拖动（手指一动整条轨迹跟着平移，不能整段预先交出去）。
    var needsFrames: Bool { guard let motion = placed?.motion else { return false }; return motion.moving && motion.tracking }
    /// 这一段已经交给 Core Animation。
    private var flying = false
    /// 台面挪过，交给 Core Animation 的那一段收掉了，等这一轮 move 接着交（见 shift）。
    private var flightCut = false
    /// 会话窗口的原生外框眼下按多大排着，见 placeContent。
    private var nativeSize: CGSize?
    /// 排布动画开始的那几轮，正文里要跟着重排的几项先不改，等这一段交给 Core Animation 以后的下一帧再改（见 arrange）：
    /// 会话窗口的原生外框改大小、标题栏给窗口按钮的让位、正文回到台面上（PanePresence）。记的是推迟到哪个终点。
    private var contentPending: WindowPose?
    private var contentLink: CADisplayLink?

    /// 读屏排序用：停着时的外框。
    var accessibilityOrder: CGRect { placed?.target.frame ?? .zero }

    init(pane: Pane, stage: PhoneStageView) {
        self.pane = pane
        self.stage = stage
        super.init(frame: .zero)
        header.layout = stage.group.layout
        layer.addSublayer(fill.base)
        layer.addSublayer(fill.minimized)
        iconMover.addSubview(icon)
        icon.isUserInteractionEnabled = false
        for stroke in [edge, ring] {
            stroke.borderWidth = DockFace.ringWidth
            stroke.cornerCurve = .continuous
        }
        for layer in [edge, ring, fill.base, fill.minimized] { layer.actions = Self.noActions }
        headerView.addSubview(buttons)
        threadSlot.attach = { [weak self] thread, pane, environment in self?.attachThread(thread, pane: pane, environment: environment) }
        threadSlot.detach = { [weak self] pane in self?.detachThread(pane) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull(),
                                                        "opacity": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
                                                        "hidden": NSNull()]

    /// 第一次排布时 motion 才有，正文、点阵等这时建：叠放从下到上是外框、点阵、正文、头像、描边、标题栏一层。
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
        layer.addSublayer(edge)
        layer.addSublayer(ring)
        addSubview(headerView)
        // 描边在头像上面、标题栏下面
        edge.zPosition = 0
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
        headerView.menuPreview = { [weak self] in self?.menuPreview() }
        motion.onStart = { [weak self] motion in self?.flightStarted(motion) }
        bodyDeferred = placed?.minimized == true
        environmentChanged()
        trackMotion()
    }

    /// 外观类的环境变了，或窗口组换了一项（资源库同一类里换角色、模板）：各个岛重新交环境，正文按新的一项重建。
    func environmentChanged() {
        guard let stage, placed != nil, container != nil else { return }
        installed = true
        header.layout = stage.group.layout
        if !bodyDeferred { installBody() }
        iconKey = nil
        updateIcon()
        updateColors()
    }

    /// 建推迟的正文、点阵和窗口按钮，见 bodyDeferred。
    func buildBody() {
        guard bodyDeferred else { return }
        bodyDeferred = false
        installBody()
    }

    private func installBody() {
        guard let stage, let motion = placed?.motion, let container, let backdrop else { return }
        let group = stage.group
        content.environment += 1
        container.island.rootView = stage.rooted(CardContent(
            group: group, pane: pane, state: content, header: header, headerRegions: headerRegions, presence: presence, motion: motion,
            reports: bodyReports, link: link, carrier: carrier, scope: scope, threadSlot: threadSlot))
        backdrop.rootView = stage.rooted(CardDots(reports: bodyReports, carrier: carrier, scope: scope, motion: motion))
        buttons.rootView = stage.rooted(CardButtons(group: group, pane: pane, header: header, state: content, motion: motion, managesVisibility: false))
    }

    /// 拆掉：不再跟模型，收掉闭包和岛里的东西，原生外框一起拆。
    func dismantle() {
        motionTracking.cancel()
        contentLink?.invalidate()
        contentLink = nil
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
        headerView.menuPreview = nil
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
        // 新建窗口刚变成会话：外框淡入，和淡出的新建窗口正文交叠
        if stage.group.workspace?.takeFadeIn(pane) == true {
            window.alpha = 0
            UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        }
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
    func arrange(_ arrangement: Arrangement, kind: WindowMotionKind) {
        let placed = arrangement.placed
        let first = self.placed == nil
        // 缩小、恢复时：别的窗口跟着改大小，动画开始的这一轮会话窗口先按原来的大小留在终点的位置上，不当场按新大小重排整段对话
        // （同 Mac 的 CardView）；缩小、恢复的这个窗口，标题栏的让位和回到台面要做的也一起推迟。这一段交给 Core Animation 以后的
        // 下一帧再改（见 flightStarted），外框、正文的动画由 Core Animation 照常走。动画开始那一刻窗口还是原来的大小、恢复的正文
        // 还没淡入，看着一样。2026-10-14 iPad 实测，连同 updateExpands、updateButtons 和正文的露出，缩小、恢复的首帧从约 45、49 毫秒
        // 降到约 14、11 毫秒，推迟的那一帧主线程约 25～30 毫秒
        let resizes = nativeSize.map { threadWindow != nil && !placed.minimized && $0 != placed.contentSize } ?? false
        let pending = resizes || header.placement != headerPlacement(placed, arrangement: arrangement)
            || !presence.onScreen && !placed.minimized
        let starting = kind == .settle && placed.motion.target != placed.target || contentPending == placed.target
        contentPending = pending && starting ? placed.target : nil
        self.placed = placed
        self.arrangement = arrangement
        if first { install(motion: placed.motion) }
        if !placed.minimized { buildBody() }
        closing = arrangement.closing
        acceptsInput = arrangement.acceptsInput
        let target = placed.target, minimized = placed.minimized

        if content.minimized != minimized { content.minimized = minimized }
        // 窗口按钮飞行中看不见（见 updateButtons），「展开」的有无等停下再换：动画开始的这一轮不重排按钮组和让位的标题栏
        if content.expansion == nil || !placed.motion.moving && (placed.motion.target == target || kind.duration == 0) { updateExpands() }
        if content.pinned != arrangement.pinned { content.pinned = arrangement.pinned }
        if (content.openSidebar == nil) != (arrangement.openSidebar == nil) { content.openSidebar = arrangement.openSidebar }
        if contentPending == nil { placePendingContent() } else if minimized, presence.onScreen { presence.onScreen = false }

        placeContent(target: target, contentSize: placed.contentSize)
        placeHeader(target: target, minimized: minimized, fixed: arrangement.fixed, state: arrangement.header)
        container?.accessibilityElementsHidden = minimized
        updateIcon()
        updateColors()
        setDimmed(arrangement.dimmed)
        if !acceptsInput { setHovered(false) }
    }

    /// 台面在窗口里挪了（侧栏收起、展开，见 PhoneStageView.layoutSubviews）：在台面坐标里反着挪，窗口里看着不动，同 Mac 的 CardView.shift。
    func shift(by offset: CGVector) {
        presentation.shift(by: offset)
        guard flying else { return }
        flying = false
        flightCut = true
        stopFlight()
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
        if flightCut {
            flightCut = false
            // 台面挪过、终点没换（见 shift）：这一段剩下的从这一刻接着交给 Core Animation
            if !motion.tracking, let flight = motion.flight {
                let now = Date.now, remaining = flight.start.addingTimeInterval(flight.duration).timeIntervalSince(now)
                if remaining > 0 { handOff(motion.presentations(from: now, duration: remaining), duration: remaining) }
            }
        }
        motionChanged()
        if !flying { applyPresentation(at: .now) }
    }

    /// 这一段开始计时（这次排版已经交上去）：按 WindowMotion 的曲线每 1/120 秒取一帧整段交给 Core Animation（见 handOff）。
    /// 取样和逐帧驱动用的是同一个 presentation，飞出来一样。
    private func flightStarted(_ motion: WindowMotion) {
        guard motion === placed?.motion, !motion.tracking, let flight = motion.flight else { return }
        handOff(motion.presentations(from: flight.start, duration: flight.duration), duration: flight.duration)
        // 这一段交上去以后的下一帧再改推迟的那几项，见 arrange。下一轮运行循环可能赶在下一帧之前，就把这一帧也压住了
        if contentPending != nil, contentLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(contentTick(_:)))
            link.add(to: .main, forMode: .common)
            contentLink = link
        }
    }

    /// 外框、最小化色、描边、头像、正文的变换和遮罩、标题两侧按 poses（按时间均匀取）整段交给 Core Animation，模型值停在最后一帧。
    private func handOff(_ poses: [WindowPose], duration: TimeInterval) {
        guard let last = poses.last else { return }
        flying = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.animate(poses, duration: duration)
        RingGeometry.animate(edge, poses, duration: duration, opacity: \.contentOpacity)
        if ringColor != nil { RingGeometry.animate(ring, poses, duration: duration) }
        let size = iconSize
        let transforms = poses.map { NSValue(caTransform3D: iconTransform($0, size: size)) }
        iconMover.layer.sublayerTransform = iconTransform(last, size: size)
        iconMover.alpha = last.iconOpacity
        iconMover.layer.add(StageKeyframes.make("sublayerTransform", transforms, duration: duration), forKey: "flight")
        iconMover.layer.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration), forKey: "flight-opacity")
        animateContent(poses, duration: duration)
        CATransaction.commit()
        stage?.updateDisplayLink()
    }

    @objc private func contentTick(_ link: CADisplayLink) {
        link.invalidate()
        contentLink = nil
        updateContentNow()
    }

    /// 正文的变换、裁切和标题两侧整段交给 Core Animation，poses 按时间均匀取。
    private func animateContent(_ poses: [WindowPose], duration: TimeInterval) {
        guard let placed, let container else { return }
        let size = laidSize(placed)
        let destination = placed.target.contentOrigin(size: size)
        let area = container.frame
        link.animate(poses.map { HostedContentFrame(pose: $0, target: placed.target, destination: destination, area: area,
                                                     contentSize: size) }, duration: duration)
    }

    /// 正文眼下按多大排着：会话窗口推迟改大小时还是原来的大小（见 placeContent），别的就是这次排布给的。
    private func laidSize(_ placed: CardPresentation.Placement) -> CGSize {
        threadWindow != nil ? nativeSize ?? placed.contentSize : placed.contentSize
    }

    /// 推迟的那几项：按终点摆正文和标题栏。标题右边的截法按标题栏当时的宽算（见 WindowHeaderAnchored.follow），
    /// 还在飞的这一段先按新的大小排好，再从这一刻接着交给 Core Animation。
    private func updateContentNow() {
        guard contentPending != nil, let placed else { return }
        contentPending = nil
        placePendingContent()
        placeContent(target: placed.target, contentSize: placed.contentSize)
        let motion = placed.motion
        guard flying, let flight = motion.flight else { return }
        // 先排好再取时刻：iPad 上整段对话按新宽重排要几十毫秒，按排之前的时刻接着交，正文会比外框落后这么一截
        container?.layoutIfNeeded()
        let now = Date.now, remaining = flight.start.addingTimeInterval(flight.duration).timeIntervalSince(now)
        guard remaining > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animateContent(motion.presentations(from: now, duration: remaining), duration: remaining)
        CATransaction.commit()
    }

    /// 缩在停靠栏里的窗口没有按钮，「展开」的有无不跟着台面换：别的窗口缩小、恢复时它的按钮组也要重排一遍玻璃，几毫秒
    /// （2026-10-14 iPad 实测，停靠栏里一个窗口的按钮组在缩小、恢复的首帧里约 2.5～7 毫秒），等它回到台面停下再换。
    /// 头一次照样给，没给时按钮组退回去读排布，台面一变就跟着更新。
    private func updateExpands() {
        guard let arrangement, let placed, content.expansion == nil || !placed.minimized, content.expansion != arrangement.expansion else { return }
        content.expansion = arrangement.expansion
    }

    /// 正文标题栏按这几项算给窗口按钮让出多少，见 PaneHeaderControlsSpace。
    private func headerPlacement(_ placed: CardPresentation.Placement, arrangement: Arrangement) -> HeaderPlacement {
        HeaderPlacement(minimized: placed.minimized, width: placed.target.frame.width, hasThread: arrangement.hasThread,
                        pinned: arrangement.pinned)
    }

    /// 动画开始的那一轮可以推迟的几项（见 arrange）：标题栏的让位、正文在不在台面上。
    private func placePendingContent() {
        guard let placed, let arrangement else { return }
        let placement = headerPlacement(placed, arrangement: arrangement)
        if header.placement != placement { header.placement = placement }
        if presence.onScreen != !placed.minimized { presence.onScreen = !placed.minimized }
    }

    /// 收掉交给 Core Animation 的那一段（换终点、停下）。
    private func stopFlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.stopAnimations()
        edge.removeAnimation(forKey: "flight")
        ring.removeAnimation(forKey: "flight")
        iconMover.layer.removeAnimation(forKey: "flight")
        iconMover.layer.removeAnimation(forKey: "flight-opacity")
        CATransaction.commit()
    }

    private func iconTransform(_ pose: WindowPose, size: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(pose.frame.midX - size / 2, pose.frame.midY - size / 2, 0)
    }

    /// 正文的范围：正文的排版框加上停着时的外框；岛的原点对齐窗口原点，同 Mac 的 CardView。
    private func placeContent(target: WindowPose, contentSize: CGSize) {
        guard let stage, let container else { return }
        // 会话窗口推迟改大小时正文还是原来的大小，按它眼下的大小算摆在哪，同 Mac 的 CardView.placeContent
        let size = threadWindow != nil && contentPending != nil ? nativeSize ?? contentSize : contentSize
        let destination = target.contentOrigin(size: size)
        let area = CGRect(origin: destination, size: size).union(target.frame)
        let origin = stage.origin
        if threadWindow != nil {
            // 原生外框：岛里的正文只剩桥，不跟着改尺寸；外框按正文停着的位置摆在这一层里，推迟改大小时先留着原来的大小
            let placement = HostedPlacementValue()
            if link.placement.value != placement { link.placement.value = placement }
            nativeSize = size
            container.nativeFrame = CGRect(x: destination.x - area.minX, y: destination.y - area.minY,
                                           width: size.width, height: size.height)
        } else {
            let placement = HostedPlacementValue(origin: CGPoint(x: origin.x + area.minX, y: origin.y + area.minY),
                                                 contentSize: contentSize,
                                                 offset: CGPoint(x: origin.x + destination.x, y: origin.y + destination.y),
                                                 extent: CGSize(width: max(origin.x + area.maxX, 0), height: max(origin.y + area.maxY, 0)))
            if link.placement.value != placement { link.placement.value = placement }
        }
        container.origin = CGPoint(x: origin.x + area.minX, y: origin.y + area.minY)
        if container.frame != area { container.frame = area }
        // 点阵层按台面全幅铺，遮罩按外框；收着时不跟着台面改尺寸（拖侧栏时台面每步改宽，整窗点阵跟着重画，见 PhoneStageView.placeIslands）
        if let backdrop, dotsShown, backdrop.frame != bounds { backdrop.frame = bounds }
        if iconMover.frame != bounds { iconMover.frame = bounds }
        // 摆在卡片上的图形按停着的位置落到点阵上
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
        buttonsShown = shown
        let menu = state.menuWidth
        let trailing = minimized ? 0 : menu + (shown ? state.controlsSize.width + Metrics.paneButtonGap : 0) + Metrics.paneMargin
        let dragFrame = CGRect(x: 0, y: 0, width: max(frame.width - trailing, 0), height: height)
        if drag.frame != dragFrame { drag.frame = dragFrame }
        drag.threshold = minimized ? Metrics.dragThreshold : max(state.height, Metrics.dragThreshold)
        drag.excluded = minimized ? [] : state.excluded
        // 窗口按钮组让开正文的菜单，在标题栏里竖着居中
        updateButtons()
        let size = state.controlsSize == .zero ? buttons.idealSize : state.controlsSize
        let x = frame.width - Metrics.paneMargin - (menu > 0 ? menu + Metrics.paneButtonGap : 0) - size.width
        let buttonsFrame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
        if buttons.frame != buttonsFrame { buttons.frame = buttonsFrame }
    }

    // MARK: - 逐帧

    /// 这一刻的样子：外框、最小化色、描边、头像、点阵遮罩和正文的变换，都按同一次取样只改图层。
    func applyPresentation(at date: Date) {
        guard let placed else { return }
        let pose = placed.motion.presentation(at: date)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.apply(pose)
        RingGeometry.apply(edge, pose, opacity: \.contentOpacity)
        if ringColor != nil { RingGeometry.apply(ring, pose) }
        iconMover.layer.sublayerTransform = iconTransform(pose, size: iconSize)
        iconMover.alpha = pose.iconOpacity
        if dotsShown { maskDots(pose) }
        if let container {
            let size = laidSize(placed)
            let destination = placed.target.contentOrigin(size: size)
            let frame = HostedContentFrame(pose: pose, target: placed.target, destination: destination, area: container.frame,
                                           contentSize: size)
            if link.frame != frame { link.apply(frame) }
        }
        CATransaction.commit()
    }

    private var iconSize: CGFloat { min(placed?.target.frame.width ?? Metrics.dragBubble, Metrics.dragBubble) }

    /// 窗口按钮露不露（见 PaneHeaderControls），placeHeader 交过来。
    private var buttonsShown = false

    /// 窗口按钮缩成停靠形状、固定排布时没有，不该露时（见 PaneHeaderControls）和飞行中看不见、不接输入，都在这一层做，
    /// 托管视图不跟着更新（见 CardButtons.managesVisibility）。改图层的透明度，不改 isHidden、alpha：改那两样 UIKit 也把整棵子树
    /// 通知一遍看不看得见，按钮组照样重画。
    private func updateButtons() {
        guard let placed, let arrangement else { return }
        let absent = placed.minimized || arrangement.fixed || !buttonsShown
        let shown = !absent && !placed.motion.moving
        let opacity: Float = shown ? 1 : 0
        if buttons.layer.opacity != opacity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            buttons.layer.opacity = opacity
            CATransaction.commit()
        }
        if buttons.isUserInteractionEnabled != shown { buttons.isUserInteractionEnabled = shown }
        if buttons.accessibilityElementsHidden != absent { buttons.accessibilityElementsHidden = absent }
    }

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
            updateButtons()
            if moving {
                setHovered(false)
            } else {
                updateContentNow()
                updateExpands()
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
        // 拖着、关闭、在停靠栏和台面之间飞的卡片压在别的窗口上面，同 Mac 的 CardView
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
            if backdrop.frame != bounds { backdrop.frame = bounds }
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

    /// 底色是卡片色；最小化色代理用卡片色、工具用它的颜色；描边展开时是 windowStroke、收起时是头像报来的颜色。
    /// 按这个视图的外观解析成 SwiftUI 里同样的值。
    private func updateColors() {
        guard let stage, let placed else { return }
        let environment = stage.environment
        func color(_ color: Color) -> CGColor { resolved(color, traits: traitCollection, in: environment).cgColor }
        fill.base.backgroundColor = color(Theme.card)
        fill.minimized.backgroundColor = color(placed.appearance.isAgent ? Theme.card : placed.appearance.tint)
        edge.borderColor = color(Theme.windowStroke)
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

    /// 悬停：缩成停靠形状停着时浮出停靠栏的名字；窗口按钮触屏一直露。
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
        // 缩在停靠栏里（家族格里的父代理也是）：放上台面
        if placed.minimized { stage.activate(pane) }
        else { stage.group.layout.focus(pane) }
    }

    /// 长按（指针右键）菜单只在缩成停靠形状时有（这时它就是停靠栏里那一格，同 DockEntryMenu）：先写名字与状态，再是实例操作（含关闭窗口）。
    /// 标题栏上没有，长按直接拿起卡片。
    private func menu() -> UIMenu? {
        guard let stage, let placed, placed.minimized, let area = stage.group.workspace,
              let target = area.windows.first(where: { $0.id == pane.id })?.target,
              let instance = area.instances.first(where: { $0.id == target.instanceId }) else { return nil }
        var items: [UIMenuElement] = [UIAction(title: area.dockLabel(.pane(pane)), attributes: .disabled) { _ in }]
        let model = stage.model
        for action in InstanceAction.all(for: instance, in: area, model: model, pane: pane) {
            var attributes: UIMenuElement.Attributes = []
            if !action.enabled { attributes.insert(.disabled) }
            if action.destructive { attributes.insert(.destructive) }
            let perform = action.perform
            items.append(UIAction(title: action.title, attributes: attributes) { _ in perform() })
        }
        return UIMenu(children: items)
    }

    /// 长按菜单浮起来的：缩成停靠形状的整个外框。从卡片上截一份图，菜单开着时原处照常显示。
    private func menuPreview() -> UITargetedPreview? {
        guard let placed else { return nil }
        let rect = placed.target.frame
        guard let snapshot = resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let radius = min(placed.target.radius, rect.height / 2)
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadius: radius)
        return UITargetedPreview(view: snapshot, parameters: parameters,
                                 target: UIPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY)))
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

    /// 缩成停靠形状时整张是一个按钮（点了展开），正文对读屏隐藏；停着时读正文和窗口按钮。收进家族格的子代理窗口整张透明，由家族格读。
    override var isAccessibilityElement: Bool {
        get { placed?.minimized == true && placed?.hidden == false }
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

    /// 标题栏上为手指长按起拖挂了 UIDragInteraction（见 CardHeaderView），读屏不因此多出拖动的入口，照旧用下面的动作。
    override var accessibilityDragSourceDescriptors: [UIAccessibilityLocationDescriptor]? {
        get { [] }
        set {}
    }

    /// 读屏的动作同窗口按钮收进更多菜单时的那几项（paneWindowActions）；缩在停靠栏里时展开窗口。
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let placed, let stage, !closing else { return nil }
            let pane = pane
            if placed.minimized {
                return [UIAccessibilityCustomAction(name: "展开窗口") { [weak stage] _ in stage?.activate(pane); return true }]
            }
            return paneWindowActions(group: stage.group, pane: pane, model: stage.model)?.commands.filter(\.enabled).map { command in
                UIAccessibilityCustomAction(name: command.title) { _ in command.action(); return true }
            }
        }
        set {}
    }
}

/// 外框底色和最小化色：两层同一个外框，底色按 min(正文 + 头像, 1)、最小化色按头像的透明度。
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

    /// 描边压在外框上：边框画在外框里面、外缘与外框贴合。头像的那一圈随头像淡入；展开时的那一圈（windowStroke）随正文淡出，
    /// opacity 传 contentOpacity。
    static func apply(_ ring: CALayer, _ pose: WindowPose, opacity: KeyPath<WindowPose, Double> = \.iconOpacity) {
        ring.removeAnimation(forKey: "flight")
        place(ring, frame: pose.frame, radius: pose.radius)
        ring.opacity = Float(pose[keyPath: opacity])
    }

    static func animate(_ ring: CALayer, _ poses: [WindowPose], duration: TimeInterval,
                        opacity: KeyPath<WindowPose, Double> = \.iconOpacity) {
        guard let last = poses.last else { return }
        apply(ring, last, opacity: opacity)
        let group = CAAnimationGroup()
        group.animations = [
            StageKeyframes.make("bounds", poses.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) }, duration: duration),
            StageKeyframes.make("position", poses.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, duration: duration),
            StageKeyframes.make("cornerRadius", poses.map { min($0.radius, min($0.frame.width, $0.frame.height) / 2) }, duration: duration),
            StageKeyframes.make("opacity", poses.map { Float($0[keyPath: opacity]) }, duration: duration),
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
    /// 藏着的正文要在下一帧露出来，见 place。
    private var revealLink: CADisplayLink?

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
        // 缩在停靠栏里藏着的正文开始飞回台面（恢复、松手放下）：这一刻它还没淡入，等下一帧再露。改 isHidden 时 UIKit 把整棵子树
        // 通知一遍看不看得见，托管的正文跟着排一遍（2026-10-14 iPad 实测，恢复窗口的首帧里约 6 毫秒），挪到动画开始以后
        if shown, isHidden, motion?.moving == true {
            revealLater()
        } else {
            cancelReveal()
            if isHidden == shown { isHidden = !shown }
        }
        mover.layer.sublayerTransform = CATransform3DMakeAffineTransform(state.transform)
        RingGeometry.place(clip, frame: state.clip, radius: state.radius)
        clip.opacity = Float(state.opacity)
    }

    private func revealLater() {
        guard revealLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(reveal(_:)))
        link.add(to: .main, forMode: .common)
        revealLink = link
    }

    @objc private func reveal(_ link: CADisplayLink) {
        cancelReveal()
        if isHidden, frameState.shown || flying { isHidden = false }
    }

    private func cancelReveal() {
        revealLink?.invalidate()
        revealLink = nil
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

/// 标题栏一层：拖动区和窗口按钮，按停着的外框摆，命中按外框的圆角裁。
/// 拖动卡片分输入方式起拖：iPad 指针（触控板、鼠标）按住挪过一段距离就起拖，同 Mac（ThresholdDrag，只认指针）；
/// 手指和笔要先长按，按系统拖放的惯例交给 UIDragInteraction，时长用系统的：标题栏上长按到时直接拿起卡片；缩成停靠形状时还有长按菜单
/// （UIContextMenuInteraction，同一个视图上），长按到时浮起、弹出菜单，不动就留着菜单，动了菜单收起、转成拖动（系统协调两者）；没长按就滑动的不起拖，
/// 照常交给别的手势。系统的拖动只借它的长按和跟踪：拖着的东西看不见，卡片照旧缩成停靠形状跟着手指（PhoneStageView.drag），
/// 松手由排布按落点放（系统那边没有放的地方，一律当取消）。
private final class CardHeaderView: UIView, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
    let drag = CardDragArea()
    var dragged: ((UIGestureRecognizer.State, CGPoint) -> Void)?
    var tapped: (() -> Void)?
    var buildMenu: (() -> UIMenu?)?
    /// 长按菜单浮起来的样子：缩成停靠形状的整个外框，卡片给。
    var menuPreview: (() -> UITargetedPreview?)?
    /// 外框在这一层里的范围和圆角。
    var clip = CGRect.zero
    var radius: CGFloat = 0
    /// 这一次按下是不是指针：指针的拖动交给 ThresholdDrag，系统的拖动不接。
    private let touchKind = TouchKindObserver()
    /// 系统的拖动开始了、还没交出松手或取消。
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(drag)
        let pan = ThresholdDrag()
        pan.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pan.addTarget(self, action: #selector(panned(_:)))
        drag.addGestureRecognizer(pan)
        drag.pan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        drag.addGestureRecognizer(tap)
        drag.addGestureRecognizer(touchKind)
        drag.addInteraction(UIContextMenuInteraction(delegate: self))
        let lift = UIDragInteraction(delegate: self)
        lift.isEnabled = true
        drag.addInteraction(lift)
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

    // MARK: 长按菜单（只在缩成停靠形状时）

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = buildMenu?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuPreview?()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuPreview?()
    }

    // MARK: 手指、笔的长按起拖

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard !touchKind.pointer, !drag.isHidden, dragged != nil else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.previewProvider = { UIDragPreview(view: Self.invisible(), parameters: Self.invisibleParameters()) }
        return [item]
    }

    /// 有长按菜单时浮起来的是菜单的那份（见 menuPreview）；拖动本身看不见，卡片自己跟着手指。
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: any UIDragSession) -> UITargetedDragPreview? {
        UITargetedDragPreview(view: Self.invisible(), parameters: Self.invisibleParameters(),
                              target: UIDragPreviewTarget(container: drag, center: session.location(in: drag)))
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem,
                         withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? { nil }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        dragging = true
        // 卡片拿起来：缩成停靠形状到手指下，轻触一下（iPad 没有触感马达，只有支持触感的笔会震）
        UIImpactFeedbackGenerator(style: .light, view: drag).impactOccurred(at: session.location(in: drag))
        dragged?(.began, windowLocation(session))
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: any UIDragSession) {
        guard dragging else { return }
        dragged?(.changed, windowLocation(session))
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, willEndWith operation: UIDropOperation) {
        guard dragging else { return }
        dragging = false
        // 系统那边没有放的地方，结果总是取消；放在哪由排布按最后的落点定
        dragged?(.ended, windowLocation(session))
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        guard dragging else { return }
        dragging = false
        dragged?(.cancelled, .zero)
    }

    /// 手指在窗口里的位置，同 ThresholdDrag 报的。
    private func windowLocation(_ session: any UIDragSession) -> CGPoint {
        drag.convert(session.location(in: drag), to: nil)
    }

    private static func invisible() -> UIView { UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)) }

    private static func invisibleParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        return parameters
    }
}

/// 记下这一次按下是不是指针（触控板、鼠标），见 CardHeaderView 的 itemsForBeginning。只看不认：按下就放弃，不挡别的手势。
private final class TouchKindObserver: UIGestureRecognizer {
    private(set) var pointer = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { $0.rawValue as NSNumber }
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        pointer = touches.first?.type == .indirectPointer
        state = .failed
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
