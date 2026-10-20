#if os(macOS)
import AppKit
import SwiftUI

/// 台面（StageView）上的一张卡片：
/// 外框和最小化色、点阵层、窗口正文、头像、头像描边、标题栏一层（拖动区、窗口按钮）。视图铺满台面，各层按台面坐标摆；
/// 铺满台面的几层（外框、点阵、头像、描边）都不接点击，只有正文和标题栏一层接。
/// 终点由台面按 CardPresentation 算好交过来，交给 WindowMotion。排布动画开始计时时整段交给 Core Animation（flightStarted），
/// 跟手拖动由台面的显示链接逐帧取样（applyPresentation），都只改图层。
/// 正文按停着的样子排一次，飞行中只改外层图层的变换和遮罩（HostedContentContainer）：会话窗口是原生外框（ThreadWindowView），
/// 别的窗口是托管视图；点阵、头像、窗口按钮各是一个托管视图。标题栏一层按停着的外框摆，飞行中看不见也不接输入：
/// 跟着外框逐帧变大小的话，拖动区这个 AppKit 视图每帧改尺寸，连带焦点、可见范围、跟踪区域和光标逐帧重算（2026-10-12 Mac 实测）。
final class CardView: NSView {
    /// 台面这一轮给这张卡片的：终点、停靠格、在不在退出、侧栏入口给不给它、是不是被停靠栏展开的面板压暗、接不接输入。
    struct Arrangement {
        let placed: CardPresentation.Placement
        let dockFrame: CGRect?
        let closing: Bool
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
        let pinShown: Bool
    }

    func headerState(layout: WindowLayout, minimized: Bool, width: CGFloat, hasThread: Bool, pinned: Bool) -> HeaderState {
        let controls = PaneHeaderControls(header: header, layout: layout, minimized: minimized, width: width, hasThread: hasThread,
                                          pinned: pinned)
        return HeaderState(height: header.height, menuWidth: header.menuWidth, controlsSize: header.controlsSize,
                           excluded: headerRegions.settled, buttonsShown: controls.shown, pinShown: controls.pinShown)
    }

    let pane: Pane
    private weak var stage: StageView?
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
    private var threadWindow: ThreadWindowView?

    private let fill = CardFillView()
    private var backdrop: BackdropHost?
    private var container: HostedContentContainer?
    /// 头像随外框平移的那一层，铺满台面：点击和读屏都穿过去，不挡下面的正文、缝和别的卡片（PassThroughView）。
    private let iconMover = PassThroughView()
    private let icon = CardIsland()
    private let ring = CardRingView()
    private let headerView = CardHeaderView()
    private let buttons = CardIsland()

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
    /// 头像里放的东西，变了才换托管视图的 rootView。
    private var iconKey: IconKey?
    /// 交给托管视图的环境，外观变了才换。
    private var installed = false
    /// 正文（会话窗口连同原生外框和对话）、点阵和窗口按钮还没建。头一次排布就收在停靠栏里的卡片先只有外框和头像：
    /// 进入工作区时台面上的窗口先出来，停靠栏里的由台面空闲时一张张补（见 StageView.warmUp），要露出来时当场建（见 arrange）。
    private(set) var bodyDeferred = false

    var motionMoving: Bool { placed?.motion.moving ?? false }

