#if os(iOS)
import SwiftUI
import UIKit

/// 紧凑布局里的一行窗口，原生版：替代 CompactPaneStack 和 CompactPaneHeaderHost。窗口按底栏的顺序排成一行，铺满时只露出当前窗口；
/// 控制区横滑时整行跟着手指走（PaneRow 照旧管状态和手势的规则），松手按 WindowMotion 的曲线整段交给 Core Animation。
/// 每个窗口是一个格（CompactSlot）：正文是一个岛（PaneBody）；会话窗口在岛里只留桥（ThreadPaneBridge），外框是原生的
/// PhoneThreadWindowView，只放对话和签名。标题栏和控制区都留在外壳上（换窗口时原地淡入淡出，只有正文跟着横滑平移）：
/// 会话窗口的是原生的（PhoneHeaderBar、ControlsBarView），开合时由外壳在图层上补位；别的窗口的是 SwiftUI（CompactPaneHeaderBar、
/// CompactPaneControlsBar），各在一个岛里，照旧在 SwiftUI 里跟着抽屉的弹簧补位（drawerShift）。
/// 窗口建好就一直留着，当前窗口先建，其余的由近到远预热（PaneRow.warmUp），同 CompactPaneStack。
final class CompactRowView: UIView {
    private(set) var group: PaneGroup
    var groupID: String { group.id }
    unowned let shell: CompactShellView
    let row: PaneRow

    /// 各个窗口，整行平移：拖着时每挪一下只重摆这一层（StripView 自己的排版），不把整行重排一遍。
    private let strip = StripView()
    private let slideTracking = ModelTracking()
    /// 别的窗口的标题栏、控制区（SwiftUI 的岛）。
    private let islandChrome = PassThroughView()
    /// 会话窗口的标题栏、控制区（原生），开合时外壳在这两层上补位。
    private let headerShifter = PassThroughView()
    private let controlsShifter = PassThroughView()
    /// 会话窗口标题栏后面的渐变，同 PaneHeaderPlacement 的 topFade：从窗口顶边铺到标题栏底边再往下 topFadeOverhang，跟着标题栏补位。
    private let fade = HostIsland()
    private var slots: [Pane: CompactSlot] = [:]
    /// 外壳上量出来的各窗口控制区高度（别的窗口的 SwiftUI 控制区报的），窗口按它让位。
    let controls = SharedPaneControls()

    private let tracking = ModelTracking()
    private var laying = false
    private var currentPane: Pane?
    private var page: Int?
    private var width: CGFloat?
    private var moving = false
    private var collapsed = true
    private var warmPanes: [Pane]?
    private var warmTask: Task<Void, Never>?
    private var presented = true
    private(set) var usesDots = false

