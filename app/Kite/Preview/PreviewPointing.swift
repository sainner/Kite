import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 指认的结果：元素在画面坐标里的位置、种类、文字、标识与源码位置。网页是指认脚本（shared/preview-point.js）给的；
/// 模拟器与 App 窗口是工作机从界面结构里找的控件，只有种类、文字与无障碍标识（identifier）。
/// file 是开发构建给的原样，可能是工作机上的绝对路径，见 source(root:)。
struct PointedElement: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let tag: String
    var text: String?
    var id: String?
    var testId: String?
    /// 无障碍标识（accessibilityIdentifier），模拟器与 App 窗口的控件才有。
    var identifier: String?
    var component: String?
    var file: String?
    var line: Int?
    /// 网页的路径（含查询）。
    var page: String?

    private static let decoder = JSONDecoder()

    /// 脚本结果的 JSON；那一点没有元素时是 null，解不出来。
    static func decode(_ json: String?) -> Self? {
        json.flatMap { try? decoder.decode(Self.self, from: Data($0.utf8)) }
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// 种类与文字：button「保存」；文字截到 40 个字。
    var summary: String {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return tag }
        return "\(tag)「\(text.count > 40 ? text.prefix(40) + "…" : text)」"
    }

    /// 悬停时框边的小字：种类与文字，有源码位置时加上文件名与行。
    var caption: String {
        guard let file else { return summary }
        return "\(summary) · \(URL(fileURLWithPath: file).lastPathComponent)\(line.map { ":\($0)" } ?? "")"
    }

    /// 源码位置写成工作区里的相对路径，带行号的接上行号；在工作区外（依赖包里）的不算。
    func source(root: String) -> String? {
        guard var file, !file.isEmpty else { return nil }
        if file.hasPrefix("file://") { file = URL(string: file)?.path ?? file }
        file = relativePath(file, to: root)
        if file.hasPrefix("./") { file.removeFirst(2) }
        // 换不成相对路径的在工作区外
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("node_modules") else { return nil }
        return line.map { "\(file):\($0)" } ?? file
    }

    /// 发送时接在正文后面的一行（docs/实例操作.md「指认」）：编号、预览与网页路径、种类与文字，再是源码位置，
    /// 没有时依次换成组件名、#id、data-testid、无障碍标识。
    func note(number: Int, preview: String, root: String) -> String {
        let handle = source(root: root) ?? component.map { "<\($0)>" } ?? id.map { "#\($0)" } ?? testId.map { "[data-testid=\"\($0)\"]" }
            ?? identifier.map { "[accessibilityIdentifier=\"\($0)\"]" }
        return "\(PreviewPointer.symbol(number)) 预览「\(preview)」\(page ?? "")：" + [summary, handle].compactMap(\.self).joined(separator: " ")
    }
}

/// 一个预览窗口的指认（docs/实例操作.md「指认」）：开着时指针下的元素框出来，点一下选中，框好编号的截图作为附件、说明随发送接在正文后面，
/// 放进最近用过的对话的输入框。坐标都是画面坐标：传过来的画面是它的逻辑尺寸，设备网页视图就是视图里的点。
/// 元素在哪由 locate 问画面所在处，截图由 snapshot 取；hold 让传过来的画面在指认期间停住（见 PreviewSession.hold）。
@Observable final class PreviewPointer {
    struct Pick: Identifiable {
        let number: Int
        let rect: CGRect
        var id: Int { number }
    }

    /// 开着时放进哪：对话按 WorkArea.pointingThread 在打开时定下，这次都放进它；附件传到的工作区；说明里写的预览名字。
    private struct Target {
        let area: WorkArea
        let thread: WorkThread
        let source: AttachmentSource
        let preview: String
    }

