#if os(macOS)
import AppKit
import SwiftUI

/// 人发的一条消息，原生气泡：靠右，贴着字宽（有代码段时占满）；收到了填上底色、白字，
/// 排队中只描边、跟系统文字色，两者之间 0.3 秒淡入淡出；太长的折到 messageFold 高，底下渐隐，下面一个展开、收起的按钮；
/// 附件排在气泡上面（AttachmentRowView，很少有）。正文和代码段用 SelectableText 同一套属性串，复制给打的原文。
/// 刚发出去时从下面 bubbleRise 处浮上来、淡显，跟着对话往上滑的那一下走，见 TranscriptListView.rise。
/// 代理来信也是它：靠左，agentBubble 的浅底、系统文字色，小圆角在左上；气泡上面一行是发信方的头像和名字（SenderLineView），折叠和操作同人发的。
/// Kite 的通知也是它：气泡同代理来信，里面是正文；上面一行是 NoticeHeaderView（图标、种类、箭头）。默认收着、只有这一行，
/// 点它气泡从左上角放大出来，再点缩回左上角（BubbleLayout.pop），下面的行跟着按 snappy 的弹簧动。没有输入 ID，不能当压缩的起点终点。
final class BubbleRowSlot: TranscriptRowSlot, ActionBarProviding {
    private let container = BubbleRowView()
    private let coordinator = ProseRowCoordinator()
    private let attachments = BlockAttachments()
    private(set) var message: Message?
    private(set) var queued = false
    /// 代理来信的发信方，人发的为 nil。
    private(set) var sender: Sender?
    /// Kite 的通知，别的为 nil。
    private var notice: Notice?
    /// 通知露着气泡；默认收着，点上面那一行露出来。
    private var opened = false
    /// 通知正在点开、收起：气泡按停着时的样子摆，行的高走到量的高为止。
    private var toggling = false
    /// 展开了全文。
    private(set) var expanded = false
    private var context: TranscriptRowContext?
    /// 怎么量、怎么摆，两端共用。
    private var layout = BubbleLayout()
    /// 气泡上面那一截（附件或发信方）连同间距多高。
    private var topHeight: CGFloat = 0
    private var hasBlocks = false
    /// 上次整条排过、没有一行是被行宽折下来的：贴字的宽。拖缝时能给的宽还放得下它，排出来一样，不用再排（见 height），同 iOS。
    private var unwrapped: CGFloat?

    /// 折起来时显示多高，比它高出不少（1.4 倍）才折。
    private static var foldHeight: CGFloat { Metrics.messageFold }

