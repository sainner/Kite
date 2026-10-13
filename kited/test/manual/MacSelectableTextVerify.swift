import AppKit
import CoreText
import ObjectiveC
import QuartzCore
import SwiftUI

// Mac 对话正文的 NSTextView（TextKit 2）原生合同。真实的 SelectableMarkdown、MacSelectableTextView、TextKitDecorations、
// PlatformText、BlockAttachment 与原生卡片 MacBlockCards、MacTextControls 连同它们依赖的 Theme、Markdown、MarkdownTable、Dots、
// InlineCode、ReferenceViews 一起编进来，放进离屏 NSWindow 里的 NSHostingView，
// 由 SwiftUI 真实地量高、更新；第八场景使用屏上窗口验证实际呈现；鼠标按 NSWindow 的命中办法交给文本视图（离屏窗口成不了 key，见 ProseHost.press）；
// 颜色资源由运行脚本用 actool 编成 Assets.car 放进 .app 包，Theme 的颜色才是真值。
// 下面八个场景都是 TextKit 2、CoreText、AppKit 与 SwiftUI 宿主配合出来的结果，读代码推不出，每个场景上方写它挡的回归。

// MARK: - 桩：提示条、宿主模型、语法高亮、读屏文案和指针/按钮样式；附件、原生代码卡片与折叠逻辑使用生产实现

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

// Mac 上附件用原生卡片；SwiftUI 的 BlockCard、CodeBlock、MarkdownTable 只因共用文件引用而编进来，本合同不走它们，按钮样式给空壳。
struct PaneButtonStyle: ButtonStyle {
    var text = false
    var fill: Color?
    var foreground: Color = .secondary
    var size: CGFloat?
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    static var pointingPlain: Self { .plain }
}

struct ReferenceLinkAttribute: TextAttribute {}
struct ReferenceLinkRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension Text {
    func referenceLink(_ linked: Bool = true) -> Text { self }
}
extension View {
    func clickPointer() -> some View { self }
    func referencePointer() -> some View { self }
}

struct HighlightedCode: View {
    let text: String
    let language: String?
    var body: some View { Text(text) }
}

/// CodeHighlighting.swift 依赖 Highlighter 包；原样返回不着色，原生代码卡片照常排版。
actor CodeHighlighter {
    static let shared = CodeHighlighter()
    func highlight(_ text: String, language: String?, dark: Bool) -> AttributedString { AttributedString(text) }
}

/// TranscriptAccessibility.swift 依赖对话模型；这里只给卡片用到的两句读屏文案。
enum TranscriptSpeech {
    static func code(language: String) -> String { "代码，\(language)" }
    static let table = "表格"
}

extension ProseTextView {
    /// 生产版在 TranscriptEventSlots.swift（依赖对话的行模型），只有表格卡片用；本合同的附件是代码块，不建表格。
    static func makeReadOnly() -> ProseTextView { make() }
}

extension View {
    func hintsScrollOverflow(_ axis: Axis = .vertical) -> some View { self }
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

private struct ClippedProseFixture: View {
    static let short = "用于滚动裁切合同的短行。"
    static let long = String(repeating: "长段中途露出时，中文与 English words 的行位置必须连续，不能出现空白或跳位。", count: 120)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 9458)
                SelectableMarkdown(source: Self.short).frame(width: 572, alignment: .leading)
                Color.clear.frame(height: 800)
                SelectableMarkdown(source: Self.long).frame(width: 572, alignment: .leading)
                Color.clear.frame(height: 1200)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .background(Color.white)
        .transaction { $0.disablesAnimations = true }
    }
}

private struct AttachmentProseFixture: View {
    let state: ProseState
    static let code = (1...32).map { "line_\($0): " + String(repeating: "long_code_value_", count: 24) }.joined(separator: "\n")
    static let source = "附件前正文，保留跨附件选区。\n\n```swift\n\(code)\n```\n\n附件后正文。"
        + String(repeating: "后续长正文让代码附件滚出时，整个文本视图仍然和外部裁切区相交。", count: 100)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 600)
                SelectableMarkdown(source: state.source).frame(width: state.width, alignment: .leading)
                Color.clear.frame(height: 1200)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .background(Color.white)
        .transaction { $0.disablesAnimations = true }
    }
}

@MainActor
private final class ClippedProseHost<Content: View> {
    let host: NSHostingView<Content>
    let window: NSWindow

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 618, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
    }

    func descendants<T: NSView>(_ type: T.Type, in root: NSView? = nil) -> [T] {
        let view = root ?? host
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    func wait(_ label: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            guard Date() < deadline else { throw TextFailure.failed("\(label)：等待超时") }
            host.layoutSubtreeIfNeeded()
            if !predicate() { RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))) }
        }
    }

    func scroll(_ scroll: NSScrollView, to y: CGFloat) throws {
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        try nextFrame()
        guard abs(clip.bounds.minY - y) <= 1 else {
            throw TextFailure.failed("夹具滚动目标 \(y) 被夹紧；实际 clip \(clip.bounds)")
        }
    }

    func nextFrame() throws {
        // 等滚动通知所在的主队列批次结束，再执行正常布局/显示，不为 TextKit 补 ensureLayout。
        var delivered = false
        DispatchQueue.main.async { delivered = true }
        let deadline = Date().addingTimeInterval(3)
        while !delivered {
            guard Date() < deadline else { throw TextFailure.failed("滚动通知没有交回主队列") }
            RunLoop.main.run(mode: .default, before: deadline)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    /// 直接读取 AppKit 基类的实现用于证明复现条件，不替换方法、不改变产品 getter 的结果。
    func appKitVisibleRect(_ view: NSTextView) throws -> CGRect {
        let selector = NSSelectorFromString("visibleRect")
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else {
            throw TextFailure.failed("无法读取 AppKit 的 visibleRect")
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(view, selector)
    }

    func pixels() throws -> Pixels {
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw TextFailure.failed("滚动宿主无法建立像素缓存")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw TextFailure.failed("滚动宿主没有绘制图像") }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw TextFailure.failed("滚动宿主无法读取 RGBA")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, scale: CGFloat(width) / host.bounds.width,
                      contentHeight: host.bounds.height, bytes: bytes)
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
        // 量高抽到了 TextKitMeasuring 的 measure(lineWidth:)，由 sizeThatFits 调它
        guard let caller, caller.contains("sizeThatFits") || caller.contains("7measure9lineWidth") else { return }
        widths.append(width)
    }
}

