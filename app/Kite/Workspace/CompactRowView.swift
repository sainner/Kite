#if os(iOS)
import SwiftUI
import UIKit

/// iPhone 和窄的 iPad 紧凑布局里的一行窗口（Mac 窄窗口是 SwiftUI 的 CompactPaneStack）。窗口按底栏的顺序排成一行，铺满时只露出当前窗口；
/// 控制区横滑时整行跟着手指走（PaneRow 照旧管状态和手势的规则），松手按 WindowMotion 的曲线整段交给 Core Animation。
/// 每个窗口是一个格（CompactSlot）：正文是一个岛（PaneBody）；会话窗口在岛里只留桥（ThreadPaneBridge），外框是原生的
/// PhoneThreadWindowView，只放对话和签名。标题栏和控制区共用外壳上两个稳定的 SwiftUI 玻璃容器，换窗口时由系统过渡，
/// 会话输入框仍是保留的 ControlsBarView。只有正文跟着横滑平移，抽屉开合时标题栏和控制区仍在原生图层上补位。
/// 窗口建好就一直留着，当前窗口先建，其余的由近到远预热（PaneRow.warmUp）：新建会话窗口要把整段对话重新建一遍、排一遍、画一遍，
/// 不赶在滑动和抽屉开合的时候；手指比预热先到时，当场建出相邻的那个。
final class CompactRowView: UIView {
    private(set) var group: PaneGroup
    var groupID: String { group.id }
    unowned let shell: CompactShellView
    let row: PaneRow

    /// 各个窗口，整行平移：拖着时每挪一下只重摆这一层（StripView 自己的排版），不把整行重排一遍。
    private let strip = StripView()
    private let slideTracking = ModelTracking()
    /// 标题栏和控制区共用两个稳定的玻璃容器，抽屉的补位仍在原生图层上完成。
    private let headerShifter = PassThroughView()
    private let controlsShifter = PassThroughView()
    private let headerIsland = HostIsland()
    private let controlsIsland = HostIsland()
    private let chrome = CompactChromeState()
    private var slots: [Pane: CompactSlot] = [:]
    /// 外壳上量出来的各窗口控制区高度（别的窗口的 SwiftUI 控制区报的），窗口按它让位。
    let controls = SharedPaneControls()