    override init(row: TranscriptRow) {
        super.init(row: row)
        let text = container.text
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = .zero
        text.clipsViewport = true
        // 行宽由 height(width:) 按贴字的宽设，视图跟着放窄时不再重排一次
        text.textContainer?.widthTracksTextView = false
        text.displaysLinkToolTips = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.usesFontPanel = false
        text.delegate = coordinator
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        coordinator.resized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
        container.fold.action = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
        container.toggleNotice = { [weak self] in self?.setOpened(!(self?.opened ?? false)) }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    var foldable: Bool { layout.foldable(foldHeight: Self.foldHeight) }


    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        let message: Message, queued: Bool, sender: Sender?, notice: Notice?
        switch row.content {
        case .message(let typed, let pending): (message, queued, sender, notice) = (typed, pending, nil, nil)
        case .item(let item):
            switch item.kind {
            case .agent(let letter, let from): (message, queued, sender, notice) = (letter, false, from, nil)
            case .kite(let kite): (message, queued, sender, notice) = (Message(id: "\(item.id)", text: kite.text), false, nil, kite)
            default: return
            }
        }
        let wasQueued = self.queued
        let first = self.message == nil
        self.message = message
        self.queued = queued
        self.sender = sender
        self.notice = notice
        self.context = context
        let id = row.id
        // 压缩前的原文里的消息没有操作栏（actionable 为 false），右键是文本视图自己的菜单
        let toggle: (() -> Void)? = context.actionable ? { context.toggleActions(id) } : nil
        container.text.secondaryClick = toggle
        container.bubble.secondaryClick = toggle
        container.text.setAccessibilityLabel(notice != nil ? TranscriptSpeech.noticeBody
                                             : sender.map(TranscriptSpeech.agent) ?? TranscriptSpeech.message(queued: queued))
        container.text.setAccessibilityCustomActions(toggle.map { toggle in
            [NSAccessibilityCustomAction(name: TranscriptSpeech.actions) { toggle(); return true }]
        })
        layout.contentChanged()
        let environment = context.environment
        let body = Theme.body.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let code = Theme.code.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        // 已接收的实色气泡恒用白字；排队中的透明描边气泡、代理来信和通知的浅底气泡跟随系统文字色
        let content = SelectableText.content(message, user: !letter, color: queued || letter ? .labelColor : .white,
                                             body: body, code: code, attachments: attachments)
        hasBlocks = !content.blocks.isEmpty
        container.text.source = content.source
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(environment))
        coordinator.show(content.text)
        container.style(queued: queued, agent: letter, animated: !first && wasQueued != queued, environment: environment)
        container.setAttachments(message.attachments)
        container.setSender(sender, environment: environment)
        container.setNotice(notice, expanded: opened, environment: environment)
        if first { container.bubble.isHidden = notice != nil && !opened }
    }

    /// 靠左、浅底的来信：代理来信、Kite 的通知。
    private var letter: Bool { sender != nil || notice != nil }

    /// 量正文见 BubbleLayout：拖缝和吸附中按近似量，记作 provisional，停下后按精确的重量。
    /// 拖缝中没折行的短消息（大多数）能给的宽还放得下就不再排：贴字的宽和高本来就不随能给的宽变，量准过的也还是准的。
    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        // 收着的通知只有那一行，正文不排
        if notice != nil, !opened {
            provisional = false
            topHeight = container.topHeight(width: width)
            let height = container.header?.height ?? 0
            measured = (width, height)
            return height
        }
        if resizing, let unwrapped, let measured, unwrapped <= width - Metrics.bubblePadding.width * 2 {
            self.measured = (width, measured.height)
            return measured.height
        }
        guard let storage = container.text.textStorage else { return 0 }
        provisional = layout.measure(container.text, storage: storage, width: width, hasBlocks: hasBlocks,
                                     resizing: resizing, expanded: expanded, foldHeight: Self.foldHeight)
        // 折着、拖缝中只排了露出来那截的长消息不算：底下没排的可能折了行
        let whole = !(provisional && foldable && !expanded)
        unwrapped = !hasBlocks && message?.attachments.isEmpty == true && whole && !container.text.softWraps ? layout.textWidth : nil
        topHeight = container.topHeight(width: width)
        let height = topHeight + bubbleHeight(expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 气泡多高：折起来的正文，加上能折时的按钮。
    private func bubbleHeight(expanded: Bool) -> CGFloat {
        layout.bubbleHeight(expanded: expanded, foldHeight: Self.foldHeight, button: container.fold.height)
    }

    override func viewFrame(in column: CGRect) -> CGRect { column }

    /// 摆好气泡里的东西：行的高可能正在展开、收起的动画里（比量的矮或高），正文按它截。
    /// 通知点开、收起的途中气泡按停着时的样子摆（缩放、淡入淡出是图层动画），箭头按行的高走到哪了转。
    override func layoutView(in frame: CGRect) {
        var size = frame.size
        if notice != nil {
            let header = container.header?.height ?? 0
            let full = topHeight + bubbleHeight(expanded: expanded)
            var turn: CGFloat = opened ? 1 : 0
            if toggling {
                turn = full > header ? min(max((frame.height - header) / (full - header), 0), 1) : turn
                size.height = full
                if let measured, abs(frame.height - measured.height) < 0.01 { toggling = false }
            }
            container.header?.turn = turn
        }
        let frames = layout.frames(row: size, top: topHeight, button: foldable ? container.fold.height : 0, leading: letter)
        container.place(frames, topHeight: topHeight, foldable: foldable, expanded: expanded)
    }

    /// 浮上来的过程：1 在下面藏着，0 到位。浮的过程中正文不能选字。
    override var rise: CGFloat {
        didSet {
            container.alphaValue = 1 - rise
            container.text.isSelectable = rise == 0
        }
    }

    /// 气泡内容在这一行里占的范围（上面那一截连同气泡），操作栏和它靠着的那边对齐。
    override var actionAnchor: CGRect {
        layout.anchor(in: frame, topWidth: container.topWidth, leading: letter)
    }

    /// 消息的操作栏，和气泡靠着的那边对齐，同 MessageActionButtons：排队中的是重试发送（发送失败时）、编辑、取消发送；收到了的是压缩起点和终点。
    /// 都有复制，折起来的还有展开全文；Kite 的通知没有压缩。点了先收起操作栏，再在 snappy 动画里做这件事。读着会话的状态，变了列表重排（见 TranscriptListView.placeActions）。
    func actionItems() -> (side: HorizontalEdge, items: [ActionItem])? {
        guard let message, let context, context.actionable, let thread = context.environment[WorkThread.self] else { return nil }
        let selection = context.environment.selectedRow
        let toast = context.environment.toast
        func done(_ body: @escaping () -> Void) -> @MainActor () -> Void {
            { selection.close(); withAnimation(.snappy, body) }
        }
        var items: [ActionItem] = []
        if queued {
            if thread.failed.contains(message.id) {
                items.append(ActionItem(title: "重试发送", icon: "arrow.clockwise", enabled: thread.connected, perform: done { thread.retry(message) }))
            }
            items.append(ActionItem(title: "编辑", icon: "pencil", enabled: thread.canCancel, perform: done { thread.cancel(message, editing: true) }))
            items.append(ActionItem(title: "取消发送", icon: "xmark", destructive: true, enabled: thread.canCancel,
                                    perform: done { thread.cancel(message) }))
        }
        items.append(ActionItem(title: "复制", icon: "doc.on.doc") {
            copyToPasteboard(message.typed, toast: toast)
            done {}()
        })
        if !queued, notice == nil {
            if thread.compactionStart == nil {
                items.append(ActionItem(title: "从这里开始压缩", icon: "arrow.down.to.line", enabled: thread.canCompact) {
                    done { thread.compactionStart = message.id }()
                    toast?.show("已选起点，在这条或之后的消息上选「压缩到这里」", systemImage: "arrow.down.to.line")
                })
            } else {
                items.append(ActionItem(title: "压缩到这里", icon: "rectangle.compress.vertical", enabled: thread.canCompact,
                                        perform: done { thread.compact(through: message.id) }))
                items.append(ActionItem(title: "取消压缩起点", icon: "xmark", perform: done { thread.compactionStart = nil }))
            }
        }
        if foldable {
            let expanded = expanded
            items.append(ActionItem(title: expanded ? "收起" : "展开全文",
                                    icon: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                    perform: done { [weak self] in self?.setExpanded(!expanded) }))
        }
        return (letter ? .leading : .trailing, items)
    }

    /// 展开、收起：气泡和下面的行一起按 snappy 的弹簧动，见 TranscriptListView 的行高动画。
    func setExpanded(_ expanded: Bool) {
        guard expanded != self.expanded, foldable else { return }
        self.expanded = expanded
        if let measured { self.measured = (measured.width, topHeight + bubbleHeight(expanded: expanded)) }
        container.fold.expanded = expanded
        heightChanged?(.spring(.snappy))
    }

    /// 通知点开、收起：气泡从左上角放大出来、缩回去，下面的行跟着按 snappy 的弹簧动。收起时开着的操作栏一起收起，缩回去以后藏起气泡。
    private func setOpened(_ opened: Bool) {
        guard notice != nil, opened != self.opened else { return }
        self.opened = opened
        container.header?.expanded = opened
        if !opened, let selection = context?.environment.selectedRow, selection.wrappedValue == row.id { selection.close() }
        toggling = true
        measured = nil
        heightChanged?(.spring(.snappy))
        guard let layer = container.bubble.layer else { return }
        if opened { container.bubble.isHidden = false }
        BubbleLayout.pop(layer, shown: opened) { [weak self] in
            if self?.opened == false { self?.container.bubble.isHidden = true }
        }
    }
}

