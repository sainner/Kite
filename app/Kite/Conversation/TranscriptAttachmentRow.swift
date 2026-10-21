#if os(macOS)
import AppKit
import SwiftUI

/// 气泡上面的附件，原生画，照 MessageAttachmentRow：图片是缩略图（取到之前是底色上一个照片图标，悬停提示名字），
/// 高 attachmentHeight、宽按比例最多两倍高；其余文件是一张小卡片（图标、名字，左右 12，高 44，描边）。一行行排，放不下换行，每行靠右，
/// 同一行里竖着居中，间距 6。点一下取原件，用默认的 App 打开。
final class AttachmentRowView: NSView {
    private var items: [AttachmentItemView] = []

    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    func show(_ attachments: [Attachment], source: AttachmentSource?) {
        if items.count != attachments.count {
            for item in items { item.removeFromSuperview() }
            items = attachments.map { _ in AttachmentItemView() }
            for item in items { addSubview(item) }
        }
        for (item, attachment) in zip(items, attachments) { item.show(attachment, source: source) }
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

/// 一个附件：图片的缩略图（取到之前是底色、照片图标）或者文件的小卡片（描边、图标、名字）。
final class AttachmentItemView: NSView, NativeCursor {
    private let shape = CAShapeLayer()
    private let thumbnail = CALayer()
    private let icon = NSImageView()
    private let name = LineLabel()
    private var attachment: Attachment?
    private var source: AttachmentSource?
    private var fileNameWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    var nativeCursor: NSCursor? { source != nil ? .pointingHand : nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        thumbnail.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.masksToBounds = true
        thumbnail.cornerRadius = Metrics.contentRadius
        thumbnail.cornerCurve = .continuous
        layer?.addSublayer(thumbnail)
        icon.contentTintColor = .secondaryLabelColor
        icon.hideFromAccessibility()
        addSubview(icon)
        addSubview(name)
        name.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ attachment: Attachment, source: AttachmentSource?) {
        // 换了附件，或者还没取到缩略图时换了来源（刚连上、流转到了别的工作机），重新取
        let refetch = self.attachment?.id != attachment.id || (thumbnail.contents == nil && self.source != source)
        self.attachment = attachment
        self.source = source
        let body = Theme.body.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        let configuration = NSImage.SymbolConfiguration(pointSize: body.pointSize, weight: .regular)
        if attachment.isImage {
            icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            name.isHidden = true
            toolTip = attachment.name
            if refetch { showThumbnail(attachment, source: source) }
        } else {
            icon.image = NSImage(systemSymbolName: attachment.icon, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            let font = Theme.secondary.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
            name.set(attachment.name, font: font, color: .labelColor)
            name.isHidden = false
            fileNameWidth = name.exactWidth
            toolTip = nil
            thumbnail.contents = nil
            icon.isHidden = false
        }
        restyle()
        needsLayout = true
    }

    /// 缓存里有就当场放上，没有就去取，取到时还是这个附件才放。
    private func showThumbnail(_ attachment: Attachment, source: AttachmentSource?) {
        if let image = AttachmentContent.shared.cached(attachment.id) { return setThumbnail(image) }
        thumbnail.contents = nil
        icon.isHidden = false
        Task { [weak self] in
            guard let image = await AttachmentContent.shared.thumbnail(attachment, from: source), self?.attachment?.id == attachment.id else { return }
            self?.setThumbnail(image)
        }
    }

    private func setThumbnail(_ image: NSImage) {
        thumbnail.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        icon.isHidden = true
    }

    /// 点一下取原件，用默认的 App 打开。
    override func mouseUp(with event: NSEvent) {
        guard let attachment, let source, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        Task { [weak self] in
            do { NSWorkspace.shared.open(try await AttachmentContent.shared.original(attachment, from: source)) }
            catch {
                let alert = NSAlert()
                alert.messageText = "打不开附件"
                alert.informativeText = error.localizedDescription
                if let window = self?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {}

    /// 图片按比例最多两倍高；文件卡片是图标、8、名字，左右各 12，高 44。
    var size: CGSize {
        guard let attachment else { return .zero }
        if let width = attachment.width, let height = attachment.height {
            let extent = Metrics.attachmentHeight
            return CGSize(width: min(extent * CGFloat(width) / CGFloat(max(height, 1)), extent * 2), height: extent)
        }
        return CGSize(width: 12 + (icon.image?.alignmentRect.width ?? 0) + 8 + fileNameWidth + 12, height: 44)
    }

    private func restyle() {
        var fill = NSColor.clear.cgColor, stroke = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor(Theme.codeBackground).cgColor
            stroke = NSColor(Theme.rule).cgColor
        }
        if attachment?.isImage == true {
            shape.fillColor = fill
            shape.strokeColor = nil
        } else {
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
        thumbnail.frame = bounds
        if attachment?.isImage == true {
            shape.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).path(in: bounds).cgPath
        } else {
            // strokeBorder：往里缩半个线宽，圆角跟着小半个线宽
            shape.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).inset(by: 0.5).path(in: bounds).cgPath
        }
        CATransaction.commit()
        let imageSize = icon.image?.size ?? .zero
        guard let attachment else { return }
        if attachment.isImage {
            // 按图标的对齐宽度居中、取到像素，同 SwiftUI 的符号图片
            let width = icon.image?.alignmentRect.width ?? imageSize.width
            icon.frame = CGRect(x: ((bounds.width - width) / 2 * 2).rounded() / 2, y: (bounds.height - imageSize.height) / 2,
                                width: imageSize.width, height: imageSize.height)
        } else {
            let lineHeight = name.lineHeight
            icon.frame = CGRect(x: 12, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
            let x = 12 + (icon.image?.alignmentRect.width ?? 0) + 8
            name.frame = CGRect(x: x, y: (bounds.height - lineHeight) / 2, width: max(bounds.width - x - 12, 0), height: lineHeight)
        }
    }

    // MARK: - 读屏：图片读成图片，文件读名字

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { attachment?.isImage == true ? .image : .staticText }
    override func accessibilityLabel() -> String? {
        guard let attachment else { return nil }
        return attachment.isImage ? TranscriptSpeech.imageAttachment(attachment.name) : TranscriptSpeech.fileAttachment(attachment.name)
    }
}
#endif
