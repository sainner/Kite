import AppKit
import CoreText
import SwiftUI

// 验证 Mac 上能否用 NSTextView（TextKit 2）替代 SwiftUI Text 排 agent 回复的散文块，而外观一点不变。
//
// 窗口里左右两栏排同一段 Markdown：左栏是现在 App 用的 MarkdownView（真实源文件编进来），右栏是 ProseTextView
// （一个 NSTextView，属性串照 iPhone 的 SelectableMarkdown 搬成 AppKit）。自动模式按顺序跑七件事，能程序判定的写进
// report.txt，判定不了的把截图留在日志目录给人看；手动模式留按钮让人亲眼看。
//
// 构建与运行见 build.sh：./build.sh --auto <日志目录>，或 ./build.sh 手动看。

let defaultColumnWidth: CGFloat = 360
let columnGap: CGFloat = 24
let windowPadding: CGFloat = 24
let fullHeight: CGFloat = 900
let compactHeight: CGFloat = 420

/// 含标题、段落、粗斜体、行内代码、引用、有序无序列表、文件引用和网页链接；网页用 .invalid 域名，不会真去取站点图标。
let sample = """
## 排版对照 heading2

这是第一段，包含 **粗体**、*斜体*、***粗斜体*** 和 `inlineCode()` 行内代码，再接一个文件引用 app/Kite/UI/Markdown.swift 以及一个 [网页链接](https://example.invalid/docs)。这一段够长，会折成两行以上，用来比较行距和折行位置是否一致。

### 三级标题 heading3

> 引用里的一段话，左边有竖线，颜色是次要色。再多写一点让它折行，以比较竖线的高度、行距和缩进。

1. 第一项，有序列表，`code` 在列表里
2. 第二项折行测试：这一项的文字够长，折到第二行时要和正文对齐，而不是回到编号下面去
   - 嵌套的无序项
   - 另一个嵌套项，带 [链接](https://example.invalid/nested) 和 `code`

- 无序项 **粗体开头**
- 无序项末尾 `code`

# 一级标题 heading1

最后一段。Done.
"""

let shortSample = "右键对照：一段普通的字，`code` 和 **粗体**。"

// MARK: - 记录

/// 弹出的菜单：通知回调里记下，主线程定时器收掉。
enum MenuWatch {
    nonisolated(unsafe) static var pending: NSMenu?
    nonisolated(unsafe) static var began: [[String]] = []
}

/// 跨线程可读，看门狗超时也能把已有结果写出去。
enum Report {
    nonisolated(unsafe) static var lines: [String] = []
    nonisolated(unsafe) static var directory: String?

    nonisolated static func log(_ line: String) {
        lines.append(line)
        print(line)
    }

    nonisolated static func flush() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
    }
}

/// 一行文字在窗口里的位置，两边都换成这个比。
struct LineInfo: Equatable {
    var rect: CGRect
    var baseline: CGFloat
    var tags: String
    var text = ""
}

struct FrameSample {
    var t: Double
    var progress: CGFloat
    var textViewY: CGFloat
    var textViewPresentationY: CGFloat
    var textViewAlpha: CGFloat
    var textViewLayerOpacity: Float
    /// 从文本视图的层一路乘到窗口内容视图的层，SwiftUI 的 .opacity 落在哪一层都算进来。
    var effectiveOpacity: Float
    var size: CGSize
    var contentOffset: CGFloat
    var probeY: CGFloat
    var draws: Int
}

// MARK: - 模型

@MainActor @Observable
final class Model {
    var auto = false
    var tuned = false
    var progress: CGFloat = 0
    /// 上浮动画里只动位置、只动透明度，用来分辨逐帧重画是谁引起的。
    var risingOffset = true
    var risingOpacity = true
    var dark = false
    var height = fullHeight
    var columnWidth = defaultColumnWidth
    var scrollTarget: ScrollPosition?

    // 下面这些只有实验流程读，不参与视图刷新；逐帧写的进度尤其不能触发重算
    @ObservationIgnored var textView: ProseNSTextView?
    @ObservationIgnored var menuViewB: ProseNSTextView?
    @ObservationIgnored var menuViewC: ProseNSTextView?
    @ObservationIgnored var probe: ProbeView?
    @ObservationIgnored var overlayHits: [String: Int] = [:]
    @ObservationIgnored var swiftUILinks: [URL] = []
    @ObservationIgnored var textKitLinks: [URL] = []
    @ObservationIgnored var contextMenuPicks = 0
    @ObservationIgnored var contentOffset: CGFloat = 0
    /// 两栏正文（左 MarkdownView，右 ProseTextView）和两个红色标记在窗口里的位置（SwiftUI .global 坐标，y 向下）。
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var leftLines: [LineInfo] = []
    @ObservationIgnored var leftLinkRects: [(scheme: String, rect: CGRect)] = []
    @ObservationIgnored var swiftUIFonts: [String: Font.Resolved] = [:]
    @ObservationIgnored var risingProgress: [String: CGFloat] = [:]
}

/// 卡片里的一个 NSView，逐帧读它在窗口里的位置，作为「SwiftUI 怎么移动一个普通 NSView」的参照。
final class ProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var windowY: CGFloat { window == nil ? -1 : convert(bounds, to: nil).minY }
}

struct Probe: NSViewRepresentable {
    let model: Model
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        model.probe = view
        return view
    }
    func updateNSView(_ view: ProbeView, context: Context) {}
}

/// 复制自 app/Kite/Conversation/MessageActions.swift 的 SecondaryClickArea（private）：盖在上面只接右键的一层。
struct SecondaryClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.secondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { if Self.secondary(event) { action?() } }

        private static func secondary(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }
    }
}

/// 复制自 app/Kite/Conversation/MessageBubble.swift 的 Rising：气泡从下面 bubbleRise 处浮上来、淡显，progress 从 1 走到 0。
/// 多了一个把逐帧进度记下来的钩子。
struct Rising: ViewModifier, Animatable {
    var progress: CGFloat
    let side: String
    let model: Model

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        model.risingProgress[side] = progress
        return content
            .offset(y: model.risingOffset ? progress * Metrics.bubbleRise : 0)
            .opacity(model.risingOpacity ? 1 - progress : 1)
    }
}

// MARK: - 界面

struct Root: View {
    let model: Model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var position = ScrollPosition(edge: .top)

    static let blocks = MarkdownBlock.parse(sample)
    static var firstIsHeading: Bool { if case .heading = blocks.first?.kind { true } else { false } }
    static let shortBlocks = MarkdownBlock.parse(shortSample)
    static let scope = ReferenceScope(machineID: "machine", workspaceID: "workspace")