/// 气泡这一行的视图：上面的附件、发信方或通知那一行，气泡（底色、描边、截住的正文、展开按钮）。翻转坐标。
final class BubbleRowView: NSView {
    let bubble = BubbleView()
    let text = ProseTextView.make()
    let fold = BubbleFoldButton()
    /// Kite 通知的那一行，别的为 nil。
    private(set) var header: NoticeHeaderView?
    /// 点了通知那一行。
    var toggleNotice: (() -> Void)?
    /// 正文按折起来的高截住，底下渐隐。
    private let clip = FlippedLayerView()
    private let fade = CAGradientLayer()
    private var attachments: AttachmentRowView?
    private var sender: SenderLineView?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(bubble)
        bubble.addSubview(clip)
        clip.addSubview(text)
        bubble.addSubview(fold)
        clip.layer?.masksToBounds = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        clip.layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, agent: Bool, animated: Bool, environment: EnvironmentValues) {
        bubble.style(queued: queued, agent: agent, animated: animated, environment: environment)
        let color: NSColor = queued || agent ? .labelColor : .white
        fold.style(color: color, font: Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont)
    }

    func setAttachments(_ list: [Attachment]) {
        if list.isEmpty {
            attachments?.removeFromSuperview()
            attachments = nil
            return
        }
        let row = attachments ?? {
            let row = AttachmentRowView()
            addSubview(row)
            attachments = row
            return row
        }()
        row.show(list)
    }

    /// 代理来信上面的头像和名字，人发的为 nil 时拿掉。
    func setSender(_ sender: Sender?, environment: EnvironmentValues) {
        guard let sender else {
            self.sender?.removeFromSuperview()
            self.sender = nil
            return
        }
        let line = self.sender ?? {
            let line = SenderLineView()
            addSubview(line)
            self.sender = line
            return line
        }()
        line.show(sender, environment: environment)
    }

    /// Kite 通知的那一行（Kite 的图标、那一句、箭头），别的为 nil 时拿掉。
    func setNotice(_ notice: Notice?, expanded: Bool, environment: EnvironmentValues) {
        guard let notice else {
            header?.removeFromSuperview()
            header = nil
            return
        }
        let header = self.header ?? {
            let header = NoticeHeaderView()
            header.action = { [weak self] in self?.toggleNotice?() }
            addSubview(header)
            self.header = header
            return header
        }()
        header.show(notice, font: Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont, environment: environment)
        header.expanded = expanded
    }

    /// 气泡上面那一截（附件那一行、发信方那一行、通知那一行）连同和气泡之间的间距多高，都没有为 0。
    func topHeight(width: CGFloat) -> CGFloat {
        if let header { return header.height + SenderLineView.gap }
        if let sender { return sender.height + SenderLineView.gap }
        guard let attachments else { return 0 }
        return ceil(attachments.size(width: width).height) + 6
    }

    var topWidth: CGFloat { header?.width ?? sender?.width ?? attachments?.frame.width ?? 0 }

    /// 按 BubbleLayout 给的框摆：上面那一截、气泡、截住正文的那层（底下渐隐）、正文、折叠按钮。
    func place(_ frames: BubbleLayout.Frames, topHeight: CGFloat, foldable: Bool, expanded: Bool) {
        if let attachments {
            let size = attachments.size(width: bounds.width)
            attachments.frame = CGRect(x: bounds.width - size.width, y: 0, width: size.width, height: topHeight - 6)
        }
        sender?.frame = CGRect(x: 0, y: 0, width: min(sender?.width ?? 0, bounds.width), height: sender?.height ?? 0)
        header?.frame = CGRect(x: 0, y: 0, width: min(header?.width ?? 0, bounds.width), height: header?.height ?? 0)
        if bubble.frame != frames.bubble { bubble.frame = frames.bubble }
        clip.frame = CGRect(x: 0, y: 0, width: frames.bubble.width, height: frames.shown)
        if text.frame != frames.text { text.frame = frames.text }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        fade.locations = [0, NSNumber(value: frames.fadeStart), 1]
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(1 - frames.faded).cgColor]
        CATransaction.commit()
        fold.isHidden = !foldable
        fold.expanded = expanded
        fold.frame = frames.fold
    }
}