extension NSTextLayoutManager {
    @objc dynamic nonisolated func contract_ensureLayout(for range: NSTextRange) {
        if let width = textContainer?.size.width { LayoutCount.record(width: width) }
        contract_ensureLayout(for: range)
    }
}

// 历史 6845be2 的可复现输入：40 条混合消息，760×700，LazyVStack 首次从底部露出新消息。
// 样例内容用于保留当时的换行与片段形态，不是当前产品说明；不导入原实验的 hook 或补排版。
private enum LazyMessageSamples {
    static let templates: [String] = [
        "好的，我先看一下 `TranscriptView.swift` 里按需排版那一段，再回来说结论。",
        """
        ## 这次改动的范围

        把 Mac 的对话正文换成 `NSTextView`，和 iPhone 共用属性串构建。涉及的文件：

        - app/Kite/UI/MacSelectableTextView.swift：representable，没有自己的滚动视图
        - app/Kite/UI/SelectableMarkdown.swift：散文块合成一个文本视图
        - app/Kite/UI/TextKitDecorations.swift：引用竖线和行内代码背景

        > 外观必须与现状一致：字体、行距、块距、行内代码背景、引用竖线、列表缩进都是反复调过的。

        下一步是每条回复一个文本视图，把代码块和表格作附件嵌进去。
        """,
        """
        我量了三轮，中位数如下：

        1. 发送后一秒内帧间隔最大 **48 ms**，丢 3 帧
        2. 文本视图 `sizeThatFits` 被问 78 次，只有 21 种宽度
        3. 改窗口宽度时每个视图重排一次

        结论先写在 .kite/memory/performance-diagnosis.md 里，详见 https://developer.apple.com/documentation/appkit/nstextview 的说明。
        """,
        "收到。",
        """
        ### 为什么先空白再出现

        TextKit 2 只排、只画视口里的片段。视口按 `enclosingScrollView` 的可见范围算，外层一滚，片段要到下一轮 layout 才建出来。
        iPhone 的 `UITextView` 自己就是滚动视图、尺寸等于内容，视口就是整段，所以没有这个现象。

        - 第一步：量出视口与 bounds 的关系
        - 第二步：逐帧抓图看新露出的行
          - 看是不是先空白
          - 看是不是逐段出现
        - 第三步：数丢帧

        > 卡顿先量再改：手感只能说明卡不卡，说明不了卡在哪。
        """,
        """
        这段比较长，模拟一条完整的回复。先说背景：Mac 上每个 Markdown 块原来是独立的 SwiftUI `Text`，系统不支持跨 `Text` 选择，连两个段落都选不到一起；iPhone 的散文已经合成一个 `UITextView`，但在代码块处断开。近期的性能修补也都聚在平台文本视图这一层。

        然后是做法。属性串构建放在 `SelectableMarkdown.attributed`，两端共用；平台差异收在 `PlatformText.swift`。块距、引用竖线顶边、行内代码背景高按 Mac 上与 SwiftUI 版并排逐行量过的差异补偿：

        1. TextKit 2 把 `lineSpacing` 放在每一行上方，段落第一行也有，所以段前距要减掉一个行距
        2. 文档第一段不认 `paragraphSpacingBefore`，开头是标题时半个块距放在视图外面
        3. 引用竖线从第一行字的顶边起，片段顶边在段前距之上还高出一个行距

        > 这是 SwiftUI 的不一致，TextKit 反而整齐；一段里差不超过 1.4 pt。

        最后是风险。`offset` 动画让 `NSTextView` 每帧重画，发送时上浮的那条消息会多一次完整的文本绘制；行内代码前有引用图标时背景画偏是两端共用的缺陷，已在 3aac1c4 修掉。

        #### 待办

        - 真机验收
        - 每条回复一个文本视图嵌入附件
        - 复制出 Markdown 原文
        """,
        "改完了，跑 `.kite/check` 通过，合同也过。要不要我把结论记进 docs/？",
        """
        > 用户 2026-10-12 确认：接受标题行高 1～2 pt、个别行 0.69 pt、中文折行位置这三项残差。

        那我就不再追这三项了，把精力放到滚动卡顿上。看 kited/test/manual/verify-mac-selectable-text-swift.ts 怎么把源文件编进 .app。
        """,
        """
        ## 候选方案

        按侵入性从小到大：

        1. 让视口等于整段：子类里覆盖 `visibleRect` 返回 `bounds`
        2. 套一个按内容尺寸的 `NSScrollView`，滚轮透传给外层
        3. Mac 的对话改回不按需建行

        每个各量一次，取外观不变且有效的。第三条若要改要说明取舍让用户定。
        """,
        """
        说明一下测法：`CADisplayLink` 记主线程帧间隔，`CGWindowListCreateImage` 抓自己窗口的像素（经 `dlsym` 调，不需要录屏权限），单次测量受指针位置和其他会话活动影响，同一份代码中位丢帧会在 2 和 11 之间跳，所以至少跑 3 次看中位。
        """,
    ]

