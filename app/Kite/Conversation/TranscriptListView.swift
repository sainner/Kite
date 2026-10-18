#if os(macOS)
import AppKit
import SwiftUI

/// Mac 主对话的列表：AppKit 自己排，行是原生视图（TranscriptRowSlot），只有可见区附近的行放进列表。
/// 为什么不用 SwiftUI 的滚动视图见 .kite/memory/decision-native-ui.md：拖缝时整列 SwiftUI 树每帧重排，越不过 60 帧。
/// 滚动的规则（两端相同，iOS 另有几条见 PhoneTranscriptView）：
/// - 打开时停在最后一条内容的底部，跟着最底下；人往上翻就不跟了，翻回最底下又跟。
/// - 内容、可见区变高变矮时：跟着最底下、底下也没露着留白，就贴着底；不然保持可见区顶上那一行不动。
/// - 发送：都滑到最底下。开启新一轮的，最后一轮至少比可见区高一个模数，不够在底下留白，滑到底时上一轮的末尾滚出顶边再多一个模数；
///   对话里只有这一轮时留白正好铺满可见区，不滚。人往上翻多少裁掉多少留白，裁到最后一条内容为止，下一次开启新一轮才重新留。
/// - 屏幕外的行空闲时补量；补量、拖缝后补排让上面的行变高变矮时，按上面的对齐保持看着的内容不动。
/// 行的仓库、排列循环、放进列表的范围、行高动画、补量在 TranscriptArrangement，跟不跟着最底下、留白、发送的状态在 TranscriptFollow，
/// 两端共用；这里是 AppKit 的那一半：滚动视图、文档视图、操作栏宿主、逐帧时钟和事件。
final class TranscriptListView: NSScrollView {
    private let document = TranscriptDocumentView()
    let arrangement = TranscriptArrangement()
    let follow = TranscriptFollow()
    private var context: TranscriptRowContext?