/// 气泡：底色（收到了）和描边（排队中）按气泡的形状画，里面的正文、按钮按形状截。右键开操作栏。代理来信换底色和形状。
final class BubbleView: NSView {
    var secondaryClick: (() -> Void)?
    private let fill = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let shape = CAShapeLayer()
    private var agent = false
    private var form: UnevenRoundedRectangle { agent ? Theme.agentBubbleShape : Theme.bubbleShape }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(fill)
        layer?.addSublayer(stroke)
        stroke.fillColor = nil
        stroke.lineWidth = 1
        layer?.mask = shape
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, agent: Bool, animated: Bool, environment: EnvironmentValues) {
        if agent != self.agent {
            self.agent = agent
            needsLayout = true
        }
        fill.fillColor = (agent ? Theme.agentBubble : Theme.bubble).resolve(in: environment).cgColor
        stroke.strokeColor = Theme.bubbleStroke.resolve(in: environment).cgColor
        // 排队中到收到，底色填进来
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        fill.opacity = queued ? 0 : 1
        stroke.opacity = queued ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 翻转坐标的视图，图层坐标也是左上为原点（实测），路径按视图坐标直接用
        let cgPath = form.path(in: bounds).cgPath
        for layer in [fill, shape] {
            layer.frame = bounds
            layer.path = cgPath
        }
        stroke.frame = bounds
        stroke.path = form.path(in: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        CATransaction.commit()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let secondaryClick { secondaryClick() } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if let secondaryClick, event.modifierFlags.contains(.control) { secondaryClick() } else { super.mouseDown(with: event) }
    }
}

