#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// iPhone、iPad 主对话的列表：UIKit 自己排，行是原生视图（TranscriptRowSlot），只有可见区附近的行放进列表。
/// 为什么不用 SwiftUI 的滚动视图见 .kite/memory/decision-native-ui.md：iPad 拖缝时整列 SwiftUI 树每次改宽都重量一遍。
/// 不用 UICollectionView：行视图跟着数据行走（文本视图里有排版和选区，附件宿主里有展开和横滑），行高动画、发送时的滑动都由列表逐帧算，
/// 排列、留白、按住看着的内容这些规则和 Mac 共用一份（TranscriptArrangement、TranscriptFollow）。
/// 滚动的规则同 Mac 的 TranscriptListView 开头，iOS 另有：
/// - 从手指按下到惯性结束不做程序定位，停下后按位置决定跟不跟；手指按下（还没拖起来）也算，长按选字时字不会在手指下面挪。
/// - 滚动不收键盘、竖向总能回弹、点状态栏回顶；回顶只给在屏上的窗口，文本视图不参与。
/// - 标题栏底下是系统的滚动软边，底边不要。
/// 让出的距离（标题栏、控制区、键盘、左右安全区）由会话窗口外框（PhoneThreadWindowView）交进来，见 setInsets。
final class PhoneTranscriptView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = PhoneTranscriptScrollView()
    private let document = PhoneTranscriptDocumentView()
    let arrangement = TranscriptArrangement()
    let follow = TranscriptFollow()
    private var context: TranscriptRowContext?
    private var insets = EdgeInsets()

    /// 程序在改滚动位置、改让出的距离，滚动回调不当成人在滚。
    private var adjusting = false
    /// 行、环境、行高变了要重排。尺寸和让出的距离都没变、也没有要排的，layoutSubviews 直接返回：
    /// 外壳的几何效果（抽屉开合、卡片飞行）移动列表时几乎每帧都调它，尺寸并没有变（spikes/ios-native-transcript V2）。
    private var needsArrange = true
    private var arrangedSize: CGSize = .zero
    /// 原生行的操作栏：托管的 SwiftUI 浮层，放在文档最上面，跟着行一起滚，见 placeActions。
    private var actions: (id: RowID, host: UIHostingController<AnyView>, above: Bool, side: HorizontalEdge)?
    private var heightTicker: FrameTicker?
    /// 所在窗口在不在屏上：紧凑布局横滑那一行的窗口都建着。不在屏上不补量、不接点状态栏回顶。
    private var presence: PanePresence?
    private let presenceTracking = ModelTracking()
    /// 手指按着没有，见 TouchObserver。
    private var touching = false
    /// 最近一次手指按下的时刻，松开后留着：点按的动作在 TouchObserver 报了松手以后才到，见 tapped。
    private var touchDown: CFTimeInterval = 0
    /// 这次按下前跟不跟着最底下，和手指拖起来没有：轻点、长按（没进选字）松手后照旧跟，见 touched。
    private var touchFollowing = false
    private var touchDragged = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        // 照 SwiftUI 的 ScrollView：scrollDismissesKeyboard 默认的 automatic 在这里落成 none，滚动不收键盘（模拟器读过它的 UIScrollView）
        scrollView.keyboardDismissMode = .none
        scrollView.topEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.isHidden = true
        scrollView.addSubview(document)
        addSubview(scrollView)
        document.list = self
        follow.relayout = { [weak self] in self?.setNeedsArrange() }

        // 手指按着就算人在滚，见 touched
        let observer = TouchObserver { [weak self] down in self?.touched(down) }
        observer.delegate = self
        scrollView.addGestureRecognizer(observer)
        // 操作栏开着时点对话里别的地方收起；和链接、按钮的点按同时生效，落在操作栏上不算
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 内容

    /// SwiftUI 那边每次更新都调：换上新的行和环境。presence 是所在窗口在不在屏上的盒子，建好就不再换。
    func update(_ rows: [TranscriptRow], context: TranscriptRowContext, presence: PanePresence?) {
        self.context = context
        if self.presence !== presence {
            self.presence = presence
            presenceTracking.cancel()
            observePresence()
        }
        let removed = arrangement.update(rows, context: context, make: { row in
            let slot = makePhoneTranscriptRowSlot(row)
            slot.heightChanged = { [weak self, weak slot] motion in
                guard let self, let slot else { return }
                if let motion { animateHeight(of: slot, motion: motion) } else { setNeedsArrange() }
            }
            return slot
        }, fits: phoneTranscriptRowSlotFits)
        for slot in removed {
            if slot.hasView { slot.view.removeFromSuperview() }
            // 托管的附件、卡片挂在视图控制器上，行删掉时一起撤下来
            (slot as? PhoneRowSlot)?.releaseView()
        }
        if !removed.isEmpty { proxies = proxies.filter { arrangement.byID[$0.key] != nil } }
        setNeedsArrange()
    }

    /// 标题栏、控制区、键盘和左右安全区让出的距离。当场排好：键盘升降时 SwiftUI 在系统键盘的动画块里交下来，
    /// 改滚动位置、行的位置都要落在这个动画块里，才和键盘同一条曲线走（spikes/ios-native-transcript V3）。
    func setInsets(_ insets: EdgeInsets) {
        guard insets != self.insets else { return }
        self.insets = insets
        let content = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        adjusting = true
        if scrollView.contentInset != content { scrollView.contentInset = content }
        let indicator = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: insets.trailing)
        if scrollView.verticalScrollIndicatorInsets != indicator { scrollView.verticalScrollIndicatorInsets = indicator }
        adjusting = false
        guard bounds.width > 0 else { return }
        layoutRows()
    }

    private func setNeedsArrange() {
        needsArrange = true
        setNeedsLayout()
    }

    // MARK: - 排列

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.frame != bounds {
            adjusting = true
            scrollView.frame = bounds
            adjusting = false
        }
        guard needsArrange || arrangedSize != bounds.size else { return }
        layoutRows()
    }

    /// 交给共用层的几何：滚动区露出来的范围（文档坐标）、让出的距离、在不在拖缝。
    private var viewport: TranscriptViewport {
        TranscriptViewport(bounds: scrollView.bounds, insets: insets, resizing: WindowLayout.anyResizing)
    }

    /// 可见区：滚动区去掉上下让出的那两截，文档坐标。
    private var visibleArea: CGRect { viewport.visible }

    private func layoutRows() {
        needsArrange = false
        arrangedSize = bounds.size
        guard bounds.width > 0 else { return }
        let viewport = viewport
        follow.visibleChanged(viewport.visible.height)
        let layout = arrangement.arrange(viewport, follow: follow)
        // 有行高动画就逐帧走：一行展开收起（animateHeight），或生成中的话变高（见 TranscriptArrangement.arrange）
        if heightTicker == nil, !arrangement.heightAnimations.isEmpty {
            let ticker = FrameTicker()
            heightTicker = ticker
            ticker.start(in: self) { [weak self] time in self?.heightStep(time) ?? false }
        }
        let wasAdjusting = adjusting
        adjusting = true
        let size = CGSize(width: bounds.width, height: layout.documentHeight)
        if document.frame.size != size {
            document.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
        }
        switch layout.scroll {
        case .top(let top): scroll(toVisibleTop: top)
        case .current: scroll(toVisibleTop: visibleArea.minY)
        case .none: break
        }
        adjusting = wasAdjusting
        let shown = self.viewport
        follow.arranged(lastBottom: layout.lastBottom, visible: shown.visible)
        realize(shown)
        placeActions()
        if layout.waiting { measureLater() }
        // 发出去的新消息排好了就开始滑
        if let pending = follow.pendingGlide, pending.arrivals != arrangement.arrivals, follow.glide == nil { startGlideIfReady() }
    }

    /// 按共用层给的放进、藏起、拿出（见 TranscriptArrangement.placements）。新放进来的不带动画：
    /// 键盘升降时这里在系统的动画块里，不然新行会从零大小长出来。
    private func realize(_ viewport: TranscriptViewport) {
        arrangement.placements(in: viewport) { slot, placement in
            switch placement {
            case .place(let placed):
                let frame = PhonePixel.align(placed)
                let view = slot.view
                if view.superview !== document {
                    UIView.performWithoutAnimation {
                        document.insertSubview(view, at: 0)
                        view.frame = frame
                        slot.layoutView(in: CGRect(origin: .zero, size: frame.size))
                    }
                    (slot as? PhoneRowSlot)?.didPlace()
                    // 进窗口时卡片还按旧位置看的露没露出来，摆好再看一次
                    EmbeddedContainerView.synchronize(in: view)
                    return
                }
                var moved = false
                if view.isHidden { view.isHidden = false; moved = true }
                if view.frame != frame { view.frame = frame; moved = true }
                slot.layoutView(in: CGRect(origin: .zero, size: frame.size))
                if moved { EmbeddedContainerView.synchronize(in: view) }
                // 滚了、挪了：文本视图露出来的那截出了上次的视口就按新视口重排。拖缝中也要：没改容器宽的行（见 PhoneProseRowSlot.keptHeight）
                // 不会自己重排，贴底时别的行变高变矮，滚动位置跟着变，它露出来的那截就换了（只比上下，没出视口时很便宜）
                if let texts = (slot as? PhoneRowSlot)?.proseViews {
                    for text in texts { text.outerScrolled(in: scrollView) }
                } else {
                    refreshViewports(in: view)
                }
            case .hide:
                if slot.view.superview != nil, !slot.view.isHidden { slot.view.isHidden = true }
            case .remove:
                if slot.view.superview != nil { slot.view.removeFromSuperview() }
            }
        }
    }

    // MARK: - 操作栏

    /// 选中了一行就在它旁边弹出操作栏：平常在这一行底下，底下放不下（会压到控制区）就放到上面，上下都放不下就压在这一行上；
    /// 和这一行给的那一边对齐，见 TranscriptArrangement.actionBarFrame。
    /// 收起时先让浮层播完收起动画再拿掉。
    private func placeActions() {
        guard let context else { return }
        let slot = context.selected.flatMap { arrangement.byID[$0] }
        let bar = (slot as? PhoneRowSlot)?.actionBar()
        if let actions, actions.id != slot?.id || bar == nil {
            // 收起：同一个浮层改成不显示，播完动画再拿掉；换到别的行时也是，新的另开一个，同 Mac
            let host = actions.host
            host.rootView = actionsRoot(nil, side: actions.side, above: actions.above, context: context)
            self.actions = nil
            Task { [weak host] in
                try? await Task.sleep(for: .milliseconds(300))
                host?.willMove(toParent: nil)
                host?.view.removeFromSuperview()
                host?.removeFromParent()
            }
        }
        guard let slot, let bar else { return }
        let anchor = slot.actionAnchor
        let above = TranscriptArrangement.actionBarAbove(anchor: anchor, visible: visibleArea)
        let host: UIHostingController<AnyView>
        if let actions, actions.id == slot.id {
            host = actions.host
            // 内容（比如展开状态）和上下都可能变，每次排版都换一遍
            host.rootView = actionsRoot(bar.content, side: bar.side, above: above, context: context)
        } else {
            host = UIHostingController(rootView: actionsRoot(nil, side: bar.side, above: above, context: context))
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            // 挂进视图控制器的层级，菜单这类要弹出界面的按钮才找得到从哪弹
            let parent = enclosingController
            parent?.addChild(host)
            UIView.performWithoutAnimation { document.addSubview(host.view) }
            if let parent { host.didMove(toParent: parent) }
            // 先按收着排好一次，再换成显示：ActionBar 按 shown 的变化自己播出现的动画
            DispatchQueue.main.async { [weak self, weak host, weak slot] in
                guard let self, let host, let slot, self.actions?.host === host, let bar = (slot as? PhoneRowSlot)?.actionBar() else { return }
                host.rootView = self.actionsRoot(bar.content, side: bar.side, above: above, context: context)
                // 显示出来以后才有真实的宽，靠右的要按它重新对齐
                self.placeActions()
            }
        }
        actions = (slot.id, host, above, bar.side)
        let size = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let frame = TranscriptArrangement.actionBarFrame(anchor: anchor, size: size, above: above, side: bar.side, visible: visibleArea)
        if host.view.frame != frame { UIView.performWithoutAnimation { host.view.frame = frame } }
        if document.subviews.last !== host.view { document.bringSubviewToFront(host.view) }
    }

    private func actionsRoot(_ content: AnyView?, side: HorizontalEdge, above: Bool, context: TranscriptRowContext) -> AnyView {
        AnyView(ActionBar(shown: content != nil, side: side, from: above ? .bottom : .top) {
            if let content { content }
        }
        .fixedSize()
        .environment(\.self, context.environment))
    }

    private var enclosingController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        return responder as? UIViewController
    }

    @objc private func tapped() {
        guard let context, context.selected != nil else { return }
        // 按满长按的时长才松手的不算点别处：长按（正文、气泡、卡片上）开出来的操作栏，松手那一下不收起。
        // 点按没有时长上限，又和行里的长按同时认，不拦的话一松手就收了
        if CACurrentMediaTime() - touchDown >= PhoneTextInteraction.pressDuration { return }
        context.select(nil)
    }

    // MARK: - 行高动画

    /// 一行自己展开、收起：从原来的高按这一行给的走法走到新量的高，下面的行跟着挪。
    private func animateHeight(of slot: TranscriptRowSlot, motion: RowMotion) {
        arrangement.animateHeight(of: slot, motion: motion)
        setNeedsArrange()
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
    /// 窗口不在屏上时不等：补量停掉，回到屏上时重排再接着（见 observePresence）。
    private func measureLater() {
        guard presence?.onScreen != false else { return }
        arrangement.measureLater(busy: { [weak self] in
            guard let self else { return true }
            return WindowLayout.anyTransitioning || follow.glide != nil || follow.userScrolling
        }, paused: { [weak self] in self?.presence?.onScreen == false }, viewport: { [weak self] in self?.viewport },
           arrange: { [weak self] in self?.layoutRows() })
    }

    /// 所在窗口进出屏幕：只有在屏上的窗口接点状态栏回顶（同一窗口里有几个开着的滚动视图时系统一个都不滚；
    /// iPad 宽屏几个窗口都在屏上，系统按点的位置挑上面那一个）；回到屏上时接着补量。
    private func observePresence() {
        let onScreen = presenceTracking.track { presence?.onScreen ?? true } changed: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.observePresence() }
        }
        scrollView.scrollsToTop = onScreen
        if onScreen, arrangement.slots.contains(where: { $0.measured == nil || $0.provisional }) { setNeedsArrange() }
    }

    // MARK: - 滚动

    /// 让可见区顶边对到文档里的 top，夹在能滚到的范围里。
    private func scroll(toVisibleTop top: CGFloat) {
        let visible = visibleArea
        let maxTop = max(document.frame.height - visible.height, 0)
        // 人在滑时不夹：越过两端是回弹，交给滚动视图自己收
        let offset = (follow.userScrolling ? top : min(max(top, 0), maxTop)) - insets.top
        guard abs(scrollView.contentOffset.y - offset) > 0.25 else { return }
        let wasAdjusting = adjusting
        adjusting = true
        scrollView.contentOffset = CGPoint(x: 0, y: offset)
        adjusting = wasAdjusting
    }

    private var distanceToBottom: CGFloat {
        document.frame.height - visibleArea.maxY
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjusting else { return }
        // 人在滚：程序的那一下让给人；底下露着的留白，翻上去多少就裁掉多少
        var arrange = follow.scrolled(distanceToBottom: distanceToBottom)
        if let context, context.selected != nil { context.select(nil) }
        // 滑进来的行还没按眼下的宽量过（补量在人滚的时候不跑），先量再放，按住顶上那一行看着的内容不动
        arrange = arrange || arrangement.needsMeasure(in: viewport)
        if arrange { layoutRows() } else { realize(viewport) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        touchDragged = true
        follow.userBegan()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userEnded()
    }

    /// 手指按下就算人在滚，松开、惯性也停了才按停的位置定跟不跟。
    /// 按下前跟着最底下、手指没拖起来也没进选字（轻点、长按开操作栏）的，松手后照旧跟：按着的那会儿流式变长，底下没跟上不算翻上去了。
    private func touched(_ down: Bool) {
        if down {
            touching = true
            touchDown = CACurrentMediaTime()
            touchFollowing = follow.following && !follow.userScrolling
            touchDragged = false
            follow.userBegan()
        } else {
            touching = false
            // 拖动的结束和惯性由滚动视图的回调接；它们和这里谁先到不一定，等这一拍过去再看
            DispatchQueue.main.async { [weak self] in
                guard let self, !touching, !scrollView.isDragging, !scrollView.isDecelerating else { return }
                userEnded(tapped: !touchDragged && touchFollowing && !Self.selecting(in: document))
            }
        }
    }

    private func userEnded(tapped: Bool = false) {
        guard follow.userScrolling else { return }
        follow.userEnded(distanceToBottom: distanceToBottom, wasFollowing: tapped)
        setNeedsArrange()
    }

    /// 有正文在选字（PhoneTextInteraction 选字时打开文本视图的 isSelectable）。
    private static func selecting(in view: UIView) -> Bool {
        if let text = view as? PhoneProseTextView { return text.isSelectable }
        return view.subviews.contains { selecting(in: $0) }
    }

    // MARK: - 手势

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !(gestureRecognizer is TouchObserver) else { return true }
        // 点在操作栏上由它自己的按钮接
        if let host = actions?.host.view, touch.view?.isDescendant(of: host) == true { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - 发送

    /// 发一条消息：append 把它加进对话，返回它会不会开启新的一轮；等新消息排好后滑到最底下，alongside 和滑同一个动画。
    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        follow.send(append, arrivals: { arrangement.arrivals }, alongside: alongside)
        DispatchQueue.main.async { [weak self] in self?.startGlideIfReady() }
    }

    /// 新消息排进来了就开始滑（排列时也看，见 layoutRows）；还没到时下一帧再看，最多等 TranscriptFollow.arrivalWait。
    private func startGlideIfReady() {
        switch follow.glideStart(arrivals: arrangement.arrivals) {
        case .none:
            return
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.startGlideIfReady() }
        case .start(let alongside):
            // 先把这一下记上再排版：排版看到程序在滚就不动滚动位置，从眼下的位置起滑
            let glide = Glide(from: visibleArea.minY)
            follow.glide = glide
            layoutIfNeeded()
            withAnimation(.spring(.glide)) { alongside() }
            glide.start(in: self) { [weak self, weak glide] progress in
                guard let self, let glide else { return false }
                return glideStep(glide, progress)
            }
        }
    }

    /// 滑的一帧：progress 是弹簧走到哪了；走完了返回 false。目标是这一帧的最底下，回复在长时跟着长。
    private func glideStep(_ glide: Glide, _ progress: Double?) -> Bool {
        let active = follow.glide === glide
        // 刚发出去的消息跟着这一下浮上来、淡显
        arrangement.rise(glide, to: 1 - CGFloat(progress ?? 1), adopting: active)
        // 人滑了一下、或者又发了一条，滑被接过去了：滚动交出去，气泡照样浮完
        guard active else {
            realize(viewport)
            return progress != nil
        }
        let target = max(document.frame.height - visibleArea.height, 0)
        guard let progress else {
            follow.glideEnded()
            scroll(toVisibleTop: target)
            setNeedsArrange()
            return false
        }
        scroll(toVisibleTop: glide.from + (target - glide.from) * progress)
        realize(viewport)
        return true
    }

    // MARK: - 内存

    /// 收到内存警告时，离可见区远（上下三屏以外）的行放掉视图和嵌着的卡片的宿主（用户 2026-10-13 定）：滚回来时按内容重建，
    /// 展开着的工具行、压缩分界收回去，卡片里的状态（代码展开、表格横滑的位置）回到初始。量过的高留着（收回去的行除外），排列不受影响。
    @objc private func memoryWarning() {
        let visible = visibleArea
        let kept = visible.insetBy(dx: 0, dy: -visible.height * 3)
        for slot in arrangement.slots where slot.frame.maxY < kept.minY || slot.frame.minY > kept.maxY {
            guard let slot = slot as? PhoneRowSlot, slot.hasView else { continue }
            slot.view.removeFromSuperview()
            slot.releaseView()
        }
    }

    // MARK: - 读屏

    /// 读屏按行的顺序一条条读：放进列表的行用它自己的视图，屏外没建、没放的行给一个代理元素（位置是行在文档里的位置，读这一行的摘要），
    /// 读屏走到它时列表滚过去、把这一行放进来，焦点再交给它的视图：屏外没建视图的行，读屏也能一路读下去。
    fileprivate func accessibilityRows() -> [Any] {
        var elements: [Any] = []
        for slot in arrangement.slots {
            if slot.hasView, slot.view.superview === document, !slot.view.isHidden {
                elements.append(slot.view)
            } else {
                elements.append(proxy(for: slot))
            }
            // 开着的操作栏紧跟在它那一行后面读
            if let actions, actions.id == slot.id { elements.append(actions.host.view!) }
        }
        return elements
    }

    private var proxies: [RowID: RowAccessibilityElement] = [:]

    private func proxy(for slot: TranscriptRowSlot) -> RowAccessibilityElement {
        let id = slot.id
        let element = proxies[id] ?? {
            let element = RowAccessibilityElement(accessibilityContainer: document)
            element.focused = { [weak self, weak element] in
                guard let self, let element else { return }
                reveal(id, from: element)
            }
            proxies[id] = element
            return element
        }()
        // 摘要按行的签名缓存：读屏每次问一遍整列，长会话里每行重拼一遍字不划算
        var hasher = Hasher()
        slot.row.shape(into: &hasher)
        let shape = hasher.finalize()
        if element.shape != shape {
            element.shape = shape
            element.accessibilityLabel = TranscriptSpeech.summary(slot.row)
        }
        element.accessibilityFrameInContainerSpace = slot.frame
        return element
    }

    /// 读屏停到屏外的一行：滚到让它露出来（夹在能滚到的范围里），放进列表，焦点交给它的视图。
    private func reveal(_ id: RowID, from element: RowAccessibilityElement) {
        guard let slot = arrangement.byID[id] else { return }
        let visible = visibleArea
        if slot.frame.minY < visible.minY || slot.frame.maxY > visible.maxY {
            scroll(toVisibleTop: slot.frame.minY - Metrics.transcriptPadding)
            follow.userEnded(distanceToBottom: distanceToBottom)
            layoutRows()
        }
        proxies[id] = nil
        if slot.hasView, slot.view.superview === document {
            UIAccessibility.post(notification: .layoutChanged, argument: slot.view)
        }
    }
}

