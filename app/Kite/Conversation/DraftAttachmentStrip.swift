import SwiftUI

/// 输入框上面待发的附件：图片是缩略图，其余文件是一张小卡片，一个挨一个靠左排，放不下换行。右上角的叉拿掉它；
/// 传的途中盖一层半透明、中间是进度，传不上去的标出来，点一下重传。圆角和玻璃同心（ComposerLayout.fieldFillRadius）。
/// 两端原生输入区（MacControlsBar、PhoneControlsBar）经 ComposerStripHost 托管它，Mac 窄窗口的 ThreadControls 直接放。
struct DraftAttachmentStrip: View {
    let thread: WorkThread

    var body: some View {
        AttachmentFlow(spacing: 6, trailing: false) {
            ForEach(thread.draftAttachments) { item in
                DraftAttachmentItem(item: item) { thread.removeAttachment(item) }
            }
        }
    }
}

private struct DraftAttachmentItem: View {
    let item: DraftAttachment
    let remove: () -> Void

    /// 缩略图的高；比气泡上的矮，输入区不至于一下子长得太高。
    static let imageHeight: CGFloat = 56

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ComposerLayout.fieldFillRadius, style: .continuous)
        content(shape)
            .overlay { status(shape) }
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 18))
                }
                .buttonStyle(.pointingPlain)
                .padding(4)
                .accessibilityLabel("移除附件")
            }
            .contentShape(shape)
            .onTapGesture { item.retry() }
            .help(item.error.map { "上传失败，点一下重试：\($0)" } ?? item.name)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.isImage ? TranscriptSpeech.imageAttachment(item.name) : TranscriptSpeech.fileAttachment(item.name))
    }

    @ViewBuilder private func content(_ shape: RoundedRectangle) -> some View {
        if item.isImage {
            let size = item.preview?.size ?? CGSize(width: 1, height: 1)
            let width = min(max(Self.imageHeight * size.width / max(size.height, 1), Self.imageHeight), Self.imageHeight * 2)
            AttachmentFace(image: item.preview)
                .frame(width: width, height: Self.imageHeight)
                .clipShape(shape)
        } else {
            HStack(spacing: 8) {
                Image(systemName: Attachment.icon(forName: item.name)).foregroundStyle(.secondary)
                Text(item.name).font(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            // 右边给叉留出地方
            .padding(.leading, 12)
            .padding(.trailing, 28)
            .frame(maxWidth: 220, alignment: .leading)
            .frame(height: 44)
            .overlay(shape.strokeBorder(Theme.rule))
        }
    }

    @ViewBuilder private func status(_ shape: RoundedRectangle) -> some View {
        if item.error != nil {
            shape.fill(.black.opacity(0.35))
                .overlay { Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.white).font(.system(size: 18, weight: .semibold)) }
        } else if item.uploading {
            shape.fill(.black.opacity(0.25))
                .overlay { ProgressView(value: item.progress).progressViewStyle(.circular).controlSize(.small).tint(.white) }
        }
    }
}

/// 两端原生输入区托管输入框上面的一行（待发附件、skill 候选）：换了会话、外观或字号重建，列的几项变了作废量出的高。
/// 高要量的那一行自己变了大小（退回来的缩略图取到了）也重新量，经 resized 让输入区重排。没有内容时藏着。
@MainActor final class ComposerStripHost {
    #if os(macOS)
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    #else
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    #endif
    var resized: () -> Void = {}
    /// 固定的高，不用量；为空时按宽量。
    private let fixedHeight: CGFloat?
    /// 现在放的是哪个会话、什么外观的；换了重建。
    private var owner: (thread: ObjectIdentifier, scheme: ColorScheme?, typeSize: DynamicTypeSize?)?
    /// 现在列着哪几项；变了重新量。
    private var items: [String] = []
    /// 按宽量出的高，换了一批或它自己报了新大小时作废。
    private var size: (width: CGFloat, height: CGFloat)?

    var view: PlatformView { host.view }

    init(height: CGFloat? = nil) {
        fixedHeight = height
        host.sizingOptions = []
        host.view.isHidden = true
        #if os(iOS)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        #endif
    }

    /// 按 thread 摆这一行，items 是列着的几项；content 只在换了会话、外观或字号时现做。
    func show(_ thread: WorkThread, items: [String], environment: EnvironmentValues?, content: () -> some View) {
        let owner = (thread: ObjectIdentifier(thread), scheme: environment?.colorScheme, typeSize: environment?.dynamicTypeSize)
        if self.owner?.thread != owner.thread || self.owner?.scheme != owner.scheme || self.owner?.typeSize != owner.typeSize {
            self.owner = owner
            size = nil
            let row = content().frame(maxWidth: .infinity, alignment: .leading)
            let environment = environment ?? EnvironmentValues()
            host.rootView = fixedHeight != nil ? AnyView(row.environment(\.self, environment)) : AnyView(row
                // 只看高：宽由输入区摆，拖缝改宽时不用每帧多排一次；量出的高本来就按宽缓存
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] _ in
                    self?.size = nil
                    self?.resized()
                }
                .environment(\.self, environment))
        }
        if items != self.items {
            self.items = items
            size = nil
        }
        if host.view.isHidden != items.isEmpty { host.view.isHidden = items.isEmpty }
    }

    /// 输入区宽 width 时那一行的高，没有内容时 0。
    func height(width: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        if let fixedHeight { return fixedHeight }
        let width = ComposerLayout.stripWidth(width)
        if let size, size.width == width { return size.height }
        let height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        size = (width, height)
        return height
    }
}

/// 图片附件的那一面：缩略图铺满，还没有时是底色上一个照片图标。气泡上的（AttachmentThumbnail）和输入框里待发的共用。
struct AttachmentFace: View {
    let image: PlatformImage?

    var body: some View {
        ZStack {
            Theme.codeBackground
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFill()
                #else
                Image(uiImage: image).resizable().scaledToFill()
                #endif
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }
}

/// 附件一个挨一个排，放不下就换行；trailing 时每行靠右（气泡上面），否则靠左（输入框上面）。同一行里竖着居中。
struct AttachmentFlow: Layout {
    var spacing: CGFloat
    var trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.indices.last, rows[last].width + spacing + size.width <= width {
                rows[last].indices.append(index)
                rows[last].width += spacing + size.width
                rows[last].height = max(rows[last].height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