    private func attributed(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        ProseAttributes.build(blocks, scope: Self.scope, appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!,
                              linkColor: .linkColor, tint: NSColor(named: "AccentColor") ?? .controlAccentColor, tuned: model.tuned)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.auto { controls }
            ScrollView {
                VStack(alignment: .leading, spacing: columnGap) {
                    HStack(alignment: .top, spacing: columnGap) {
                        column("SwiftUI Text（现状）", side: "left") {
                            // 和 TranscriptView.AgentText 一样：MarkdownView 铺满一栏，右键盖一层 SecondaryClickArea
                            MarkdownView(sample)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Probe(model: model))
                                .contentShape(Rectangle())
                                .overlay { SecondaryClickArea { model.overlayHits["left", default: 0] += 1 } }
                                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                                    GeometryReader { proxy in
                                        let origin = proxy.frame(in: .global).origin
                                        let lines = layouts.flatMap { anchored -> [LineInfo] in
                                            let base = proxy[anchored.origin]
                                            return anchored.layout.map { line in
                                                let rect = line.typographicBounds.rect
                                                    .offsetBy(dx: base.x + origin.x, dy: base.y + origin.y)
                                                var tags: [String] = []
                                                if line.contains(where: { $0[InlineCodeAttribute.self] != nil }) { tags.append("code") }
                                                if line.contains(where: { $0[ReferenceLinkAttribute.self] != nil }) { tags.append("link") }
                                                return LineInfo(rect: rect, baseline: line.typographicBounds.origin.y + base.y + origin.y,
                                                                tags: tags.joined(separator: "+"))
                                            }
                                        }
                                        let links = layouts.flatMap { anchored -> [(String, CGRect)] in
                                            let base = proxy[anchored.origin]
                                            return anchored.layout.flatMap { line in
                                                line.compactMap { run -> (String, CGRect)? in
                                                    guard run[ReferenceLinkAttribute.self] != nil else { return nil }
                                                    let rect = run.typographicBounds.rect.offsetBy(dx: base.x + origin.x, dy: base.y + origin.y)
                                                    // 用字符内容认是哪个链接：网页链接含「链接」二字，文件引用是 Markdown.swift
                                                    return (rect.width > 60 ? "kite" : "https", rect)
                                                }
                                            }
                                        }
                                        Color.clear.onChange(of: lines, initial: true) {
                                            model.leftLines = lines
                                            model.leftLinkRects = links
                                        }
                                    }
                                }
                        }
                        column("NSTextView（TextKit 2）", side: "right") {
                            // 文本视图为背景留出绘制余量，外层抵消这段边距，正文宽度与起点不变（和 iPhone 一样）
                            ProseTextView(text: attributed(Self.blocks), onLink: { model.textKitLinks.append($0) },
                                          onMake: { model.textView = $0 })
                                .padding(.horizontal, -Metrics.inlineCodePadding)
                                // TextKit 不认第一段的 paragraphSpacingBefore；tuned 变体把标题开头那半个块距放到视图外面
                                .padding(.top, model.tuned && Self.firstIsHeading ? Metrics.markdownBlockGap(NSFont.preferredFont(forTextStyle: .body).pointSize) / 2 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .overlay { SecondaryClickArea { model.overlayHits["right", default: 0] += 1 } }
                        }
                    }
                    // 右键的另两种挂法：B 保留 NSTextView 自己的菜单再挂 SwiftUI contextMenu；C 不弹系统菜单再挂 contextMenu
                    HStack(alignment: .top, spacing: columnGap) {
                        ProseTextView(text: attributed(Self.shortBlocks), onMake: { model.menuViewB = $0 })
                            .padding(.horizontal, -Metrics.inlineCodePadding)
                            .frame(width: model.columnWidth)
                            .contextMenu { Button("自定义操作 B") { model.contextMenuPicks += 1 } }
                        ProseTextView(text: attributed(Self.shortBlocks), suppressMenu: true, onMake: { model.menuViewC = $0 })
                            .padding(.horizontal, -Metrics.inlineCodePadding)
                            .frame(width: model.columnWidth)
                            .contextMenu { Button("自定义操作 C") { model.contextMenuPicks += 1 } }
                    }
                    .font(Theme.secondary)
                }
                .padding(windowPadding)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in model.contentOffset = offset }
            .onChange(of: model.scrollTarget) { _, target in if let target { position = target } }
        }
        .font(Theme.body)
        .background(Theme.background)
        .frame(width: model.columnWidth * 2 + columnGap + windowPadding * 2, height: model.height)
        .ignoresSafeArea()
        .environment(\.referenceScope, Self.scope)
        .environment(\.openURL, OpenURLAction { url in
            model.swiftUILinks.append(url)
            return .handled
        })
        .preferredColorScheme(model.dark ? .dark : .light)
        .onAppear { recordFonts() }
        .task { if model.auto { await Experiment(model: model).run() } }
    }

    private func column<Content: View>(_ title: String, side: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Theme.secondary).foregroundStyle(.secondary)
                Spacer()
                // 纯红标记，截图里靶定这一栏的像素位置
                Color(red: 1, green: 0, blue: 0).frame(width: 8, height: 8)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frames["marker-\(side)"] = $0 }
            }
            content()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frames[side] = $0 }
                .modifier(Rising(progress: model.progress, side: side, model: model))
        }
        .frame(width: model.columnWidth)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("上浮 0.5 秒") {
                model.progress = 1
                DispatchQueue.main.async { withAnimation(.spring(.smooth(duration: 0.5))) { model.progress = 0 } }
            }
            Button("上浮 + 滚到底") {
                model.height = compactHeight
                model.scrollTarget = ScrollPosition(edge: .top)
                model.progress = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(.smooth(duration: 0.5))) {
                        model.progress = 0
                        model.scrollTarget = ScrollPosition(edge: .bottom)
                    }
                }
            }
            Button(model.dark ? "浅色" : "深色") { model.dark.toggle() }
            Button(model.columnWidth == defaultColumnWidth ? "变窄" : "变宽") { model.columnWidth = model.columnWidth == defaultColumnWidth ? 240 : defaultColumnWidth }
            Button(model.height == fullHeight ? "矮窗口" : "高窗口") { model.height = model.height == fullHeight ? compactHeight : fullHeight }
        }
        .buttonStyle(.bordered)
        .padding(8)
    }

    private func recordFonts() {
        let body = Theme.body.resolve(in: fontContext)
        model.swiftUIFonts = [
            "body": body,
            "heading1": Theme.heading1.resolve(in: fontContext),
            "heading2": Theme.heading2.resolve(in: fontContext),
            "heading3": Theme.heading3.resolve(in: fontContext),
            "inlineCode": InlineCodeStyle.font(relativeTo: body).resolve(in: fontContext),
            "inlineCodeBold": InlineCodeStyle.font(relativeTo: body).bold().resolve(in: fontContext),
            "bold": Theme.body.bold().resolve(in: fontContext),
            "italic": Theme.body.italic().resolve(in: fontContext),
        ]
    }
}

// MARK: - 实验

@MainActor
final class Experiment {
    let model: Model
    var window: NSWindow { NSApp.windows.first { $0.contentView != nil && $0.isVisible } ?? NSApp.windows.first! }
    var textView: ProseNSTextView { model.textView! }
    var samples: [FrameSample] = []
    var captures: [(t: Double, progress: CGFloat, contentOffset: CGFloat, image: CGImage)] = []
    var displayLink: CADisplayLink?
    var recordStart = Date()
    var menuBegan: [[String]] {
        get { MenuWatch.began }
        set { MenuWatch.began = newValue }
    }
    var menuObserver: NSObjectProtocol?

    init(model: Model) { self.model = model }

