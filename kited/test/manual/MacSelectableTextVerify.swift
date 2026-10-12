import AppKit
import CoreText
import ObjectiveC
import SwiftUI

// Mac 对话正文的 NSTextView（TextKit 2）原生合同。真实的 SelectableMarkdown、MacSelectableTextView、TextKitDecorations、
// PlatformText 连同它们依赖的 Theme、Markdown、InlineCode、ReferenceViews 一起编进来，放进离屏 NSWindow 里的 NSHostingView，
// 由 SwiftUI 真实地量高、更新；鼠标按 NSWindow 的命中办法交给文本视图（离屏窗口成不了 key，见 ProseHost.press）；
// 颜色资源由运行脚本用 actool 编成 Assets.car 放进 .app 包，Theme 的颜色才是真值。
// 下面五个场景都是 TextKit 2、CoreText、AppKit 与 SwiftUI 宿主配合出来的结果，读代码推不出，每个场景上方写它挡的回归。

// MARK: - 桩：真实源文件引用到、但正文排版用不到的类型（代码块卡片、表格、提示条、宿主模型）

@Observable final class ToastCenter {
    func show(_ text: String, systemImage: String? = nil) {}
}

extension EnvironmentValues {
    @Entry var toast: ToastCenter?
    /// MessageBubble.swift 里定义，气泡上浮时关掉选字；这里固定可选。
    @Entry var messageTextSelectable = true
}

func copyToPasteboard(_ text: String, toast: ToastCenter?) {}

func splitLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return (text.hasSuffix("\n") ? String(text.dropLast()) : text).components(separatedBy: "\n")
}

typealias BlockCardPress = (_ pressed: Bool, _ at: CGPoint) -> Void

struct BlockCard<Label: View, Actions: View, Content: View>: View {
    let content: Content

    init(label: String, copyLabel: String, background: Color = Theme.codeBackground, radius: CGFloat = Metrics.contentRadius,
         copy: @escaping () -> Void, @ViewBuilder actions: @escaping (_ press: @escaping BlockCardPress) -> Actions,
         @ViewBuilder content: () -> Content) where Label == Text {
        self.content = content()
    }

    var body: some View { content }
}

struct BlockCardIcon: View {
    init(_ asset: String) {}
    var body: some View { EmptyView() }
}

struct HighlightedCode: View {
    let text: String
    let language: String?
    var body: some View { Text(text) }
}

extension View {
    func hintsScrollOverflow(_ axis: Axis = .vertical) -> some View { self }
}

struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    var body: some View { EmptyView() }
}

@Observable final class AppModel {
    func openFileReference(_ file: FileReference, in area: WorkArea) async throws {}
}

@Observable final class WorkArea {
    struct Machine { let id: String }
    struct Remote { let machine: Machine }
    let id = "contract"
    var remote: Remote?
}

// MARK: - 夹具

private enum TextFailure: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "Mac 文本视图原生验证失败"
    }
}

@Observable @MainActor
private final class ProseState {
    var source: String
    var width: CGFloat = 360
    var opened: [URL] = []

    init(source: String) { self.source = source }
}

/// 和 TranscriptView 里一样，SelectableMarkdown 直接放在给定宽度的列里；openURL 记下收到的链接。
private struct ProseFixture: View {
    let state: ProseState
    static let margin: CGFloat = 20

    var body: some View {
        SelectableMarkdown(source: state.source)
            .frame(width: state.width, alignment: .topLeading)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 读像素时只画视图树，窗口底色不在里面；白底让 4% 透明度的代码底色量得出来
            .background(Color.white)
            .environment(\.openURL, OpenURLAction { url in
                state.opened.append(url)
                return .handled
            })
            .transaction { $0.disablesAnimations = true }
    }
}

/// 读出来的像素：按窗口坐标（y 向上）取色。
private struct Pixels {
    struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        func distance(to other: RGB) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    let contentHeight: CGFloat
    let bytes: [UInt8]

    func color(at point: CGPoint) -> RGB {
        let x = min(max(Int((point.x * scale).rounded(.down)), 0), width - 1)
        let y = min(max(Int(((contentHeight - point.y) * scale).rounded(.down)), 0), height - 1)
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }
}