    private let tracking = ModelTracking()
    private var laying = false
    private var chromeDirty = false
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
        addSubview(headerShifter)
        addSubview(controlsShifter)
        headerShifter.addSubview(headerIsland)
        controlsShifter.addSubview(controlsIsland)
        headerIsland.hitRegion = { [weak self] in
            guard let self, chrome.source != nil else { return nil }
            return CGRect(x: 0, y: shell.state.covered.top, width: bounds.width, height: chrome.headerHeight)
        }
        controlsIsland.hitRegion = { [weak self] in
            guard let self, let pane = chrome.source?.pane else { return nil }
            let height = controls.height(for: pane)
            return CGRect(x: 0, y: bounds.height - shell.state.covered.bottom - height, width: bounds.width, height: height)
        }
        installChrome()
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
        installChrome()
        for slot in slots.values { slot.install(row: self) }
        setNeedsLayout()
    }

    private func installChrome() {
        headerIsland.rootView = rooted(CompactSharedHeader(chrome: chrome, shell: shell.state))
        controlsIsland.rootView = rooted(CompactSharedControls(chrome: chrome, shell: shell.state, controls: controls))
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
        chrome.source = nil
        headerIsland.rootView = AnyView(EmptyView())
        controlsIsland.rootView = AnyView(EmptyView())
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
        for view in [strip, headerShifter, controlsShifter, headerIsland, controlsIsland] where view.bounds.size != bounds.size {
            view.bounds = CGRect(origin: .zero, size: bounds.size)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        placeStrip()

        let focusChanged = currentPane != read.focused
        let animateChrome = focusChanged && currentPane != nil && !(shell.look?.reduceMotion ?? false)
        if focusChanged { currentPane.flatMap { slots[$0]?.thread }?.controls.endTyping() }
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
        }
        if focusChanged || chromeDirty {
            chromeDirty = false
            let source = read.focused.flatMap { slots[$0]?.source }
            if animateChrome { prepareControlsTransition(to: source) }
            withAnimation(animateChrome ? .snappy : nil) { chrome.source = source }
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
        _ = chrome.headerHeight
        for pane in read.panes { _ = controls.height(for: pane) }
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
        let xs = motion.presentations(from: flight.start, duration: flight.duration).map(\.frame.minX)
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

    /// 共享标题栏和控制区给正文让位；键盘升降只更新当前露出的会话。
    private func layoutChrome(_ slot: CompactSlot, exposed: Bool, read: Read) {
        if slot.pane == read.focused, chrome.source?.pane == slot.pane,
           chrome.headerHeight > 0, slot.state.headerHeight != chrome.headerHeight {
            slot.state.headerHeight = chrome.headerHeight
        }
        guard let thread = slot.thread else { return }
        var covered = read.covered
        if read.keyboardShown, !exposed { covered.bottom = read.home }
        let headerHeight = slot.state.headerHeight ?? defaultHeaderHeight(covered.top)
        thread.compactInsets = EdgeInsets(top: covered.top + headerHeight, leading: covered.leading,
            bottom: covered.bottom + controlsHeight(thread, keyboardShown: read.keyboardShown && exposed, read: read),
            trailing: covered.trailing)
    }

    /// 会话窗口的控制区多高：玻璃按原生输入区当前的宽当场量，底下的留白同 PaneControlsBottom（键盘升起时只留 paneMargin），
    /// 不等共用控制区的 SwiftUI 量完报上来（晚一轮，键盘升降时对话的让位会落在键盘动画后面）。
    /// 还没显示过的输入区按可用宽度量自己的内容，不借当前窗口的高度，避免打字增高时连带重排屏外会话。
    private func controlsHeight(_ thread: PhoneThreadWindowView, keyboardShown: Bool, read: Read) -> CGFloat {
        let available = max(bounds.width - read.covered.leading - read.covered.trailing - 2 * Metrics.paneMargin, 0)
        let width = thread.controls.bounds.width > 0 ? thread.controls.bounds.width : min(Metrics.transcriptWidth, available)
        let safe = keyboardShown ? 0 : read.home
        return thread.controls.height(forWidth: width) + max(Metrics.paneMargin, safe) - safe
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
        window.chromeChanged = { [weak self, weak slot, weak window] in
            guard let self, let slot else { return }
            reported(window?.compactChrome, for: slot)
        }
        window.controlsResized = { [weak self] in self?.setNeedsLayout() }
        slot.thread = window
        slot.view.addSubview(window)
        window.frame = slot.view.bounds
        window.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if !slot.state.native { slot.state.native = true }
        reported(window.compactChrome, for: slot)
        slot.dotsPresence.stage = environment.dotStage
        slot.dotsPresence.track(slot.reports)
        setNeedsLayout()
    }

    private func detachThread(_ slot: CompactSlot, pane threadPane: ThreadPaneModel?) {
        guard let window = slot.thread, threadPane == nil || window.pane === threadPane else { return }
        window.dismantle()
        window.removeFromSuperview()
        slot.thread = nil
        reported(nil, for: slot)
        if slot.state.native { slot.state.native = false }
        slot.dotsPresence.track(nil)
        setNeedsLayout()
    }

    /// 换窗口时控制区的玻璃怎么过渡。两边都有控件时按 matchedGeometry 从一边形变到另一边；只有一边有时，另一边只有一块
    /// 不显示的 identity 玻璃，容器间距里没有可借的形状，matchedGeometry 会把玻璃缩成小圆球，动画末尾一下没了，所以改成原地 materialize。
    /// 系统登记每块玻璃时连同过渡一起存下，移除时按最后一次登记的算：要走的这份控制区得先带着新过渡更新一次，再换掉。
    private func prepareControlsTransition(to source: CompactPaneHeader?) {
        let materialize = (chrome.source?.hasControls ?? false) != (source?.hasControls ?? false)
        guard chrome.controlsMaterialize != materialize else { return }
        chrome.controlsMaterialize = materialize
        controlsIsland.controller.view.layoutIfNeeded()
    }

    // MARK: - 别的窗口报上来的

    /// 别的窗口报上来标题栏和控制区（CompactPaneHeaders），放进外壳上的两个岛。
    fileprivate func reported(_ header: CompactPaneHeader?, for slot: CompactSlot) {
        // 原生会话的空桥也会报 nil，不能覆盖它已经交给外壳的标题栏。
        if header == nil, let source = slot.thread?.compactChrome { slot.source = source }
        else { slot.source = header }
        if slot.pane == currentPane {
            if laying { chromeDirty = true }
            else {
                chrome.source = slot.source
            }
        }
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
            return [headerIsland, slot.view, controlsIsland]
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

    /// 一行窗口并排摆在这里，整层平移露出当前那个，自己只有一屏宽：命中按窗口的范围算，不按 bounds 截，
    /// 否则第二个起的窗口都落在 bounds 外，整页点不到也滚不动（2026-10-14 iPhone，角色的签名、初始配置）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { $0.frame.contains(point) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
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
    /// 别的窗口报上来的标题栏和控制区。
    var source: CompactPaneHeader?
    var usesDots = false

    init(pane: Pane) {
        self.pane = pane
        view.addSubview(island)
        island.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
    }

    func dismantle() {
        thread?.dismantle()
        thread = nil
        threadSlot.attach = nil
        threadSlot.detach = nil
        dotsPresence.release()
        island.hitRegion = nil
        island.rootView = AnyView(EmptyView())
        island.removeFromSuperview()
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

#endif