    /// 要台面的显示链接逐帧取样：只有跟手拖动（指针一动整条轨迹跟着平移，不能整段预先交出去）。
    /// 别的排布动画开始计时时整段交给 Core Animation（见 flightStarted），主线程忙也不掉帧。
    var needsFrames: Bool { guard let motion = placed?.motion else { return false }; return motion.moving && motion.tracking }
    /// 这一段已经交给 Core Animation。
    private var flying = false
    /// 台面挪过，交给 Core Animation 的那一段收掉了，等这一轮 move 接着交（见 shift）。
    private var flightCut = false
    /// 会话窗口的原生外框眼下按多大排着，见 placeContent。
    private var nativeSize: CGSize?
    /// 排布动画开始的那几轮，会话窗口的原生外框先不按终点改大小，等这一段交给 Core Animation 以后的下一帧再改（见 arrange）。
    /// 记的是推迟到哪个终点。
    private var resizePending: WindowPose?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(pane: Pane, stage: StageView) {
        self.pane = pane
        self.stage = stage
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        header.layout = stage.group.layout
        addSubview(fill)
        iconMover.wantsLayer = true
        iconMover.addSubview(icon)
        headerView.addSubview(buttons)
        setAccessibilityRole(.group)
        threadSlot.attach = { [weak self] thread, pane, environment in self?.attachThread(thread, pane: pane, environment: environment) }
        threadSlot.detach = { [weak self] pane in self?.detachThread(pane) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 第一次排布时 motion 才有，正文、点阵等这时建：叠放从下到上是外框、点阵、正文、头像、描边、标题栏一层。
    private func install(motion: WindowMotion) {
        guard let stage else { return }
        let backdrop = BackdropHost(rootView: AnyView(EmptyView()))
        backdrop.sizingOptions = []
        backdrop.wantsLayer = true
        backdrop.alphaValue = 0
        let container = HostedContentContainer(rootView: AnyView(EmptyView()))
        container.motion = motion
        link.container = container
        self.backdrop = backdrop
        self.container = container
        addSubview(backdrop)
        addSubview(container)
        addSubview(iconMover)
        addSubview(ring)
        addSubview(headerView)
        let pane = pane
        headerView.drag.onChanged = { [weak stage] drag in stage?.drag(pane, to: drag.location) }
        headerView.drag.onEnded = { [weak stage] in stage?.drop() }
        headerView.drag.onClick = { [weak self] in self?.click() }
        headerView.contextMenu.delegate = headerView
        headerView.buildMenu = { [weak self] menu in self?.buildMenu(menu) }
        motion.onStart = { [weak self] motion in self?.flightStarted(motion) }
        bodyDeferred = placed?.minimized == true
        environmentChanged()
        trackMotion()
    }

    /// 外观类的环境变了，或窗口组换了一项（资源库同一类里换角色、模板）：各个托管视图重新交环境，正文按新的一项重建，
    /// 会话窗口的原生外框也换上。正文里的桥接上来的环境跟着变（CardContentState.environment 每次加一），见 ThreadPaneBridge。
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
        container.host.rootView = stage.rooted(CardContent(
            group: group, pane: pane, state: content, header: header, headerRegions: headerRegions, presence: presence, motion: motion,
            reports: bodyReports, link: link, carrier: carrier, scope: scope, threadSlot: threadSlot))
        backdrop.rootView = stage.rooted(CardDots(reports: bodyReports, carrier: carrier, scope: scope, motion: motion))
        buttons.rootView = stage.rooted(CardButtons(group: group, pane: pane, header: header, state: content, motion: motion))
    }

    /// 拆掉：不再跟模型，收掉闭包和托管视图里的东西，原生外框一起拆。闭包都只弱持有台面和卡片，这里清掉是为了不留着已经没用的模型。
    func dismantle() {
        motionTracking.cancel()
        resizeLink?.invalidate()
        resizeLink = nil
        threadWindow?.dismantle()
        threadWindow = nil
        threadSlot.attach = nil
        threadSlot.detach = nil
        placed?.motion.onStart = nil
        presentation.motion?.onStart = nil
        let drag = headerView.drag
        drag.onChanged = nil
        drag.onEnded = nil
        drag.onClick = nil
        headerView.buildMenu = nil
        container?.native = nil
        container?.host.rootView = AnyView(EmptyView())
        backdrop?.rootView = AnyView(EmptyView())
        icon.rootView = AnyView(EmptyView())
        buttons.rootView = AnyView(EmptyView())
        link.container = nil
    }

    // MARK: - 会话窗口的原生外框

    /// 正文里的会话窗口桥接上来（或它的环境变了）：建原生外框，托管的正文从此不跟着改尺寸（见 placeContent）。
    private func attachThread(_ thread: WorkThread, pane threadPane: ThreadPaneModel, environment: EnvironmentValues) {
        guard let stage, let motion = placed?.motion, let container else { return }
        if let threadWindow, threadWindow.thread === thread, threadWindow.pane === threadPane {
            threadWindow.environmentChanged(environment, group: stage.group)
            return
        }
        threadWindow?.dismantle()
        let window = ThreadWindowView(thread: thread, pane: threadPane, environment: environment, group: stage.group, paneID: pane,
                                      model: stage.model, header: header, regions: headerRegions, reports: bodyReports, motion: motion)
        threadWindow = window
        container.native = window
        // 新建窗口刚变成会话：外框淡入，和淡出的新建窗口正文交叠
        if stage.group.workspace?.takeFadeIn(pane) == true {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        }
        if !content.nativeThread { content.nativeThread = true }
        stage.needsLayout = true
    }

    /// 桥不在了（窗口不再是会话）：收掉原生外框，正文回到托管视图。
    private func detachThread(_ threadPane: ThreadPaneModel) {
        guard let threadWindow, threadWindow.pane === threadPane else { return }
        threadWindow.dismantle()
        self.threadWindow = nil
        container?.native = nil
        if content.nativeThread { content.nativeThread = false }
        bodyReports.threadSlots = []
        stage?.needsLayout = true
    }

    // MARK: - 排布

    /// 台面这一轮排布（在台面的观察之外调）：记下终点和状态，摆好不随时钟走的各层，再由台面把终点交给 motion（见 move）。
    func arrange(_ arrangement: Arrangement, kind: WindowMotionKind) {
        let placed = arrangement.placed
        let first = self.placed == nil
        // 缩小、恢复时别的窗口跟着改大小：动画开始的这一轮会话窗口先按原来的大小留在终点的位置上，不当场按新大小重排整段对话，
        // 这一段交给 Core Animation 以后的下一帧再改（见 flightStarted）。动画开始那一刻窗口还是原来的大小，看着一样；动作到第一帧
        // 少了整个窗口的重排（2026-10-14 Mac 实测约 10 毫秒），重排挪到动画开始以后，外框、正文的动画由 Core Animation 照常走
        if let nativeSize, threadWindow != nil, !placed.minimized, nativeSize != placed.contentSize,
           kind == .settle && placed.motion.target != placed.target || resizePending == placed.target {
            resizePending = placed.target
        } else {
            resizePending = nil
        }
        self.placed = placed
        self.arrangement = arrangement
        if first { install(motion: placed.motion) }
        if !placed.minimized { buildBody() }
        closing = arrangement.closing
        acceptsInput = arrangement.acceptsInput
        let target = placed.target, minimized = placed.minimized

        if content.minimized != minimized { content.minimized = minimized }
        // 窗口按钮飞行中看不见（见 CardButtons），「展开」的有无等停下再换：动画开始的这一轮不重排按钮组和让位的标题栏
        if content.expansion == nil || !placed.motion.moving && (placed.motion.target == target || kind.duration == 0) { updateExpands() }
        if content.pinned != arrangement.pinned { content.pinned = arrangement.pinned }
        if (content.openSidebar == nil) != (arrangement.openSidebar == nil) { content.openSidebar = arrangement.openSidebar }
        if presence.onScreen != !minimized { presence.onScreen = !minimized }
        // 正文标题栏按这几项算给窗口按钮让出多少，见 PaneHeaderControlsSpace；会话窗口推迟改大小时一起推迟
        if resizePending == nil { placeHeaderControls() }

        placeContent(target: target, contentSize: placed.contentSize)
        placeHeader(target: target, minimized: minimized, fixed: arrangement.fixed, state: arrangement.header)
        updateIcon()
        updateColors()
        setDimmed(arrangement.dimmed)
        if !acceptsInput { setHovered(false) }
    }

    /// 台面在窗口里挪了（侧栏收起、展开，见 StageView.layout）：在台面坐标里反着挪，窗口里看着不动。交给 Core Animation 的那一段
    /// 是按原来的坐标取的，先收掉；接着台面这一轮照常 arrange、move，终点换了从这一刻重新起一段，没换的把剩下的接着交。
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
        // 这一段交上去以后的下一帧再按终点改会话窗口的大小，见 arrange。下一轮运行循环可能赶在下一帧之前，就把这一帧也压住了
        if resizePending != nil, resizeLink == nil {
            let link = displayLink(target: self, selector: #selector(resizeTick(_:)))
            link.add(to: .main, forMode: .common)
            resizeLink = link
        }
    }

    private var resizeLink: CADisplayLink?

    /// 外框、最小化色、描边、头像、正文的变换和遮罩、标题两侧按 poses（按时间均匀取）整段交给 Core Animation，模型值停在最后一帧。
    private func handOff(_ poses: [WindowPose], duration: TimeInterval) {
        guard let last = poses.last else { return }
        flying = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.animate(poses, duration: duration)
        if ringColor != nil { ring.animate(poses, duration: duration) }
        let size = iconSize
        if let layer = iconMover.layer {
            let transforms = poses.map { NSValue(caTransform3D: iconTransform($0, size: size)) }
            layer.sublayerTransform = iconTransform(last, size: size)
            iconMover.alphaValue = last.iconOpacity
            layer.add(StageKeyframes.make("sublayerTransform", transforms, duration: duration), forKey: "flight")
            layer.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration), forKey: "flight-opacity")
        }
        animateContent(poses, duration: duration)
        CATransaction.commit()
        stage?.updateDisplayLink()
    }

    @objc private func resizeTick(_ link: CADisplayLink) {
        link.invalidate()
        resizeLink = nil
        resizeNow()
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

    /// 推迟的会话窗口改大小：按终点摆正文和标题栏。标题右边的截法按标题栏当时的宽算（见 WindowHeaderAnchored.follow），
    /// 还在飞的这一段先按新的大小排好，再从这一刻接着交给 Core Animation。
    private func resizeNow() {
        guard resizePending != nil, let placed else { return }
        resizePending = nil
        placeHeaderControls()
        placeContent(target: placed.target, contentSize: placed.contentSize)
        let motion = placed.motion
        guard flying, let flight = motion.flight else { return }
        let now = Date.now, remaining = flight.start.addingTimeInterval(flight.duration).timeIntervalSince(now)
        guard remaining > 0 else { return }
        container?.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animateContent(motion.presentations(from: now, duration: remaining), duration: remaining)
        CATransaction.commit()
    }

    /// 缩在停靠栏里的窗口没有按钮，「展开」的有无不跟着台面换：别的窗口缩小、恢复时它看不见的按钮组也要重排一遍玻璃，
    /// 首帧里几毫秒（2026-10-14 实测，挡住以后 Mac 缩小、恢复的首帧约 27 → 24、35 → 28 毫秒），等它回到台面停下再换。
    /// 头一次照样给，没给时按钮组退回去读排布，台面一变就跟着更新。
    private func updateExpands() {
        guard let arrangement, let placed, content.expansion == nil || !placed.minimized, content.expansion != arrangement.expansion else { return }
        content.expansion = arrangement.expansion
    }

    private func placeHeaderControls() {
        guard let placed, let arrangement else { return }
        let headerPlacement = HeaderPlacement(minimized: placed.minimized, width: placed.target.frame.width, hasThread: arrangement.hasThread,
                                              pinned: arrangement.pinned)
        if header.placement != headerPlacement { header.placement = headerPlacement }
    }

    /// 收掉交给 Core Animation 的那一段（换终点、停下）。
    private func stopFlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.stopAnimations()
        ring.stopAnimations()
        iconMover.layer?.removeAnimation(forKey: "flight")
        iconMover.layer?.removeAnimation(forKey: "flight-opacity")
        CATransaction.commit()
    }

    private func iconTransform(_ pose: WindowPose, size: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(pose.frame.midX - size / 2, pose.frame.midY - size / 2, 0)
    }

    /// 托管正文的范围：正文的排版框加上停着时的外框（标题两侧按外框贴边，外框比正文宽时按钮在正文外面，托管视图要盖住它们才接得到点击）；
    /// 托管视图的原点对齐窗口原点，正文保留窗口坐标（见 HostedContentContainer）。
    private func placeContent(target: WindowPose, contentSize: CGSize) {
        guard let stage, let container else { return }
        // 会话窗口推迟改大小时正文还是原来的大小，按它眼下的大小算摆在哪：按新的大小居中的话，原来大小的正文偏出两者差的一半、
        // 一边被外框切掉，改了大小再跳回来（2026-10-20 侧栏收起、展开逐帧截图，正文先偏后跳）
        let size = threadWindow != nil && resizePending != nil ? nativeSize ?? contentSize : contentSize
        let destination = target.contentOrigin(size: size)
        let area = CGRect(origin: destination, size: size).union(target.frame)
        let origin = stage.origin
        if threadWindow != nil {
            // 原生外框：托管的正文只剩桥，不跟着改尺寸；外框按正文停着的位置摆在这一层里，推迟改大小时先留着原来的大小
            let placement = HostedPlacementValue()
            if link.placement.value != placement { link.placement.value = placement }
            nativeSize = size
            container.nativeFrame = CGRect(x: destination.x - area.minX, y: destination.y - area.minY,
                                           width: size.width, height: size.height)
            threadWindow?.windowOrigin = CGPoint(x: origin.x + destination.x, y: origin.y + destination.y)
        } else {
            let placement = HostedPlacementValue(origin: CGPoint(x: origin.x + area.minX, y: origin.y + area.minY),
                                                 contentSize: contentSize,
                                                 offset: CGPoint(x: origin.x + destination.x, y: origin.y + destination.y),
                                                 extent: CGSize(width: max(origin.x + area.maxX, 0), height: max(origin.y + area.maxY, 0)))
            if link.placement.value != placement { link.placement.value = placement }
        }
        container.origin = CGPoint(x: origin.x + area.minX, y: origin.y + area.minY)
        if container.frame != area { container.frame = area }
        // 点阵层按台面全幅铺，遮罩按外框。窗口没开点阵时里面是空的，不跟着台面改尺寸（侧栏拖宽时台面每步都变）；
        // 开了点阵时台面重排一轮（见 StageView.arrange 读 usesDots），这里接着铺满
        if let backdrop, backdrop.frame != bounds, bodyReports.usesDots || backdrop.frame == .zero { backdrop.frame = bounds }
        for view in [fill, ring, iconMover] where view.frame != bounds { view.frame = bounds }
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
        let contextMenu = minimized ? headerView.contextMenu : nil
        if drag.menu !== contextMenu { drag.menu = contextMenu }
        let shown = state.buttonsShown
        if content.buttonsShown != shown { content.buttonsShown = shown }
        if content.pinShown != state.pinShown { content.pinShown = state.pinShown }
        let menu = state.menuWidth
        let trailing = minimized ? 0 : menu + (shown ? state.controlsSize.width + Metrics.paneButtonGap : 0) + Metrics.paneMargin
        let dragFrame = CGRect(x: 0, y: 0, width: max(frame.width - trailing, 0), height: height)
        if drag.frame != dragFrame { drag.frame = dragFrame }
        let cursor: NSCursor = minimized ? .pointingHand : .openHand
        if drag.cursor !== cursor {
            drag.cursor = cursor
            window?.invalidateCursorRects(for: drag)
        }
        drag.activeCursor = .closedHand
        drag.minimumDistance = minimized ? Metrics.dragThreshold : state.height
        drag.excluded = minimized ? [] : state.excluded
        // 窗口按钮组让开正文的菜单，在标题栏里竖着居中
        buttons.isHidden = minimized || fixed
        let size = state.controlsSize == .zero ? buttons.fittingSize : state.controlsSize
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
        ring.apply(pose, shown: ringColor != nil)
        iconMover.layer?.sublayerTransform = iconTransform(pose, size: iconSize)
        iconMover.alphaValue = pose.iconOpacity
        if dotsShown { maskDots(pose) }
        if let container {
            let size = laidSize(placed)
            let destination = placed.target.contentOrigin(size: size)
            let area = container.frame
            let frame = HostedContentFrame(pose: pose, target: placed.target, destination: destination, area: area, contentSize: size)
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
                resizeNow()
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
        // 拖着、关闭、在停靠栏和台面之间飞的卡片压在别的窗口上面。不然按加入的先后排，缩小时从后面那个窗口底下穿过，
        // 快到停靠栏才从它的直边露出来，头像和卡片都被切掉一截（2026-10-12 Mac 实测）
        let raised = arrangement?.dragged == true || closing || motion.changingForm
        if raised != self.raised {
            self.raised = raised
            layer?.zPosition = raised ? 1 : 0
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

    /// 点阵不参与过渡（见 WindowLayout.transitioning）：卡片在动、拖缝调整大小时当场收起；停下后淡入 0.25 秒，交给图层动画，主线程不逐帧插值。
    private func updateDots() {
        guard let backdrop, let placed else { return }
        let shown = !(arrangement?.dotsHidden ?? false) && !placed.motion.moving
        guard shown != dotsShown else { return }
        dotsShown = shown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.alphaValue = shown ? 1 : 0
        if shown {
            maskDots(placed.motion.presentation(at: .now))
            // 不经过 animator()：它由 AppKit 的动画管理器驱动，收起时在首帧后面多一次整窗排版
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.layer?.add(fade, forKey: "fade")
        } else {
            // 收起要当场收：淡入还在走的话图层动画会盖过新的透明度
            backdrop.layer?.removeAnimation(forKey: "fade")
        }
        CATransaction.commit()
    }

    private let dotsMask = CAShapeLayer()

    private func maskDots(_ pose: WindowPose) {
        guard let layer = backdrop?.layer else { return }
        if layer.mask !== dotsMask { layer.mask = dotsMask }
        dotsMask.frame = layer.bounds
        var rect = pose.frame
        if !layer.contentsAreFlipped() { rect.origin.y = layer.bounds.height - rect.maxY }
        dotsMask.path = RoundedRectangle(cornerRadius: pose.radius).path(in: rect).cgPath
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 底色是卡片色；最小化色代理用卡片色、工具用它的颜色；描边是头像报来的颜色。按这个视图的外观解析成 SwiftUI 里同样的值。
    private func updateColors() {
        guard let stage, let placed else { return }
        var environment = stage.environment
        environment.colorScheme = effectiveAppearance.isDark ? .dark : .light
        func resolved(_ color: Color) -> CGColor { color.resolve(in: environment).cgColor }
        fill.colors(base: resolved(Theme.card), minimized: resolved(placed.appearance.isAgent ? Theme.card : placed.appearance.tint))
        ring.color(ringColor.map(resolved))
    }

    // MARK: - 压暗

    /// 停靠栏展开着面板时，缩在停靠栏里的卡片模糊 4、透明 0.3，同 DockDimmed；跟着展开收起的 snappy 走。
    private func setDimmed(_ dimmed: Bool) {
        guard dimmed != self.dimmed, let layer else { return }
        self.dimmed = dimmed
        let reduceMotion = stage?.look?.reduceMotion ?? false
        let opacity: Float = dimmed ? 0.3 : 1, radius: CGFloat = dimmed ? 4 : 0
        let from = layer.presentation()?.opacity ?? layer.opacity
        // 半径按点，同 SwiftUI 的 blur（2026-10-13 逐像素比过；按像素乘屏幕倍数会糊一倍）
        let scale: CGFloat = 1
        let fromRadius = (layer.presentation()?.value(forKeyPath: "filters.blur.inputRadius") as? CGFloat) ?? (dimmed ? 0 : 4 * scale)
        if contentFilters.isEmpty, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            contentFilters = [blur]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 不压暗了：动画走完把模糊拿掉，不让它一直挂在卡片的图层上
        if !dimmed {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.dimmed else { return }
                contentFilters = []
            }
        }
        alphaValue = CGFloat(opacity)
        layer.setValue(radius * scale, forKeyPath: "filters.blur.inputRadius")
        if !reduceMotion {
            layer.add(StageAnimation.spring("opacity", from: Double(from), to: Double(opacity), spring: .snappy), forKey: "dim")
            layer.add(StageAnimation.spring("filters.blur.inputRadius", from: Double(fromRadius), to: Double(radius * scale), spring: .snappy),
                      forKey: "dim-blur")
        }
        CATransaction.commit()
    }

    // MARK: - 悬停与点击

    /// 指针在不在这张卡片上（台面统一跟踪，见 StageView.refreshHover）：停着时按外框（缩成停靠形状时是圆或圆角方）算。
    func contains(_ point: CGPoint) -> Bool {
        guard let placed, acceptsInput, !placed.motion.moving else { return false }
        let target = placed.target
        return NSBezierPath(roundedRect: target.frame, xRadius: target.radius, yRadius: target.radius).contains(point)
    }

    /// 正文停着、看得见、接输入，且 point（台面坐标）落在外框里：点了聚焦这个窗口，见 StageView.focusClick。
    func showsContent(at point: CGPoint) -> Bool {
        guard let placed, !placed.minimized, contains(point) else { return false }
        return true
    }

    /// 悬停：窗口按钮露出来（见 PaneHeaderControls）；缩成停靠形状停着时浮出停靠栏的名字。
    func setHovered(_ hovered: Bool) {
        guard hovered != self.hovered else { return }
        self.hovered = hovered
        if header.hovered != hovered { header.hovered = hovered }
        guard let stage, let placed, let area = stage.group.workspace else { return }
        let layout = stage.group.layout
        // 缩成停靠形状、停着、没在拖动和拖缝时才浮出停靠栏的名字
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

    /// 右键菜单只在缩成停靠形状时有（这时它就是停靠栏里那一格，同 DockEntryMenu）：先写名字与状态，再是实例操作和关闭窗口。标题栏上没有。
    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let stage, let placed, let area = stage.group.workspace,
              let target = area.windows.first(where: { $0.id == pane.id })?.target,
              let instance = area.instances.first(where: { $0.id == target.instanceId }) else { return }
        guard placed.minimized else { return }
        let label = NSMenuItem(title: area.dockLabel(.pane(pane)), action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        let model = stage.model
        for action in InstanceAction.all(for: instance, in: area, model: model, pane: pane) {
            menu.addItem(MenuAction.item(action.title, enabled: action.enabled, destructive: action.destructive, perform: action.perform))
        }
    }

    // MARK: - 命中与读屏

    /// 卡片铺满台面，自己不接点击，只有里面的正文和标题栏一层接；不接输入时（过渡中、退出、拖缝、被压暗）整张都不接。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsInput else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func accessibilityLabel() -> String? { placed?.appearance.name }

    /// 收进家族格的子代理窗口整张透明，读屏也跳过，由家族格读。
    override func isAccessibilityElement() -> Bool { placed?.hidden != true }

    override func accessibilityFrame() -> NSRect {
        guard let placed, let window else { return .zero }
        return window.convertToScreen(convert(placed.target.frame, to: nil))
    }

    /// 读屏打开右键菜单（VO-Shift-M）：同缩成停靠形状时右键。
    override func accessibilityPerformShowMenu() -> Bool {
        guard let placed, placed.minimized, acceptsInput else { return false }
        let menu = headerView.contextMenu
        buildMenu(menu)
        guard !menu.items.isEmpty else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: placed.target.frame.minX + 12, y: placed.target.frame.minY + 12), in: self)
        return true
    }

    /// 读屏的动作同窗口按钮收进更多菜单时的那几项（paneWindowActions）；缩在停靠栏里时展开窗口。最小化时正文对读屏隐藏，见 PaneCardBody。
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let placed, let stage, !closing else { return nil }
        let pane = pane
        if placed.minimized {
            return [NSAccessibilityCustomAction(name: "展开窗口") { [weak stage] in stage?.activate(pane); return true }]
        }
        return paneWindowActions(group: stage.group, pane: pane, model: stage.model)?.commands.filter(\.enabled).map { command in
            NSAccessibilityCustomAction(name: command.title) { command.action(); return true }
        }
    }
}