    static func messages(_ count: Int) -> [String] {
        (0..<count).map { index in
            let template = templates[index % templates.count]
            return template + "\n\n（第 \(index + 1) 条）"
        }
    }
}


private struct LazyViewportFixture: View {
    let messages = LazyMessageSamples.messages(40)
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, text in
                    SelectableMarkdown(source: text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(Theme.body)
            .frame(maxWidth: Metrics.transcriptWidth)
            .padding(.horizontal, Metrics.padding * 2)
            .padding(.vertical, Metrics.transcriptPadding)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .transaction { $0.disablesAnimations = true }
    }
}

private final class LazyFrameMarker: NSView {
    var token = 0 { didSet { needsDisplay = true } }
    var onPaint: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for bit in 0..<10 {
            ((token & (1 << bit)) != 0 ? NSColor.red : NSColor.green).setFill()
            CGRect(x: CGFloat(bit * 10), y: 0, width: 8, height: 8).fill()
        }
        NSColor.blue.setFill()
        CGRect(x: 112, y: 0, width: 8, height: 8).fill()
        // 读当次真实绘制的视图坐标，再用截图中的条码匹配，避免抓图和几何错拍。
        onPaint?()
    }
}

private final class LazyFrameClock: NSObject {
    var ticks = 0
    var link: CADisplayLink?
    func start(_ window: NSWindow) {
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) { ticks += 1 }
    func next() throws {
        let target = ticks + 1
        let deadline = Date().addingTimeInterval(3)
        while ticks < target {
            guard Date() < deadline else { throw TextFailure.failed("Lazy 屏幕合同没有 display link；检查锁屏/可用显示器") }
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }
}

private enum LazyViewportContract {
    struct ViewPosition {
        let id: String
        let object: ObjectIdentifier
        let rect: CGRect
    }
    struct Geometry {
        let views: [ViewPosition]
    }
    struct ScreenInk {
        let token: Int
        let width: Int
        let height: Int
        let ink: [UInt8]
        func at(_ point: CGPoint) -> Bool {
            let x = Int(floor(point.x)), y = height - 1 - Int(floor(point.y))
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return ink[y * width + x] != 0
        }
        func hasInk(near point: CGPoint) -> Bool {
            for dy in -1...1 {
                for dx in -1...1 where at(CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy))) {
                    return true
                }
            }
            return false
        }
    }
    struct Shot {
        let image: ScreenInk
        let geometry: Geometry
    }
    typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func screen(_ window: NSWindow) throws -> ScreenInk? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
            throw TextFailure.failed("无法打开 CoreGraphics")
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { throw TextFailure.failed("没有窗口截图接口") }
        let create = unsafeBitCast(symbol, to: CreateWindowImage.self)
        guard let image = create(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
                                 CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue() else {
            throw TextFailure.failed("当前会话无法读取测试窗口的实际屏幕图像；不是产品坐标失败")
        }
        // 统一为 1 像素/pt，整趟只保存二值墨迹，避免逐帧保留 Retina RGBA 的高内存。
        let width = 760, height = 700
        let nativeWidth = image.width, nativeHeight = image.height
        let sx = CGFloat(nativeWidth) / CGFloat(width), sy = CGFloat(nativeHeight) / CGFloat(height)
        var bytes = [UInt8](repeating: 0, count: nativeWidth * nativeHeight * 4)
        let rendered = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: nativeWidth, height: nativeHeight, bitsPerComponent: 8,
                                          bytesPerRow: nativeWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: nativeWidth, height: nativeHeight))
            return true
        }
        guard rendered else { throw TextFailure.failed("无法读取屏幕像素") }
        func color(x: Int, y: Int) -> (Int, Int, Int) {
            let px = Int((CGFloat(x) + 0.5) * sx), py = Int((CGFloat(height - 1 - y) + 0.5) * sy)
            let i = (py * nativeWidth + px) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        let anchor = color(x: 117, y: 5)
        guard anchor.0 < 80, anchor.1 < 80, anchor.2 > 180 else { return nil }
        var token = 0
        for bit in 0..<10 {
            let c = color(x: 6 + bit * 10, y: 5)
            if c.0 > 180, c.1 < 80, c.2 < 80 { token |= 1 << bit }
            else if !(c.1 > 180 && c.0 < 80 && c.2 < 80) { return nil }
        }
        // 每 pt 汇总覆盖到的所有原生像素；不能先 nearest-neighbor 缩图抽掉浅灰文字的细笔画。
        var ink = [UInt8](repeating: 0, count: width * height)
        for y in 0..<nativeHeight {
            let row = min(height - 1, Int(CGFloat(y) / sy)) * width
            for x in 0..<nativeWidth {
                let i = (y * nativeWidth + x) * 4
                if bytes[i] < 160 && bytes[i + 1] < 160 && bytes[i + 2] < 160 {
                    ink[row + min(width - 1, Int(CGFloat(x) / sx))] = 1
                }
            }
        }
        return ScreenInk(token: token, width: width, height: height, ink: ink)
    }

    static func verify() throws {
        let host = NSHostingView(rootView: LazyViewportFixture())
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: CGRect(x: visibleFrame.minX + 40, y: visibleFrame.minY + 40, width: 760, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 700))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        let marker = LazyFrameMarker(frame: CGRect(x: 2, y: 2, width: 122, height: 8))
        root.addSubview(marker)
        window.contentView = root
        window.orderFront(nil)
        let clock = LazyFrameClock()
        clock.start(window)
        defer { clock.stop(); marker.onPaint = nil; window.close() }
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
        }
        var scroll: NSScrollView?
        for _ in 0..<20 {
            try clock.next()
            scroll = descendants(NSScrollView.self, in: host).first
            if scroll?.documentView?.bounds.height ?? 0 > 700 { break }
        }
        guard let scroll, let document = scroll.documentView else { throw TextFailure.failed("Lazy 合同没有外层滚动视图") }
        let clip = scroll.contentView
        func scrollTo(_ y: CGFloat) {
            let maxY = max(0, document.frame.height - clip.bounds.height)
            clip.scroll(to: CGPoint(x: 0, y: min(max(y, 0), maxY)))
            scroll.reflectScrolledClipView(clip)
        }
        var geometries: [Int: Geometry] = [:]
        marker.onPaint = {
            let texts = descendants(NSTextView.self, in: host)
            let positions = texts.compactMap { view -> ViewPosition? in
                let rect = view.convert(view.bounds, to: nil)
                guard rect.intersects(root.bounds), !view.string.isEmpty else { return nil }
                return ViewPosition(id: String(view.string.suffix(16)).replacingOccurrences(of: "\n", with: " "), object: ObjectIdentifier(view), rect: rect)
            }
            geometries[marker.token] = Geometry(views: positions)
        }
        // Lazy 内容高会随新行测量改变。等真实底边和文档高连续稳定，不按秒休眠，也不触碰文本排版。
        var lastBottom: CGFloat = -1, stable = 0
        for _ in 0..<40 {
            let bottom = max(0, document.frame.height - clip.bounds.height)
            scrollTo(bottom)
            marker.token = 0
            try clock.next()
            let current = max(0, document.frame.height - clip.bounds.height)
            if abs(current - lastBottom) <= 0.5, abs(clip.bounds.minY - current) <= 0.5 { stable += 1 } else { stable = 0 }
            lastBottom = current
            if stable >= 3 { break }
        }
        guard stable >= 3 else { throw TextFailure.failed("Lazy 文档底部未稳定") }
        let start = clip.bounds.minY
        let initialObjects = Set(descendants(NSTextView.self, in: host).map(ObjectIdentifier.init))
        guard initialObjects.count < 40, start > 1680 else {
            throw TextFailure.failed("未形成按需创建的长对话；初始 native \(initialObjects.count)，底部 \(start)")
        }
        func pass(base: Int) throws -> [Shot] {
            var images: [ScreenInk] = []
            scrollTo(start)
            marker.token = base
            try clock.next()
            for step in 0...72 {
                if let image = try screen(window) { images.append(image) }
                if step < 70 {
                    scrollTo(start - CGFloat(step + 1) * 24)
                    marker.token = base + step + 1
                }
                try clock.next()
            }
            var seen = Set<Int>()
            let shots = images.compactMap { image -> Shot? in
                guard image.token >= base, image.token <= base + 70, seen.insert(image.token).inserted,
                      let geometry = geometries[image.token] else { return nil }
                return Shot(image: image, geometry: geometry)
            }
            guard shots.count >= 30 else { throw TextFailure.failed("可配对的屏幕帧不足；\(shots.count)/71，不能判定绘制") }
            return shots
        }
        // 整趟采集结束前不读 TextKit 行片段、不调用 cacheDisplay，不让验证主动重画掩盖首次空白。
        let cold = try pass(base: 1)
        let warm = try pass(base: 101)
        var reference: [String: (ScreenInk, ViewPosition)] = [:]
        for shot in warm {
            for view in shot.geometry.views where view.rect.minY >= 12 && view.rect.maxY <= 698 && reference[view.id] == nil {
                reference[view.id] = (shot.image, view)
            }
        }
        guard reference.count >= 3 else { throw TextFailure.failed("暖趟完整参考不足：\(reference.count)") }
        func compare(_ actualImage: ScreenInk, rect actualRect: CGRect, to expectedImage: ScreenInk, rect expectedRect: CGRect) -> (Int, Int, CGRect) {
            let visible = actualRect.intersection(CGRect(x: 0, y: 12, width: 760, height: 686)).insetBy(dx: 4, dy: 4)
            var missing = 0, ink = 0
            var missingBounds = CGRect.null
            for y in stride(from: ceil(visible.minY) + 0.5, to: floor(visible.maxY), by: 1) {
                for x in stride(from: ceil(visible.minX) + 0.5, to: floor(visible.maxX), by: 1) {
                    let point = CGPoint(x: x, y: y)
                    let wanted = CGPoint(x: expectedRect.minX + x - actualRect.minX,
                                         y: expectedRect.maxY - (actualRect.maxY - y))
                    let a = actualImage.at(point), b = expectedImage.at(wanted)
                    if a {
                        ink += 1
                        if !expectedImage.hasInk(near: wanted) {
                            missing += 1
                            missingBounds = missingBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                        }
                    }
                    if b {
                        ink += 1
                        if !actualImage.hasInk(near: point) {
                            missing += 1
                            missingBounds = missingBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                        }
                    }
                }
            }
            return (missing, ink, missingBounds)
        }
        var checks = 0, coldPartialObjects = Set<ObjectIdentifier>(), failures: [String] = []
        var comparedIDs = Set<String>(), worstMismatch = 0.0
        for shot in cold {
            for view in shot.geometry.views {
                guard let (expectedImage, expectedView) = reference[view.id],
                      abs(view.rect.width - expectedView.rect.width) <= 1,
                      abs(view.rect.height - expectedView.rect.height) <= 1 else { continue }
                let visible = view.rect.intersection(CGRect(x: 0, y: 12, width: 760, height: 686)).insetBy(dx: 4, dy: 4)
                guard visible.width > 100, visible.height > 12 else { continue }
                if !initialObjects.contains(view.object), view.rect.maxY > 702, view.rect.minY > 12 {
                    coldPartialObjects.insert(view.object)
                }
                let (missing, ink, missingBounds) = compare(shot.image, rect: view.rect, to: expectedImage, rect: expectedView.rect)
                guard ink > 100 else { continue }
                checks += 1
                comparedIDs.insert(view.id)
                worstMismatch = max(worstMismatch, Double(missing) / Double(ink))
                if missing * 200 > ink {
                    failures.append("帧 \(shot.image.token) 消息 \(view.id) 高 \(view.rect.height)，露出 \(visible.height)，错位/缺墨 \(missing)/\(ink)，差异屏幕范围 \(missingBounds)")
                }
            }
        }
        guard checks >= 30, coldPartialObjects.count >= 1 else {
            throw TextFailure.failed("未覆盖新的 Lazy 原生行首次仅底部露出；比较 \(checks)，新 partial 对象 \(coldPartialObjects.count)，参考 \(reference.count)")
        }
        guard failures.isEmpty else {
            throw TextFailure.failed("Lazy 首次部分露出像素与完整参考不一致；冷帧 \(cold.count)，暖帧 \(warm.count)，新 partial \(coldPartialObjects.count)；\n" + failures.prefix(3).joined(separator: "\n"))
        }
        // 每次改宽前保持同一原生行顶部裁切，抓首次真正呈现的画面，再完整滚入该行建立参考。
        // 不先滚到顶部暖布局，也不通过等待像素正确来跳过失败首帧。
        guard let target = descendants(NSTextView.self, in: host).first(where: {
            let rect = $0.convert($0.bounds, to: nil)
            return rect.intersects(root.bounds) && rect.height > 170 && rect.height < 430
        }), let targetStorage = target.textStorage else {
            throw TextFailure.failed("改宽夹具没有可完整显示的中长消息")
        }
        guard targetStorage.length >= 5 else { throw TextFailure.failed("改宽夹具正文不足以建立非空选区") }
        target.setSelectedRange(NSRange(location: 1, length: 4))
        let identity = ObjectIdentifier(target), selection = target.selectedRange()
        guard selection.length > 0 else { throw TextFailure.failed("改宽前未建立非空选区") }
        func markedShot(_ token: Int) throws -> Shot {
            marker.token = token
            for _ in 0..<12 {
                try clock.next()
                if let image = try screen(window), image.token == token, let geometry = geometries[token] {
                    return Shot(image: image, geometry: geometry)
                }
            }
            throw TextFailure.failed("改宽帧标记没有呈现：\(token)")
        }
        for (index, width) in [CGFloat(520), CGFloat(760)].enumerated() {
            let before = target.convert(target.bounds, to: clip)
            scrollTo(before.minY + min(120, before.height / 3))
            let cropped = try markedShot(201 + index * 3)
            guard let croppedPosition = cropped.geometry.views.first(where: { $0.object == identity }),
                  croppedPosition.rect.maxY > 720, croppedPosition.rect.minY < 680 else {
                throw TextFailure.failed("改宽前同一消息顶部必须已被裁切")
            }
            let wantedWidth = target.bounds.width + width - host.bounds.width
            host.setFrameSize(CGSize(width: width, height: 700))
            let first = try markedShot(202 + index * 3)
            guard let firstPosition = first.geometry.views.first(where: { $0.object == identity }),
                  firstPosition.rect.maxY > 702, firstPosition.rect.minY < 698,
                  abs(firstPosition.rect.width - wantedWidth) <= 1,
                  target.textStorage === targetStorage, target.selectedRange() == selection else {
                throw TextFailure.failed("改宽首次显示未保持裁切的同一正文/Storage/选区或尺寸；目标宿主宽 \(width)，正文宽 \(target.bounds.width)，期望 \(wantedWidth)")
            }
            let now = target.convert(target.bounds, to: clip)
            scrollTo(now.minY - 24)
            let reference = try markedShot(203 + index * 3)
            guard let full = reference.geometry.views.first(where: { $0.object == identity }),
                  full.rect.minY >= 12, full.rect.maxY <= 698,
                  full.rect.size == firstPosition.rect.size else {
                throw TextFailure.failed("改宽完整参考未包含同一消息的当前全部内容；高 \(target.bounds.height)")
            }
            let (missing, ink, rect) = compare(first.image, rect: firstPosition.rect, to: reference.image, rect: full.rect)
            guard ink > 1000, missing * 200 <= ink else {
                throw TextFailure.failed("顶部裁切时改宽到 \(width - 40) pt 的首帧错位/缺墨 \(missing)/\(ink)，范围 \(rect)，消息 \(firstPosition.id)")
            }
        }
        print("通过：Lazy 40 条消息冷滚 70×24 pt，冷/暖配对 \(cold.count)/\(warm.count) 帧；\(coldPartialObjects.count) 个新原生对象部分露出，\(comparedIDs.count) 条消息 \(checks) 个切片与完整参考对齐，最大不匹配 \(worstMismatch)；同实例720→480→720首帧对齐，Storage/选区保持")
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
            try clippedTextReportsEmptyOnlyWhenFullyOutsideAndKeepsLongParagraphStable()
            try offscreenAttachmentResumesAtCurrentWidthWithItsStateAndSelection()
            try LazyViewportContract.verify()
            print("Mac 文本视图的八个原生场景验证通过")
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

    // 真实缺陷：SwiftUI 滚动裁切下，AppKit 的 visibleRect 可非空却完全落在文本 bounds 之外。
    // 屏外正文必须给 TextKit 空视口；长段只露中间时又必须保留整段视口，避免字形空白或跳位。
    // 使用真实 NSScrollView/NSHostingView 裁切，期望来自屏幕相交关系与滚动前的行几何，不模拟产品的 getter。
    private static func clippedTextReportsEmptyOnlyWhenFullyOutsideAndKeepsLongParagraphStable() throws {
        let harness = ClippedProseHost(rootView: ClippedProseFixture())
        defer { harness.window.close() }
        try harness.wait("滚动正文建立") {
            let texts = harness.descendants(NSTextView.self)
            return texts.contains { $0.string == ClippedProseFixture.short && $0.bounds.height > 0 }
                && texts.contains { $0.string == ClippedProseFixture.long && $0.bounds.height > 1800 }
        }
        let texts = harness.descendants(NSTextView.self)
        guard let short = texts.first(where: { $0.string == ClippedProseFixture.short }),
              let long = texts.first(where: { $0.string == ClippedProseFixture.long }),
              let shortStorage = short.textStorage, let longStorage = long.textStorage,
              let scroll = harness.descendants(NSScrollView.self).first else {
            throw TextFailure.failed("滚动夹具缺少两个正文或 NSScrollView")
        }
        let clip = scroll.contentView
        let shortBounds = short.bounds, longBounds = long.bounds
        let shortSelection = NSRange(location: 1, length: 4), longSelection = NSRange(location: 8, length: 12)
        short.setSelectedRange(shortSelection)
        long.setSelectedRange(longSelection)

        func check(_ label: String, shortVisible: Bool, longVisible: Bool) throws {
            for (view, originalStorage, originalBounds, selection, expectedVisible) in [
                (short, shortStorage, shortBounds, shortSelection, shortVisible),
                (long, longStorage, longBounds, longSelection, longVisible),
            ] {
                let inClip = view.convert(view.bounds, to: clip)
                guard inClip.intersects(clip.bounds) == expectedVisible else {
                    throw TextFailure.failed("\(label)：夹具裁切位置不符合场景；正文 \(inClip)，clip \(clip.bounds)")
                }
                let visible = view.visibleRect
                guard expectedVisible ? visible == view.bounds : visible.isEmpty else {
                    throw TextFailure.failed("\(label)：\(expectedVisible ? "露出部分时应报告整段 bounds" : "完全屏外时应报告空视口")；visibleRect \(visible)，bounds \(view.bounds)，正文在 clip 内 \(inClip)，clip \(clip.bounds)")
                }
                guard view.window === harness.window, harness.descendants(NSTextView.self).contains(where: { $0 === view }),
                      view.textStorage === originalStorage, view.bounds == originalBounds,
                      view.selectedRange() == selection else {
                    throw TextFailure.failed("\(label)：滚动改变了原生对象、正文尺寸或已有选区")
                }
            }
        }

        func lines() throws -> [CGRect] {
            guard let layout = long.textLayoutManager else { throw TextFailure.failed("长段缺少 TextKit 2") }
            var result: [CGRect] = []
            // 只读已存在的片段，不请求 ensureLayout/ensuresLayout 来掩盖视口造成的缺字。
            layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    result.append(line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                                 dy: fragment.layoutFragmentFrame.minY))
                }
                return true
            }
            return result
        }

        let shortInClip = short.convert(short.bounds, to: clip)
        try harness.scroll(scroll, to: shortInClip.minY + 801)
        let appKitRect = try harness.appKitVisibleRect(short)
        guard !appKitRect.isEmpty, !appKitRect.intersects(short.bounds) else {
            throw TextFailure.failed("未复现 AppKit 非空但不相交的前提；AppKit visibleRect \(appKitRect)，bounds \(short.bounds)，clip \(clip.bounds)")
        }
        try check("短行完全位于裁切区上方", shortVisible: false, longVisible: true)
        print("通过：AppKit visibleRect \(appKitRect) 与短行 bounds \(short.bounds) 不相交，产品报告空视口")

        try harness.scroll(scroll, to: shortInClip.maxY - 8)
        try check("短行只露出 8 pt", shortVisible: true, longVisible: true)
        try harness.scroll(scroll, to: shortInClip.minY - 24)
        try check("短行完整滚入", shortVisible: true, longVisible: true)
        let referenceLines = try lines()
        guard referenceLines.count > 30 else { throw TextFailure.failed("长段夹具行数不足：\(referenceLines.count)") }

        let longInClip = long.convert(long.bounds, to: clip)
        let middle = (longInClip.midY - clip.bounds.height / 2).rounded()
        try harness.scroll(scroll, to: middle)
        try check("长段仅中部露出", shortVisible: false, longVisible: true)
        guard try lines() == referenceLines else { throw TextFailure.failed("长段中途露出后行几何发生跳位") }
        let firstPixels = try harness.pixels()
        let darkPixels = stride(from: 0, to: firstPixels.bytes.count, by: 4).filter {
            firstPixels.bytes[$0] < 128 && firstPixels.bytes[$0 + 1] < 128 && firstPixels.bytes[$0 + 2] < 128
        }.count
        guard darkPixels > 1000 else { throw TextFailure.failed("长段中部出现空白；实际深色像素只有 \(darkPixels)") }

        try harness.scroll(scroll, to: 0)
        try check("两段全部滚出", shortVisible: false, longVisible: false)
        try harness.scroll(scroll, to: middle)
        try check("再次滚回长段中部", shortVisible: false, longVisible: true)
        guard try lines() == referenceLines else { throw TextFailure.failed("滚出再回来后长段行几何发生跳位") }
        let returnedPixels = try harness.pixels()
        guard returnedPixels.width == firstPixels.width, returnedPixels.height == firstPixels.height,
              zip(returnedPixels.bytes, firstPixels.bytes).allSatisfy({ abs(Int($0.0) - Int($0.1)) <= 3 }) else {
            throw TextFailure.failed("滚出再回到同一中部位置后，文字实际绘制发生变化")
        }
        print("通过：完全屏外、部分露出和滚入的视口语义正确；长段 \(referenceLines.count) 行中途露出有 \(darkPixels) 个深色像素，往返滚动保持行位置、绘制、对象与选区")
    }

    // 屏外附件延迟原生卡片改宽后，真实 clip 通知必须在再次显示时补齐尺寸，且不能重建卡片丢掉折叠/横滑状态。
    // 真实 BlockAttachment/TextKit provider、EmbeddedContainerView、CodeCardView/OverflowScrollView 与外层 NSScrollView 配合，单看源码不能确认通知与布局顺序。
    // 只有语法高亮是薄桩；展开走卡片里 TextButton 的读屏按下（离屏窗口不合成鼠标），横滑是卡片里真实的 NSScrollView。
    private static func offscreenAttachmentResumesAtCurrentWidthWithItsStateAndSelection() throws {
        let state = ProseState(source: AttachmentProseFixture.source)
        state.width = 520
        let harness = ClippedProseHost(rootView: AttachmentProseFixture(state: state))
        defer { harness.window.close() }
        try harness.wait("带附件正文建立") {
            harness.descendants(NSTextView.self).contains { $0.string.hasPrefix("附件前正文") && $0.bounds.height > 900 }
        }
        guard let textView = harness.descendants(NSTextView.self).first(where: { $0.string.hasPrefix("附件前正文") }),
              let storage = textView.textStorage, let scroll = harness.descendants(NSScrollView.self).first else {
            throw TextFailure.failed("附件夹具没有生产正文或外层滚动视图")
        }
        let clip = scroll.contentView
        let initialY = textView.convert(textView.bounds, to: clip).minY - 20
        try harness.scroll(scroll, to: initialY)
        try harness.wait("TextKit 建立附件 provider") { !harness.descendants(EmbeddedContainerView.self).isEmpty }
        guard let container = harness.descendants(EmbeddedContainerView.self).first,
              let attachment = container.attachment, let card = container.subviews.first as? CodeCardView else {
            throw TextFailure.failed("没有实际的附件容器或其中的原生代码卡片；容器子视图 \(harness.descendants(EmbeddedContainerView.self).first?.subviews.map { String(describing: type(of: $0)) } ?? [])")
        }
        try harness.wait("原生代码卡片折起并露出「显示全部」") {
            container.bounds.height > 0 && harness.descendants(TextButton.self, in: card).contains { !$0.isHidden && $0.title == "显示全部 32 行" }
        }
        let foldedHeight = container.bounds.height
        let foldButtons = harness.descendants(TextButton.self, in: card)
        guard foldButtons.count == 1, let expand = foldButtons.first else {
            throw TextFailure.failed("代码卡片里应只有一个「显示全部」按钮，实际 \(foldButtons.map(\.title))")
        }
        guard expand.accessibilityPerformPress() else { throw TextFailure.failed("「显示全部」不接受读屏按下") }
        try harness.wait("原生代码卡片展开并更新 TextKit 高度") { container.bounds.height > foldedHeight + 100 }
        let expandedSize = container.bounds.size
        guard expand.isHidden else { throw TextFailure.failed("原生代码卡片展开后仍显示「显示全部」") }
        guard let horizontal = harness.descendants(NSScrollView.self, in: card).first(where: {
            ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 300
        }) else { throw TextFailure.failed("长代码没有建立实际横向滚动视图") }
        horizontal.contentView.scroll(to: CGPoint(x: 160, y: horizontal.contentView.bounds.minY))
        horizontal.reflectScrolledClipView(horizontal.contentView)
        try harness.nextFrame()
        guard abs(horizontal.contentView.bounds.minX - 160) <= 1 else { throw TextFailure.failed("横滑夹具没有到达 160 pt") }

        let rendered = storage.string as NSString
        let before = try range(of: "跨附件选区", in: rendered)
        let after = try range(of: "附件后正文", in: rendered)
        let selection = NSRange(location: before.location, length: NSMaxRange(after) - before.location)
        var attachments = 0
        storage.enumerateAttribute(.attachment, in: selection) { value, _, _ in
            if value as? BlockAttachment === attachment { attachments += 1 }
        }
        guard attachments == 1 else { throw TextFailure.failed("选区必须跨过同一个真实 BlockAttachment") }
        textView.setSelectedRange(selection)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kite.contract.attachment.\(ProcessInfo.processInfo.processIdentifier)"))
        defer { pasteboard.releaseGlobally() }
        func copySelection() throws -> String {
            pasteboard.declareTypes(textView.writablePasteboardTypes, owner: nil)
            guard textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes),
                  let copied = pasteboard.string(forType: .string) else { throw TextFailure.failed("跨附件选区没有写出原文") }
            return copied
        }
        let originalCopy = try copySelection()
        guard originalCopy.contains(AttachmentProseFixture.code), originalCopy.contains("```swift") else {
            throw TextFailure.failed("跨附件复制没有保留完整代码及 Markdown 围栏")
        }
        let widthInset = state.width - expandedSize.width
        let visibleCardFrame = card.frame

        func checkIdentityAndState(_ label: String) throws {
            guard textView.textStorage === storage, textView.selectedRange() == selection,
                  container.attachment === attachment, container.subviews.first === card,
                  harness.descendants(EmbeddedContainerView.self).contains(where: { $0 === container }),
                  harness.descendants(NSScrollView.self, in: card).contains(where: { $0 === horizontal }) else {
                throw TextFailure.failed("\(label)：正文、附件、原生卡片、横向滚动对象或选区被替换")
            }
            guard abs(horizontal.contentView.bounds.minX - 160) <= 1,
                  abs(container.bounds.height - expandedSize.height) <= 1, expand.isHidden else {
                throw TextFailure.failed("\(label)：展开或横滑状态丢失；高 \(container.bounds.height)/\(expandedSize.height)，横向位置 \(horizontal.contentView.bounds.minX)，「显示全部」隐藏 \(expand.isHidden)")
            }
            guard abs(container.bounds.width - (state.width - widthInset)) <= 1 else {
                throw TextFailure.failed("\(label)：TextKit 附件占位没有跟随正文改宽；容器 \(container.bounds)，正文宽 \(state.width)")
            }
        }

        let offscreenY = container.convert(container.bounds, to: clip).maxY + 200
        try harness.scroll(scroll, to: offscreenY)
        guard !container.convert(container.bounds, to: clip).intersects(clip.bounds),
              textView.convert(textView.bounds, to: clip).intersects(clip.bounds) else {
            throw TextFailure.failed("附件应完全屏外，但它所在的长正文仍需露出")
        }
        for width: CGFloat in [360, 560, 420] {
            state.width = width
            try harness.wait("屏外正文改宽 \(width)") { abs(textView.bounds.width - (width + Metrics.inlineCodePadding * 2)) <= 1 }
            try checkIdentityAndState("屏外宽 \(width)")
            guard card.isHidden, card.frame == visibleCardFrame else {
                throw TextFailure.failed("完全屏外的原生卡片应隐藏并保留原 frame；hidden \(card.isHidden)，frame \(card.frame)，原 frame \(visibleCardFrame)")
            }
        }

        // 通过真实 NSClipView bounds 通知滚入，只等下一批主队列与正常显示；不直接调用产品的 host/sync。
        let partialY = container.convert(container.bounds, to: clip).minY - clip.bounds.height + 80
        try harness.scroll(scroll, to: partialY)
        try checkIdentityAndState("仅部分滚入首帧")
        let visiblePart = card.convert(card.bounds, to: clip).intersection(clip.bounds)
        guard !card.isHidden, card.frame == container.bounds,
              !visiblePart.isEmpty, visiblePart.height <= 81 else {
            throw TextFailure.failed("附件仅部分滚入首帧应先对齐当前容器再显示；hidden \(card.isHidden)，frame \(card.frame)，bounds \(container.bounds)，可见部分 \(visiblePart)")
        }
        let pixels = try harness.pixels()
        let painted = clip.convert(visiblePart, to: nil)
        var ink = 0
        for y in stride(from: painted.minY, to: painted.maxY, by: 1) {
            for x in stride(from: painted.minX, to: painted.maxX, by: 1) {
                let color = pixels.color(at: CGPoint(x: x, y: y))
                if color.r < 128 && color.g < 128 && color.b < 128 { ink += 1 }
            }
        }
        guard ink > 10 else { throw TextFailure.failed("部分滚入的代码附件没有实际绘出内容；深色像素 \(ink)") }

        state.width = 520
        try harness.wait("附件恢复原宽") { abs(textView.bounds.width - (520 + Metrics.inlineCodePadding * 2)) <= 1 }
        try harness.scroll(scroll, to: initialY)
        try checkIdentityAndState("恢复原宽并完整滚入")
        guard !card.isHidden, card.frame == container.bounds,
              container.bounds.size == expandedSize, try copySelection() == originalCopy else {
            throw TextFailure.failed("恢复原宽后附件尺寸、展开状态或跨附件原文复制发生变化")
        }
        print("通过：原生代码卡片展开后高 \(foldedHeight) → \(expandedSize.height)，屏外三次改宽保留占位/卡片/横滑/选区；仅露出 80 pt 时首帧同步尺寸且绘出 \(ink) 个深色像素，回原宽状态与复制原文恢复")
    }
}