    /// 程序在改滚动位置，滚动通知不当成人在滚。
    private var adjusting = false
    /// 这一段滑动落在行里的横向滚动视图上、主方向竖向，由列表接过来滚，见 takeScroll。
    private var takesGesture = false
    private var scrollMonitor: Any?
    /// 滚动软边的容器在这里面找，见 registerPanePockets；不给就在整个窗口里找（Mac 窄窗口里列表托管在 SwiftUI 的窗口里）。
    weak var pocketScope: NSView?
    private(set) var pocketsRegistered = false
    /// 开着的操作栏：原生的浮层（ActionBarView），放在文档最上面，跟着行一起滚，见 placeActions。
    private var actions: (id: RowID, host: ActionBarView, above: Bool, side: HorizontalEdge)?
    private var heightTicker: FrameTicker?
    /// 操作栏里的按钮读着会话的状态（能不能取消、压缩起点这些），变了重排一次；换了一行重新看。
    private let actionsTracking = ModelTracking()
    private var trackedActions: RowID?
    /// 有行开着操作栏时，点列表里别处（包括文本视图上）先收起它；文本视图照常接着处理这次点击。
    private var clickMonitor: Any?
    /// 拖缝时把滚动条藏了，见 layoutRows。
    private var scrollerHidden = false
    /// 拖缝、拖侧栏停下后再排一次：滚动条露回来、按近似量的行补量。停下时宽度不一定再变，不会自己排。
    private var resizeEnd: Task<Void, Never>?
    /// 读屏给远处还没建视图的行的代理，按行认，见 accessibilityTranscript。
    private var proxies: [RowID: TranscriptRowProxy] = [:]

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        documentView = document
        document.list = self
        follow.relayout = { [weak self] in self?.needsLayout = true }
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(liveScrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 内容

    /// 标题栏、控制区让出的高。会话还空着、列表藏着时也要交：排版时按它记下留白按多高的可见区算（TranscriptFollow.visibleChanged），
    /// 按整窗记的话，第一条消息发出去留白多出这两截，滑过了头，等留白跟上变矮的可见区再跳回顶上。
    func setInsets(_ insets: NSEdgeInsets) {
        guard contentInsets.top != insets.top || contentInsets.bottom != insets.bottom else { return }
        // 设 insets 时滚动视图把可见区挪到顶上，这一下是程序改的，不当成人在滚：列表排过以后再交 insets 时，
        // 当成人滚的话就不跟着最底下了，停在顶上
        adjusting = true
        contentInsets = insets
        adjusting = false
        needsLayout = true
    }

    /// SwiftUI 那边每次更新都调：换上新的行和环境。
    func update(_ rows: [TranscriptRow], context: TranscriptRowContext) {
        self.context = context
        let removed = arrangement.update(rows, context: context, make: { row in
            let slot = makeTranscriptRowSlot(row)
            slot.heightChanged = { [weak self, weak slot] motion in
                guard let self, let slot else { return }
                if let motion { animateHeight(of: slot, motion: motion) } else { needsLayout = true }
            }
            return slot
        }, fits: transcriptRowSlotFits)
        for slot in removed {
            if slot.hasView { slot.view.removeFromSuperview() }
            proxies[slot.id] = nil
        }
        needsLayout = true
    }

    // MARK: - 排列

    override func layout() {
        super.layout()
        if !pocketsRegistered { pocketsRegistered = registerPanePockets(in: pocketScope) }
        layoutRows()
    }

    /// 交给共用层的几何：滚动区露出来的范围、标题栏和控制区让出的高、在不在拖缝。
    private var viewport: TranscriptViewport {
        TranscriptViewport(bounds: contentView.bounds,
                           insets: EdgeInsets(top: contentInsets.top, leading: 0, bottom: contentInsets.bottom, trailing: 0),
                           resizing: WindowLayout.anyResizing)
    }

    /// 可见区：滚动区去掉标题栏、控制区让出的高，文档坐标。
    private var visibleArea: CGRect { viewport.visible }

    private func layoutRows() {
        let width = contentView.bounds.width
        guard width > 0 else { return }
        let viewport = viewport
        follow.visibleChanged(viewport.visible.height)
        // 拖缝时藏起滚动条：每步按住看着的内容都要改滚动位置，会把它闪出来，长正文只排一截时把手的位置还是估的。
        // 用透明度藏：要不要显示由滚动视图每次 tile 时自己定，改 isHidden 会被它改回来
        if viewport.resizing != scrollerHidden {
            scrollerHidden = viewport.resizing
            verticalScroller?.alphaValue = viewport.resizing ? 0 : 1
        }
        if viewport.resizing { awaitResizeEnd() }
        let layout = arrangement.arrange(viewport, follow: follow)
        adjusting = true
        if document.frame.size != CGSize(width: width, height: layout.documentHeight) {
            document.setFrameSize(CGSize(width: width, height: layout.documentHeight))
        }
        // 滚动位置
        switch layout.scroll {
        case .top(let top): scroll(toVisibleTop: top)
        case .current: scroll(toVisibleTop: visibleArea.minY)
        case .none: break
        }
        adjusting = false
        let shown = self.viewport
        follow.arranged(lastBottom: layout.lastBottom, visible: shown.visible)
        realize(shown)
        placeActions()
        if layout.waiting { measureLater() }
        // 发出去的新消息排好了就开始滑
        if let pending = follow.pendingGlide, pending.version != arrangement.version, follow.glide == nil { startGlideIfReady() }
    }

    private func awaitResizeEnd() {
        guard resizeEnd == nil else { return }
        resizeEnd = Task { [weak self] in
            while WindowLayout.anyResizing {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            self?.resizeEnd = nil
            self?.needsLayout = true
        }
    }

    /// 按共用层给的放进、藏起、拿出（见 TranscriptArrangement.placements）。
    private func realize(_ viewport: TranscriptViewport) {
        arrangement.placements(in: viewport) { slot, placement in
            switch placement {
            case .place(let frame):
                let view = slot.view
                if view.superview !== document { document.addSubview(view) }
                if view.isHidden { view.isHidden = false }
                if view.frame != frame { view.frame = frame }
                slot.layoutView(in: CGRect(origin: .zero, size: frame.size))
            case .hide:
                if slot.view.superview != nil, !slot.view.isHidden { slot.view.isHidden = true }
            case .remove:
                if slot.view.superview != nil { slot.view.removeFromSuperview() }
            }
        }
    }

    // MARK: - 操作栏

    /// 选中了一行就在它旁边弹出操作栏（ActionBarView）：平常在这一行底下，底下放不下（会压到控制区）就放到上面，上下都放不下就压在这一行上；
    /// 和这一行给的那一边对齐，见 TranscriptArrangement.actionBarAbove、actionBarFrame。收起时先让浮层播完收起动画再拿掉。
    private func placeActions() {
        guard let context else { return }
        let selected = context.environment.selectedRow.wrappedValue
        watchClicks(selected != nil)
        let slot = selected.flatMap { arrangement.byID[$0] }
        if trackedActions != slot?.id {
            trackedActions = slot?.id
            actionsTracking.cancel()
        }
        let bar = slot.flatMap { slot in
            actionsTracking.track { (slot as? ActionBarProviding)?.actionItems() } changed: { [weak self] in self?.needsLayout = true }
        }
        if let actions, actions.id != slot?.id || bar == nil {
            // 收起：缩回角上，播完拿掉
            let host = actions.host
            self.actions = nil
            host.disappear { [weak host] in host?.removeFromSuperview() }
        }
        guard let slot, let bar else { return }
        let anchor = slot.actionAnchor
        let above = TranscriptArrangement.actionBarAbove(anchor: anchor, visible: visibleArea)
        let host: ActionBarView
        let appearing: Bool
        if let actions, actions.id == slot.id {
            host = actions.host
            appearing = false
        } else {
            host = ActionBarView()
            document.addSubview(host)
            appearing = true
        }
        // 按钮能不能按、展开状态这些每次排版都换一遍
        host.show(bar.items)
        actions = (slot.id, host, above, bar.side)
        host.frame = TranscriptArrangement.actionBarFrame(anchor: anchor, size: host.fittingSize, above: above, side: bar.side, visible: visibleArea)
        if document.subviews.last !== host { document.addSubview(host, positioned: .above, relativeTo: nil) }
        if appearing {
            host.layoutSubtreeIfNeeded()
            host.appear(side: bar.side, from: above ? .bottom : .top)
            announce(host)
        }
    }

    private func watchClicks(_ watching: Bool) {
        if watching, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === window else { return event }
                let point = convert(event.locationInWindow, from: nil)
                let inBar = actions.map { $0.host.convert($0.host.bounds, to: self).contains(point) } ?? false
                // 右键交给行自己开关；左键点到列表里操作栏以外的地方就收起
                if bounds.contains(point), !inBar, event.type == .leftMouseDown { closeActions() }
                return event
            }
        } else if !watching, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: - 行高动画

    /// 一行自己展开、收起：从原来的高按这一行给的走法走到新量的高，下面的行跟着挪。
    private func animateHeight(of slot: TranscriptRowSlot, motion: RowMotion) {
        arrangement.animateHeight(of: slot, motion: motion)
        needsLayout = true
        if heightTicker == nil {
            let ticker = FrameTicker()
            heightTicker = ticker
            ticker.start(in: self) { [weak self] time in self?.heightStep(time) ?? false }
        }
    }

    /// 行高动画的一帧，都走完了返回 false。
    private func heightStep(_ now: CFTimeInterval) -> Bool {
        _ = arrangement.stepHeights(now)
        layoutRows()
        if arrangement.heightAnimations.isEmpty { heightTicker = nil }
        return !arrangement.heightAnimations.isEmpty
    }

    // MARK: - 补量

    /// 宽度停下、没有窗口在过渡、人和程序都没在滚的时候，屏幕外的行分批按眼下的宽量好，见 TranscriptArrangement.measureLater。
    private func measureLater() {
        arrangement.measureLater(busy: { [weak self] in
            guard let self else { return true }
            return WindowLayout.anyTransitioning || follow.glide != nil || follow.userScrolling
        }, viewport: { [weak self] in self?.viewport }, arrange: { [weak self] in self?.layoutRows() })
    }

    // MARK: - 滚动

    /// 让可见区顶边对到文档里的 top，夹在能滚到的范围里。
    private func scroll(toVisibleTop top: CGFloat) {
        let visible = visibleArea
        let maxTop = max(document.frame.height - visible.height, 0)
        // 人在滑时不夹：越过两端是回弹，交给滚动视图自己收
        let origin = (follow.userScrolling ? top : min(max(top, 0), maxTop)) - contentInsets.top
        guard abs(contentView.bounds.minY - origin) > 0.25 else { return }
        let wasAdjusting = adjusting
        adjusting = true
        contentView.scroll(to: CGPoint(x: 0, y: origin))
        reflectScrolledClipView(contentView)
        adjusting = wasAdjusting
    }

    private var distanceToBottom: CGFloat {
        document.frame.height - visibleArea.maxY
    }

    @objc private func boundsChanged() {
        guard !adjusting else { return }
        // 人在滚：程序的那一下让给人；底下露着的留白，翻上去多少就裁掉多少
        if follow.scrolled(distanceToBottom: distanceToBottom) { needsLayout = true }
        if case .some = context?.environment.selectedRow.wrappedValue { context?.environment.selectedRow.close() }
        realize(viewport)
    }

    @objc private func liveScrollBegan() {
        follow.userBegan()
    }

    @objc private func liveScrollEnded() {
        follow.userEnded(distanceToBottom: distanceToBottom)
    }

    // MARK: - 行里的横向滚动

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window else { return event }
                return takeScroll(event) ? nil : event
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// 嵌块（代码、表格）里有横向的 NSScrollView，竖向的滑动它也接下、不往外传，落在块上就滚不动对话。
    /// 按一段滑动开头的主方向分流：竖向的整段连同惯性交给列表，横向的照常给块。滚轮没有分段，每一格各看各的。
    private func takeScroll(_ event: NSEvent) -> Bool {
        if event.phase.contains(.mayBegin) {
            takesGesture = false
        } else if event.phase.contains(.began) || event.phase.isEmpty && event.momentumPhase.isEmpty {
            takesGesture = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) && overInnerScroller(event)
        }
        guard takesGesture else { return false }
        scrollWheel(with: event)
        return true
    }

