#if os(iOS)
import SwiftUI
import UIKit

/// 会话里发生的事，不是谁说的话，照 EventLabel：后台任务结束的通知（铃铛）、打断（举手）、API 错误（三角，红色）。
/// 一行次要色小字带图标，长了折行；长按弹出拷贝、共享，同 Text 的 textSelection。
final class PhoneEventRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var label: PhoneIconLabel?
    private let menu = PhoneCopyMenu()
    private var content: (text: String, icon: String, color: UIColor) = ("", "bell", .secondaryLabel)
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)

    override var hasView: Bool { label != nil }

    override var view: UIView {
        if let label { return label }
        let label = PhoneIconLabel(lines: 0)
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        label.addInteraction(UIContextMenuInteraction(delegate: menu))
        self.label = label
        show()
        return label
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content else { return }
        switch item.kind {
        case .notification(let text): content = (text, "bell", .secondaryLabel)
        case .interrupted: content = ("已打断", "hand.raised", .secondaryLabel)
        case .apiError(let text): content = (text, "exclamationmark.triangle", UIColor(Theme.danger))
        default: return
        }
        font = Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as UIFont
        let text = content.text
        menu.text = { text }
        show()
    }

    private func show() {
        guard let label else { return }
        label.set(content.text, systemImage: content.icon, font: font, color: content.color)
        label.accessibilityLabel = content.text
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let label = view as! PhoneIconLabel
        let height = label.height(width: width)
        measured = (width, height)
        return height
    }

    override func layoutView(in frame: CGRect) {
        label?.setNeedsLayout()
    }

    func didPlace() {}

    func releaseView() {
        label = nil
    }
}

/// Kite 发给 agent 的消息，照原来的 SwiftUI 版：细边框圆角框，里面上面一行「Kite 发给 agent」带图标（小字），下面是正文，都是次要色；
/// 长按正文弹出拷贝、共享，同 Text 的 textSelection。
final class PhoneKiteRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var box: PhoneKiteRowView?
    private let menu = PhoneCopyMenu()
    private var text = ""
    private var fonts = (secondary: UIFont.preferredFont(forTextStyle: .subheadline), body: UIFont.preferredFont(forTextStyle: .body))
    private var rule: CGColor?

    override var hasView: Bool { box != nil }

    override var view: UIView {
        if let box { return box }
        let box = PhoneKiteRowView()
        box.body.addInteraction(UIContextMenuInteraction(delegate: menu))
        self.box = box
        show()
        return box
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .kite(let text) = item.kind else { return }
        self.text = text
        let environment = context.environment
        fonts = (Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont,
                 Theme.body.resolve(in: environment.fontResolutionContext).ctFont as UIFont)
        rule = Theme.rule.resolve(in: environment).cgColor
        menu.text = { text }
        show()
    }

    private func show() {
        guard let box else { return }
        box.title.set("Kite 发给 agent", systemImage: "arrow.triangle.merge", font: fonts.secondary, color: .secondaryLabel)
        box.body.set(text, font: fonts.body, color: .secondaryLabel)
        box.border.strokeColor = rule
        box.accessibilityLabel = "Kite 发给 agent：\(text)"
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let box = view as! PhoneKiteRowView
        let height = box.height(width: width)
        measured = (width, height)
        return height
    }

    override func layoutView(in frame: CGRect) {
        box?.setNeedsLayout()
    }

    func didPlace() {}

    func releaseView() {
        box = nil
    }
}

/// Kite 发来的消息的框：padding 12，标题行和正文之间 6，描边 Theme.rule、圆角 contentRadius（连续圆角，描边画在里面）。
final class PhoneKiteRowView: UIView {
    let title = PhoneIconLabel(lines: 1)
    let body = PhoneTextLine()
    let border = CAShapeLayer()
    private static let padding: CGFloat = 12
    private static let spacing: CGFloat = 6

