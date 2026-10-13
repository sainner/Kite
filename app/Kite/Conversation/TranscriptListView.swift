#if os(macOS)
import AppKit
import SwiftUI

/// Mac 主对话的列表：AppKit 自己排，行是原生视图（TranscriptRowSlot），只有可见区附近的行放进列表。
/// 为什么不用 SwiftUI 的滚动视图见 .kite/memory/decision-mac-transcript-appkit.md：拖缝时整列 SwiftUI 树每帧重排，越不过 60 帧。
/// 滚动的规则同 TranscriptScroll：
/// - 打开时停在最后一条内容的底部，跟着最底下；人往上翻就不跟了，翻回最底下又跟。
/// - 内容、可见区变高变矮时：跟着最底下、底下也没露着留白，就贴着底；不然保持可见区顶上那一行不动。
/// - 发送：都滑到最底下。开启新一轮的，最后一轮至少比可见区高一个模数，不够在底下留白，滑到底时上一轮的末尾滚出顶边再多一个模数；
///   对话里只有这一轮时留白正好铺满可见区，不滚。人往上翻多少裁掉多少留白，裁到最后一条内容为止，下一次开启新一轮才重新留。
/// - 屏幕外的行空闲时补量；补量、拖缝后补排让上面的行变高变矮时，按上面的对齐保持看着的内容不动。
final class TranscriptListView: NSScrollView {
    private let document = TranscriptDocumentView()
    private var slots: [TranscriptRowSlot] = []
    private var byID: [RowID: TranscriptRowSlot] = [:]
    /// 各行上次更新时的形状签名，托管的行签名变了才换内容，见 update。
    private var shapes: [RowID: Int] = [:]
    private var context: TranscriptRowContext?
    /// 环境里会让行重画的几项：外观变了所有行都换一遍，选中的行、刚发出的消息变了托管的行换一遍。
    private var appearanceKey: AppearanceKey?
    private var hostedKey: HostedKey?
    /// 每次换行加一，发送时用它看新消息到了没有。
    private var version = 0

    /// 跟着最底下。
    private var following = true
    /// 留白被人往上翻裁掉了多少。打开时为 nil，不留白；发送并开启新一轮时从 0 开始。
    private var trim: CGFloat?
    /// 留白按多高的可见区算：变高时当场跟上，变矮时等 0.6 秒（可见区变矮时留白要等一会儿再缩，见 TranscriptScroll.visibleChanged）。
    private var heldVisible: CGFloat = 0
    private var shrinking: Task<Void, Never>?
    /// 底下的留白这会儿露在可见区里。
    private var blankShown = false
    /// 程序在改滚动位置，滚动通知不当成人在滚。
    private var adjusting = false
    /// 人在滚（含惯性）。
    private var userScrolling = false
    /// 发送后滑到最底下的那一下。
    private var glide: Glide?
    /// 发出去、等新消息排好再滑的那一下。
    private var pendingGlide: (version: Int, alongside: () -> Void, attempts: Int)?
    /// 空闲时补量屏幕外的行。
    private var measuring: Task<Void, Never>?
    private var pocketsRegistered = false
    /// 原生行的操作栏：托管的 SwiftUI 浮层，放在文档最上面，跟着行一起滚，见 placeActions。
    private var actions: (id: RowID, host: NSHostingView<AnyView>, above: Bool)?
    private var actionsRemoval: Task<Void, Never>?
    /// 有行开着操作栏时，点列表里别处（包括文本视图上）先收起它；文本视图照常接着处理这次点击。
    private var clickMonitor: Any?

    /// 屏幕外的行排在可见区上下各多远以内就建视图、跟着宽度量。
    private static let margin: CGFloat = 0.5
    /// 拖缝时只量可见区上下各四分之一屏以内的行，其余按原来的高占位，停下再补。
    private static let resizeMargin: CGFloat = 0.25

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        documentView = document
        document.list = self
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(liveScrollBegan), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 内容