    /// 落点在列表里一个竖向滚不动的滚动视图上。盖在列表上面的（输入区上等你回应的卡片）不算，它们的滚动视图自己滚。
    private func overInnerScroller(_ event: NSEvent) -> Bool {
        guard let root = window?.contentView?.superview, var view = root.hitTest(event.locationInWindow),
              view.isDescendant(of: self) else { return false }
        while view !== self {
            if let scroll = view as? NSScrollView {
                return (scroll.documentView?.frame.height ?? 0) <= scroll.contentView.bounds.height + 1
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
        return false
    }

    // MARK: - 发送

    /// 发一条消息：append 把它加进对话，返回它会不会开启新的一轮；等新消息排好后滑到最底下，alongside 和滑同一个动画。
    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        follow.send(append, version: { arrangement.version }, alongside: alongside)
        DispatchQueue.main.async { [weak self] in self?.startGlideIfReady() }
    }

    /// 新消息到了就开始滑；SwiftUI 还没把新消息交过来时下一拍再看，最多等几拍。
    private func startGlideIfReady() {
        switch follow.glideStart(version: arrangement.version) {
        case .none:
            return
        case .wait:
            DispatchQueue.main.async { [weak self] in self?.startGlideIfReady() }
        case .start(let alongside):
            // 先把这一下记上再排版：排版看到程序在滚就不动滚动位置，从眼下的位置起滑
            let glide = Glide(from: visibleArea.minY)
            follow.glide = glide
            glide.rising = arrangement.slots.filter { $0.rise > 0 }.map(\.id)
            layoutSubtreeIfNeeded()
            withAnimation(.spring(.glide)) { alongside() }
            glide.start(in: self) { [weak self] progress in self?.glideStep(progress) ?? false }
        }
    }

    /// 滑的一帧：progress 是弹簧走到哪了；走完了返回 false。目标是这一帧的最底下，回复在长时跟着长。
    private func glideStep(_ progress: Double?) -> Bool {
        guard let glide = follow.glide else { return false }
        let target = max(document.frame.height - visibleArea.height, 0)
        // 刚发出去的消息跟着这一下浮上来、淡显
        for id in glide.rising { arrangement.byID[id]?.rise = 1 - CGFloat(progress ?? 1) }
        guard let progress else {
            follow.glideEnded()
            adjusting = true
            scroll(toVisibleTop: target)
            adjusting = false
            needsLayout = true
            return false
        }
        adjusting = true
        scroll(toVisibleTop: glide.from + (target - glide.from) * progress)
        adjusting = false
        realize(viewport)
        return true
    }
}


// MARK: - 读屏

extension TranscriptListView {
    /// 读屏按行的先后一条条读：建了视图的行交出视图里的元素（文本视图、按钮这些），远处还没建视图的给代理元素，读整行（TranscriptSpeech.summary），
    /// 读屏走到它时滚过去、建出视图。开着的操作栏跟在它那一行后面。
    func accessibilityTranscript() -> [Any] {
        var rows: [Any] = []
        var live = Set<RowID>()
        let bar = actions
        for slot in arrangement.slots {
            if slot.hasView, slot.view.superview === document, !slot.view.isHidden {
                rows += NSAccessibility.unignoredChildren(from: [slot.view])
            } else {
                let proxy = proxies[slot.id] ?? TranscriptRowProxy(list: self, id: slot.id)
                proxy.text = TranscriptSpeech.summary(slot.row)
                proxies[slot.id] = proxy
                live.insert(slot.id)
                rows.append(proxy)
            }
            if let bar, bar.id == slot.id { rows += NSAccessibility.unignoredChildren(from: [bar.host]) }
        }
        for id in proxies.keys where !live.contains(id) { proxies[id] = nil }
        return rows
    }