    func run() async {
        try? await Task.sleep(for: .seconds(1.0))
        // 合成的鼠标事件要窗口是 key 才会分发到视图（非 key 窗口的第一次点击只用来激活），所以先把自己提到前面
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.6))
        Report.log("App 已激活：\(NSApp.isActive)，窗口 key：\(window.isKeyWindow)")
        Report.log("# Mac TextKit 2 散文块实验 \(Date())\(model.tuned ? "（tuned 变体：块距减行距、标题固定行高、竖线顶边下移一个行距、代码背景按代码字体高、.standard 折行、开头标题外补半块距）" : "（照搬 iOS 属性串）")")
        Report.log("窗口 \(window.frame.size)，缩放 \(window.backingScaleFactor)")
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                MenuWatch.began.append(menu.items.map(\.title))
                MenuWatch.pending = menu
            }
        }
        // 弹出来的菜单收掉，不然跑不下去；在跟踪开始之后的下一轮再收，免得把 AppKit 的菜单状态搅乱。菜单跟踪是嵌套运行循环，定时器要加到 common 模式
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = MenuWatch.pending else { return }
                MenuWatch.pending = nil
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        await fonts()
        await appearance(dark: false)
        await decorations()
        await selection()
        await links()
        await rightClick()
        await rising(withScroll: false)
        await rising(withScroll: true)
        await risingDraws()
        await heights()
        await scrolling()
        await appearance(dark: true)
        Report.flush()
        NSApp.terminate(nil)
    }

    private func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: 0. 字体

    private func fonts() async {
        Report.log("\n## 0. 字体解析对照（SwiftUI Font.resolve 的 CTFont 与 AppKit NSFont）")
        let body = NSFont.preferredFont(forTextStyle: .body)
        let pairs: [(String, NSFont)] = [
            ("body", body),
            ("heading1", ProseAttributes.semibold(.title2)),
            ("heading2", ProseAttributes.semibold(.title3)),
            ("heading3", .preferredFont(forTextStyle: .headline)),
            ("inlineCode", ProseAttributes.inlineCodeFont(relativeTo: body)),
            ("inlineCodeBold", ProseAttributes.inlineCodeFont(relativeTo: NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.bold), size: 0)!)),
            ("bold", NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.bold), size: 0)!),
            ("italic", NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: 0)!),
        ]
        Report.log("| 用途 | SwiftUI：PostScript 名 / 字号 / 字重 | AppKit：PostScript 名 / 字号 / 字重 | 一致 |")
        Report.log("|---|---|---|---|")
        for (name, nsFont) in pairs {
            guard let resolved = model.swiftUIFonts[name] else { continue }
            let ct = resolved.ctFont
            let swiftUIName = CTFontCopyPostScriptName(ct) as String
            let appKitName = CTFontCopyPostScriptName(nsFont as CTFont) as String
            let swiftUIWeight = weight(of: ct), appKitWeight = weight(of: nsFont as CTFont)
            let same = swiftUIName == appKitName && abs(CTFontGetSize(ct) - nsFont.pointSize) < 0.01 && abs(swiftUIWeight - appKitWeight) < 0.01
            Report.log("| \(name) | \(swiftUIName) / \(fmt(CTFontGetSize(ct))) / \(fmt(swiftUIWeight)) | \(appKitName) / \(fmt(nsFont.pointSize)) / \(fmt(appKitWeight)) | \(same ? "是" : "否") |")
        }
        Report.log("字体度量（CoreText ascent / descent / leading，a+d；NSLayoutManager.defaultLineHeight）：")
        for (name, font) in pairs.prefix(4) {
            let ct = font as CTFont
            Report.log("- \(name)：\(fmt(CTFontGetAscent(ct))) / \(fmt(CTFontGetDescent(ct))) / \(fmt(CTFontGetLeading(ct)))，a+d \(fmt(CTFontGetAscent(ct) + CTFontGetDescent(ct)))；defaultLineHeight \(fmt(NSLayoutManager().defaultLineHeight(for: font)))")
        }
        let size = model.swiftUIFonts["body"]?.pointSize ?? 0
        Report.log("Metrics.markdownLineSpacing(\(fmt(size))) = \(fmt(Metrics.markdownLineSpacing(size)))，markdownBlockGap = \(fmt(Metrics.markdownBlockGap(size)))，listIndent = \(fmt(Metrics.listIndent))，listMarker = \(fmt(Metrics.listMarker))，inlineCodePadding = \(fmt(Metrics.inlineCodePadding))，inlineCodeRadius = \(fmt(Metrics.inlineCodeRadius))，inlineCodeFontScale = \(Metrics.inlineCodeFontScale)")
    }

    private func weight(of font: CTFont) -> CGFloat {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .nan
    }

    // MARK: 7. 外观对照

    private func appearance(dark: Bool) async {
        let name = dark ? "dark" : "light"
        Report.log("\n## 7. 外观对照（\(dark ? "深色" : "浅色")）")
        model.dark = dark
        model.progress = 0
        model.height = fullHeight
        model.columnWidth = defaultColumnWidth
        await settle(0.8)
        guard let image = Capture.window(window) else {
            Report.log("截不到窗口像素（CGWindowListCreateImage 返回空）")
            return
        }
        let shot = Capture.Bitmap(image)
        guard let mapping = shot.mapping(markers: [model.frames["marker-left"]!, model.frames["marker-right"]!], windowWidth: window.contentView!.bounds.width) else {
            Report.log("截图里找不到红色标记，无法对齐像素；整窗截图写到 \(name)-window.png")
            shot.write(to: Report.directory! + "/\(name)-window.png")
            return
        }
        Report.log("像素映射：缩放 \(fmt(mapping.scale))，偏移 \(fmt(mapping.offset.x)),\(fmt(mapping.offset.y))（与 onGeometryChange 的 .global 坐标比较）")

        let left = model.frames["left"]!, right = model.frames["right"]!
        let rightLines = textKitLines()
        let leftLines = model.leftLines.sorted { $0.rect.minY < $1.rect.minY }
        Report.log("正文高度：SwiftUI \(fmt(left.height))，NSTextView \(fmt(right.height))，差 \(fmt(right.height - left.height))")

        // 逐行几何：SwiftUI 的行按 y 重叠归并（列表的编号和正文是两个 Text），再与 TextKit 的行片段按顺序对
        let leftRows = merge(leftLines)
        Report.log("行数：SwiftUI \(leftRows.count)（归并前 \(leftLines.count) 个 Text 行），NSTextView \(rightLines.count)")
        Report.log("| # | SwiftUI y / 高 / 基线 / 右端 | NSTextView y / 高 / 基线 / 右端 | Δy | Δ高 | 基线在行内的位置 左/右 | 标记 | 这一行的字 |")
        Report.log("|---|---|---|---|---|---|---|---|")
        var worst = (dy: 0.0 as CGFloat, dh: 0.0 as CGFloat, db: 0.0 as CGFloat)
        for index in 0..<max(leftRows.count, rightLines.count) {
            let l = index < leftRows.count ? leftRows[index] : nil
            let r = index < rightLines.count ? rightLines[index] : nil
            func cell(_ line: LineInfo?, relativeTo frame: CGRect) -> String {
                guard let line else { return "—" }
                return "\(fmt(line.rect.minY - frame.minY)) / \(fmt(line.rect.height)) / \(fmt(line.baseline - frame.minY)) / \(fmt(line.rect.maxX - frame.minX))"
            }
            var deltas = ["", "", ""]
            if let l, let r {
                let dy = (r.rect.minY - right.minY) - (l.rect.minY - left.minY)
                let dh = r.rect.height - l.rect.height
                let db = (r.baseline - r.rect.minY) - (l.baseline - l.rect.minY)
                deltas = [fmt(dy), fmt(dh), "\(fmt(l.baseline - l.rect.minY)) / \(fmt(r.baseline - r.rect.minY))"]
                worst = (max(worst.dy, abs(dy)), max(worst.dh, abs(dh)), max(worst.db, abs(db)))
            }
            Report.log("| \(index + 1) | \(cell(l, relativeTo: left)) | \(cell(r, relativeTo: right)) | \(deltas.joined(separator: " | ")) | \(r?.tags ?? l?.tags ?? "") | \(r?.text ?? "") |")
        }
        Report.log("最大偏差：Δy \(fmt(worst.dy))，Δ行高 \(fmt(worst.dh))，基线在行内位置的差 \(fmt(worst.db))（单位 pt）；右端 x 不同的行说明折行位置不同")

        // 整栏像素对照：两栏裁成同样大小，逐像素比；排版位移会让每一行都算成不同，这张图看的是整体
        let height = max(left.height, right.height) + 8
        let leftCrop = shot.crop(CGRect(x: left.minX - 4, y: left.minY - 4, width: defaultColumnWidth + 8, height: height), mapping)
        let rightCrop = shot.crop(CGRect(x: right.minX - 4, y: right.minY - 4, width: defaultColumnWidth + 8, height: height), mapping)
        leftCrop.write(to: Report.directory! + "/\(name)-left.png")
        rightCrop.write(to: Report.directory! + "/\(name)-right.png")
        let diff = leftCrop.compare(rightCrop)
        diff.image.write(to: Report.directory! + "/\(name)-diff.png")
        Report.log("整栏像素对照（阈值 24/255）：不同像素 \(diff.changed) / \(diff.total)（\(String(format: "%.2f", Double(diff.changed) / Double(diff.total) * 100))%）；两栏行位置不同时这里必然大，看下面按基线对齐的逐行对照")

        // 逐行按基线对齐再比：排除行间距的差，只剩字形、字距、颜色、装饰
        let background = leftCrop.color(x: 2, y: 2)
        Report.log("逐行对照（每行按各自基线对齐裁出 基线-18…+8 的带子再比，第一个有墨像素的 x 相对正文左边）：")
        Report.log("| # | 不同像素 | 占比 | 允许整像素平移(dx,dy)后的占比 | 首墨 x 左/右 | 标记 |")
        Report.log("|---|---|---|---|---|---|")
        var stacked: [Capture.Bitmap] = []
        for (index, r) in rightLines.enumerated() {
            guard index < leftRows.count else { break }
            let l = leftRows[index]
            let bandL = CGRect(x: left.minX - 4, y: l.baseline - 18, width: defaultColumnWidth + 8, height: 26)
            let bandR = CGRect(x: right.minX - 4, y: r.baseline - 18, width: defaultColumnWidth + 8, height: 26)
            let cropL = shot.crop(bandL, mapping), cropR = shot.crop(bandR, mapping)
            let rowDiff = cropL.compare(cropR)
            let aligned = cropL.bestAlignment(cropR)
            let inkL = cropL.firstInkColumn(in: CGRect(x: 0, y: 0, width: defaultColumnWidth + 8, height: 26), scale: mapping.scale, background: background).map { $0 - 4 }
            let inkR = cropR.firstInkColumn(in: CGRect(x: 0, y: 0, width: defaultColumnWidth + 8, height: 26), scale: mapping.scale, background: background).map { $0 - 4 }
            Report.log("| \(index + 1) | \(rowDiff.changed) | \(String(format: "%.2f%%", Double(rowDiff.changed) / Double(rowDiff.total) * 100)) | \(aligned.dx),\(aligned.dy) → \(String(format: "%.2f%%", Double(aligned.changed) / Double(rowDiff.total) * 100)) | \(inkL.map(fmt) ?? "?") / \(inkR.map(fmt) ?? "?") | \(r.tags) |")
            stacked.append(cropL)
            stacked.append(cropR)
            stacked.append(rowDiff.image)
        }
        Capture.Bitmap.stack(stacked, columns: 3).write(to: Report.directory! + "/\(name)-rows.png")
        Report.log("逐行对照图：\(name)-rows.png（每行三格：左 SwiftUI、中 NSTextView、右 差异——红只左有、蓝只右有、紫都有但颜色不同）")

        // 颜色：链接文字、链接图标、引用文字取最饱和/最深的像素
        let linkRects = textKitLinkRects()
        if let r = linkRects.first(where: { $0.scheme == "https" }), let l = model.leftLinkRects.first(where: { $0.scheme == "https" }) {
            Report.log("网页链接文字颜色（最饱和像素）：SwiftUI \(shot.mostSaturated(in: l.rect, mapping))，NSTextView \(shot.mostSaturated(in: r.rect, mapping))；系统 linkColor \(Capture.describe(NSColor.linkColor, dark: dark))，App 主题色 \(Capture.describe(NSColor(named: "AccentColor")!, dark: dark))")
        }
        if let r = linkRects.first(where: { $0.scheme == "kite" }), let l = model.leftLinkRects.first(where: { $0.scheme == "kite" }) {
            let iconL = CGRect(x: l.rect.minX - 14, y: l.rect.minY, width: 14, height: l.rect.height)
            let iconR = CGRect(x: r.rect.minX - 14, y: r.rect.minY, width: 14, height: r.rect.height)
            Report.log("文件引用文字颜色：SwiftUI \(shot.mostSaturated(in: l.rect, mapping))，NSTextView \(shot.mostSaturated(in: r.rect, mapping))；文件图标颜色（文字左边 14pt）：SwiftUI \(shot.mostSaturated(in: iconL, mapping))，NSTextView \(shot.mostSaturated(in: iconR, mapping))")
        }
        if let quoteIndex = rightLines.firstIndex(where: { $0.tags.contains("quote") }), quoteIndex < leftRows.count {
            let r = rightLines[quoteIndex], l = leftRows[quoteIndex]
            Report.log("引用文字颜色（最深像素）：SwiftUI \(shot.darkest(in: CGRect(x: l.rect.minX + 14, y: l.rect.minY, width: 100, height: l.rect.height), mapping, dark: dark))，NSTextView \(shot.darkest(in: CGRect(x: r.rect.minX + 14, y: r.rect.minY, width: 100, height: r.rect.height), mapping, dark: dark))")
        }
        if let r = rightLines.first(where: { $0.tags == "code" }), let l = leftRows.first(where: { $0.tags == "code" }) {
            Report.log("正文颜色（最深像素）：SwiftUI \(shot.darkest(in: CGRect(x: l.rect.minX, y: l.rect.minY, width: 60, height: l.rect.height), mapping, dark: dark))，NSTextView \(shot.darkest(in: CGRect(x: r.rect.minX, y: r.rect.minY, width: 60, height: r.rect.height), mapping, dark: dark))")
        }
        Report.log("截图：\(name)-left.png、\(name)-right.png、\(name)-diff.png、\(name)-rows.png")
    }

    /// NSTextView 里每个链接文字（不含图标）在窗口里的位置。
    private func textKitLinkRects() -> [(scheme: String, rect: CGRect)] {
        guard let storage = textView.textStorage, let layout = textView.textLayoutManager else { return [] }
        var result: [(String, CGRect)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let textStart = (storage.string as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: "\u{FFFC}\u{2060}").inverted, options: [], range: range)
            guard textStart.location != NSNotFound,
                  let start = layout.location(layout.documentRange.location, offsetBy: textStart.location),
                  let end = layout.location(layout.documentRange.location, offsetBy: range.location + range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            var frame: CGRect?
            layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
                frame = frame.map { $0.union(rect) } ?? rect
                return true
            }
            guard let frame else { return }
            let origin = textView.textContainerOrigin
            let windowRect = textView.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: nil)
            let top = window.contentView!.bounds.height - windowRect.maxY
            result.append((url.scheme ?? "", CGRect(x: windowRect.minX, y: top, width: windowRect.width, height: windowRect.height)))
        }
        return result
    }

    /// NSTextView 里每个行片段在窗口里的位置。
    private func textKitLines() -> [LineInfo] {
        guard let layout = textView.textLayoutManager, let storage = textView.textStorage else { return [] }
        var lines: [LineInfo] = []
        let origin = textView.textContainerOrigin
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
                let local = bounds.offsetBy(dx: origin.x, dy: origin.y)
                let windowRect = textView.convert(local, to: nil)
                let top = window.contentView!.bounds.height - windowRect.maxY
                let baseline = top + line.glyphOrigin.y
                var tags: [String] = []
                let range = NSRange(location: layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location) + line.characterRange.location,
                                    length: line.characterRange.length)
                if range.location + range.length <= storage.length, range.length > 0 {
                    storage.enumerateAttributes(in: range) { attributes, _, _ in
                        if attributes[.inlineCodeDecoration] != nil, !tags.contains("code") { tags.append("code") }
                        if attributes[.link] != nil, !tags.contains("link") { tags.append("link") }
                    }
                    if storage.attribute(.quoteDecoration, at: range.location, effectiveRange: nil) != nil { tags.append("quote") }
                }
                let text = range.location + range.length <= storage.length ? (storage.string as NSString).substring(with: range) : ""
                lines.append(LineInfo(rect: CGRect(x: windowRect.minX, y: top, width: windowRect.width, height: windowRect.height),
                                      baseline: baseline, tags: tags.joined(separator: "+"),
                                      text: text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "▣").replacingOccurrences(of: "\u{2060}", with: "")))
            }
            return true
        }
        return lines
    }

    /// 同一行上的几个 Text（列表编号和正文）归并成一行。
    private func merge(_ lines: [LineInfo]) -> [LineInfo] {
        var rows: [LineInfo] = []
        for line in lines {
            if let last = rows.last, line.rect.minY < last.rect.maxY - 2, abs(line.baseline - last.baseline) < 2 {
                var merged = last
                merged.rect = last.rect.union(line.rect)
                merged.tags = [last.tags, line.tags].filter { !$0.isEmpty }.joined(separator: "+")
                rows[rows.count - 1] = merged
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    // MARK: 6. 装饰

    private func decorations() async {
        Report.log("\n## 6. 装饰（引用竖线、行内代码背景）")
        guard let image = Capture.window(window) else { return }
        let shot = Capture.Bitmap(image)
        guard let mapping = shot.mapping(markers: [model.frames["marker-left"]!, model.frames["marker-right"]!], windowWidth: window.contentView!.bounds.width) else { return }
        let right = model.frames["right"]!, left = model.frames["left"]!
        let rightLines = textKitLines()
        let leftRows = merge(model.leftLines.sorted { $0.rect.minY < $1.rect.minY })
        let background = shot.color(at: CGPoint(x: right.minX + 2, y: right.minY - 14), mapping)
        Report.log("背景色 \(background)")
        // 引用竖线：沿 x=1.5 从引用首行上方 8pt 往下扫
        if let quoteIndex = rightLines.firstIndex(where: { $0.tags.contains("quote") }), quoteIndex < leftRows.count {
            let r = rightLines[quoteIndex], l = leftRows[quoteIndex]
            let textKit = shot.color(at: CGPoint(x: right.minX + 1.5, y: r.rect.midY), mapping)
            let swiftUI = shot.color(at: CGPoint(x: left.minX + 1.5, y: l.rect.midY), mapping)
            Report.log("引用竖线取样（x=1.5pt，引用首行中部）：NSTextView \(textKit)，SwiftUI \(swiftUI)，背景 \(background)；NSTextView 画出来了：\(textKit != background ? "是" : "否")")
            let span = shot.verticalSpan(x: right.minX + 1.5, from: r.rect.minY - 8, to: r.rect.maxY + 40, background: background, mapping)
            let spanLeft = shot.verticalSpan(x: left.minX + 1.5, from: l.rect.minY - 8, to: l.rect.maxY + 40, background: background, mapping)
            Report.log("竖线纵向范围（相对各自引用首行的顶边）：NSTextView \(span.map { "\(fmt($0.lowerBound - r.rect.minY))…\(fmt($0.upperBound - r.rect.minY))（高 \(fmt($0.upperBound - $0.lowerBound))）" } ?? "没找到")，SwiftUI \(spanLeft.map { "\(fmt($0.lowerBound - l.rect.minY))…\(fmt($0.upperBound - l.rect.minY))（高 \(fmt($0.upperBound - $0.lowerBound))）" } ?? "没找到")；引用两行字的范围是 0…\(fmt(r.rect.height + Metrics.markdownLineSpacing(13) + (rightLines.count > quoteIndex + 1 ? rightLines[quoteIndex + 1].rect.height : 0)))")
        }
        // 行内代码背景：每个 code run 所在行的中线上，从字形左边 12pt 起往右扫，记背景块和墨的左右边
        if let storage = textView.textStorage, let layout = textView.textLayoutManager {
            var runs: [NSRange] = []
            storage.enumerateAttribute(.inlineCodeDecoration, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { runs.append(range) }
            }
            Report.log("行内代码背景块（pt，相对各栏左边；padding 应为 \(fmt(Metrics.inlineCodePadding))）：")
            for found in runs {
                guard let start = layout.location(layout.documentRange.location, offsetBy: found.location),
                      let end = layout.location(start, offsetBy: found.length), let textRange = NSTextRange(location: start, end: end) else { continue }
                var frame: CGRect?
                layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
                    frame = frame.map { $0.union(rect) } ?? rect
                    return true
                }
                guard let frame else { continue }
                let origin = textView.textContainerOrigin
                let windowRect = textView.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: nil)
                let top = window.contentView!.bounds.height - windowRect.maxY
                guard let rowIndex = rightLines.firstIndex(where: { $0.rect.minY <= top + 1 && $0.rect.maxY >= top + windowRect.height - 1 }), rowIndex < leftRows.count else { continue }
                let r = rightLines[rowIndex], l = leftRows[rowIndex]
                // 在基线上方 2pt 扫（字母 x 高度之内，背景块之内）
                let yR = r.baseline - 2, yL = l.baseline - 2
                // TextKit 给的段落片段左边约等于背景块左边；从它左边 2pt（还是背景）起往右扫
                let x0 = windowRect.minX - right.minX - 2, x1 = windowRect.maxX - right.minX + 40
                let extentR = shot.boxExtent(y: yR, from: right.minX + x0, to: right.minX + x1, background: background, mapping)
                let extentL = shot.boxExtent(y: yL, from: left.minX + x0, to: left.minX + x1, background: background, mapping)
                func describe(_ e: Capture.Bitmap.BoxExtent?, _ frame: CGRect) -> String {
                    guard let e else { return "没找到背景块" }
                    return "块 \(fmt(e.boxLeft - frame.minX))…\(fmt(e.boxRight - frame.minX))，墨 \(fmt(e.inkLeft - frame.minX))…\(fmt(e.inkRight - frame.minX))，左右 padding \(fmt(e.inkLeft - e.boxLeft)) / \(fmt(e.boxRight - e.inkRight))，块色 \(e.color)"
                }
                let text = (storage.string as NSString).substring(with: found)
                Report.log("- 行 \(rowIndex + 1)「\(text.replacingOccurrences(of: "\u{FFFC}", with: "▣").replacingOccurrences(of: "\u{2060}", with: ""))」TextKit 段落片段 x \(fmt(windowRect.minX - right.minX))…\(fmt(windowRect.maxX - right.minX))：NSTextView \(describe(extentR, right))；SwiftUI \(describe(extentL, left))")
                // DecoratedFragment 用 CoreText 重排这一行取字形位置；和 TextKit 自己的位置对一下，看附件、kern 会不会让两者漂移
                if let fragment = layout.textLayoutFragment(for: start) {
                    for line in fragment.textLineFragments where NSLocationInRange(found.location - layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location), line.characterRange) {
                        let typesetter = CTTypesetterCreateWithAttributedString(line.attributedString)
                        let shaped = CTTypesetterCreateLine(typesetter, CFRange(location: line.characterRange.location, length: line.characterRange.length))
                        let local = found.location - layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
                        for run in CTLineGetGlyphRuns(shaped) as! [CTRun] {
                            let runRange = CTRunGetStringRange(run)
                            guard runRange.location <= local, local < runRange.location + runRange.length else { continue }
                            var position = CGPoint.zero
                            CTRunGetPositions(run, CFRange(location: local - runRange.location, length: 1), &position)
                            let ctX = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + position.x
                            Report.log("  CoreText 重排得到首字形 x \(fmt(ctX))，TextKit 段落片段 x \(fmt(frame.minX))，差 \(fmt(ctX - frame.minX))（容器坐标）；行片段 typographicBounds \(line.typographicBounds)，glyphOrigin \(line.glyphOrigin)")
                        }
                    }
                }
                // 纵向：在块的左 padding 区扫
                if let e = extentR {
                    let xR = (e.boxLeft + e.inkLeft) / 2
                    let spanR = shot.verticalSpan(x: xR, from: r.rect.minY - 6, to: r.rect.maxY + 8, background: background, mapping)
                    let spanL = extentL.map { shot.verticalSpan(x: ($0.boxLeft + $0.inkLeft) / 2, from: l.rect.minY - 6, to: l.rect.maxY + 8, background: background, mapping) } ?? nil
                    Report.log("  纵向（相对各自这一行的顶边）：NSTextView \(spanR.map { "\(fmt($0.lowerBound - r.rect.minY))…\(fmt($0.upperBound - r.rect.minY))（高 \(fmt($0.upperBound - $0.lowerBound))）" } ?? "?")，SwiftUI \(spanL.map { "\(fmt($0.lowerBound - l.rect.minY))…\(fmt($0.upperBound - l.rect.minY))（高 \(fmt($0.upperBound - $0.lowerBound))）" } ?? "?")")
                }
            }
            // 附件图标本身：画进位图看颜色，顺便看 isTemplate
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let attachment = value as? NSTextAttachment, let image = attachment.image,
                      (storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.scheme == "kite" else { return }
                let size = NSSize(width: 32, height: 32)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                var darkest: NSColor?
                for y in 0..<32 { for x in 0..<32 { if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9, darkest == nil || c.brightnessComponent < darkest!.brightnessComponent { darkest = c } } }
                Report.log("文件图标附件：isTemplate \(image.isTemplate)，尺寸 \(fmt(image.size.width))×\(fmt(image.size.height))，自己画出来最深像素 \(darkest.map { Capture.describe($0, dark: false) } ?? "?")（应为链接色 \(Capture.describe(NSColor.linkColor, dark: false))）")
                stop.pointee = true
            }
        }
        Report.log("坐标系：DecoratedFragment 在 NSTextView（flipped）里按片段局部坐标画，和 iOS 版一字不改；竖线和背景块都在字的位置上，说明不用翻转。")
    }

    // MARK: 1. 跨段落选择与复制

    private func selection() async {
        Report.log("\n## 1. 跨段落选择与复制")
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let from = string.range(of: "折成两行以上").location
        let to = string.range(of: "竖线的高度").location
        guard from != NSNotFound, to != NSNotFound else { Report.log("样例里找不到定位文字"); return }
        let range = NSRange(location: from, length: to + "竖线的高度".count - from)
        textView.setSelectedRange(range)
        window.makeFirstResponder(textView)
        NSPasteboard.general.clearContents()
        textView.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        let expected = string.substring(with: range)
        Report.log("setSelectedRange 跨段落（第一段中部 → 引用中部，含三级标题）：选区长度 \(textView.selectedRange().length)，复制得到 \(copied.count) 字，与 textStorage 对应子串一致：\(copied == expected ? "是" : "否")")
        Report.log("复制内容（原样）：\(copied.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\u{FFFC}", with: "<附件>").replacingOccurrences(of: "\u{2060}", with: "<WJ>").replacingOccurrences(of: "\t", with: "<Tab>"))")
        Report.log("Cmd+C 走响应链（NSApp.sendAction copy:）：")
        NSPasteboard.general.clearContents()
        let sent = NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        let viaMenu = NSPasteboard.general.string(forType: .string) ?? ""
        Report.log("- sendAction 返回 \(sent)，剪贴板 \(viaMenu.count) 字，一致：\(viaMenu == expected ? "是" : "否")")

        // 鼠标拖选：从第一段拖到有序列表第二项，看 NSTextView 的跟踪循环吃不吃合成事件
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let a = point(ofCharacter: string.range(of: "粗斜体").location), b = point(ofCharacter: string.range(of: "回到编号下面").location)
        post(.leftMouseDown, at: a)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            post(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        post(.leftMouseUp, at: b)
        await settle(0.5)
        let dragged = textView.selectedRange()
        let text = dragged.length > 0 ? string.substring(with: dragged) : ""
        Report.log("合成鼠标拖选（第一段「粗斜体」→ 列表第二项「回到编号下面」）：选区 \(dragged)，开头「\(text.prefix(6))…」结尾「…\(text.suffix(6))」，跨过标题、引用和列表：\(text.contains("heading3") && text.contains("引用里") && text.contains("第一项") ? "是" : "否")")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
    }

    /// 某个字符在窗口里的位置（AppKit 窗口坐标，y 向上）。
    private func point(ofCharacter index: Int) -> CGPoint {
        guard let layout = textView.textLayoutManager, let start = layout.location(layout.documentRange.location, offsetBy: index),
              let end = layout.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else { return .zero }
        var frame = CGRect.zero
        layout.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            frame = rect
            return false
        }
        let origin = textView.textContainerOrigin
        let local = frame.offsetBy(dx: origin.x, dy: origin.y)
        let windowRect = textView.convert(local, to: nil)
        return CGPoint(x: windowRect.midX, y: windowRect.midY)
    }

    private func post(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: Int.random(in: 1...100_000), clickCount: 1, pressure: 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func click(at point: CGPoint, button: NSEvent.EventType = .leftMouseDown, flags: NSEvent.ModifierFlags = []) async {
        post(button, at: point, flags: flags)
        post(button == .rightMouseDown ? .rightMouseUp : .leftMouseUp, at: point, flags: flags)
        await settle(0.4)
    }

    // MARK: 2. 链接点击

    private func links() async {
        Report.log("\n## 2. 链接点击")
        guard let storage = textView.textStorage else { return }
        var web: NSRange?, file: NSRange?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            // 跳过附件字符和 WORD JOINER，点在文字上
            let textStart = (storage.string as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: "\u{FFFC}\u{2060}").inverted, options: [], range: range)
            guard textStart.location != NSNotFound else { return }
            if url.scheme == "https", web == nil { web = NSRange(location: textStart.location, length: range.length - (textStart.location - range.location)) }
            if url.scheme == "kite", file == nil { file = NSRange(location: textStart.location, length: range.length - (textStart.location - range.location)) }
        }
        model.textKitLinks = []
        if let web {
            await click(at: point(ofCharacter: web.location + web.length / 2))
            Report.log("点网页链接文字：delegate 收到 \(model.textKitLinks.map(\.absoluteString))")
        }
        if let file {
            let before = model.textKitLinks.count
            await click(at: point(ofCharacter: file.location + 1))
            Report.log("点文件引用文字：delegate 收到 \(model.textKitLinks.dropFirst(before).map(\.absoluteString))")
            // 点图标（附件字符）
            let iconIndex = file.location - 2
            if iconIndex >= 0, (storage.string as NSString).character(at: iconIndex) == 0xFFFC {
                let count = model.textKitLinks.count
                await click(at: point(ofCharacter: iconIndex))
                Report.log("点文件引用的图标（附件）：delegate 收到 \(model.textKitLinks.dropFirst(count).map(\.absoluteString))")
            }
        }
        let count = model.textKitLinks.count
        let plain = (storage.string as NSString).range(of: "最后一段").location
        await click(at: point(ofCharacter: plain + 1))
        Report.log("点非链接文字「最后一段」：delegate 收到 \(model.textKitLinks.count - count) 次（应为 0），点后选区 \(textView.selectedRange())")
        Report.log("SwiftUI 侧（左栏）这期间 openURL 收到 \(model.swiftUILinks.count) 次（应为 0，说明事件没串到左栏）")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: 3. 右键

    private func rightClick() async {
        Report.log("\n## 3. 右键与系统编辑菜单")
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        // A：App 现在的挂法，SecondaryClickArea 盖在 ProseTextView 上
        model.overlayHits = [:]
        textView.menuRequests = 0
        menuBegan = []
        await click(at: point(ofCharacter: string.range(of: "第一段").location), button: .rightMouseDown)
        Report.log("A. SecondaryClickArea 盖在 NSTextView 上，右键正文：操作栏回调 \(model.overlayHits["right"] ?? 0) 次，NSTextView.menu(for:) 被问 \(textView.menuRequests) 次，弹出的 NSMenu \(menuBegan.count) 个")
        // A 有选区时右键
        textView.setSelectedRange(NSRange(location: string.range(of: "第一段").location, length: 6))
        model.overlayHits = [:]
        textView.menuRequests = 0
        menuBegan = []
        await click(at: point(ofCharacter: string.range(of: "第一段").location + 2), button: .rightMouseDown)
        Report.log("A. 有选区时右键选中的字：操作栏回调 \(model.overlayHits["right"] ?? 0) 次，menu(for:) \(textView.menuRequests) 次，NSMenu \(menuBegan.count) 个；选区仍为 \(textView.selectedRange())")
        // Control+左键
        model.overlayHits = [:]
        await click(at: point(ofCharacter: string.range(of: "第一段").location), flags: [.control])
        Report.log("A. Control+左键：操作栏回调 \(model.overlayHits["right"] ?? 0) 次")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // C：menu(for:) 返回 nil + 外层 SwiftUI contextMenu（先于 B 做，免得 B 弹过的系统菜单影响它）
        if let viewC = model.menuViewC {
            for attempt in 1...2 {
                viewC.menuRequests = 0
                viewC.rightClicks = 0
                menuBegan = []
                let p = center(of: viewC)
                let hit = window.contentView?.hitTest(p)
                await click(at: p, button: .rightMouseDown)
                await settle(0.4)
                Report.log("C. menu(for:) 返回 nil + .contextMenu（第 \(attempt) 次，点处 hitTest 是 \(hit.map { String(describing: type(of: $0)) } ?? "nil")，就是 C 自己：\(hit === viewC)）：rightMouseDown 到达 \(viewC.rightClicks) 次，menu(for:) \(viewC.menuRequests) 次，弹出菜单 \(menuBegan.count) 个，菜单项：\(menuBegan.map { $0.filter { !$0.isEmpty }.prefix(8).joined(separator: "、") })，SwiftUI 的 contextMenu 出现：\(menuBegan.contains { $0.contains("自定义操作 C") } ? "是" : "否")")
            }
        }
        // B：不盖层，NSTextView 默认菜单 + 外层 SwiftUI contextMenu
        if let viewB = model.menuViewB {
            viewB.menuRequests = 0
            viewB.rightClicks = 0
            menuBegan = []
            let p = center(of: viewB)
            let hit = window.contentView?.hitTest(p)
            await click(at: p, button: .rightMouseDown)
            await settle(0.4)
            Report.log("B. 默认 NSTextView + .contextMenu（点处 hitTest 是 \(hit.map { String(describing: type(of: $0)) } ?? "nil")，就是 B 自己：\(hit === viewB)）：rightMouseDown 到达 \(viewB.rightClicks) 次，menu(for:) \(viewB.menuRequests) 次，弹出菜单 \(menuBegan.count) 个，菜单项：\(menuBegan.map { $0.filter { !$0.isEmpty }.prefix(8).joined(separator: "、") })，SwiftUI 的 contextMenu 出现：\(menuBegan.contains { $0.contains("自定义操作 B") } ? "是" : "否")")
        }
        // 系统编辑菜单的「拷贝」：NSTextView 作为第一响应者时 Edit 菜单里 copy: 可用
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        window.makeFirstResponder(textView)
        let copyItem = NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let enabled = textView.validateUserInterfaceItem(copyItem)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let disabled = textView.validateUserInterfaceItem(copyItem)
        Report.log("Edit 菜单 copy: 的可用性由 NSTextView 校验：有选区 \(enabled)，无选区 \(disabled)")
        let editMenu = NSApp.mainMenu?.items.first { $0.title == "Edit" || $0.title == "编辑" }?.submenu
        Report.log("App 主菜单里的 Edit 菜单：\(editMenu.map { $0.items.map(\.title).filter { !$0.isEmpty }.joined(separator: "、") } ?? "没有")")
        window.makeFirstResponder(nil)
    }

    private func center(of view: NSView) -> CGPoint {
        let rect = view.convert(view.bounds, to: nil)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: 4. 上浮动画

    private func rising(withScroll: Bool) async {
        Report.log("\n## 4. 上浮动画\(withScroll ? "（同时对话滚到底，和 ThreadPane.send 一样）" : "（只上浮）")")
        model.dark = false
        model.columnWidth = defaultColumnWidth
        model.height = withScroll ? compactHeight : fullHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        model.progress = 1
        await settle(0.6)
        let startTextViewY = textView.convert(textView.bounds, to: nil).minY
        let startProbeY = model.probe?.windowY ?? 0
        textView.drawCalls = 0
        textView.frameSizeChanges = 0
        textView.frameOriginChanges = 0
        samples = []
        captures = []
        recordStart = Date()
        let link = window.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        withAnimation(.spring(.smooth(duration: 0.5))) {
            model.progress = 0
            if withScroll { model.scrollTarget = ScrollPosition(edge: .bottom) }
        }
        try? await Task.sleep(for: .seconds(0.9))
        link.invalidate()
        displayLink = nil
        await settle(0.3)

        let endTextViewY = textView.convert(textView.bounds, to: nil).minY
        let endProbeY = model.probe?.windowY ?? 0
        let endOffset = model.contentOffset
        Report.log("起点（progress=1）NSTextView 窗口 y \(fmt(startTextViewY))，终点 \(fmt(endTextViewY))，差 \(fmt(endTextViewY - startTextViewY))（上浮 \(fmt(Metrics.bubbleRise))\(withScroll ? "，叠加滚动 \(fmt(endOffset))" : "，应等于 bubbleRise")）；探针 NSView 差 \(fmt(endProbeY - startProbeY))")
        Report.log("动画期间 NSTextView.draw 调用 \(textView.drawCalls) 次，setFrameOrigin 改了 \(textView.frameOriginChanges) 次，setFrameSize 改了 \(textView.frameSizeChanges) 次，记了 \(samples.count) 帧")
        Report.log("| t(ms) | progress | 期望偏移 | NSTextView 相对终点 | layer.presentation 相对终点 | 探针 NSView 相对终点 | 滚动偏移 | 期望 opacity | alpha | 自身层 opacity | 到窗口的累计 opacity | 累计 draw |")
        Report.log("|---|---|---|---|---|---|---|---|---|---|---|---|")
        var worst: CGFloat = 0, worstProbe: CGFloat = 0, worstOpacity: Float = 0
        for sample in samples {
            // AppKit 窗口坐标 y 向上：上浮剩 progress*32 表示视图在终点下方，窗口 y 小 progress*32；滚动把整列往上推，窗口 y 变大
            let expected = -sample.progress * Metrics.bubbleRise + (sample.contentOffset - endOffset)
            let actual = sample.textViewY - endTextViewY
            let presented = sample.textViewPresentationY - endTextViewY
            let probe = sample.probeY - endProbeY
            worst = max(worst, abs(actual - expected))
            worstProbe = max(worstProbe, abs(probe - expected))
            worstOpacity = max(worstOpacity, abs(sample.effectiveOpacity - Float(1 - sample.progress)))
            Report.log("| \(Int(sample.t * 1000)) | \(fmt(sample.progress)) | \(fmt(expected)) | \(fmt(actual)) | \(fmt(presented)) | \(fmt(probe)) | \(fmt(sample.contentOffset)) | \(fmt(1 - sample.progress)) | \(fmt(sample.textViewAlpha)) | \(String(format: "%.2f", sample.textViewLayerOpacity)) | \(String(format: "%.2f", sample.effectiveOpacity)) | \(sample.draws) |")
        }
        Report.log("NSTextView 的 frame 与「progress 推算的上浮 + 当帧滚动偏移」的最大偏差 \(fmt(worst)) pt；探针 NSView \(fmt(worstProbe)) pt；层的累计 opacity 与 1-progress 的最大偏差 \(String(format: "%.2f", worstOpacity))")

        // 像素：动画中途的截图里，一级标题那一行的墨相对动画结束后的位置移了多少、淡了多少
        guard let endImage = Capture.window(window) else { return }
        let end = Capture.Bitmap(endImage)
        guard let mapping = end.mapping(markers: [model.frames["marker-left"]!, model.frames["marker-right"]!], windowWidth: window.contentView!.bounds.width) ?? Capture.Mapping.fallback(end, window) else {
            Report.log("动画结束的截图里找不到标记，像素对照略过")
            return
        }
        let endName = "rise\(withScroll ? "-scroll" : "")-end.png"
        end.write(to: Report.directory! + "/" + endName)
        let rightLines = textKitLines()
        let leftRows = merge(model.leftLines.sorted { $0.rect.minY < $1.rect.minY })
        // 一级标题是倒数第二行
        guard rightLines.count >= 2, leftRows.count >= 2 else { return }
        let headingR = rightLines[rightLines.count - 2], headingL = leftRows[leftRows.count - 2]
        let left = model.frames["left"]!, right = model.frames["right"]!
        let background = end.color(at: CGPoint(x: right.minX + 2, y: right.minY - 14), mapping)
        func inkTop(_ bitmap: Capture.Bitmap, column: CGRect, around y: CGFloat, spread: CGFloat, opacity: CGFloat = 1) -> CGFloat? {
            // 淡显中的墨浅，阈值跟着期望的不透明度降
            bitmap.firstInkRow(in: CGRect(x: column.minX, y: y - spread, width: 200, height: spread * 2), mapping, background: background,
                               threshold: max(8, Int(40 * opacity)))
        }
        func intensity(_ bitmap: Capture.Bitmap, column: CGRect, top: CGFloat) -> Double {
            bitmap.inkIntensity(in: CGRect(x: column.minX, y: top, width: 200, height: 22), mapping, background: background)
        }
        guard let endTopL = inkTop(end, column: left, around: headingL.rect.minY, spread: 6),
              let endTopR = inkTop(end, column: right, around: headingR.rect.minY, spread: 6) else {
            Report.log("结束截图里找不到一级标题的墨（左 \(fmt(headingL.rect.minY)) 右 \(fmt(headingR.rect.minY))），像素对照略过")
            return
        }
        for (index, capture) in captures.enumerated() {
            let shot = Capture.Bitmap(capture.image)
            let name = "rise\(withScroll ? "-scroll" : "")-\(index).png"
            shot.write(to: Report.directory! + "/" + name)
            // 跟着上浮的话，这一帧的墨在结束位置下方 progress*32（.global 坐标 y 向下），再加上滚动还没滚完的那一段
            let scrollRemaining = endOffset - capture.contentOffset
            let expectedShift = capture.progress * Metrics.bubbleRise + scrollRemaining
            func describe(_ side: String, column: CGRect, endTop: CGFloat) -> String {
                let near = inkTop(shot, column: column, around: endTop + expectedShift, spread: 8, opacity: 1 - capture.progress)
                let wide = near ?? inkTop(shot, column: column, around: endTop + expectedShift - 20, spread: 28, opacity: 1 - capture.progress)
                let ratio = intensity(shot, column: column, top: (wide ?? endTop + expectedShift)) / max(intensity(end, column: column, top: endTop), 1)
                let shift = wide.map { $0 - endTop }
                return "\(side)：墨顶边相对结束位置 \(shift.map(fmt) ?? "找不到")（期望 \(fmt(expectedShift))，其中滚动 \(fmt(scrollRemaining))）\(near == nil ? "，期望位置 ±8pt 内没有墨" : "")；墨量是结束时的 \(String(format: "%.0f%%", ratio * 100))（期望约 \(String(format: "%.0f%%", (1 - capture.progress) * 100))）"
            }
            Report.log("截图 \(name)（t=\(Int(capture.t * 1000))ms，progress \(fmt(capture.progress))）：")
            Report.log("- 左栏 SwiftUI Text（textSelection 开着）\(describe("", column: left, endTop: endTopL))")
            Report.log("- 右栏 NSTextView \(describe("", column: right, endTop: endTopR))")
        }
        model.height = fullHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.5)
    }

    /// 逐帧重画是位置还是透明度引起的：分别只动一样，数 draw。
    private func risingDraws() async {
        Report.log("\n## 4b. 上浮动画期间 NSTextView 为什么逐帧重画")
        model.height = fullHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.5)
        let idleStart = textView.drawCalls
        await settle(0.9)
        Report.log("静止 0.9 秒：draw \(textView.drawCalls - idleStart) 次")
        for (name, offset, opacity) in [("只动位置（offset）", true, false), ("只动透明度（opacity）", false, true), ("位置加透明度", true, true)] {
            model.risingOffset = offset
            model.risingOpacity = opacity
            model.progress = 1
            await settle(0.4)
            let start = textView.drawCalls
            let originStart = textView.frameOriginChanges, sizeStart = textView.frameSizeChanges
            withAnimation(.spring(.smooth(duration: 0.5))) { model.progress = 0 }
            await settle(0.9)
            Report.log("\(name)：0.5 秒弹簧期间 draw \(textView.drawCalls - start) 次，setFrameOrigin \(textView.frameOriginChanges - originStart) 次，setFrameSize \(textView.frameSizeChanges - sizeStart) 次")
        }
        model.risingOffset = true
        model.risingOpacity = true
        // 只滚动：对话滚到底时所有消息都在动，看 NSTextView 会不会跟着逐帧重画
        model.height = compactHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.5)
        let scrollStart = textView.drawCalls
        withAnimation(.spring(.smooth(duration: 0.5))) { model.scrollTarget = ScrollPosition(edge: .bottom) }
        await settle(0.9)
        Report.log("只滚动（scrollTo 底部，0.5 秒弹簧）：draw \(textView.drawCalls - scrollStart) 次")
        model.height = fullHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.5)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = Date().timeIntervalSince(recordStart)
        let presentation = textView.layer?.presentation()
        let presentationY: CGFloat
        if let presentation, let superview = textView.superview {
            presentationY = superview.convert(presentation.frame, to: nil).minY
        } else {
            presentationY = textView.convert(textView.bounds, to: nil).minY
        }
        var effective: Float = 1
        var layer = textView.layer
        while let current = layer {
            effective *= (current.presentation() ?? current).opacity
            layer = current.superlayer
        }
        samples.append(FrameSample(t: t, progress: model.risingProgress["right"] ?? -1,
                                   textViewY: textView.convert(textView.bounds, to: nil).minY,
                                   textViewPresentationY: presentationY,
                                   textViewAlpha: textView.alphaValue, textViewLayerOpacity: presentation?.opacity ?? textView.layer?.opacity ?? -1,
                                   effectiveOpacity: effective, size: textView.frame.size, contentOffset: model.contentOffset,
                                   probeY: model.probe?.windowY ?? 0, draws: textView.drawCalls))
        if (captures.isEmpty && t > 0.10) || (captures.count == 1 && t > 0.22) {
            if let image = Capture.window(window) {
                captures.append((t, model.risingProgress["right"] ?? -1, model.contentOffset, image))
            }
        }
    }

    // MARK: 5. 高度自适应

    private func heights() async {
        Report.log("\n## 5. 高度自适应")
        model.progress = 0
        model.height = fullHeight
        func check(_ label: String) {
            let left = model.frames["left"]!, right = model.frames["right"]!
            let usage = textView.textLayoutManager?.usageBoundsForTextContainer.height ?? 0
            let lastLine = textKitLines().last.map { $0.rect.maxY - right.minY } ?? 0
            Report.log("\(label)：sizeThatFits 被问 \(textView.sizeQueriesReport) 次、实际排版量了 \(textView.measurementsReport) 次；栏宽 \(fmt(model.columnWidth))，NSTextView frame 宽 \(fmt(textView.frame.width))（含两侧 \(fmt(Metrics.inlineCodePadding)) 余量）高 \(fmt(textView.frame.height))，TextKit usage 高 \(fmt(usage))，最后一行底边 \(fmt(lastLine))，SwiftUI 侧同宽高度 \(fmt(left.height))；高度正确：\(abs(textView.frame.height - ceil(usage)) <= 1 && lastLine <= textView.frame.height + 0.5 ? "是" : "否")")
        }
        await settle(0.3)
        check("宽 360")
        model.columnWidth = 240
        await settle(0.6)
        check("改窄到 240")
        model.columnWidth = defaultColumnWidth
        await settle(0.6)
        check("改回 360")
    }

    // MARK: 5b. 滚轮

    private func scrolling() async {
        Report.log("\n## 5b. 放进 ScrollView：滚轮穿过 NSTextView")
        model.height = compactHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.6)
        let before = model.contentOffset
        let center = center(of: textView)
        let hit = window.contentView?.hitTest(center)
        Report.log("NSTextView 中心的 hitTest 命中：\(hit.map { String(describing: type(of: $0)) } ?? "nil")；enclosingScrollView：\(textView.enclosingScrollView.map { String(describing: type(of: $0)) } ?? "nil")")
        textView.scrollWheelEvents = 0
        // 滚轮事件没有公开构造器，经 CGEvent 转
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -6, wheel2: 0, wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: center)
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        // 直接交给命中的视图，等于事件分发到它身上
        (hit ?? textView).scrollWheel(with: event)
        await settle(0.6)
        Report.log("向下滚 6 行：外层 ScrollView 的 contentOffset \(fmt(before)) → \(fmt(model.contentOffset))，NSTextView.scrollWheel 收到 \(textView.scrollWheelEvents) 次，自己没有滚动范围（不在 NSScrollView 里）")
        model.height = fullHeight
        model.scrollTarget = ScrollPosition(edge: .top)
        await settle(0.4)
    }
}