/// 卡片里的托管视图（头像、窗口按钮）：按自己的大小摆，点击和读屏照常。
final class CardIsland: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
    }

    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 外框底色和最小化色：两层同一个轮廓，底色按 min(正文 + 头像, 1)、最小化色按头像的透明度。
private final class CardFillView: NSView {
    private let base = CAShapeLayer()
    private let minimized = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(base)
        layer?.addSublayer(minimized)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func colors(base: CGColor, minimized: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.base.fillColor = base
        self.minimized.fillColor = minimized
        CATransaction.commit()
    }

    func apply(_ pose: WindowPose) {
        guard let layer else { return }
        stopAnimations()
        let path = outline(pose.frame, radius: pose.radius, in: layer)
        for shape in [base, minimized] {
            shape.frame = layer.bounds
            shape.path = path
        }
        base.opacity = baseOpacity(pose)
        minimized.opacity = Float(pose.iconOpacity)
    }

    private func baseOpacity(_ pose: WindowPose) -> Float { Float(min(pose.contentOpacity + pose.iconOpacity, 1)) }

    /// 整段交给 Core Animation：路径和透明度按每一帧走，模型值停在最后一帧。
    func animate(_ poses: [WindowPose], duration: TimeInterval) {
        guard let layer, let last = poses.last else { return }
        apply(last)
        let paths = poses.map { outline($0.frame, radius: $0.radius, in: layer) }
        for shape in [base, minimized] { shape.add(StageKeyframes.make("path", paths, duration: duration), forKey: "flight") }
        base.add(StageKeyframes.make("opacity", poses.map(baseOpacity), duration: duration), forKey: "flight-opacity")
        minimized.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration), forKey: "flight-opacity")
    }

    func stopAnimations() {
        for shape in [base, minimized] {
            shape.removeAnimation(forKey: "flight")
            shape.removeAnimation(forKey: "flight-opacity")
        }
    }
}