    init(group: PaneGroup, shell: CompactShellView) {
        self.group = group
        self.shell = shell
        row = PaneRow(layout: group.layout, drawer: shell.drawer, width: shell.bounds.width)
        super.init(frame: .zero)
        addSubview(strip)
        strip.laidOut = { [weak self] in self?.placeStrip() }
        addSubview(islandChrome)
        addSubview(headerShifter)
        addSubview(controlsShifter)
        headerShifter.addSubview(fade)
        fade.isUserInteractionEnabled = false
        fade.accessibilityElementsHidden = true
        setLayerOpacity(fade, 0, animated: false)
        fade.rootView = shell.rooted(CompactTopFade())
        row.slide.onStart = { [weak self] motion in self?.slideStarted(motion) }
        #if DEBUG && KITE_LAYOUT_AUDIT
        PerfProbe.row = row
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 资源库里同一类换一项（角色、模板）：一行不重建，各窗口的正文按新的一项换。
    func update(group: PaneGroup) {
        let changed = GroupKey(group) != GroupKey(self.group)
        self.group = group
        if changed { environmentChanged() }
    }

    /// 外观类的环境变了：各个岛重新交环境，会话窗口的原生外框跟着桥换（桥按 nativeThreadGeneration 再交一遍）。
    func environmentChanged() {
        fade.rootView = shell.rooted(CompactTopFade())
        for slot in slots.values { slot.install(row: self) }
        setNeedsLayout()
    }

    func dismantle() {
        warmTask?.cancel()
        warmTask = nil
        tracking.cancel()
        slideTracking.cancel()
        strip.laidOut = nil
        row.slide.onStart = nil
        for slot in slots.values { slot.dismantle() }
        slots = [:]
    }

    /// 淡出时：里面摆在点阵上的图形先收回（同 dotsPresence 转场）。
    func setPresented(_ presented: Bool) {
        self.presented = presented
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - 排版

    private struct Read {
        var panes: [Pane] = []
        var focused: Pane?
        var warm: Set<Pane> = []
        var swipe: PaneRow.Swipe?
        var moving = false
        var page: Int?
        var covered = EdgeInsets()
        var home: CGFloat = 0
        var keyboardShown = false
        var collapsed = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        laying = true
        defer { laying = false }
        let read = tracking.track({ readModel() }) { [weak self] in self?.invalidate() }
        let width = bounds.width, height = bounds.height
        for view in [strip, islandChrome, headerShifter, controlsShifter] where view.bounds.size != bounds.size {
            view.bounds = CGRect(origin: .zero, size: bounds.size)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        placeStrip()

        // 各个窗口：当前的和预热过的。当前窗口换了时标题栏、控制区淡入淡出（snappy），同 CompactPaneHeaderHost 的 .animation(.snappy, value: focused)
        let focusChanged = currentPane != read.focused
        let fades = focusChanged && currentPane != nil && !(shell.look?.reduceMotion ?? false)
        currentPane = read.focused
        for (pane, slot) in slots where !read.panes.contains(pane) {
            slot.dismantle()
            slots[pane] = nil
        }
        var dots = false
        for (index, pane) in read.panes.enumerated() where read.warm.contains(pane) || pane == read.focused {
            let slot = slots[pane] ?? makeSlot(pane)
            let current = pane == read.focused
            // 滑动途中，开始时那个窗口两旁的都可能露出来
            let exposed = current || read.swipe.map { abs(index - $0.page) <= 1 } == true
            slot.view.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
            if slot.presence.onScreen != exposed { slot.presence.onScreen = exposed }
            let dotsShown = presented && current && read.swipe == nil
            if slot.state.presented != dotsShown { slot.state.presented = dotsShown }
            slot.dotsPresence.update(shown: dotsShown)
            slot.view.isUserInteractionEnabled = current
            slot.view.accessibilityElementsHidden = !current
            if exposed, slot.usesDots { dots = true }
            layoutChrome(slot, exposed: exposed, read: read)
            slot.setChromeOpacity(current ? 1 : 0, animated: fades)
        }
        // 渐变：当前窗口是会话窗口时露出来，铺到它的标题栏底下
        if let slot = read.focused.flatMap({ slots[$0] }), let thread = slot.thread {
            let height = read.covered.top + thread.headerBar.height + Metrics.topFadeOverhang
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            if fade.frame != frame { fade.frame = frame }
            setLayerOpacity(fade, 1, animated: fades)
        } else {
            setLayerOpacity(fade, 0, animated: fades)
        }
        if usesDots != dots {
            usesDots = dots
            DispatchQueue.main.async { [weak shell] in shell?.updateDots() }
        }

        // 观察之外，同 CompactPaneStack 的几个 onChange：当过当前窗口的记进预热过的，当前窗口换了停过去，停稳了结束这次横滑，
        // 宽变了、抽屉拉开了不带动画停到当前窗口上，窗口增删了重新预热
        let events = (focused: focusChanged ? read.focused : nil, page: read.page != page, settled: moving && !read.moving,
                      width: self.width != nil && self.width != width, opened: collapsed && !read.collapsed,
                      panes: warmPanes != read.panes)
        page = read.page
        moving = read.moving
        collapsed = read.collapsed
        self.width = width
        if events.panes { warmPanes = read.panes }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            row.reduceMotion = shell.look?.reduceMotion ?? false
            if let focused = events.focused { row.keep(focused) }
            if events.page { row.follow() }
            if events.settled { row.settled() }
            if events.width {
                row.width = width
                row.snap()
            }
            if events.opened { row.snap() }
            if events.panes {
                warmTask?.cancel()
                warmTask = Task { [row] in await row.warmUp() }
            }
        }
    }

    private func readModel() -> Read {
        var read = Read()
        let layout = group.layout
        read.panes = layout.panes
        read.focused = layout.focused
        read.warm = row.warm
        read.swipe = row.swipe
        read.moving = row.slide.moving
        read.page = row.page
        let state = shell.state
        read.covered = state.covered
        read.home = state.home
        read.keyboardShown = state.keyboardShown
        read.collapsed = shell.drawer.collapsed
        return read
    }

    private func invalidate() {
        setNeedsLayout()
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    private func makeSlot(_ pane: Pane) -> CompactSlot {
        let slot = CompactSlot(pane: pane)
        slots[pane] = slot
        strip.addSubview(slot.view)
        slot.threadSlot.attach = { [weak self, weak slot] thread, pane, environment in
            guard let self, let slot else { return }
            attachThread(slot, thread: thread, pane: pane, environment: environment)
        }
        slot.threadSlot.detach = { [weak self, weak slot] pane in
            guard let self, let slot else { return }
            detachThread(slot, pane: pane)
        }
        slot.install(row: self)
        islandChrome.addSubview(slot.headerIsland)
        islandChrome.addSubview(slot.controlsIsland)
        return slot
    }

    // MARK: - 整行平移

    /// 整行的位置：拖着、停着时直接摆；松手后的一段在开始计时时整段交给 Core Animation（slideStarted）。只读整行的位置，变了只重排 strip。
    private func placeStrip() {
        let flying = slideTracking.track({
            _ = row.slide.target
            return row.slide.moving && row.slide.flight != nil
        }) { [weak self] in self?.strip.setNeedsLayout() }
        guard !flying else { return }
        strip.layer.removeAnimation(forKey: "slide")
        setStrip(row.slide.presentation(at: .now).frame.minX)
    }

    private func setStrip(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.layer.transform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }

    /// 松手后的一段开始计时：按 WindowMotion 的曲线每 1/120 秒取一帧，整段交给 Core Animation，模型值停在终点。
    private func slideStarted(_ motion: WindowMotion) {
        guard let flight = motion.flight else { return }
        let steps = max(Int((flight.duration * 120).rounded(.up)), 1)
        let xs = (0...steps).map { motion.presentation(at: flight.start.addingTimeInterval(flight.duration * Double($0) / Double(steps))).frame.minX }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.layer.transform = CATransform3DMakeTranslation(xs[xs.count - 1], 0, 0)
        strip.layer.add(StageKeyframes.make("transform", xs.map { NSValue(caTransform3D: CATransform3DMakeTranslation($0, 0, 0)) },
                                            duration: flight.duration), forKey: "slide")
        CATransaction.commit()
    }

    // MARK: - 标题栏和控制区

    /// 抽屉补位：会话窗口的原生标题栏、控制区平移（外壳逐帧或整段给），同 drawerShift。
    func shift(header: CGFloat, controls: CGFloat) {
        headerShifter.layer.transform = CATransform3DMakeTranslation(0, header, 0)
        controlsShifter.layer.transform = CATransform3DMakeTranslation(0, controls, 0)
    }

    func animateShift(header: [CGFloat], controls: [CGFloat], duration: TimeInterval) {
        headerShifter.layer.add(StageKeyframes.make("transform", header.map { NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0, 0)) },
                                                    duration: duration), forKey: "drawer.transform")
        controlsShifter.layer.add(StageKeyframes.make("transform", controls.map { NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0, 0)) },
                                                      duration: duration), forKey: "drawer.transform")
    }

    func stopShift() {
        headerShifter.layer.removeAnimation(forKey: "drawer.transform")
        controlsShifter.layer.removeAnimation(forKey: "drawer.transform")
    }

    /// 一个窗口的标题栏和控制区：当前窗口的露出来，别的藏着（换窗口时淡入淡出，见 fadeChrome）；会话窗口按外壳的安全区摆原生的两块，
    /// 让出的距离交给对话；别的窗口的两个岛铺满窗口，按它们报的高接点按。
    /// 没露出来的会话窗口按键盘收着的样子排：键盘升降时只有露出来的窗口重排对话（每个窗口一次几十毫秒，iPad 强制紧凑布局真机实测），
    /// 键盘升着时不能横滑，换过去时再按当时的样子排。
    private func layoutChrome(_ slot: CompactSlot, exposed: Bool, read: Read) {
        let width = bounds.width, height = bounds.height
        var covered = read.covered
        guard let thread = slot.thread, let area = slot.controlsArea else {
            for island in [slot.headerIsland, slot.controlsIsland] where island.frame != bounds { island.frame = bounds }
            slot.chromeHeight = (top: covered.top, header: slot.state.headerHeight ?? defaultHeaderHeight(covered.top),
                                 controls: controls.height(for: slot.pane), bottom: covered.bottom)
            return
        }
        let keyboardShown = read.keyboardShown && exposed
        if read.keyboardShown, !exposed { covered.bottom = read.home }
        let header = thread.headerBar
        header.topInset = covered.top
        let headerHeight = header.height
        let headerFrame = CGRect(x: covered.leading, y: covered.top, width: max(width - covered.leading - covered.trailing, 0), height: headerHeight)
        if header.frame != headerFrame { header.frame = headerFrame }
        // 控制区：左右留 paneMargin，玻璃最宽 transcriptWidth 居中；键盘升起时最左边是收起键盘（只在 iPhone 上）。
        // 底边距取 max(paneMargin, Home 条) 只算一次，键盘升起时在键盘上方留 paneMargin，同 PaneControlsBottom
        let safe = keyboardShown ? 0 : read.home
        let bottomPadding = max(Metrics.paneMargin, safe) - safe
        area.showsKeyboardButton = ScreenKeyboard.applies && keyboardShown
        area.typing = { [weak thread] in thread?.controls.typing ?? false }
        area.keyboardShown = keyboardShown
        let available = max(width - covered.leading - covered.trailing - 2 * Metrics.paneMargin, 0)
        let glassHeight = area.layout(available: available)
        let areaHeight = glassHeight + bottomPadding
        area.frame = CGRect(x: covered.leading + Metrics.paneMargin, y: height - covered.bottom - areaHeight, width: available, height: areaHeight)
        thread.compactInsets = EdgeInsets(top: covered.top + headerHeight, leading: covered.leading,
                                          bottom: covered.bottom + areaHeight, trailing: covered.trailing)
    }

    /// 别的窗口的标题栏还没量出来时按这个高让位，同 CompactPaneHeaderHost。
    private func defaultHeaderHeight(_ top: CGFloat) -> CGFloat {
        Metrics.paneHeaderButton + Metrics.paneMargin + max(Metrics.paneMargin, top) - top
    }

    // MARK: - 会话窗口的原生外框

    private func attachThread(_ slot: CompactSlot, thread: WorkThread, pane threadPane: ThreadPaneModel, environment: EnvironmentValues) {
        if let window = slot.thread, window.thread === thread, window.pane === threadPane {
            window.environmentChanged(environment, group: group)
            return
        }
        detachThread(slot, pane: nil)
        let window = PhoneThreadWindowView(thread: thread, pane: threadPane, environment: environment, group: group, paneID: slot.pane,
                                           model: shell.model, header: slot.cardHeader, regions: slot.regions, reports: slot.reports,
                                           motion: row.slide, compact: true)
        window.chromeChanged = { [weak self] in self?.setNeedsLayout() }
        slot.thread = window
        slot.view.addSubview(window)
        window.frame = slot.view.bounds
        window.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let area = CompactControlsArea(bar: window.controls)
        area.row = self
        slot.controlsArea = area
        headerShifter.addSubview(window.headerBar)
        controlsShifter.addSubview(area)
        slot.headerIsland.isHidden = true
        slot.controlsIsland.isHidden = true
        if !slot.state.native { slot.state.native = true }
        slot.setChromeOpacity(slot.pane == currentPane ? 1 : 0, animated: false)
        slot.dotsPresence.stage = environment.dotStage
        slot.dotsPresence.track(slot.reports)
        setNeedsLayout()
    }

    private func detachThread(_ slot: CompactSlot, pane threadPane: ThreadPaneModel?) {
        guard let window = slot.thread, threadPane == nil || window.pane === threadPane else { return }
        window.dismantle()
        window.removeFromSuperview()
        window.headerBar.removeFromSuperview()
        slot.controlsArea?.removeFromSuperview()
        slot.controlsArea = nil
        slot.thread = nil
        slot.headerIsland.isHidden = false
        slot.controlsIsland.isHidden = false
        if slot.state.native { slot.state.native = false }
        slot.dotsPresence.track(nil)
        setNeedsLayout()
    }

    // MARK: - 别的窗口报上来的

    /// 别的窗口报上来标题栏和控制区（CompactPaneHeaders），放进外壳上的两个岛。
    fileprivate func reported(_ header: CompactPaneHeader?, for slot: CompactSlot) {
        slot.source = header
        slot.installChrome(row: self)
        setNeedsLayout()
    }

    fileprivate func reportedDots(_ uses: Bool, for slot: CompactSlot) {
        guard slot.usesDots != uses else { return }
        slot.usesDots = uses
        setNeedsLayout()
    }

    /// 岛里的 SwiftUI 环境：外壳给的整份，加上这一行给的。
    fileprivate func rooted(_ view: some View) -> AnyView {
        shell.rooted(view
            .environment(group.layout)
            .environment(\.windowMotion, row.slide)
            .environment(\.paneSwipe, row.swipeActions))
    }

    // MARK: - 读屏

    /// 按看的顺序：当前窗口的标题栏、正文、控制区。
    override var accessibilityElements: [Any]? {
        get {
            guard let currentPane, let slot = slots[currentPane] else { return [] }
            if let thread = slot.thread, let area = slot.controlsArea { return [thread.headerBar, slot.view, area] }
            return [slot.headerIsland, slot.view, slot.controlsIsland]
        }
        set {}
    }

    /// 窗口组是哪一个：同 PhoneStageView.GroupKey。
    private struct GroupKey: Equatable {
        let layout: ObjectIdentifier
        let workspace: ObjectIdentifier?
        let item: AgentContextItem?

        init(_ group: PaneGroup) {
            layout = ObjectIdentifier(group.layout)
            workspace = group.workspace.map(ObjectIdentifier.init)
            if case .agentContext(let item, _) = group { self.item = item } else { item = nil }
        }
    }
}