/// 代理来信上面那一行：发信方的头像（不动的一帧，见 AgentAvatar.still）、间距 6、名字（次要色小字，放不下截掉），竖着居中。
final class SenderLineView: NSView {
    /// 和下面的气泡之间。
    static let gap: CGFloat = 8
    private let avatar = CALayer()
    private let name = LineLabel()
    private var diameter: CGFloat = 18
    private var shown: (sender: Sender, environment: EnvironmentValues)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(avatar)
        addSubview(name)
        // 读屏由正文前面的说明读发信方（TranscriptSpeech.agent）
        setAccessibilityElement(false)
        name.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ sender: Sender, environment: EnvironmentValues) {
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        diameter = AgentAvatar.inlineDiameter(font: font.pointSize)
        name.set(sender.name, font: font, color: .secondaryLabelColor)
        shown = (sender, environment)
        drawAvatar()
        needsLayout = true
    }

    private func drawAvatar() {
        guard let shown else { return }
        let scale = window?.backingScaleFactor ?? 2
        let instance = shown.sender.instance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatar.contentsScale = scale
        avatar.contents = AgentAvatar.still(design: AgentAvatar.design(for: instance, environment: shown.environment), instance: instance,
                                            diameter: diameter, scale: scale, environment: shown.environment)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawAvatar()
    }

    var height: CGFloat { max(diameter, name.lineHeight) }
    var width: CGFloat { diameter + 6 + name.textWidth }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatar.frame = CGRect(x: 0, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        CATransaction.commit()
        let x = diameter + 6
        name.frame = CGRect(x: x, y: (bounds.height - name.lineHeight) / 2, width: max(bounds.width - x, 0), height: name.lineHeight)
    }
}

/// 折起来的气泡下面的按钮：「展开全文」「收起」连同箭头，居中，跟着气泡的宽。
final class BubbleFoldButton: NativeButton {
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            label.stringValue = expanded ? "收起" : "展开全文"
            chevron.image = Self.symbol(expanded ? "chevron.up" : "chevron.down", font: label.font)
            needsLayout = true
        }
    }
    private let label = NSTextField(labelWithString: "展开全文")
    private let chevron = NSImageView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(label)
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(color: NSColor, font: NSFont) {
        label.font = font
        label.textColor = color
        chevron.image = Self.symbol(expanded ? "chevron.up" : "chevron.down", font: font)
        chevron.contentTintColor = color
        needsLayout = true
    }

    /// 上下边距加一行字。
    var height: CGFloat {
        ceil(label.intrinsicContentSize.height) + Metrics.bubblePadding.height * 2
    }

    private static func symbol(_ name: String, font: NSFont?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font?.pointSize ?? 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    override func layout() {
        super.layout()
        // 按字本身的宽居中：NSTextField 的固有宽度两边各多出单元格的边距（约 2 pt），按它排字会偏
        let labelSize = label.intrinsicContentSize
        let inset = (labelSize.width - textWidth) / 2
        let imageSize = chevron.image?.size ?? .zero
        // 字和箭头之间：SwiftUI 的 HStack(spacing: 6) 排符号图片时两边比 NSImage 的尺寸多留约 1 pt，逐像素对过取 8
        let spacing: CGFloat = 8
        let width = textWidth + spacing + imageSize.width
        let scale = window?.backingScaleFactor ?? 2
        let x = ((bounds.width - width) / 2 * scale).rounded() / scale
        label.frame = CGRect(x: x - inset, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        chevron.frame = CGRect(x: x + textWidth + spacing, y: (bounds.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height)
    }

    private var textWidth: CGFloat {
        label.attributedStringValue.size().width
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityLabel() -> String? { TranscriptSpeech.fold(expanded: expanded) }
    override func accessibilityChildren() -> [Any]? { [] }
}

#endif