    /// SwiftUI 那边每次更新都调：换上新的行和环境，insets 是标题栏、控制区让出的高。
    func update(_ rows: [TranscriptRow], context: TranscriptRowContext, insets: NSEdgeInsets) {
        self.context = context
        if contentInsets.top != insets.top || contentInsets.bottom != insets.bottom {
            contentInsets = insets
        }
        let appearance = AppearanceKey(context.environment), hosted = HostedKey(context.environment)
        let appearanceChanged = appearance != appearanceKey, hostedChanged = hosted != hostedKey
        appearanceKey = appearance
        hostedKey = hosted
        var next: [TranscriptRowSlot] = []
        var nextByID: [RowID: TranscriptRowSlot] = [:]
        for row in rows {
            var hasher = Hasher()
            row.shape(into: &hasher)
            let shape = hasher.finalize()
            let slot: TranscriptRowSlot
            if let existing = byID[row.id], transcriptRowSlotFits(existing, row) {
                slot = existing
                // 签名（记录只追加，字数就能看出变没变）或外观变了才换内容、作废量过的高；
                // 选中的行、刚发出的消息变了只换托管的行的内容，高不变
                let resized = shapes[row.id] != shape || appearanceChanged
                if resized || hostedChanged && slot is HostedRowSlot { slot.update(row, context: context, resized: resized) }
            } else {
                if let existing = byID[row.id], existing.hasView { existing.view.removeFromSuperview() }
                slot = makeTranscriptRowSlot(row)
                slot.heightChanged = { [weak self] in self?.needsLayout = true }
                slot.update(row, context: context, resized: true)
            }
            shapes[row.id] = shape
            next.append(slot)
            nextByID[row.id] = slot
        }
        for (id, slot) in byID where nextByID[id] !== slot {
            if slot.hasView { slot.view.removeFromSuperview() }
            shapes[id] = nil
        }
        slots = next
        byID = nextByID
        version += 1
        needsLayout = true
    }

    // MARK: - 排列

    override func layout() {
        super.layout()
        if !pocketsRegistered { pocketsRegistered = registerPanePockets() }
        layoutRows()
    }

    /// 可见区：滚动区去掉标题栏、控制区让出的高，文档坐标。
    private var visibleArea: CGRect {
        let bounds = contentView.bounds
        return CGRect(x: bounds.minX, y: bounds.minY + contentInsets.top,
                      width: bounds.width, height: max(bounds.height - contentInsets.top - contentInsets.bottom, 0))
    }

    /// 内容列：最宽 transcriptWidth，两边至少留 padding × 2，居中。
    private func column(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let columnWidth = max(min(width - Metrics.padding * 4, Metrics.transcriptWidth), 0)
        return (((width - columnWidth) / 2).rounded(), columnWidth)
    }