/// 一行窗口的那一层：排版时只交给外面重摆位置（平移在图层上），里面的窗口各自按 frame 摆。
private final class StripView: UIView {
    var laidOut: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut?()
    }
}

// MARK: - 一个窗口

/// 一行里的一个窗口：正文的岛（会话窗口只有桥）、原生外框（会话窗口），别的窗口的标题栏和控制区的岛。
private final class CompactSlot {
    let pane: Pane
    let view = UIView()
    let island = HostIsland()
    let presence = PanePresence()
    let threadSlot = ThreadWindowSlot()
    let state = CompactSlotState()
    /// 原生外框要的几样，紧凑布局里没有窗口按钮，只占位。
    let cardHeader = PaneCardHeader()
    let regions = HeaderRegions()
    let reports = PaneCardBodyReports()
    let dotsPresence = NativeDotsPresence()
    var thread: PhoneThreadWindowView?
    var controlsArea: CompactControlsArea?
    /// 别的窗口：报上来的标题栏和控制区，和放它们的两个岛。
    var source: CompactPaneHeader?
    let headerIsland = HostIsland()
    let controlsIsland = HostIsland()
    var usesDots = false
    /// 别的窗口：状态栏让出的、标题栏高、控制区高、底下让出的，接点按的范围按它们算。
    var chromeHeight: (top: CGFloat, header: CGFloat, controls: CGFloat, bottom: CGFloat) = (0, 0, 0, 0)