/// 头像的描边压在外框上，随头像淡入：内缩半个线宽、外缘与外框贴合，飞过同色的窗口时也看得出轮廓，落进停靠栏外框就是头像那一圈。
private final class CardRingView: NSView {
    private let shape = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineWidth = DockFace.ringWidth
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func color(_ color: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeColor = color
        shape.isHidden = color == nil
        CATransaction.commit()
    }

    func apply(_ pose: WindowPose, shown: Bool) {
        guard shown, let layer else { return }
        stopAnimations()
        shape.frame = layer.bounds
        shape.path = path(pose, in: layer)
        shape.opacity = Float(pose.iconOpacity)
    }

    private func path(_ pose: WindowPose, in layer: CALayer) -> CGPath {
        let inset = DockFace.ringWidth / 2
        return outline(pose.frame.insetBy(dx: inset, dy: inset), radius: max(pose.radius - inset, 0), in: layer)
    }

    /// 整段交给 Core Animation，同 CardFillView.animate。
    func animate(_ poses: [WindowPose], duration: TimeInterval) {
        guard let layer, let last = poses.last else { return }
        apply(last, shown: true)
        shape.add(StageKeyframes.make("path", poses.map { path($0, in: layer) }, duration: duration), forKey: "flight")
        shape.add(StageKeyframes.make("opacity", poses.map { Float($0.iconOpacity) }, duration: duration), forKey: "flight-opacity")
    }

