#if os(macOS)
import AppKit
import SwiftUI

/// 气泡上面的附件，原生画，照 MessageAttachmentRow：图片是缩略图（假数据没有图片本身，按尺寸画个框，中间一个照片图标，悬停提示名字），
/// 高 attachmentHeight、宽按比例最多两倍高；其余文件是一张小卡片（图标、名字，左右 12，高 44，描边）。一行行排，放不下换行，每行靠右，
/// 同一行里竖着居中，间距 6。
final class AttachmentRowView: NSView {
    private var items: [AttachmentItemView] = []

    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    func show(_ attachments: [Attachment]) {
        if items.count != attachments.count {
            for item in items { item.removeFromSuperview() }
            items = attachments.map { _ in AttachmentItemView() }
            for item in items { addSubview(item) }
        }
        for (item, attachment) in zip(items, attachments) { item.show(attachment) }
        needsLayout = true
    }

    /// 按给的宽排成几行：每行的下标、宽、高。
    private func rows(width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, item) in items.enumerated() {
            let size = item.size
            if let last = rows.indices.last, rows[last].width + Self.spacing + size.width <= width {
                rows[last].indices.append(index)
                rows[last].width += Self.spacing + size.width
                rows[last].height = max(rows[last].height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }

    /// 在 width 宽里排出来多大。
    func size(width: CGFloat) -> CGSize {
        let rows = rows(width: width)
        let height = rows.map(\.height).reduce(0, +) + Self.spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows(width: bounds.width) {
            var x = bounds.width - row.width
            for index in row.indices {
                let size = items[index].size
                items[index].frame = CGRect(x: x, y: y + (row.height - size.height) / 2, width: size.width, height: size.height)
                x += size.width + Self.spacing
            }
            y += row.height + Self.spacing
        }
    }
}

/// 一个附件：图片的框（底色、照片图标）或者文件的小卡片（描边、图标、名字）。
final class AttachmentItemView: NSView {
    private let shape = CAShapeLayer()
    private let icon = NSImageView()
    private let name = LineLabel()
    private var attachment: Attachment?
    private var fileNameWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        icon.contentTintColor = .secondaryLabelColor
        icon.hideFromAccessibility()
        addSubview(icon)
        addSubview(name)
        name.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ attachment: Attachment) {
        self.attachment = attachment
        let body = Theme.body.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        let configuration = NSImage.SymbolConfiguration(pointSize: body.pointSize, weight: .regular)
        switch attachment {
        case .image(let title, _, _):
            icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            name.isHidden = true
            toolTip = title
        case .file(let title):
            icon.image = NSImage(systemSymbolName: Self.icon(title), accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            let font = Theme.secondary.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
            name.set(title, font: font, color: .labelColor)
            name.isHidden = false
            fileNameWidth = name.exactWidth
            toolTip = nil
        }
        restyle()
        needsLayout = true
    }

    /// 图片按比例最多两倍高；文件卡片是图标、8、名字，左右各 12，高 44。
    var size: CGSize {
        switch attachment {
        case .image(_, let width, let height):
            let extent = Metrics.attachmentHeight
            return CGSize(width: min(extent * CGFloat(width) / CGFloat(max(height, 1)), extent * 2), height: extent)
        case .file:
            return CGSize(width: 12 + (icon.image?.alignmentRect.width ?? 0) + 8 + fileNameWidth + 12, height: 44)
        case nil:
            return .zero
        }
    }

    private func restyle() {
        var fill = NSColor.clear.cgColor, stroke = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor(Theme.codeBackground).cgColor
            stroke = NSColor(Theme.rule).cgColor
        }
        switch attachment {
        case .image:
            shape.fillColor = fill
            shape.strokeColor = nil
        default:
            shape.fillColor = nil
            shape.strokeColor = stroke
            shape.lineWidth = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        if case .image = attachment {
            shape.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).path(in: bounds).cgPath
        } else {
            // strokeBorder：往里缩半个线宽，圆角跟着小半个线宽
            shape.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).inset(by: 0.5).path(in: bounds).cgPath
        }
        CATransaction.commit()
        let imageSize = icon.image?.size ?? .zero
        switch attachment {
        case .image:
            // 按图标的对齐宽度居中、取到像素，同 SwiftUI 的符号图片
            let width = icon.image?.alignmentRect.width ?? imageSize.width
            icon.frame = CGRect(x: ((bounds.width - width) / 2 * 2).rounded() / 2, y: (bounds.height - imageSize.height) / 2,
                                width: imageSize.width, height: imageSize.height)
        case .file:
            let lineHeight = name.lineHeight
            icon.frame = CGRect(x: 12, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
            let x = 12 + (icon.image?.alignmentRect.width ?? 0) + 8
            name.frame = CGRect(x: x, y: (bounds.height - lineHeight) / 2, width: max(bounds.width - x - 12, 0), height: lineHeight)
        case nil:
            break
        }
    }

    private static func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "xlsx", "xls", "numbers": "tablecells"
        case "zip": "doc.zipper"
        default: "doc"
        }
    }

    // MARK: - 读屏：图片读成图片，文件读名字

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? {
        if case .image = attachment { return .image }
        return .staticText
    }
    override func accessibilityLabel() -> String? {
        switch attachment {
        case .image(let name, _, _): TranscriptSpeech.imageAttachment(name)
        case .file(let name): TranscriptSpeech.fileAttachment(name)
        case nil: nil
        }
    }
}
#endif