    init(pane: Pane) {
        self.pane = pane
        view.addSubview(island)
        island.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        headerIsland.hitRegion = { [weak self] in
            guard let self else { return nil }
            return CGRect(x: 0, y: chromeHeight.top, width: headerIsland.bounds.width, height: chromeHeight.header)
        }
        controlsIsland.hitRegion = { [weak self] in
            guard let self else { return nil }
            let height = controlsIsland.bounds.height
            return CGRect(x: 0, y: height - chromeHeight.bottom - chromeHeight.controls, width: controlsIsland.bounds.width, height: chromeHeight.controls)
        }
    }

    /// 正文的岛：PaneBody，会话窗口换成桥（nativeThreadWindow），同 CompactPaneStack 给窗口的环境。
    func install(row: CompactRowView) {
        let group = row.group, pane = pane, shellState = row.shell.state
        island.frame = view.bounds
        island.rootView = row.rooted(CompactSlotRoot(group: group, pane: pane, slot: state, shell: shellState, threadSlot: threadSlot,
                                                     presence: presence, controls: row.controls,
                                                     report: { [weak row, weak self] header in
                                                         guard let row, let self else { return }
                                                         row.reported(header, for: self)
                                                     }, usesDots: { [weak row, weak self] uses in
                                                         guard let row, let self else { return }
                                                         row.reportedDots(uses, for: self)
                                                     }))
        installChrome(row: row)
    }