    init() {
        super.init(frame: .zero)
        body.lines = 0
        layer.addSublayer(border)
        border.fillColor = nil
        border.lineWidth = 1
        addSubview(title)
        addSubview(body)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func height(width: CGFloat) -> CGFloat {
        let inner = max(width - Self.padding * 2, 0)
        return Self.padding * 2 + title.height(width: inner) + Self.spacing + body.height(width: inner)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = max(bounds.width - Self.padding * 2, 0)
        let titleHeight = title.height(width: inner)
        title.frame = CGRect(x: Self.padding, y: Self.padding, width: inner, height: titleHeight)
        let y = Self.padding + titleHeight + Self.spacing
        body.frame = CGRect(x: Self.padding, y: y, width: inner, height: body.height(width: inner))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).inset(by: 0.5).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// 压缩的分界，照 CompactedDivider：一条横线中间一行次要色小字（「之前的对话已压缩成摘要」，展开后「收起摘要」），整条可点；
/// 点开下面托管原来的摘要、显示原文和撤销压缩（CompactionDetails），和下面的行一起按 snappy 的弹簧展开，摘要跟着淡入。
/// 展开的原文自己变高时下面的行也跟着同一条弹簧走（SwiftUI 版托管在 Mac 原生列表里时下面的行会跳，用户 2026-10-13 定不照搬）。
final class PhoneCompactedRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneCompactedRowView?
    private var compaction: Compaction?
    private var children: [Item] = []
    private var context: TranscriptRowContext?
    private var expanded = false
    /// 展开的原文开没开，收起摘要再点开时还在，同 SwiftUI 版的 @State。
    private let original = CompactionOriginal()
    private var details: UIHostingController<AnyView>?
    private var headerHeight: CGFloat = 0
    private var detailsHeight: CGFloat = 0
    private static let spacing: CGFloat = 10
    private static let motion = RowMotion.spring(.snappy)

    override var hasView: Bool { container != nil }
    override var view: UIView { rowView }

    private var rowView: PhoneCompactedRowView {
        if let container { return container }
        let container = PhoneCompactedRowView()
        container.header.action = { [weak self] in self?.toggle() }
        self.container = container
        show()
        return container
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .compacted(let compaction, let children) = item.kind else { return }
        self.compaction = compaction
        self.children = children
        self.context = context
        show()
    }

    private func show() {
        guard let compaction, let context, let container else { return }
        let environment = context.environment
        container.header.show(expanded ? "收起摘要" : compaction.dividerTitle,
                              font: Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont,
                              rule: Theme.rule.resolve(in: environment).cgColor)
        details?.rootView = detailsRoot()
    }

    private func detailsRoot() -> AnyView {
        guard let compaction, let context else { return AnyView(EmptyView()) }
        let original = original
        return AnyView(HostedRowFrame {
            CompactionDetails(compaction: compaction, children: children,
                              original: Binding { original.shown } set: { original.shown = $0 })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] in self?.detailsReported($0) }
        }
        .environment(\.self, context.environment))
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let container = rowView
        headerHeight = container.header.height
        if expanded, let details {
            detailsHeight = details.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let height = headerHeight + (expanded ? Self.spacing + detailsHeight : 0)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算走到哪了，摘要那截多透明跟着它。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        container.header.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        guard let details else { return }
        let full = Self.spacing + detailsHeight
        let progress = full > 0 ? min(max((frame.height - headerHeight) / full, 0), 1) : (expanded ? 1 : 0)
        details.view.frame = CGRect(x: 0, y: headerHeight + Self.spacing, width: frame.width, height: detailsHeight)
        details.view.alpha = progress
        // 收起走完拿掉
        if !expanded, progress == 0 {
            details.willMove(toParent: nil)
            details.view.removeFromSuperview()
            details.removeFromParent()
            self.details = nil
        }
    }

    private func toggle() {
        guard let container else { return }
        context?.select(nil)
        expanded.toggle()
        if expanded, details == nil {
            let controller = UIHostingController(rootView: detailsRoot())
            controller.sizingOptions = []
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            container.addSubview(controller.view)
            controller.view.alpha = 0
            adopt(controller)
            details = controller
        }
        show()
        measured = nil
        heightChanged?(Self.motion)
    }

    /// 摘要那截自己变高变矮（显示、收起原文，原文里展开了什么）：下面的行跟着同一条弹簧走。
    private func detailsReported(_ height: CGFloat) {
        guard expanded, abs(height - detailsHeight) > 0.5, let measured else { return }
        detailsHeight = height
        self.measured = (measured.width, headerHeight + Self.spacing + height)
        heightChanged?(Self.motion)
    }

    func didPlace() {
        if let details { adopt(details) }
    }

    func releaseView() {
        details?.removeFromParent()
        details = nil
        container = nil
        // 重建时是收着的，量过的高（可能带着摘要那截）作废
        if expanded { measured = nil }
        expanded = false
    }
}

/// 压缩分界的原文开没开，托管的 SwiftUI 读它，变了跟着重画。
@MainActor @Observable final class CompactionOriginal {
    var shown = false
}

final class PhoneCompactedRowView: UIView {
    let header = PhoneDividerHeader()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 压缩分界的那一条：HStack(spacing: 10) 两边各一条 1 pt 的横线，中间的字按自己的宽居中，竖着居中。
final class PhoneDividerHeader: PhonePlainControl {
    private let title = PhoneTextLine()
    private let left = CALayer()
    private let right = CALayer()

    override init() {
        super.init()
        content.layer.addSublayer(left)
        content.layer.addSublayer(right)
        content.addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, font: UIFont, rule: CGColor) {
        title.set(text, font: font, color: .secondaryLabel)
        left.backgroundColor = rule
        right.backgroundColor = rule
        accessibilityLabel = text
        setNeedsLayout()
    }

    var height: CGFloat { title.lineHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 10
        let width = title.naturalWidth
        let side = max((bounds.width - width - spacing * 2) / 2, 0)
        title.frame = CGRect(x: side + spacing, y: 0, width: width, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = PhonePixel.round((bounds.height - 1) / 2)
        left.frame = CGRect(x: 0, y: y, width: side, height: 1)
        right.frame = CGRect(x: side + spacing * 2 + width, y: y, width: side, height: 1)
        CATransaction.commit()
    }
}
#endif