extension ProseNSTextView {
    var measurementsReport: String {
        (delegate as? ProseTextView.Coordinator).map { "\($0.measurements)" } ?? "?"
    }
    var sizeQueriesReport: String {
        (delegate as? ProseTextView.Coordinator).map { "\($0.sizeQueries)" } ?? "?"
    }
}

func fmt(_ value: CGFloat) -> String { String(format: "%.2f", value) }

// MARK: - 截图

enum Capture {
    typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// 抓自己窗口的像素；符号在 SDK 里标了弃用，经 dlsym 调，不需要录屏权限（见 .kite/memory/performance-diagnosis.md）。
    static func window(_ window: NSWindow) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowListOption.optionIncludingWindow.rawValue
        let imageOptions = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return create(.null, options, CGWindowID(window.windowNumber), imageOptions)?.takeRetainedValue()
    }

    struct Mapping {
        var scale: CGFloat
        var offset: CGPoint
        func pixel(_ point: CGPoint) -> (x: Int, y: Int) {
            (Int((point.x * scale + offset.x).rounded()), Int((point.y * scale + offset.y).rounded()))
        }
        /// 找不到标记时（滚动后标记不在视口里）按窗口尺寸直接换算：整窗截图与内容视图同原点。
        static func fallback(_ bitmap: Bitmap, _ window: NSWindow) -> Mapping? {
            guard let content = window.contentView else { return nil }
            return Mapping(scale: CGFloat(bitmap.width) / content.bounds.width, offset: .zero)
        }
    }

    static func describe(_ color: NSColor, dark: Bool) -> String {
        var result = "?"
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                result = Color(r: Int((rgb.redComponent * 255).rounded()), g: Int((rgb.greenComponent * 255).rounded()), b: Int((rgb.blueComponent * 255).rounded())).description
            }
        }
        return result
    }

    struct Color: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
        func distance(to other: Color) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
    }

    struct Band { var minY: CGFloat; var maxY: CGFloat; var count: Int }

    final class Bitmap {
        let width: Int, height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = buffer
        }

        init(width: Int, height: Int, data: [UInt8]) {
            self.width = width
            self.height = height
            self.data = data
        }

        func color(x: Int, y: Int) -> Color {
            guard x >= 0, y >= 0, x < width, y < height else { return Color(r: -1, g: -1, b: -1) }
            let i = (y * width + x) * 4
            return Color(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
        }

        func color(at point: CGPoint, _ mapping: Mapping) -> Color {
            let p = mapping.pixel(point)
            return color(x: p.x, y: p.y)
        }

        /// pt → 像素的映射：缩放按截图宽度除以窗口内容宽度，偏移按左边那个纯红标记在截图里的位置；再用右边的标记核对。
        func mapping(markers: [CGRect], windowWidth: CGFloat) -> Mapping? {
            let scale = CGFloat(width) / windowWidth
            var first: (x: Int, y: Int)?
            search: for y in 0..<height {
                for x in 0..<width where color(x: x, y: y) == Color(r: 255, g: 0, b: 0) {
                    first = (x, y)
                    break search
                }
            }
            guard let first else { return nil }
            let mapping = Mapping(scale: scale, offset: CGPoint(x: CGFloat(first.x) - markers[0].minX * scale, y: CGFloat(first.y) - markers[0].minY * scale))
            let check = mapping.pixel(CGPoint(x: markers[1].midX, y: markers[1].midY))
            guard color(x: check.x, y: check.y) == Color(r: 255, g: 0, b: 0) else { return nil }
            return mapping
        }

        func crop(_ rect: CGRect, _ mapping: Mapping) -> Bitmap {
            let origin = mapping.pixel(rect.origin)
            let w = Int((rect.width * mapping.scale).rounded()), h = Int((rect.height * mapping.scale).rounded())
            var out = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = origin.x + x, sy = origin.y + y
                    let o = (y * w + x) * 4
                    if sx >= 0, sy >= 0, sx < width, sy < height {
                        let i = (sy * width + sx) * 4
                        out[o] = data[i]; out[o + 1] = data[i + 1]; out[o + 2] = data[i + 2]; out[o + 3] = 255
                    } else {
                        out[o + 3] = 255
                    }
                }
            }
            return Bitmap(width: w, height: h, data: out)
        }

        struct Comparison {
            var image: Bitmap
            var changed: Int
            var strong: Int
            var total: Int
            var rows: [Int]
            func bands(scale: CGFloat, top: CGFloat) -> [Band] {
                var bands: [Band] = []
                var current: (start: Int, end: Int, count: Int)?
                for (y, count) in rows.enumerated() {
                    if count > 0 {
                        if let c = current, y <= c.end + Int(2 * scale) { current = (c.start, y, c.count + count) } else {
                            if let c = current { bands.append(Band(minY: CGFloat(c.start) / scale - top, maxY: CGFloat(c.end + 1) / scale - top, count: c.count)) }
                            current = (y, y, count)
                        }
                    }
                }
                if let c = current { bands.append(Band(minY: CGFloat(c.start) / scale - top, maxY: CGFloat(c.end + 1) / scale - top, count: c.count)) }
                return bands
            }
        }

        /// 逐像素比：差图里相同处淡灰，只有左边有墨的红、只有右边有墨的蓝，都有但颜色不同的紫。
        func compare(_ other: Bitmap) -> Comparison {
            let w = min(width, other.width), h = min(height, other.height)
            var out = [UInt8](repeating: 255, count: w * h * 4)
            var changed = 0, strong = 0
            var rows = [Int](repeating: 0, count: h)
            let background = color(x: 2, y: 2)
            for y in 0..<h {
                for x in 0..<w {
                    let a = color(x: x, y: y), b = other.color(x: x, y: y)
                    let d = a.distance(to: b)
                    let o = (y * w + x) * 4
                    if d <= 24 {
                        let ink = a.distance(to: background)
                        let v = UInt8(255 - min(ink, 255) / 3)
                        out[o] = v; out[o + 1] = v; out[o + 2] = v
                    } else {
                        changed += 1
                        rows[y] += 1
                        if d > 96 { strong += 1 }
                        let aInk = a.distance(to: background) > 24, bInk = b.distance(to: background) > 24
                        if aInk && !bInk { out[o] = 220; out[o + 1] = 40; out[o + 2] = 40 }
                        else if bInk && !aInk { out[o] = 40; out[o + 1] = 90; out[o + 2] = 230 }
                        else { out[o] = 170; out[o + 1] = 60; out[o + 2] = 200 }
                    }
                }
            }
            return Comparison(image: Bitmap(width: w, height: h, data: out), changed: changed, strong: strong, total: w * h, rows: rows)
        }

        /// 两张图允许 ±3 像素平移再比，取差最少的：排除亚像素相位带来的整像素错位，剩下的才是字形本身的差。
        func bestAlignment(_ other: Bitmap) -> (dx: Int, dy: Int, changed: Int) {
            var best = (dx: 0, dy: 0, changed: Int.max)
            let w = min(width, other.width), h = min(height, other.height)
            for dy in -3...3 {
                for dx in -3...3 {
                    var changed = 0
                    for y in max(0, -dy)..<min(h, h - dy) {
                        for x in max(0, -dx)..<min(w, w - dx) where color(x: x, y: y).distance(to: other.color(x: x + dx, y: y + dy)) > 24 { changed += 1 }
                    }
                    if changed < best.changed { best = (dx, dy, changed) }
                }
            }
            return best
        }

        /// 某一列从上往下扫，找与背景不同的连续一段。
        func verticalSpan(x: CGFloat, from: CGFloat, to: CGFloat, background: Color, _ mapping: Mapping) -> ClosedRange<CGFloat>? {
            let px = mapping.pixel(CGPoint(x: x, y: 0)).x
            var start: Int?, end: Int?
            for py in mapping.pixel(CGPoint(x: 0, y: from)).y...mapping.pixel(CGPoint(x: 0, y: to)).y {
                let ink = color(x: px, y: py).distance(to: background) > 6
                if ink { if start == nil { start = py }; end = py } else if start != nil { break }
            }
            guard let start, let end else { return nil }
            return (CGFloat(start) - mapping.offset.y) / mapping.scale...(CGFloat(end + 1) - mapping.offset.y) / mapping.scale
        }

        /// 区域里第一行有墨的像素行（pt）。
        func firstInkRow(in rect: CGRect, _ mapping: Mapping, background: Color, threshold: Int = 40) -> CGFloat? {
            let origin = mapping.pixel(rect.origin)
            let w = Int(rect.width * mapping.scale), h = Int(rect.height * mapping.scale)
            for y in 0..<h {
                var ink = 0
                for x in 0..<w where color(x: origin.x + x, y: origin.y + y).distance(to: background) > threshold { ink += 1 }
                if ink >= 3 { return (CGFloat(origin.y + y) - mapping.offset.y) / mapping.scale }
            }
            return nil
        }

        struct BoxExtent { var boxLeft: CGFloat; var boxRight: CGFloat; var inkLeft: CGFloat; var inkRight: CGFloat; var color: Color }

        /// 沿一条横线扫：淡于背景但不是字的像素算背景块，深的算墨。
        func boxExtent(y: CGFloat, from: CGFloat, to: CGFloat, background: Color, _ mapping: Mapping) -> BoxExtent? {
            let py = mapping.pixel(CGPoint(x: 0, y: y)).y
            var boxLeft: Int?, boxRight: Int?, inkLeft: Int?, inkRight: Int?, boxColor: Color?
            for px in mapping.pixel(CGPoint(x: from, y: 0)).x...mapping.pixel(CGPoint(x: to, y: 0)).x {
                let c = color(x: px, y: py)
                let d = c.distance(to: background)
                if d > 3 {
                    if boxLeft == nil { boxLeft = px; boxColor = c }
                    boxRight = px
                    if d > 60 {
                        if inkLeft == nil { inkLeft = px }
                        inkRight = px
                    }
                } else if boxLeft != nil, let right = boxRight, px > right + Int(1.0 * mapping.scale) {
                    break
                }
            }
            guard let boxLeft, let boxRight, let boxColor else { return nil }
            func pt(_ v: Int) -> CGFloat { (CGFloat(v) - mapping.offset.x) / mapping.scale }
            return BoxExtent(boxLeft: pt(boxLeft), boxRight: pt(boxRight + 1), inkLeft: pt(inkLeft ?? boxLeft), inkRight: pt((inkRight ?? boxRight) + 1), color: boxColor)
        }

        /// 区域里最靠左的有墨像素列（相对位图左边，pt）。
        func firstInkColumn(in rect: CGRect, scale: CGFloat, background: Color) -> CGFloat? {
            let x0 = max(Int(rect.minX * scale), 0), y0 = max(Int(rect.minY * scale), 0)
            let x1 = min(Int(rect.maxX * scale), width), y1 = min(Int(rect.maxY * scale), height)
            guard x1 > x0, y1 > y0 else { return nil }
            for x in x0..<x1 {
                for y in y0..<y1 where color(x: x, y: y).distance(to: background) > 40 { return CGFloat(x) / scale }
            }
            return nil
        }

        /// 区域里墨的总量（与背景的距离之和），比较淡显程度。
        func inkIntensity(in rect: CGRect, _ mapping: Mapping, background: Color) -> Double {
            let origin = mapping.pixel(rect.origin)
            let w = Int(rect.width * mapping.scale), h = Int(rect.height * mapping.scale)
            var total = 0
            for y in 0..<h { for x in 0..<w { total += color(x: origin.x + x, y: origin.y + y).distance(to: background) } }
            return Double(total)
        }

        /// 区域里与背景差得最多的像素颜色（取最深的几个的平均）。
        func dominantInk(in rect: CGRect, scale: CGFloat) -> String {
            let x0 = Int(rect.minX * scale), y0 = Int(rect.minY * scale), w = Int(rect.width * scale), h = Int(rect.height * scale)
            let background = color(x: 2, y: 2)
            var inks: [(Int, Color)] = []
            for y in 0..<h { for x in 0..<w { let c = color(x: x0 + x, y: y0 + y); inks.append((c.distance(to: background), c)) } }
            let top = inks.sorted { $0.0 > $1.0 }.prefix(12).map(\.1)
            guard !top.isEmpty else { return "?" }
            return Color(r: top.map(\.r).reduce(0, +) / top.count, g: top.map(\.g).reduce(0, +) / top.count, b: top.map(\.b).reduce(0, +) / top.count).description
        }

        /// 把几张位图按列排成一张（宽度按最宽的，列间 4 像素，行间 4 像素）。
        static func stack(_ bitmaps: [Bitmap], columns: Int) -> Bitmap {
            guard !bitmaps.isEmpty else { return Bitmap(width: 1, height: 1, data: [0, 0, 0, 255]) }
            let cellW = bitmaps.map(\.width).max()!, cellH = bitmaps.map(\.height).max()!
            let rows = (bitmaps.count + columns - 1) / columns
            let w = cellW * columns + 4 * (columns - 1), h = cellH * rows + 4 * (rows - 1)
            var out = [UInt8](repeating: 128, count: w * h * 4)
            for (index, bitmap) in bitmaps.enumerated() {
                let ox = (index % columns) * (cellW + 4), oy = (index / columns) * (cellH + 4)
                for y in 0..<bitmap.height {
                    for x in 0..<bitmap.width {
                        let i = (y * bitmap.width + x) * 4, o = ((oy + y) * w + ox + x) * 4
                        out[o] = bitmap.data[i]; out[o + 1] = bitmap.data[i + 1]; out[o + 2] = bitmap.data[i + 2]; out[o + 3] = 255
                    }
                }
            }
            return Bitmap(width: w, height: h, data: out)
        }

        /// 区域里最饱和的像素（通道差最大），用来找彩色的链接文字。
        func mostSaturated(in rect: CGRect, _ mapping: Mapping) -> String {
            let o = mapping.pixel(rect.origin)
            let w = Int(rect.width * mapping.scale), h = Int(rect.height * mapping.scale)
            var best: (Int, Color)?
            for y in 0..<h {
                for x in 0..<w {
                    let c = color(x: o.x + x, y: o.y + y)
                    let saturation = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
                    if best == nil || saturation > best!.0 { best = (saturation, c) }
                }
            }
            return best.map { "\($0.1)（饱和度 \($0.0)）" } ?? "?"
        }

        /// 区域里与背景差最大的像素（深色外观下是最亮的）。
        func darkest(in rect: CGRect, _ mapping: Mapping, dark: Bool) -> String {
            let o = mapping.pixel(rect.origin)
            let w = Int(rect.width * mapping.scale), h = Int(rect.height * mapping.scale)
            var best: Color?
            for y in 0..<h {
                for x in 0..<w {
                    let c = color(x: o.x + x, y: o.y + y)
                    if best == nil || (dark ? c.r + c.g + c.b > best!.r + best!.g + best!.b : c.r + c.g + c.b < best!.r + best!.g + best!.b) { best = c }
                }
            }
            return best?.description ?? "?"
        }

        func write(to path: String) {
            var copy = data
            guard let context = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 入口

@main
struct MacTextKitProseSpike: App {
    @State private var model: Model = {
        let model = Model()
        let args = CommandLine.arguments
        model.tuned = args.contains("--tuned")
        DecoratedFragment.codeBoxFollowsRunFont = model.tuned
        if let index = args.firstIndex(of: "--auto"), index + 1 < args.count {
            model.auto = true
            Report.directory = args[index + 1]
            try? FileManager.default.createDirectory(atPath: args[index + 1], withIntermediateDirectories: true)
            // 看门狗：弹出的菜单收不掉或事件卡住时，把已有结果写出去再退出
            Thread.detachNewThread {
                sleep(120)
                Report.lines.append("\n看门狗：120 秒未完成，强制退出")
                Report.flush()
                _exit(2)
            }
        }
        return model
    }()

    var body: some Scene {
        Window("Mac TextKit 2 散文块实验", id: "spike") {
            Root(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