    func installChrome(row: CompactRowView) {
        guard let source else {
            headerIsland.rootView = AnyView(EmptyView())
            controlsIsland.rootView = AnyView(EmptyView())
            return
        }
        let state = state, shellState = row.shell.state, controls = row.controls
        headerIsland.rootView = row.rooted(CompactChromeHeaderRoot(source: source, slot: state, shell: shellState))
        controlsIsland.rootView = row.rooted(CompactChromeControlsRoot(source: source, shell: shellState, controls: controls))
    }

    func setChromeOpacity(_ opacity: Float, animated: Bool) {
        for view in [thread?.headerBar, controlsArea, headerIsland, controlsIsland] as [UIView?] {
            guard let view else { continue }
            setLayerOpacity(view, opacity, animated: animated)
            view.isUserInteractionEnabled = opacity > 0
        }
    }

    func dismantle() {
        thread?.dismantle()
        thread?.headerBar.removeFromSuperview()
        thread = nil
        controlsArea?.removeFromSuperview()
        controlsArea = nil
        threadSlot.attach = nil
        threadSlot.detach = nil
        dotsPresence.release()
        for island in [island, headerIsland, controlsIsland] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
            island.removeFromSuperview()
        }
        view.removeFromSuperview()
    }
}

/// 一个窗口里托管视图读的：摆在点阵上的图形在不在场（只有当前窗口、没在横滑时），别的窗口量出来的标题栏高。
@MainActor @Observable private final class CompactSlotState {
    var presented = true
    /// 会话窗口的原生外框接上了，见 CompactContentPlacement 的 native。
    var native = false
    var headerHeight: CGFloat?
}