    private func layoutRows() {
        let width = contentView.bounds.width
        guard width > 0 else { return }
        let visible = visibleArea
        visibleChanged(visible.height)
        let (x, columnWidth) = column(width: width)
        let resizing = WindowLayout.anyResizing
        // 对齐：程序在滚时交给那一下；跟着最底下、没露留白时贴底；不然保持可见区顶上那一行不动
        let keepsBottom = following && !blankShown && glide == nil && pendingGlide == nil
        let anchor = keepsBottom || glide != nil ? nil : currentAnchor(in: visible)
        let near = visible.insetBy(dx: 0, dy: -visible.height * (resizing ? Self.resizeMargin : Self.margin))
        let estimate = estimatedHeight(columnWidth)
        var y = Metrics.transcriptPadding
        var lastTurnTop = Metrics.transcriptPadding
        var lastTurnStartsHuman = slots.first?.row.startsHumanTurn ?? false
        var waiting = false
        for (index, slot) in slots.enumerated() {
            if index > 0 {
                if slot.row.startsHumanTurn {
                    lastTurnTop = y
                    lastTurnStartsHuman = true
                }
                y += Metrics.rowSpacing + slot.row.gap
            }
            let old = slot.frame
            // 量：可见区附近的按眼下的宽量；远的有量过的高就先用着（宽可能是旧的），没有就估，空闲时再补
            let close = old.maxY > near.minY && old.minY < near.maxY || old == .zero && y < near.maxY && y + estimate > near.minY
            let height: CGFloat
            if let measured = slot.measured, measured.width == columnWidth || !close {
                height = measured.height
                if measured.width != columnWidth { waiting = true }
            } else if close {
                height = slot.height(width: columnWidth)
            } else {
                height = estimate
                waiting = true
            }
            slot.frame = CGRect(x: x, y: y, width: columnWidth, height: height)
            y += height
        }
        let lastBottom = y
        // 留白：最后一轮（从开启它的那条消息的上一行底边算起）至少多高
        if let trim, lastTurnStartsHuman, !slots.isEmpty {
            let only = lastTurnTop == Metrics.transcriptPadding
            let tail = max(visible.height, heldVisible) - Metrics.transcriptPadding + DotMetrics.module - trim
            let minimum = only ? tail - Metrics.transcriptPadding - DotMetrics.module : tail
            y = max(y, lastTurnTop + max(minimum, 0))
        }
        let height = max(y + Metrics.transcriptPadding, visible.height)
        adjusting = true
        if document.frame.size != CGSize(width: width, height: height) {
            document.setFrameSize(CGSize(width: width, height: height))
        }
        // 滚动位置
        if glide == nil, pendingGlide == nil {
            if keepsBottom {
                scroll(toVisibleTop: height - visible.height)
            } else if let anchor, let slot = byID[anchor.id] {
                scroll(toVisibleTop: slot.frame.minY - anchor.offset)
            } else {
                scroll(toVisibleTop: visibleArea.minY)
            }
        }
        adjusting = false
        let shown = visibleArea
        blankShown = lastBottom < shown.maxY - Metrics.transcriptPadding - 1 && trim != nil
        realize(around: shown)
        placeActions()
        if waiting { measureLater() }
        // 发出去的新消息排好了就开始滑
        if let pendingGlide, pendingGlide.version != version, glide == nil { startGlideIfReady() }
    }

    /// 可见区附近的行放进列表、摆好位置，远的拿出来。
    private func realize(around visible: CGRect) {
        let near = visible.insetBy(dx: 0, dy: -visible.height * Self.margin)
        for slot in slots {
            let shown = slot.frame.maxY > near.minY && slot.frame.minY < near.maxY
            if shown {
                let view = slot.view
                if view.superview !== document { document.addSubview(view) }
                let frame = slot.viewFrame(in: slot.frame)
                if view.frame != frame { view.frame = frame }
            } else if slot.hasView, slot.view.superview != nil {
                slot.view.removeFromSuperview()
            }
        }
    }

    /// 可见区顶上那一行和它离顶边多远，内容变高变矮后按它把看着的内容放回原处。
    private func currentAnchor(in visible: CGRect) -> (id: RowID, offset: CGFloat)? {
        guard let slot = slots.first(where: { $0.frame.maxY > visible.minY }) else { return nil }
        return (slot.id, slot.frame.minY - visible.minY)
    }

    /// 没量过的行先按量过的平均高估，一行都没量过时估 60 pt。
    private func estimatedHeight(_ width: CGFloat) -> CGFloat {
        let known = slots.compactMap { $0.measured.map(\.height) }
        guard !known.isEmpty else { return 60 }
        return known.reduce(0, +) / CGFloat(known.count)
    }

    // MARK: - 操作栏