    /// 读屏走到还没建视图的行：滚到它露出来（行顶对着可见区顶边），建出视图后告诉读屏换了元素。
    func scrollRowToVisible(_ id: RowID) {
        guard let slot = arrangement.byID[id] else { return }
        let visible = visibleArea
        if slot.frame.minY >= visible.minY, slot.frame.maxY <= visible.maxY { return }
        // 当作人翻过去：不再跟着最底下
        scroll(toVisibleTop: slot.frame.minY - Metrics.transcriptPadding)
        _ = follow.scrolled(distanceToBottom: distanceToBottom)
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAccessibility.post(element: document, notification: .layoutChanged)
    }

    /// 这一行在屏幕上的位置。
    func screenFrame(of id: RowID) -> CGRect {
        guard let slot = arrangement.byID[id], let window else { return .zero }
        return window.convertToScreen(document.convert(slot.frame, to: nil))
    }

    /// 操作栏刚弹出来：开着读屏时告诉它，好让读屏移过去。
    func announce(_ host: NSView) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host else { return }
            NSAccessibility.post(element: document, notification: .layoutChanged,
                                 userInfo: [.uiElements: NSAccessibility.unignoredChildren(from: [host])])
        }
    }
}

/// 远处还没建视图的一行给读屏的代理：读整行的一句话，读屏走到它（聚焦或请它滚到可见）时列表滚过去建出视图。
/// NSAccessibilityElement 不归主线程，读屏的回调实际在主线程进来，取列表时按主线程处理。
nonisolated final class TranscriptRowProxy: NSAccessibilityElement {
    nonisolated(unsafe) private weak var list: TranscriptListView?
    let id: RowID
    nonisolated(unsafe) var text = ""

    @MainActor init(list: TranscriptListView, id: RowID) {
        self.list = list
        self.id = id
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityParent() -> Any? { list }

    override func accessibilityFrame() -> NSRect {
        let list = list
        let id = id
        return MainActor.assumeIsolated { list?.screenFrame(of: id) ?? .zero }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        scrollToVisible()
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        [NSAccessibility.Action(rawValue: "AXScrollToVisible")]
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action.rawValue == "AXScrollToVisible" else { return }
        scrollToVisible()
    }

    private func scrollToVisible() {
        let list = list
        let id = id
        MainActor.assumeIsolated { list?.scrollRowToVisible(id) }
    }
}

/// 列表的文档视图：翻转坐标，点空白处收起操作栏。读屏按行的先后交出各行，见 TranscriptListView.accessibilityTranscript。
final class TranscriptDocumentView: NSView {
    weak var list: TranscriptListView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        list?.closeActions()
        super.mouseDown(with: event)
    }

    override func accessibilityChildren() -> [Any]? {
        list?.accessibilityTranscript() ?? super.accessibilityChildren()
    }
}

extension TranscriptListView {
    func closeActions() {
        if context?.environment.selectedRow.wrappedValue != nil { context?.environment.selectedRow.close() }
    }
}
#endif