extension PhoneTranscriptView {
    /// 行里的文本视图看看要不要按新视口重排（见 PhoneProseTextView.outerScrolled）。找到文本视图就不往里找了。
    fileprivate func refreshViewports(in view: UIView) {
        if let text = view as? PhoneProseTextView {
            text.outerScrolled(in: scrollView)
            return
        }
        for child in view.subviews { refreshViewports(in: child) }
    }
}

/// 列表的滚动视图：从按钮（折叠、工具行的汇总行）上拖起来也照样滚。UIScrollView 默认不让 UIControl 上起手的拖动取消它的触摸，
/// 拖动就滚不起来；SwiftUI 的按钮不是 UIControl，原来没有这个问题。
/// 按下不等：默认先压住触摸约 150 毫秒看是不是要滚，行里的按钮、链接按下的样子和长按都晚一拍；关掉以后手指一落下就交给它们，
/// 动起来滚的时候照上面取消它们的触摸。
private final class PhoneTranscriptScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// 列表的文档视图：行按文档坐标摆在里面。读屏的元素由列表按行的顺序给，屏外没建的行用代理元素。
final class PhoneTranscriptDocumentView: UIView {
    weak var list: PhoneTranscriptView?

    override var accessibilityElements: [Any]? {
        get { list?.accessibilityRows() }
        set {}
    }
}

/// 屏外一行的读屏代理，读屏停到它时交给列表把这一行放进来。
private final class RowAccessibilityElement: UIAccessibilityElement {
    var focused: (() -> Void)?
    /// 摘要按哪个签名的行拼的。
    var shape: Int?

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        focused?()
    }
}

/// 只看手指按下、松开的手势：从不识别，不挡别的手势和触摸。滚动视图的回调只报拖起来以后的事，
/// 手指按下还没拖的那一段（长按选字、按着不动）也要算人在滚，不然流式回复贴底时字会在手指下面挪。
private final class TouchObserver: UIGestureRecognizer {
    private let changed: (Bool) -> Void
    private var touching = 0

    init(_ changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touching == 0 { changed(true) }
        touching += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches.count)
    }

    private func lift(_ count: Int) {
        touching = max(touching - count, 0)
        if touching == 0 {
            changed(false)
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        if touching > 0 {
            touching = 0
            changed(false)
        }
    }
}
#endif