    /// 选中了原生行就在它旁边弹出操作栏：平常在这一行底下，底下放不下（会压到控制区）就放到上面；和这一行的左边对齐。
    /// 托管的行（气泡等）的操作栏还在它们自己的 SwiftUI 视图里（MessageBubble 的 actionBar）。
    /// 收起时先让浮层播完收起动画再拿掉。
    private func placeActions() {
        guard let context else { return }
        let selected = context.environment.selectedRow.wrappedValue
        watchClicks(selected != nil)
        let slot = selected.flatMap { byID[$0] } as? ProseRowSlot
        if let actions, actions.id != slot?.id {
            // 收起：同一个浮层改成不显示，播完动画再拿掉
            let host = actions.host
            host.rootView = actionsRoot(slot: nil, side: .leading, above: actions.above, context: context)
            self.actions = nil
            actionsRemoval?.cancel()
            actionsRemoval = Task { [weak host] in
                try? await Task.sleep(for: .milliseconds(300))
                host?.removeFromSuperview()
            }
        }
        guard let slot else { return }
        let visible = visibleArea
        let room = Metrics.actionBarGap + Metrics.paneHeaderButton
        let above = slot.frame.maxY + room > visible.maxY && slot.frame.minY - room >= visible.minY
        let host: NSHostingView<AnyView>
        if let actions, actions.id == slot.id {
            host = actions.host
            if actions.above != above { host.rootView = actionsRoot(slot: slot, side: .leading, above: above, context: context) }
        } else {
            actionsRemoval?.cancel()
            host = NSHostingView(rootView: actionsRoot(slot: nil, side: .leading, above: above, context: context))
            host.sizingOptions = [.intrinsicContentSize]
            document.addSubview(host)
            // 先按收着排好一次，再换成显示：ActionBar 按 shown 的变化自己播出现的动画
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, self.actions?.host === host else { return }
                host.rootView = self.actionsRoot(slot: slot, side: .leading, above: above, context: context)
            }
        }
        actions = (slot.id, host, above)
        let size = host.fittingSize
        let y = above ? slot.frame.minY - Metrics.actionBarGap - size.height : slot.frame.maxY + Metrics.actionBarGap
        host.frame = CGRect(x: slot.frame.minX, y: y, width: size.width, height: size.height)
        if document.subviews.last !== host { document.addSubview(host, positioned: .above, relativeTo: nil) }
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

    private func actionsRoot(slot: ProseRowSlot?, side: HorizontalEdge, above: Bool, context: TranscriptRowContext) -> AnyView {
        AnyView(ActionBar(shown: slot != nil, side: side, from: above ? .bottom : .top) {
            if let slot { AgentTextActions(text: slot.source ?? "") }
        }
        .fixedSize()
        .environment(\.self, context.environment))
    }

    // MARK: - 补量