/// 会话窗口原生外框里的签名（ThreadBackdropRoot 报的图形）：横滑时、不是当前窗口时收回，同 SwiftUI 的 DotsPresence。
@MainActor private final class NativeDotsPresence {
    weak var stage: DotStage?
    private let owner = "presence.\(UUID().uuidString)"
    private var slots: Set<String> = []
    private var shown = true
    private let tracking = ModelTracking()
    private weak var reports: PaneCardBodyReports?

    func track(_ reports: PaneCardBodyReports?) {
        self.reports = reports
        tracking.cancel()
        refresh()
    }

    func update(shown: Bool) {
        guard shown != self.shown else { return }
        self.shown = shown
        stage?.setHidden(slots, by: owner, !shown)
    }

    private func refresh() {
        let new = tracking.track({ reports?.threadSlots ?? [] }) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        stage?.setHidden(slots.subtracting(new), by: owner, false)
        stage?.setHidden(new, by: owner, !shown)
        slots = new
    }

    func release() {
        tracking.cancel()
        stage?.release(slots, by: owner)
        slots = []
    }
}

// MARK: - 托管的 SwiftUI

/// 一个窗口的正文：PaneBody 连同 CompactPaneStack、CompactPaneHeaderHost 给窗口的环境，按停着的样子让出安全区（CompactContentPlacement）。
/// 别的窗口的标题栏和控制区报上来（CompactPaneHeaders），交给外壳上的两个岛；会话窗口里只有桥。
private struct CompactSlotRoot: View {
    let group: PaneGroup
    let pane: Pane
    let slot: CompactSlotState
    let shell: CompactShellState
    let threadSlot: ThreadWindowSlot
    let presence: PanePresence
    let controls: SharedPaneControls
    let report: (CompactPaneHeader?) -> Void
    let usesDots: (Bool) -> Void

