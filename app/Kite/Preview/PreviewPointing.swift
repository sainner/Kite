import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 指认的结果：元素在画面坐标里的位置、种类、文字、外观、标识与源码位置。网页是指认脚本（shared/preview-point.js）给的；
/// 模拟器与 App 窗口是工作机从界面结构里找的控件，只有种类、文字与无障碍标识（identifier）。
/// file 是开发构建给的原样，可能是工作机上的绝对路径，见 source(root:)。
struct PointedElement: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// 元素左上角的圆角，网页才有。
    var radius: Double?
    let tag: String
    var text: String?
    /// 文字颜色 #RRGGBB（半透明的是 #RRGGBBAA）与「字号 字体」，网页才有。
    var color: String?
    var font: String?
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

    /// 框的圆角：跟元素的，没有圆角的（含模拟器、App 窗口的控件）给 4 点，不超过短边的一半。
    var cornerRadius: CGFloat { min(max(radius ?? 0, 4), min(width, height) / 2) }

    /// 种类与文字：button「保存」；文字截到 40 个字。
    var summary: String { summary(limit: 40) }

    /// 种类与文字，文字截到 limit 个字。
    func summary(limit: Int) -> String {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return tag }
        return "\(tag)「\(text.count > limit ? text.prefix(limit) + "…" : text)」"
    }

    /// 尺寸：28×28。
    var size: String { "\(Int(width.rounded()))×\(Int(height.rounded()))" }

    /// 源码的文件名与行，悬停的说明里用。
    var fileName: String? {
        file.map { "\(URL(fileURLWithPath: $0).lastPathComponent)\(line.map { ":\($0)" } ?? "")" }
    }

    /// 颜色的色块。
    var swatch: Color? {
        guard let color, color.hasPrefix("#"), let value = UInt32(color.dropFirst(), radix: 16) else { return nil }
        let channels = color.count == 9 ? value : value << 8 | 0xFF
        return Color(.sRGB, red: Double(channels >> 24 & 0xFF) / 255, green: Double(channels >> 16 & 0xFF) / 255,
                     blue: Double(channels >> 8 & 0xFF) / 255, opacity: Double(channels & 0xFF) / 255)
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
        let cornerRadius: CGFloat
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
    /// 指针在画面上的哪一点，没开着时也记着（Mac 上见 PointerTracker），按住 ⌥ 打开时当场框出指针下的元素。
    @ObservationIgnored private var pointed: CGPoint?

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

    /// 控制区最右边的开关，单独成组（PaneHeaderActionGroup），开着时整块用选中样式。
    func action(area: WorkArea, client: KitedClient, preview: String) -> PaneHeaderAction {
        PaneHeaderAction(title: "指认", systemImage: "scope", help: active ? "关掉指认" : "指出页面上的元素，截图和说明放进最近用过的对话\(Self.holdHint)", on: active) { [self] in
            if active { stop() } else { start(area: area, client: client, preview: preview) }
        }
    }

    #if os(macOS)
    private static let holdHint = "（指针在画面上时按住 ⌥ 临时打开）"
    private static let copyHint = "，按 C 复制颜色"
    #else
    private static let holdHint = ""
    private static let copyHint = ""
    #endif

    /// 开着时信息区说放进哪个对话；出错时说原因。
    var notice: PaneNotice? {
        if let failure { return .failure(failure) }
        return thread.map { .info("指认：点一下选中元素，放进「\($0.title)」的输入框\(Self.copyHint)", symbol: "scope") }
    }

    /// 打开：点开关，或 Mac 上按住 ⌥（PointingKeys）。指针已经在画面上时当场框出它下面的元素。
    func start(area: WorkArea, client: KitedClient, preview: String) {
        guard !active else { return }
        failure = nil
        target = Target(area: area, thread: area.pointingThread(), source: AttachmentSource(client: client, workspace: area.id), preview: preview)
        hold(true)
        if let pointed { hovering(pointed) }
    }

    /// 记下指针在画面上的哪一点，nil 是不在画面上。
    func track(_ point: CGPoint?) {
        pointed = point
    }

    /// 复制指针下元素的颜色；没有颜色的（模拟器、App 窗口的控件）什么也不做。
    func copyColor(toast: ToastCenter?) {
        guard active, let color = hover?.color else { return }
        copyToPasteboard(color, toast: toast)
    }

    /// 关掉；选过元素的话，把那个对话放上台面。没开着时什么也不做。
    func stop() {
        guard let target else { return }
        if !picks.isEmpty { target.area.bringUp(target.thread) }
        self.target = nil
        hover = nil
        hovered = nil
        picks = []
        hold(false)
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
            guard let data = await Self.annotate(image, rect: element.rect.applying(CGAffineTransform(scaleX: scale, y: scale)),
                                                 cornerRadius: element.cornerRadius * scale, scale: scale, badge: badge.cgImage, color: color) else {
                failure = "截图没有存下来"
                return
            }
            do {
                let item = try DraftAttachment(data: data, name: "指认\(Self.symbol(number)).jpg",
                                               note: element.note(number: number, preview: target.preview, root: target.area.remote.workspace.cwd), badge: number)
                target.thread.attach([item], to: target.source)
                picks.append(Pick(number: number, rect: element.rect, cornerRadius: element.cornerRadius))
            } catch {
                failure = "截图没有存下来：\(error.localizedDescription)"
            }
        }
    }

    /// 截图上画出选中的元素：主题色的框，编号的中心在元素的左上角（同画面上的，见 PointingLayer.box）。rect、cornerRadius 是图片的像素，
    /// rect 的原点在左上；scale 是每个画面坐标多少像素。
    @concurrent nonisolated private static func annotate(_ image: CGImage, rect: CGRect, cornerRadius: CGFloat, scale: CGFloat,
                                                         badge: CGImage?, color: CGColor) async -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 的原点在左下
        context.setStrokeColor(color)
        // 描边的中线在元素外 1 点，整条线落在元素外面，圆角与元素的同心
        let ring = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -scale, dy: -scale)
        let corner = min(cornerRadius + scale, ring.width / 2, ring.height / 2)
        context.setLineWidth(2 * scale)
        context.addPath(CGPath(roundedRect: ring, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.strokePath()
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

/// 盖在画面上的指认层（docs/实例操作.md「指认」）。开着时指针下的元素描框，旁边的卡片写种类、文字、尺寸与外观，选中的标上编号；
/// 点按、拖动都归它，盖住的画面收不到。没开着时什么也不画、不接点按，Mac 上只跟着指针记位置，按住 ⌥ 时用 start 打开（PointingKeys）。
/// pictureSize 是画面坐标的尺寸，画面按比例居中摆（同 ScreenView），不给时画面就是整层（设备网页视图）。
/// 触屏上按住移动时一路框出手指下的元素，松手选中。
struct PointingLayer: View {
    let pointer: PreviewPointer
    var pictureSize: CGSize?
    /// 打开指认，同点开关。
    let start: () -> Void
    @Environment(\.toast) private var toast
    /// 卡片的大小，摆的时候躲开层的边。
    @State private var cardSize = CGSize.zero

    /// 框的线宽，线整条落在元素外面。
    static let ringWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let size = pictureSize ?? geometry.size
            let frame = ScreenGeometry.fit(size, in: geometry.size)
            let scale = size.width > 0 ? frame.width / size.width : 1
            let onScreen = { (rect: CGRect) in rect.applying(CGAffineTransform(scaleX: scale, y: scale)).offsetBy(dx: frame.minX, dy: frame.minY) }
            let toPicture = { (location: CGPoint) in ScreenGeometry.point(location, in: frame, frame: size).map { CGPoint(x: $0.x, y: $0.y) } }
            ZStack(alignment: .topLeading) {
                if pointer.active {
                    Color.clear
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
                ForEach(pointer.shownPicks) { pick in
                    let rect = onScreen(pick.rect)
                    Self.box(rect, cornerRadius: pick.cornerRadius * scale, filled: false)
                    NumberBadge(number: pick.number)
                        .offset(x: rect.minX - NumberBadge.size / 2, y: rect.minY - NumberBadge.size / 2)
                }
                if let hover = pointer.hover {
                    let rect = onScreen(hover.rect)
                    Self.box(rect, cornerRadius: hover.cornerRadius * scale, filled: true)
                    PointingCard(element: hover)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(Self.cardOffset(rect, card: cardSize, in: geometry.size))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            #if os(macOS)
            .background {
                PointerTracker { location in
                    let point = location.flatMap(toPicture)
                    pointer.track(point)
                    PointingKeys.shared.hovering(point.map { _ in PointingKeys.Hovered(pointer: pointer, start: start, toast: toast) })
                }
                .allowsHitTesting(false)
            }
            #endif
        }
    }

    /// 框：元素外面一圈描边，圆角与元素的同心；悬停的里面再淡淡铺一层主题色。rect、cornerRadius 是层里的点。
    private static func box(_ rect: CGRect, cornerRadius: CGFloat, filled: Bool) -> some View {
        let ring = rect.insetBy(dx: -ringWidth, dy: -ringWidth)
        let shape = RoundedRectangle(cornerRadius: cornerRadius + ringWidth)
        return shape
            .strokeBorder(Color.accentColor, lineWidth: ringWidth)
            .background(shape.fill(Color.accentColor.opacity(filled ? 0.1 : 0)))
            .frame(width: ring.width, height: ring.height)
            .offset(x: ring.minX, y: ring.minY)
            .allowsHitTesting(false)
    }

    /// 卡片放在框的上边、与框左对齐，上边放不下放到下边；左右挪进层里。
    private static func cardOffset(_ rect: CGRect, card: CGSize, in layer: CGSize) -> CGSize {
        let gap: CGFloat = 6
        let ring = rect.insetBy(dx: -ringWidth, dy: -ringWidth)
        let x = min(max(ring.minX, 0), max(layer.width - card.width, 0))
        let above = ring.minY - gap - card.height
        let y = above >= 0 ? above : min(ring.maxY + gap, max(layer.height - card.height, 0))
        return CGSize(width: x, height: y)
    }
}

/// 悬停时框旁边的卡片：种类与文字、尺寸，网页再给颜色与字体，有源码位置的给文件与行。深色底，标签在左、值靠右。
private struct PointingCard: View {
    let element: PointedElement

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text(element.summary(limit: 16))
                    .fontWeight(.semibold)
                Text(element.size)
                    .font(Self.value)
                    .gridColumnAlignment(.trailing)
            }
            if let color = element.color {
                GridRow {
                    Self.label("颜色")
                    HStack(spacing: 5) {
                        if let swatch = element.swatch {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(swatch)
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                                .frame(width: 10, height: 10)
                        }
                        Text(color)
                            .font(Self.value)
                    }
                }
            }
            if let font = element.font {
                GridRow {
                    Self.label("字体")
                    Text(font.count > 28 ? font.prefix(28) + "…" : font)
                        .font(Self.value)
                }
            }
            if let file = element.fileName {
                GridRow {
                    Self.label("源码")
                    Text(file)
                        .font(Self.value)
                }
            }
        }
        .font(Theme.caption)
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    private static let value = Theme.caption.monospaced()

    private static func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.6))
    }
}