    /// 宽度停下、没有窗口在过渡、人和程序都没在滚的时候，屏幕外的行分批按眼下的宽量好，每批不超过 8 ms。
    private func measureLater() {
        guard measuring == nil else { return }
        measuring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if WindowLayout.anyTransitioning || glide != nil || userScrolling { continue }
                guard measureBatch() else {
                    measuring = nil
                    return
                }
                layoutRows()
            }
        }
    }

    /// 离可见区最近的没量准的行量一批，还有没量准的返回 true。
    private func measureBatch() -> Bool {
        let (_, columnWidth) = column(width: contentView.bounds.width)
        let visible = visibleArea
        let pending = slots.filter { $0.measured?.width != columnWidth }
            .sorted { distance($0.frame, from: visible) < distance($1.frame, from: visible) }
        guard !pending.isEmpty else { return false }
        let start = CACurrentMediaTime()
        for slot in pending {
            _ = slot.height(width: columnWidth)
            if CACurrentMediaTime() - start > 0.008 { break }
        }
        return true
    }

    private func distance(_ frame: CGRect, from visible: CGRect) -> CGFloat {
        max(visible.minY - frame.maxY, frame.minY - visible.maxY, 0)
    }

    // MARK: - 滚动

    /// 让可见区顶边对到文档里的 top，夹在能滚到的范围里。
    private func scroll(toVisibleTop top: CGFloat) {
        let visible = visibleArea
        let maxTop = max(document.frame.height - visible.height, 0)
        let origin = min(max(top, 0), maxTop) - contentInsets.top
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
        if glide != nil { glide = nil }
        if let trim, blankShown, distanceToBottom > 0.5 {
            self.trim = trim + distanceToBottom
            needsLayout = true
        }
        following = distanceToBottom <= 1
        if case .some = context?.environment.selectedRow.wrappedValue { context?.environment.selectedRow.close() }
        realize(around: visibleArea)
    }

    @objc private func liveScrollBegan() { userScrolling = true }

    @objc private func liveScrollEnded() {
        userScrolling = false
        following = distanceToBottom <= 1
    }

    /// 可见区变矮时，等它最后一次变完 0.6 秒再让留白跟上，那时已经变回去了就不缩。
    private func visibleChanged(_ height: CGFloat) {
        if height >= heldVisible {
            shrinking?.cancel()
            shrinking = nil
            heldVisible = height
        } else if shrinking == nil {
            shrinking = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
                guard let self else { return }
                heldVisible = visibleArea.height
                shrinking = nil
                needsLayout = true
            }
        }
    }

    // MARK: - 发送

    /// 发一条消息：append 把它加进对话，返回它会不会开启新的一轮；等新消息排好后滑到最底下，alongside 和滑同一个动画。
    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        following = true
        glide = nil
        let startsTurn = append()
        if startsTurn { trim = 0 }
        pendingGlide = (version, alongside, 0)
        DispatchQueue.main.async { [weak self] in self?.startGlideIfReady() }
    }

    /// 新消息到了就开始滑；SwiftUI 还没把新消息交过来时下一拍再看，最多等几拍。
    private func startGlideIfReady() {
        guard let pending = pendingGlide, glide == nil else { return }
        if pending.version == version && pending.attempts < 5 {
            pendingGlide = (pending.version, pending.alongside, pending.attempts + 1)
            DispatchQueue.main.async { [weak self] in self?.startGlideIfReady() }
            return
        }
        pendingGlide = nil
        // 先把这一下记上再排版：排版看到程序在滚就不动滚动位置，从眼下的位置起滑
        let glide = Glide(from: visibleArea.minY)
        self.glide = glide
        layoutSubtreeIfNeeded()
        withAnimation(.spring(.glide)) { pending.alongside() }
        glide.start(in: self) { [weak self] progress in self?.glideStep(progress) ?? false }
    }

    /// 滑的一帧：progress 是弹簧走到哪了；走完了返回 false。目标是这一帧的最底下，回复在长时跟着长。
    private func glideStep(_ progress: Double?) -> Bool {
        guard let glide else { return false }
        let target = max(document.frame.height - visibleArea.height, 0)
        guard let progress else {
            self.glide = nil
            following = true
            adjusting = true
            scroll(toVisibleTop: target)
            adjusting = false
            needsLayout = true
            return false
        }
        adjusting = true
        scroll(toVisibleTop: glide.from + (target - glide.from) * progress)
        adjusting = false
        realize(around: visibleArea)
        return true
    }

    // MARK: - 环境

    /// 外观：字色、装饰按它解析成颜色。
    private struct AppearanceKey: Equatable {
        let colorScheme: ColorScheme
        let font: Font?

        init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            font = environment.font
        }
    }

    /// 托管的行还读选中的行（操作栏）和刚发出的消息（上浮）。
    private struct HostedKey: Equatable {
        let selected: RowID?
        let arriving: Set<String>

        init(_ environment: EnvironmentValues) {
            selected = environment.selectedRow.wrappedValue
            arriving = environment.arrivingMessages
        }
    }
}


/// 列表的文档视图：翻转坐标，点空白处收起操作栏。
final class TranscriptDocumentView: NSView {
    weak var list: TranscriptListView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        list?.closeActions()
        super.mouseDown(with: event)
    }
}

extension TranscriptListView {
    func closeActions() {
        if context?.environment.selectedRow.wrappedValue != nil { context?.environment.selectedRow.close() }
    }
}

/// 发送后滑到最底下：弹簧和 TranscriptScroll.glide 同一条（Spring.smooth 0.5 秒），按显示刷新逐帧走。
@MainActor private final class Glide: NSObject {
    let from: CGFloat
    private var started: CFTimeInterval?
    private var link: CADisplayLink?
    private var step: ((Double?) -> Bool)?

    init(from: CGFloat) { self.from = from }

    func start(in view: NSView, step: @escaping (Double?) -> Bool) {
        self.step = step
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let started = started ?? now
        self.started = started
        let spring = Spring.glide
        let time = now - started
        let done = time >= spring.settlingDuration
        if step?(done ? nil : spring.value(target: 1.0, time: time)) != true {
            link.invalidate()
            self.link = nil
            step = nil
        }
    }
}
#endif