    var body: some View {
        PaneBody(group: group, pane: pane)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .environment(\.nativeThreadWindow, threadSlot)
            .environment(\.panePresence, presence)
            .environment(\.sharedPaneHeaderHeight, slot.native ? 0 : slot.headerHeight ?? Metrics.paneHeaderButton + Metrics.paneMargin
                         + max(Metrics.paneMargin, shell.covered.top) - shell.covered.top)
            .environment(\.sharedPaneControls, controls)
            .modifier(DotsPresence(presented: slot.presented))
            .modifier(CompactContentPlacement(state: shell, native: slot.native))
            // 隔一拍交出去：托管视图可能在外壳这次排版当中更新
            .onPreferenceChange(WindowDotsActive.self) { uses in Task { @MainActor in usesDots(uses) } }
            .overlayPreferenceValue(CompactPaneHeaders.self) { headers in
                CompactHeaderReporter(header: headers.first(where: { $0.pane == pane }), report: report)
            }
    }
}

/// 会话窗口标题栏后面的渐变：岛的高是窗口顶边到标题栏底边再加 topFadeOverhang，渐变自己往下伸出那一截。
private struct CompactTopFade: View {
    var body: some View {
        GeometryReader { proxy in
            PaneTopFade()
                .frame(height: max(proxy.size.height - Metrics.topFadeOverhang, 0))
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// 把报上来的标题栏交出去：偏好的值不能比较，用一个不占地方的原生视图，每次更新时交。
private struct CompactHeaderReporter: UIViewRepresentable {
    let header: CompactPaneHeader?
    let report: (CompactPaneHeader?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let header = header, report = report
        Task { @MainActor in report(header) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { .zero }
}

/// 别的窗口的标题栏：同 CompactPaneHeaderHost 里的 CompactPaneHeaderBar，量出来的高交给窗口让位。
private struct CompactChromeHeaderRoot: View {
    let source: CompactPaneHeader
    let slot: CompactSlotState
    let shell: CompactShellState

    var body: some View {
        CompactPaneHeaderBar(source: source)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if slot.headerHeight != height { slot.headerHeight = height }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .safeAreaPadding(shell.covered)
    }
}

/// 别的窗口的控制区：同 CompactPaneHeaderHost 里的 CompactPaneControlsBar，量出来的高记给窗口。
private struct CompactChromeControlsRoot: View {
    let source: CompactPaneHeader
    let shell: CompactShellState
    let controls: SharedPaneControls

    var body: some View {
        CompactPaneControlsBar(source: source, controls: controls, keyboardShown: shell.keyboardShown)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .safeAreaPadding(shell.covered)
    }
}

// MARK: - 会话窗口的控制区

/// 会话窗口的控制区（紧凑布局）：原生输入区，键盘升起时最左边是收起键盘，两块玻璃在同一个玻璃容器里（间距 paneButtonGap），
/// 同 PaneControlsBar。整条（连同左右边距和底下的留白）接上拉底栏和横滑换窗口：挪过 dragThreshold 时看横着挪得多还是竖着挪得多，
/// 竖着的拉底栏（打字时不接），横着的换窗口（打字、键盘升起时不接，从思考强度起手的留给它调档），同 DrawerPullModifier 和 PaneControlSwipe。
private final class CompactControlsArea: UIView, UIGestureRecognizerDelegate {
    let bar: ControlsBarView
    weak var row: CompactRowView?
    var typing: () -> Bool = { false }
    var keyboardShown = false
    var showsKeyboardButton = false {
        didSet {
            guard showsKeyboardButton != oldValue else { return }
            // 收起键盘按钮插进来、撤出去时旁边让位，跟着键盘的动画（外壳在键盘的动画块里排版）
            keyboardButton.alpha = showsKeyboardButton ? 1 : 0
            setNeedsLayout()
        }
    }
    private let container: UIVisualEffectView
    private let keyboardButton = KeyboardGlassButton()
    private let drag = ThresholdDrag()
    private enum Mode { case pull, swipe }
    private var mode: Mode?
    private var glassWidth: CGFloat = 0
    private var glassHeight: CGFloat = 0

    init(bar: ControlsBarView) {
        self.bar = bar
        let effect = UIGlassContainerEffect()
        effect.spacing = Metrics.paneButtonGap
        container = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        addSubview(container)
        container.contentView.addSubview(keyboardButton)
        container.contentView.addSubview(bar)
        keyboardButton.alpha = 0
        drag.delegate = self
        drag.addTarget(self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按给的宽摆：键盘按钮（有的话）加间距，后面是最宽 transcriptWidth 的玻璃，整组居中；返回玻璃的高。
    func layout(available: CGFloat) -> CGFloat {
        let button = showsKeyboardButton ? keyboardButton.size.width + Metrics.paneButtonGap : 0
        glassWidth = max(min(Metrics.transcriptWidth, available - button), 0)
        glassHeight = bar.height(forWidth: glassWidth)
        setNeedsLayout()
        return glassHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let button = showsKeyboardButton ? keyboardButton.size.width + Metrics.paneButtonGap : 0
        let x = (bounds.width - button - glassWidth) / 2
        let size = keyboardButton.size
        keyboardButton.frame = CGRect(x: x, y: glassHeight - size.height, width: size.width, height: size.height)
        let glass = CGRect(x: x + button, y: 0, width: glassWidth, height: glassHeight)
        if bar.frame != glass { bar.frame = glass }
    }

    /// 整条接触摸（玻璃以外的边距和底下的留白也是），同 PaneControlsBar 的 contentShape。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { bounds.contains(point) }

    // MARK: - 拉底栏、横滑

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === drag else { return super.gestureRecognizerShouldBegin(recognizer) }
        let translation = drag.translation
        if DrawerPull.isHorizontal(translation) {
            guard !typing(), !keyboardShown, let start = drag.start, let row else { return false }
            if bar.effortFrame.contains(bar.convert(start, from: nil)) || !row.shell.drawer.collapsed { return false }
            mode = .swipe
        } else {
            guard !typing() else { return false }
            mode = .pull
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func dragged(_ recognizer: ThresholdDrag) {
        guard let row, let mode else { return }
        let pull = row.shell.drawer.actionsPull, swipe = row.row.swipeActions
        switch recognizer.state {
        case .began, .changed:
            if mode == .pull { pull.changed(recognizer.translation, recognizer.velocity) } else { swipe.track(recognizer.translation.width) }
        case .ended:
            if mode == .pull { pull.ended(recognizer.velocity) } else { swipe.end(recognizer.translation.width, recognizer.predictedTranslation.width) }
            self.mode = nil
        case .cancelled, .failed:
            if mode == .pull { pull.ended(.zero) } else { swipe.cancel() }
            self.mode = nil
        default:
            break
        }
    }

    override var accessibilityElements: [Any]? {
        get { showsKeyboardButton ? [keyboardButton, bar] : [bar] }
        set {}
    }
}

/// 收起键盘：同 KeyboardDismissButton（PaneHeaderButtonGroup 里一个 ActionButton）——交互玻璃的胶囊，正文字号的图标。
private final class KeyboardGlassButton: UIView {
    private let glass: UIVisualEffectView
    private let button = UIButton(type: .custom)

    override init(frame: CGRect) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        glass = UIVisualEffectView(effect: effect)
        super.init(frame: frame)
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        glass.contentView.addSubview(button)
        button.tintColor = .label
        button.accessibilityLabel = "收起键盘"
        // 等按钮松手这次更新过去再收：同步收的话键盘让位会沿用玻璃松手的回弹
        button.addAction(UIAction { _ in Task { @MainActor in dismissKeyboard() } }, for: .primaryActionTriggered)
        updateImage()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.updateImage() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateImage() {
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        button.setImage(UIImage(systemName: KeyboardDismissButton.icon, withConfiguration: UIImage.SymbolConfiguration(font: font)), for: .normal)
    }

    /// 图标方框（正文字号缩放的 labelExtent）加按钮自带的半个间距、组两端的留白，高是标题栏按钮高。
    var size: CGSize {
        let extent = UIFontMetrics(forTextStyle: .body).scaledValue(for: InputMode.current.labelExtent, compatibleWith: traitCollection)
        return CGSize(width: extent + Metrics.paneHeaderButtonGap + 2 * Metrics.paneHeaderGroupInset, height: Metrics.paneHeaderButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = glass.contentView.bounds
    }
}
#endif