    private var target: Target?
    var active: Bool { target != nil }
    var thread: WorkThread? { target?.thread }
    /// 指针下的元素。
    private(set) var hover: PointedElement?
    /// 这次指认选中的；关掉指认时清掉，从输入框里拿掉的不再画（见 shownPicks）。
    private(set) var picks: [Pick] = []
    private(set) var failure: String?
    @ObservationIgnored private let locate: (CGPoint) async -> PointedElement?
    @ObservationIgnored private let snapshot: (CGSize) async -> CGImage?
    @ObservationIgnored private let hold: (Bool) -> Void
    /// 悬停一次只问一个，问的期间指针又动了就接着问最后那一点；hovered 是 hover 问的那一点。
    @ObservationIgnored private var wanted: CGPoint?
    @ObservationIgnored private var hovered: CGPoint?
    @ObservationIgnored private var locating = false
    @ObservationIgnored private var picking = false

    init(locate: @escaping (CGPoint) async -> PointedElement?, snapshot: @escaping (CGSize) async -> CGImage?, hold: @escaping (Bool) -> Void = { _ in }) {
        self.locate = locate
        self.snapshot = snapshot
        self.hold = hold
    }

    /// 正文与说明里写的编号：①到⑳，再往后写成 (21)。
    static func symbol(_ number: Int) -> String {
        guard (1...20).contains(number), let scalar = Unicode.Scalar(UInt32(0x245F + number)) else { return "(\(number))" }
        return String(scalar)
    }

    /// 选中的、还在输入框里的。
    var shownPicks: [Pick] {
        let numbers = Set(thread?.draftAttachments.compactMap(\.badge) ?? [])
        return picks.filter { numbers.contains($0.number) }
    }