@MainActor
private final class ProseHost {
    let state: ProseState
    let host: NSHostingView<ProseFixture>
    let window: NSWindow
    static let windowSize = CGSize(width: 480, height: 720)

    init(source: String) {
        state = ProseState(source: source)
        host = NSHostingView(rootView: ProseFixture(state: state))
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: Self.windowSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // 固定浅色外观，Theme 的颜色和像素阈值都按浅色算
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
    }

    func close() { window.close() }

    var textView: NSTextView? { Self.find(in: host) }

    private static func find(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    /// 等到文本视图放好、宽度是列宽加两侧余量（SelectableMarkdown 用负 padding 抵消的绘制余量）。
    func settled(_ label: String) throws -> NSTextView {
        var found: NSTextView?
        try wait(label) {
            guard let view = textView, view.frame.height > 0,
                  abs(view.frame.width - (state.width + Metrics.inlineCodePadding * 2)) < 0.5 else { return false }
            found = view
            return true
        }
        // 再走一轮，让 SwiftUI 把量好的尺寸落到 frame 上
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let view = found else { throw TextFailure.failed("\(label)：没有找到文本视图") }
        return view
    }

    func wait(_ label: String, seconds: Double = 5, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { throw TextFailure.failed("\(label)：等待超时") }
            host.layoutSubtreeIfNeeded()
            if !predicate() { RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))) }
        }
    }

    /// 几个字符在窗口里占的矩形（窗口坐标，y 向上）；取 TextKit 的标准文本段。
    func rect(of range: NSRange, in view: NSTextView) throws -> CGRect {
        guard let layout = view.textLayoutManager, let start = layout.location(layout.documentRange.location, offsetBy: range.location),
              let end = layout.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) else {
            throw TextFailure.failed("取不到字符范围 \(range) 的位置")
        }
        var frame = CGRect.null
        layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            frame = frame.union(rect)
            return true
        }
        guard !frame.isNull else { throw TextFailure.failed("字符范围 \(range) 没有文本段") }
        let origin = view.textContainerOrigin
        return view.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: nil)
    }

    /// 某个字符所在行的基线在窗口里的 y。
    func baseline(of index: Int, in view: NSTextView) throws -> CGFloat {
        guard let layout = view.textLayoutManager, let location = layout.location(layout.documentRange.location, offsetBy: index),
              let fragment = layout.textLayoutFragment(for: location) else {
            throw TextFailure.failed("取不到字符 \(index) 的排版片段")
        }
        let local = index - layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(local, $0.characterRange) }) else {
            throw TextFailure.failed("字符 \(index) 不在任何行片段里")
        }
        let y = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let origin = view.textContainerOrigin
        return view.convert(CGPoint(x: 0, y: y + origin.y), to: nil).y
    }

    func pixels() throws -> Pixels {
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw TextFailure.failed("无法建立宿主的像素缓存")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { throw TextFailure.failed("像素缓存没有 CGImage") }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw TextFailure.failed("无法读取宿主的 RGBA 像素") }
        return Pixels(width: width, height: height, scale: CGFloat(width) / host.bounds.width, contentHeight: host.bounds.height, bytes: bytes)
    }

    // MARK: 合成鼠标事件

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: Int.random(in: 1...100_000), clickCount: 1, pressure: 1)!
    }

    /// 左键按在 point：先按 NSWindow 的办法从 contentView 命中，要求命中的就是文本视图（左键穿过 SwiftUI 宿主，没被别的层截走），
    /// 再把按下直接交给它。离屏的无边框窗口不激活 App 成不了 key，NSWindow.sendEvent 会把左键吞掉，这一步替它做；
    /// 拖动和松开先放进 App 的事件队列，NSTextView 的 mouseDown 自己循环取。
    private func press(at start: CGPoint, through: [CGPoint], up end: CGPoint, expecting view: NSTextView, _ label: String) throws {
        let hit = window.contentView?.hitTest(start)
        guard hit === view else {
            throw TextFailure.failed("\(label)：左键在 \(start) 应命中文本视图，实际 \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        for point in through { NSApp.postEvent(event(.leftMouseDragged, at: point), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, at: end), atStart: false)
        view.mouseDown(with: event(.leftMouseDown, at: start))
    }

    func drag(from start: CGPoint, to end: CGPoint, in view: NSTextView) throws {
        let through = (1...6).map { step -> CGPoint in
            let t = CGFloat(step) / 6
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        try press(at: start, through: through, up: end, expecting: view, "拖选")
    }

    func click(at point: CGPoint, in view: NSTextView, _ label: String) throws {
        try press(at: point, through: [], up: point, expecting: view, label)
    }
}

// MARK: - 计数：sizeThatFits 让 TextKit 排版的次数

/// 记下 sizeThatFits 每次调 ensureLayout(for:) 时文本容器的宽度：它只在量过的宽度之外才调，同一宽度出现两次就是缓存没起作用。
/// NSTextView 自己的 viewport 排版（layoutViewport、_updateContentHeight）也走这个选择子，按直接调用者过滤掉。
private enum LayoutCount {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var widths: [CGFloat] = []

    static func install() {
        guard let original = class_getInstanceMethod(NSTextLayoutManager.self, NSSelectorFromString("ensureLayoutForRange:")),
              let replacement = class_getInstanceMethod(NSTextLayoutManager.self, #selector(NSTextLayoutManager.contract_ensureLayout(for:))) else {
            return
        }
        method_exchangeImplementations(original, replacement)
    }

    nonisolated static func record(width: CGFloat) {
        guard enabled else { return }
        // 跳过 record 自己和换上去的方法（含它的 @objc 壳），第一个外部帧就是直接调用者
        let caller = Thread.callStackSymbols.first { !$0.contains("LayoutCount") && !$0.contains("contract_ensure") }
        guard caller?.contains("sizeThatFits") == true else { return }
        widths.append(width)
    }
}

extension NSTextLayoutManager {
    @objc dynamic nonisolated func contract_ensureLayout(for range: NSTextRange) {
        if let width = textContainer?.size.width { LayoutCount.record(width: width) }
        contract_ensureLayout(for: range)
    }
}

// MARK: - 场景

@MainActor @main
private struct MacSelectableTextContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        LayoutCount.install()
        do {
            try selectionSpansParagraphHeadingAndQuote()
            try nestedListInlineCodeBackgroundWrapsGlyphs()
            try heightFollowsWidthAndLaysOutOncePerWidth()
            try streamingAppendOnlyEditsTheTail()
            try linkClickReachesOpenURLButPlainTextDoesNot()
            print("Mac 文本视图的五个原生场景验证通过")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func string(_ view: NSTextView) throws -> NSString {
        guard let storage = view.textStorage else { throw TextFailure.failed("文本视图没有 textStorage") }
        return storage.string as NSString
    }

    private static func range(of text: String, in string: NSString) throws -> NSRange {
        let range = string.range(of: text)
        guard range.location != NSNotFound else { throw TextFailure.failed("正文里找不到「\(text)」") }
        return range
    }

    private static func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // 1. 跨段落、标题、引用的选区与复制。
    // 换成 NSTextView 的理由就是 SwiftUI 不能跨 Text 选字；段落、标题、引用在属性串里是带不同段落样式和自定义装饰属性的几个段落，
    // 选区能不能从一段拖进另一段、复制能否按源文保留段间空行与 Markdown 标记，由 TextKit 2 的选择与 AppKit 的 pasteboard 写入决定。
    // 复制写到单独命名的 pasteboard（和 copy: 走同一条 writeSelection 路径），不碰用户的剪贴板。
    private static func selectionSpansParagraphHeadingAndQuote() throws {
        let harness = ProseHost(source: """
        第一段落的文字，够长一点，用来从中部开始选，再往后拖到下面去。

        ### 三级标题 heading3

        > 引用里的一段话，左边有竖线，选到这里为止，后面还有几个字。
        """)
        defer { harness.close() }
        let view = try harness.settled("选区场景的文本视图")
        let text = try string(view)
        let paragraphTail = "够长一点，用来从中部开始选，再往后拖到下面去。"
        let heading = "三级标题 heading3"
        let quoteHead = "引用里的一段话，左边有竖线"
        let from = try range(of: paragraphTail, in: text)
        let to = try range(of: quoteHead, in: text)
        let selection = NSRange(location: from.location, length: NSMaxRange(to) - from.location)

        view.setSelectedRange(selection)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kite.contract.selectable-text.\(ProcessInfo.processInfo.processIdentifier)"))
        defer { pasteboard.releaseGlobally() }
        // copy: 就是对 generalPasteboard 调这一句；类型要用它自己报的（legacy 名字），传 .string 它不认
        pasteboard.declareTypes(view.writablePasteboardTypes, owner: nil)
        let written = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
        guard written, let copied = pasteboard.string(forType: .string) else {
            throw TextFailure.failed("跨段选区没有写出纯文本；writeSelection 返回 \(written)，pasteboard 类型 \(pasteboard.types ?? [])，选区 \(view.selectedRange())")
        }
        let expected = "\(paragraphTail)\n\n### \(heading)\n\n> \(quoteHead)"
        guard copied == expected else {
            throw TextFailure.failed("跨段复制应保留 Markdown 原文的空行、标题与引用标记；实际 \(copied.debugDescription)")
        }
        print("通过：setSelectedRange 跨段落、标题、引用后复制保留 Markdown 原文")

        // 鼠标从第一段拖到引用：选区要跨过中间的标题
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let start = center(try harness.rect(of: NSRange(location: from.location, length: 2), in: view))
        let end = center(try harness.rect(of: NSRange(location: NSMaxRange(to) - 2, length: 2), in: view))
        try harness.drag(from: start, to: end, in: view)
        let headingRange = try range(of: heading, in: text)
        try harness.wait("鼠标拖选形成选区", seconds: 3) { view.selectedRange().length > 0 }
        let dragged = view.selectedRange()
        guard dragged.location <= headingRange.location, NSMaxRange(dragged) >= NSMaxRange(headingRange),
              dragged.location >= from.location - 1, NSMaxRange(dragged) <= NSMaxRange(to) + 1 else {
            throw TextFailure.failed("鼠标从第一段拖到引用应选中中间的标题；选区 \(dragged)，标题 \(headingRange)，起点 \(from.location)，终点 \(NSMaxRange(to))")
        }
        print("通过：鼠标从第一段拖到引用，选区 \(dragged) 跨过标题 \(headingRange)")
    }

    // 2. 深度不小于 2 的列表项里，行内代码背景要包住字形。
    // 真实缺陷（3aac1c4 修）：DecoratedFragment 让 CoreText 重排一行取字形位置，CoreText 把制表位算在行起点、TextKit 算在容器起点，
    // 嵌套列表的行起点有缩进，背景整体画偏一个缩进。只有把视图真画出来、对照 TextKit 的字形位置看像素才知道对不对。
    // 每个 `code` 都放在行末：从字形左边 2.5 pt 到右边 2.5 pt 要连成一块代码底色（颜色就是 Theme.codeBackground 叠在白底上），
    // 右边再往外 12 pt 是白底；背景整体偏一个缩进时字形左边露出白底，就判失败。
    private static func nestedListInlineCodeBackgroundWrapsGlyphs() throws {
        let harness = ProseHost(source: """
        段落里的 `code`

        1. 第一项带 `code`
           - 嵌套项带 `code`
             - 再嵌一层 `code`
        """)
        defer { harness.close() }
        let view = try harness.settled("嵌套列表场景的文本视图")
        guard let storage = view.textStorage else { throw TextFailure.failed("文本视图没有 textStorage") }
        var codes: [NSRange] = []
        storage.enumerateAttribute(.inlineCodeDecoration, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { codes.append(range) }
        }
        guard codes.count == 4 else { throw TextFailure.failed("样例应有 4 处行内代码，实际 \(codes.count)") }
        let pixels = try harness.pixels()
        let white = Pixels.RGB(r: 255, g: 255, b: 255)
        let viewFrame = view.convert(view.bounds, to: nil)
        let background = pixels.color(at: CGPoint(x: viewFrame.maxX - 2, y: viewFrame.maxY - 2))
        guard background.distance(to: white) <= 2 else {
            throw TextFailure.failed("文本视图右下角应是白底，实际 \(background)")
        }
        // 代码底色是 Theme 的 4% 透明色叠在白底上
        let fill = Theme.codeBackground.resolvedCGColor(for: .light)
        guard let components = fill.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              components.count == 4 else {
            throw TextFailure.failed("Theme.codeBackground 没有解析出 sRGB 分量（Assets.car 没装进包里？）：\(fill)")
        }
        let alpha = components[3]
        let expected = Pixels.RGB(r: Int((255 * (1 - alpha) + components[0] * 255 * alpha).rounded()),
                                  g: Int((255 * (1 - alpha) + components[1] * 255 * alpha).rounded()),
                                  b: Int((255 * (1 - alpha) + components[2] * 255 * alpha).rounded()))
        guard expected.distance(to: white) >= 4 else {
            throw TextFailure.failed("代码底色叠在白底上应和白底分得开，实际 \(expected)")
        }
        for (index, code) in codes.enumerated() {
            let segment = try harness.rect(of: code, in: view)
            // 基线上方 3 pt，穿过小写字母的 x 高度
            let y = try harness.baseline(of: code.location, in: view) + 3
            // 字形的墨：从 TextKit 文本段左边起往右找；代码在行末，右边放宽到 12 pt 之内
            var inkMin = CGFloat.infinity, inkMax = -CGFloat.infinity
            var x = segment.minX - 2
            while x <= segment.maxX + 12 {
                if pixels.color(at: CGPoint(x: x, y: y)).distance(to: white) >= 40 {
                    inkMin = min(inkMin, x)
                    inkMax = max(inkMax, x)
                }
                x += 0.5
            }
            guard inkMin.isFinite, inkMax - inkMin >= 12 else {
                throw TextFailure.failed("第 \(index + 1) 处代码在基线上方 3 pt 的那一行没有找到四个字母的墨；文本段 \(segment)，墨 \(inkMin)…\(inkMax)")
            }
            // 从字形左边 2.5 pt 到右边 2.5 pt，每个像素都不是白底：底色连成一块、把字形包在里面
            var gaps: [CGFloat] = []
            x = inkMin - 2.5
            while x <= inkMax + 2.5 {
                if pixels.color(at: CGPoint(x: x, y: y)).distance(to: white) < 3 { gaps.append(x) }
                x += 0.5
            }
            let leftPad = pixels.color(at: CGPoint(x: inkMin - 2.5, y: y))
            let rightPad = pixels.color(at: CGPoint(x: inkMax + 2.5, y: y))
            let beyond = pixels.color(at: CGPoint(x: inkMax + 12, y: y))
            let indent = (storage.attribute(.paragraphStyle, at: code.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            let describe = "第 \(index + 1) 处代码（段落 headIndent \(indent)）：墨 \(inkMin)…\(inkMax)，左内边距 \(leftPad)，右内边距 \(rightPad)，右外 12 pt \(beyond)，期望底色 \(expected)"
            guard gaps.isEmpty else {
                throw TextFailure.failed("行内代码背景应连成一块包住字形，这些位置露出了白底 \(gaps)；\(describe)")
            }
            guard leftPad.distance(to: expected) <= 3, rightPad.distance(to: expected) <= 3 else {
                throw TextFailure.failed("字形两侧的内边距应是 Theme.codeBackground 叠在白底上的颜色；\(describe)")
            }
            guard beyond.distance(to: white) <= 2 else {
                throw TextFailure.failed("行内代码背景不应越过字形右侧 12 pt；\(describe)")
            }
            print("通过：\(describe)")
        }
    }

    // 3. 按宽度量高。
    // sizeThatFits 把宽度放到文本容器上再量，SwiftUI 一轮布局会用多种宽度反复问；frame 高是否等于 TextKit 排出来的高、末行是否越界、
    // 改回同宽是否同高、同一宽度是否只排一次，取决于 TextKit 2 的容器几何与 SwiftUI 的提案顺序怎么配合。
    // 排版次数由 LayoutCount 从 ensureLayout(for:) 数，只认 sizeThatFits 发起的；缓存失效时 360 会被排不止一次、改回 360 会再排。
    private static func heightFollowsWidthAndLaysOutOncePerWidth() throws {
        LayoutCount.widths = []
        LayoutCount.enabled = true
        defer { LayoutCount.enabled = false }
        let harness = ProseHost(source: """
        ## 量高对照

        这一段够长，会在 360 宽下折成几行、在 240 宽下折成更多行，用来比较文本视图的高度是不是跟着排出来的高度走，末行有没有越出视图底边。

        > 引用也折行：再多写一点让它在窄的时候折到第三行，看竖线和高度都对不对。

        1. 第一项，`code` 在列表里
        2. 第二项折行测试：这一项的文字够长，折到第二行时要和正文对齐，而不是回到编号下面去
        """)
        defer { harness.close() }

        func check(_ label: String) throws -> CGFloat {
            let view = try harness.settled(label)
            guard let layout = view.textLayoutManager else { throw TextFailure.failed("\(label)：文本视图没有 textLayoutManager") }
            LayoutCount.enabled = false
            layout.ensureLayout(for: layout.documentRange)
            LayoutCount.enabled = true
            let usage = layout.usageBoundsForTextContainer.height
            var lastLine: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
                for line in fragment.textLineFragments {
                    lastLine = max(lastLine, fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY)
                }
                return true
            }
            let height = view.frame.height
            guard abs(height - ceil(usage)) <= 0.5 else {
                throw TextFailure.failed("\(label)：frame 高 \(height) 应等于排出来的高度 ceil(\(usage))")
            }
            guard lastLine <= height + 0.5 else {
                throw TextFailure.failed("\(label)：末行底边 \(lastLine) 越出 frame 高 \(height)")
            }
            print("通过：\(label)，frame \(view.frame.size)，TextKit usage 高 \(usage)，末行底边 \(lastLine)，排版过的容器宽 \(LayoutCount.widths)")
            return height
        }

        let wide = try check("宽 360")
        let firstPass = LayoutCount.widths
        let containerWidth = 360.0
        guard firstPass.filter({ abs($0 - containerWidth) < 0.5 }).count == 1 else {
            throw TextFailure.failed("宽 360 的一轮布局里，容器宽 \(containerWidth) 应只排一次；实际排版过的宽 \(firstPass)")
        }
        harness.state.width = 240
        let narrow = try check("改窄到 240")
        guard narrow > wide else { throw TextFailure.failed("改窄到 240 后应比 360 时更高；360 高 \(wide)，240 高 \(narrow)") }
        let afterNarrow = LayoutCount.widths.count
        harness.state.width = 360
        let wideAgain = try check("改回 360")
        guard wideAgain == wide else { throw TextFailure.failed("改回 360 应与第一次同高；第一次 \(wide)，改回 \(wideAgain)") }
        guard LayoutCount.widths.count == afterNarrow else {
            throw TextFailure.failed("改回量过的宽度不应再排版；240 之后又排了 \(Array(LayoutCount.widths[afterNarrow...]))")
        }
        print("通过：三种宽度共排版 \(LayoutCount.widths.count) 次，改回 360 没有再排")
    }

    // 4. 流式追加只补末尾。
    // 新串是旧串原样往后长时，updateNSView 只往 textStorage 末尾补字：textStorage 仍是同一对象、前面的选区不动、高度跟着长。
    // 补字还是整段重设，从 NSTextStorage 的 didProcessEditing 通知里看编辑范围；选区能不能保住要 TextKit 2 真的只从编辑处重排才成立。
    private static func streamingAppendOnlyEditsTheTail() throws {
        let harness = ProseHost(source: "第一段落，先选中这里的几个字。\n\n第二段正在流式输出")
        defer { harness.close() }
        let view = try harness.settled("流式场景的文本视图")
        guard let storage = view.textStorage else { throw TextFailure.failed("文本视图没有 textStorage") }
        let text = try string(view)
        let selection = try range(of: "选中这里", in: text)
        view.setSelectedRange(selection)
        let heightBefore = view.frame.height
        let lengthBefore = storage.length

        var edits: [NSRange] = []
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { note in
            guard let range = (note.object as? NSTextStorage)?.editedRange else { return }
            MainActor.assumeIsolated { edits.append(range) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        harness.state.source += "，继续往后长。"
        try harness.wait("末尾补字落到 textStorage") { (view.textStorage?.string ?? "").hasSuffix("继续往后长。") }
        guard view.textStorage === storage else { throw TextFailure.failed("流式追加后 textStorage 换成了另一个对象") }
        guard view.selectedRange() == selection else {
            throw TextFailure.failed("流式追加后前面的选区应不动；之前 \(selection)，之后 \(view.selectedRange())")
        }
        guard let edit = edits.first, edit.location == lengthBefore, edits.count == 1 else {
            throw TextFailure.failed("流式追加应只在旧串末尾 \(lengthBefore) 处编辑一次；实际编辑 \(edits)")
        }
        print("通过：同段追加只编辑 \(edit)，选区 \(selection) 不动")

        edits = []
        harness.state.source += "\n\n第三段是新追加的一段。"
        try harness.wait("追加的新段落落到 textStorage") { (view.textStorage?.string ?? "").hasSuffix("第三段是新追加的一段。") }
        try harness.wait("高度跟着新段落长") { view.frame.height > heightBefore }
        guard view.selectedRange() == selection else {
            throw TextFailure.failed("追加新段落后前面的选区应不动；之前 \(selection)，之后 \(view.selectedRange())")
        }
        guard edits.count == 1, edits[0].location == lengthBefore + "，继续往后长。".utf16.count else {
            throw TextFailure.failed("追加新段落应只在末尾编辑一次；实际编辑 \(edits)")
        }
        print("通过：追加新段落只编辑 \(edits[0])，高度 \(heightBefore) → \(view.frame.height)，选区不动")
    }

    // 5. 链接点击经 delegate 到 openURL，点普通文字不触发。
    // 左键要穿过 SwiftUI 宿主落到 NSTextView，由它判定点的是不是链接属性，再经 clickedOnLink 回到 SwiftUI 环境里的 openURL；
    // 网页链接和文件引用（kite://）各一个。先点普通文字再点链接，链接到达时计数是 1 就说明普通文字那下没触发。
    private static func linkClickReachesOpenURLButPlainTextDoesNot() throws {
        let harness = ProseHost(source: "看 [文档](https://example.invalid/docs) 和 app/Kite/UI/Markdown.swift，后面是普通文字。")
        defer { harness.close() }
        let view = try harness.settled("链接场景的文本视图")
        guard let storage = view.textStorage else { throw TextFailure.failed("文本视图没有 textStorage") }
        var web: NSRange?, file: NSRange?
        let text = storage.string as NSString
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            // 跳过附件字符和 WORD JOINER，点在文字上
            let start = text.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{FFFC}\u{2060}").inverted, options: [], range: range)
            guard start.location != NSNotFound else { return }
            let textRange = NSRange(location: start.location, length: NSMaxRange(range) - start.location)
            if url.scheme == "https", web == nil { web = textRange }
            if url.scheme == "kite", file == nil { file = textRange }
        }
        guard let web, let file else { throw TextFailure.failed("正文里应有网页链接和文件引用，实际 web \(String(describing: web))，file \(String(describing: file))") }
        let plain = try range(of: "普通文字", in: text)

        try harness.click(at: center(try harness.rect(of: NSRange(location: plain.location + 1, length: 1), in: view)), in: view, "点普通文字")
        try harness.click(at: center(try harness.rect(of: NSRange(location: web.location + 1, length: 1), in: view)), in: view, "点网页链接")
        try harness.wait("网页链接到达 openURL", seconds: 3) { !harness.state.opened.isEmpty }
        guard harness.state.opened == [URL(string: "https://example.invalid/docs")!] else {
            throw TextFailure.failed("先点普通文字再点网页链接，openURL 应只收到网页链接一次；实际 \(harness.state.opened)")
        }
        try harness.click(at: center(try harness.rect(of: NSRange(location: file.location + 1, length: 1), in: view)), in: view, "点文件引用")
        try harness.wait("文件引用到达 openURL", seconds: 3) { harness.state.opened.count >= 2 }
        let components = harness.state.opened.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        guard harness.state.opened.count == 2, components?.scheme == "kite",
              components?.queryItems?.first(where: { $0.name == "path" })?.value == "app/Kite/UI/Markdown.swift" else {
            throw TextFailure.failed("点文件引用应把 kite:// 链接交给 openURL；实际 \(harness.state.opened)")
        }
        print("通过：openURL 依次收到 \(harness.state.opened.map(\.absoluteString))，点普通文字没有触发")
    }
}