    func stopAnimations() {
        shape.removeAnimation(forKey: "flight")
        shape.removeAnimation(forKey: "flight-opacity")
    }
}

/// 外框的轮廓：同 WindowOutline（SwiftUI 的 RoundedRectangle），按图层坐标；图层没翻转时上下翻过来。
/// 段数固定（见 WindowOutline.path），Core Animation 能在两帧之间插值。
private func outline(_ frame: CGRect, radius: CGFloat, in layer: CALayer) -> CGPath {
    var rect = frame
    if !layer.contentsAreFlipped() { rect.origin.y = layer.bounds.height - rect.maxY }
    return WindowOutline.path(in: rect, radius: radius)
}

/// 标题栏一层：拖动区和窗口按钮，按停着的外框摆，命中按外框的圆角裁。
private final class CardHeaderView: NSView, NSMenuDelegate {
    let drag = MouseDragArea.DragView()
    let contextMenu = NSMenu()
    var buildMenu: ((NSMenu) -> Void)?
    /// 外框在这一层里的范围和圆角。
    var clip = CGRect.zero
    var radius: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard NSBezierPath(roundedRect: clip, xRadius: radius, yRadius: radius).contains(local) else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu?(menu)
    }
}

/// 一个菜单项和它的动作。
@MainActor final class MenuAction: NSObject {
    private let perform: @MainActor () -> Void

    private init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }

    /// destructive：标题用危险色，同 MenuButton。菜单只认标题自带的颜色，不可用时由菜单自己调淡。
    static func item(_ title: String, enabled: Bool, destructive: Bool = false, perform: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuAction(perform)
        let item = NSMenuItem(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        if destructive {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor(named: "Danger") ?? .systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        }
        return item
    }

    @objc private func run() { perform() }
}

#endif