#if os(macOS)
/// 铺在指认层底下跟着指针的视图：只报指针在层里的位置（原点在左上，离开是 nil），不接点按，指认没开着时下面的画面照常收点按。
private struct PointerTracker: NSViewRepresentable {
    let moved: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.moved = moved
    }

    final class TrackerView: NSView {
        var moved: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { moved?(convert(event.locationInWindow, from: nil)) }
        override func mouseMoved(with event: NSEvent) { moved?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { moved?(nil) }
    }
}

/// 键鼠上的指认（docs/实例操作.md「指认」）：指针在预览画面上时只按住 ⌥ 临时打开指认，松开就关（同点开关关掉）；
/// 指认开着、指针在画面上时按 C 复制指针下元素的颜色，这个键不再往下发。临时打开时按了别的键就关掉，那个键照常发出去。
@MainActor final class PointingKeys {
    static let shared = PointingKeys()

    /// 指针所在的预览画面：它的指认、打开指认的方法、复制后提示用的。
    struct Hovered {
        weak var pointer: PreviewPointer?
        let start: () -> Void
        let toast: ToastCenter?
    }

    private var hovered: Hovered?
    /// 按住 ⌥ 临时打开的。
    private weak var holding: PreviewPointer?
    private var monitor: Any?
    private var observer: NSObjectProtocol?

    /// 指针移到一个预览画面上（nil 是不在任何画面上）。按着 ⌥ 移进画面的也打开。
    func hovering(_ entry: Hovered?) {
        install()
        let entered = entry != nil && entry?.pointer !== hovered?.pointer
        hovered = entry
        if entered, holding == nil, Self.optionOnly(NSEvent.modifierFlags) { begin() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PointingKeys.shared.release() }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            if !Self.optionOnly(event.modifierFlags) { release() } else if holding == nil { begin() }
        case .keyDown:
            if let pointer = hovered?.pointer, pointer.active, event.charactersIgnoringModifiers?.lowercased() == "c",
               event.modifierFlags.intersection([.command, .control, .shift]).isEmpty {
                pointer.copyColor(toast: hovered?.toast)
                return nil
            }
            release()
        default: break
        }
        return event
    }

    private func begin() {
        guard let hovered, let pointer = hovered.pointer, !pointer.active else { return }
        hovered.start()
        if pointer.active { holding = pointer }
    }

    private func release() {
        holding?.stop()
        holding = nil
    }

    private static func optionOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == .option
    }
}
#endif