    /// 控制区最右边的开关，单独一块玻璃，开着时整块用选中样式。
    func button(area: WorkArea, client: KitedClient, preview: String) -> some View {
        PaneHeaderButtonGroup(selected: active) {
            Button { [self] in toggle(area: area, client: client, preview: preview) } label: {
                PaneHeaderButtonLabel("指认", systemImage: "scope")
            }
            .foregroundStyle(active ? Color.white : Color.primary)
            .help(active ? "关掉指认" : "指出页面上的元素，截图和说明放进最近用过的对话")
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    /// 开着时信息区说放进哪个对话；出错时说原因。
    var notice: PaneNotice? {
        if let failure { return .failure(failure) }
        return thread.map { .info("指认：点一下选中元素，放进「\($0.title)」的输入框", symbol: "scope") }
    }

    /// 打开或关掉；关掉时选过元素的话，把那个对话放上台面。
    private func toggle(area: WorkArea, client: KitedClient, preview: String) {
        if let target {
            if !picks.isEmpty { area.bringUp(target.thread) }
            self.target = nil
            hover = nil
            hovered = nil
            picks = []
            hold(false)
        } else {
            failure = nil
            target = Target(area: area, thread: area.pointingThread(), source: AttachmentSource(client: client, workspace: area.id), preview: preview)
            hold(true)
        }
    }

    /// 指针移到画面上这一点，nil 是移出了画面。
    func hovering(_ point: CGPoint?) {
        guard active else { return }
        wanted = point
        if point == nil { hover = nil; hovered = nil }
        guard !locating, point != nil else { return }
        locating = true
        Task {
            var asked: CGPoint?
            while let next = wanted, next != asked {
                asked = next
                let element = await locate(next)
                if active, wanted != nil { hover = element; hovered = next }
            }
            locating = false
        }
    }

    /// 选中这一点上的元素：截图画上框和编号，作为附件放进对话的输入框，说明随发送接在正文后面。size 是画面坐标的尺寸。
    func pick(at point: CGPoint, size: CGSize) {
        guard !picking, let target else { return }
        picking = true
        Task {
            defer { picking = false }
            failure = nil
            // 点下去的就是刚才悬停问过的那一点（点按、松手都是）时直接用它的结果，不再问一趟
            var element = hover
            if hovered != point { element = await locate(point) }
            guard let element else { return }
            guard let image = await snapshot(size), size.width > 0 else {
                failure = "没有截到画面"
                return
            }
            guard target.thread.attachmentRoom > 0 else {
                failure = "一条消息最多带 \(WorkThread.maxAttachments) 个附件，指认也算在里面"
                return
            }
            let number = (target.thread.draftAttachments.compactMap(\.badge).max() ?? 0) + 1
            let scale = CGFloat(image.width) / size.width
            let badge = ImageRenderer(content: NumberBadge(number: number))
            badge.scale = scale
            let color = Color.accentColor.resolve(in: EnvironmentValues()).cgColor
            guard let data = await Self.annotate(image, rect: element.rect.applying(CGAffineTransform(scaleX: scale, y: scale)), scale: scale,
                                                 badge: badge.cgImage, color: color) else {
                failure = "截图没有存下来"
                return
            }
            do {
                let item = try DraftAttachment(data: data, name: "指认\(Self.symbol(number)).jpg",
                                               note: element.note(number: number, preview: target.preview, root: target.area.remote.workspace.cwd), badge: number)
                target.thread.attach([item], to: target.source)
                picks.append(Pick(number: number, rect: element.rect))
            } catch {
                failure = "截图没有存下来：\(error.localizedDescription)"
            }
        }
    }

    /// 截图上画出选中的元素：主题色的框，编号的中心在框的左上角（同画面上的）。rect 是图片的像素坐标（原点在左上），scale 是每个画面坐标多少像素。
    @concurrent nonisolated private static func annotate(_ image: CGImage, rect: CGRect, scale: CGFloat, badge: CGImage?, color: CGColor) async -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 的原点在左下
        context.setStrokeColor(color)
        context.setLineWidth(2 * scale)
        context.stroke(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -scale, dy: -scale))
        if let badge {
            let w = CGFloat(badge.width), h = CGFloat(badge.height)
            // 贴着画面边的挪进来
            let x = min(max(rect.minX - w / 2, 0), width - w), y = min(max(rect.minY - h / 2, 0), height - h)
            context.draw(badge, in: CGRect(x: x, y: height - y - h, width: w, height: h))
        }
        guard let annotated = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, annotated, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// 指认开着时盖在画面上的一层（docs/实例操作.md「指认」）：指针下的元素描框、旁边写种类与文字，选中的标上编号；
/// 点按、拖动都归它，盖住的画面收不到。pictureSize 是画面坐标的尺寸，画面按比例居中摆（同 ScreenView），不给时画面就是整层（设备网页视图）。
/// 触屏上按住移动时一路框出手指下的元素，松手选中。
struct PointingLayer: View {
    let pointer: PreviewPointer
    var pictureSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let size = pictureSize ?? geometry.size
            let frame = ScreenGeometry.fit(size, in: geometry.size)
            let scale = size.width > 0 ? frame.width / size.width : 1
            let onScreen = { (rect: CGRect) in rect.applying(CGAffineTransform(scaleX: scale, y: scale)).offsetBy(dx: frame.minX, dy: frame.minY) }
            let toPicture = { (location: CGPoint) in ScreenGeometry.point(location, in: frame, frame: size).map { CGPoint(x: $0.x, y: $0.y) } }
            ZStack(alignment: .topLeading) {
                ForEach(pointer.shownPicks) { pick in
                    let rect = onScreen(pick.rect)
                    Self.box(rect, filled: false)
                    NumberBadge(number: pick.number)
                        .offset(x: rect.minX - NumberBadge.size / 2, y: rect.minY - NumberBadge.size / 2)
                }
                if let hover = pointer.hover {
                    let rect = onScreen(hover.rect)
                    Self.box(rect, filled: true)
                    Text(hover.caption)
                        .font(Theme.caption)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .fixedSize()
                        // 放在框的上边，贴着顶边时放到下边
                        .offset(x: max(rect.minX, 0), y: rect.minY >= 24 ? rect.minY - 22 : rect.maxY + 4)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer.hovering(toPicture(location))
                case .ended: pointer.hovering(nil)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { pointer.hovering(toPicture($0.location)) }
                .onEnded { value in if let point = toPicture(value.location) { pointer.pick(at: point, size: size) } })
        }
    }

    private static func box(_ rect: CGRect, filled: Bool) -> some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Rectangle().fill(Color.accentColor.opacity(filled ? 0.15 : 0)))
            .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}
