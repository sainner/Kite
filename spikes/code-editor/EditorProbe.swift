#if DEBUG
// 代码编辑器上色的验证探针（2026-10-23），用法见 spikes/code-editor/README.md：上色跟不跟得上打字、画没画错、各步多久。
// -editorProbe normal|big，报告写回缓存目录、Mac 上同时打到终端
import SwiftUI
import SwiftTreeSitter
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum EditorProbe {
    static var source: String? { UserDefaults.standard.string(forKey: "editorProbe") }
    static var isRequested: Bool { source != nil }

    static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// 报告写进缓存目录（iOS 用 devicectl 取回），Mac 上同时打到终端。
    static var reportURL: URL { caches.appendingPathComponent("editor-probe-\(source!).txt") }

    /// 测试用的代码：一段有代表性的 Swift 反复接起来，normal 约 900 行，big 约 2 MB。
    static var text: String {
        let repeats = source == "big" ? 2_000_000 / sample.utf8.count : 900 / sample.split(separator: "\n").count
        return (0..<repeats).map { sample.replacingOccurrences(of: "Sample", with: "Sample\($0)") }.joined()
    }

    private static let sample = #"""
    import SwiftUI

    /// 浏览窗口的一段示例：目录、文件内容和控制区。注释里有中文，字符串里也有。
    struct SampleView: View {
        @State private var query = ""
        @State private var selection: Set<String> = []
        let items: [String]
        var limit = 200

        var body: some View {
            List(filtered, id: \.self, selection: $selection) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.hasSuffix(".swift") ? "swift" : "doc.text")
                    Text(item).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if selection.contains(item) { Text("已选").foregroundStyle(.secondary) }
                }
            }
            .searchable(text: $query, prompt: "搜索文件")
            .onChange(of: query) { _, new in
                guard !new.isEmpty else { return }
                print("搜索：\(new)，共 \(filtered.count) 个")
            }
        }

        /// 按名字过滤，最多 limit 个。
        private var filtered: [String] {
            let term = query.trimmingCharacters(in: .whitespaces).lowercased()
            return items.filter { term.isEmpty || $0.lowercased().contains(term) }.prefix(limit).map(\.self)
        }

        func load(from url: URL) async throws -> [String] {
            let data = try await URLSession.shared.data(from: url).0
            let decoded = try JSONDecoder().decode([String].self, from: data)
            return decoded.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    enum SampleError: Error, CustomStringConvertible {
        case missing(path: String), tooLarge(Int)

        var description: String {
            switch self {
            case .missing(let path): "找不到 \(path)"
            case .tooLarge(let size): "文件太大：\(size / 1024) KB"
            }
        }
    }

    """#
}

struct EditorProbeView: View {
    @State private var text = EditorProbe.text

    var body: some View {
        CodeEditor(document: SourceDocument(path: "probe.swift", editable: true, text: text, version: ""), created: { EditorProbeRun.shared.attach($0) })
            .task { await EditorProbeRun.shared.run() }
    }
}

/// 画的那一刻核对颜色：TextKit 画一段时，这段的显示颜色应该和语法树算出来的一样。
nonisolated final class CheckingFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        nonisolated(unsafe) let fragment = self
        MainActor.assumeIsolated { EditorProbeRun.shared.check(fragment) }
        super.draw(at: point, in: context)
    }
}

final class EditorProbeRun: NSObject, NSTextLayoutManagerDelegate, NSTextContentStorageDelegate, NSTextStorageDelegate {
    /// 编辑器自己在文字存储处理改动时花的时间（增量解析、行号）。
    private var parseTime = 0.0
    static let shared = EditorProbeRun()
    private var view: CodeEditorView?
    private var lines: [String] = []
    private var created = Date()
    private var draws = 0
    private var badDraws = 0
    private var badSamples: [String] = []
    private var validations = 0
    private var validationTime = 0.0
    /// 第几次改动。
    private var edits = 0
    /// 画过的段（起点），看改了显示颜色以后系统重不重画。
    private var drawnStarts: [Int] = []

    private var textView: PlatformTextView? {
        #if canImport(UIKit)
        view
        #else
        view?.textView
        #endif
    }

    func log(_ line: String) {
        lines.append(line)
        print("editor-probe: \(line)")
    }

    func attach(_ view: CodeEditorView) {
        self.view = view
        let previous = view.styler?.changed
        view.styler?.changed = { [weak self] in
            self?.edits += 1
            previous?()
        }
        created = Date()
        guard let manager = textView?.textLayoutManager else { log("没有 textLayoutManager：退回了 TextKit 1"); return }
        log("建好时 textLayoutManager.delegate 原来是 \(manager.delegate.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        // -editorProbeCheck NO：只计时，不换排版代理（iOS 的文本视图自己用着它）
        if UserDefaults.standard.string(forKey: "editorProbeCheck") != "NO" {
            manager.delegate = self
            // 建编辑器时已经排好的段落不是核对用的片段：整份重设一次，各段都换成核对用的片段
            if let storage = textView?.textStorage {
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: storage.string)
            }
        } else {
            log("只计时，不核对颜色")
        }
        // 文字存储的改动经过这里转给编辑器，计时
        #if canImport(UIKit)
        textView?.textStorage.delegate = self
        #else
        textView?.textStorage?.delegate = self
        #endif
        // 生成段落经过这里转给编辑器，数次数、计时
        if let content = manager.textContentManager as? NSTextContentStorage {
            log("内容存储原来的代理：\(content.delegate.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
            content.delegate = self
        }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: TextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            let start = CFAbsoluteTimeGetCurrent()
            view?.styler?.textStorage(storage, didProcessEditing: editedMask, range: editedRange, changeInLength: delta)
            parseTime += CFAbsoluteTimeGetCurrent() - start
        }
    }

    nonisolated func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        nonisolated(unsafe) var result: NSTextParagraph?
        MainActor.assumeIsolated {
            let start = CFAbsoluteTimeGetCurrent()
            result = view?.styler?.paragraph(range)
            validations += 1
            validationTime += CFAbsoluteTimeGetCurrent() - start
        }
        return result
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        CheckingFragment(textElement: textElement, range: textElement.elementRange)
    }

    func check(_ fragment: NSTextLayoutFragment) {
        guard let view, let styler = view.styler, let syntax = styler.syntax, let manager = fragment.textLayoutManager,
              let storage = (manager.textContentManager as? NSTextContentStorage)?.textStorage,
              let range = styler.nsRange(fragment.rangeInElement), range.length > 0 else { return }
        draws += 1
        drawnStarts.append(range.location)
        let text = storage.mutableString
        var expected = [PlatformColor?](repeating: nil, count: range.length)
        for highlight in syntax.highlights(in: range, text: text) {
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0, let color = SyntaxPalette.color(for: highlight.name) else { continue }
            for index in clipped.location..<NSMaxRange(clipped) { expected[index - range.location] = color }
        }
        var actual = [PlatformColor?](repeating: nil, count: range.length)
        let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString
        if let paragraph, paragraph.length == range.length {
            // 正文的字带着文本视图的默认字色，算正文色
            for index in 0..<range.length {
                let color = paragraph.attribute(.foregroundColor, at: index, effectiveRange: nil) as? PlatformColor
                actual[index] = name(color) == "别的颜色" ? nil : color
            }
        } else {
            badSamples.append("  [\(range.location)] 段落元素和片段的范围对不上")
        }
        var wrong: [Int] = []
        for index in 0..<range.length where expected[index] !== actual[index] {
            let character = text.character(at: range.location + index)
            if character == 0x20 || character == 0x09 || character == 0x0A { continue }
            wrong.append(index)
        }
        if !wrong.isEmpty {
            badDraws += 1
            if badSamples.count < 8 {
                let line = text.substring(with: NSRange(location: range.location, length: min(range.length, 60)))
                let first = wrong[0]
                badSamples.append("  [\(range.location)] \(wrong.count) 字颜色不对（第 \(first) 字起，该是 \(name(expected[first]))、实际 \(name(actual[first]))；现在第 \(edits) 次改动）：\(line.debugDescription)")
                let highlights = syntax.highlights(in: range, text: text).filter { NSLocationInRange(range.location + first, $0.range) }
                badSamples.append("    那个字的种类：\(highlights.map(\.name))")
            }
        }
    }

    private func name(_ color: PlatformColor?) -> String {
        guard let color else { return "正文色" }
        for name in ["keyword", "string", "string.escape", "comment", "function", "type", "constant", "attribute"]
        where SyntaxPalette.color(for: name) === color { return name }
        return "别的颜色"
    }

    private func frame() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func resetCounts() {
        draws = 0; badDraws = 0; badSamples = []; validations = 0; validationTime = 0
    }

    /// 不等画，直接核对屏幕上的各段：这时还错的不是闪一帧，是真错了。
    private func audit(_ title: String) {
        guard let textView, let manager = textView.textLayoutManager, let styler = view?.styler else { return }
        let saved = (draws, badDraws, badSamples)
        draws = 0; badDraws = 0; badSamples = []
        #if canImport(UIKit)
        let visible = textView.bounds.offsetBy(dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        #else
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        #endif
        if let first = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(visible.minY, 0))) {
            manager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: []) { fragment in
                guard fragment.layoutFragmentFrame.minY <= visible.maxY else { return false }
                check(fragment)
                return true
            }
        }
        log("\(title)：屏幕上 \(draws) 段，现在颜色还不对的 \(badDraws) 段")
        badSamples.forEach { log($0) }
        (draws, badDraws, badSamples) = saved
    }

    private func dumpParagraphs(around location: Int) {
        guard let manager = textView?.textLayoutManager, let styler = view?.styler, let text = storage?.mutableString else { return }
        let line = styler.lines.line(containing: location)
        for index in max(line - 1, 0)...min(line + 1, styler.lines.count - 1) {
            let start = styler.lines.starts[index]
            let end = index + 1 < styler.lines.count ? styler.lines.starts[index + 1] : text.length
            let fragment = styler.textRange(NSRange(location: start, length: 0)).flatMap { manager.textLayoutFragment(for: $0.location) }
            let range = fragment.flatMap { styler.nsRange($0.rangeInElement) }
            log("  第 \(index) 行 [\(start)..<\(end)] 所在段 \(range.map { "[\($0.location)..<\(NSMaxRange($0))]" } ?? "无")：\(text.substring(with: NSRange(location: start, length: min(end - start, 50))).debugDescription)")
        }
    }

    private func reportCounts(_ title: String) {
        audit(title + "（事后核对）")
        log("\(title)：画了 \(draws) 段，颜色不对的 \(badDraws) 段；生成带色段落 \(validations) 次共 \(ms(validationTime))")
        badSamples.forEach { log($0) }
        resetCounts()
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }

    private func stats(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "无" }
        let sorted = samples.sorted()
        return "平均 \(ms(samples.reduce(0, +) / Double(samples.count)))，中位 \(ms(sorted[sorted.count / 2]))，最大 \(ms(sorted.last!))"
    }

    // MARK: 驱动

    private var storage: NSTextStorage? { textView?.textStorage }

    private func select(_ location: Int) {
        #if canImport(UIKit)
        view?.selectedRange = NSRange(location: location, length: 0)
        #else
        view?.textView.setSelectedRange(NSRange(location: location, length: 0))
        #endif
    }

    private func type(_ text: String) {
        #if canImport(UIKit)
        view?.insertText(text)
        #else
        view?.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        #endif
    }

    private func backspace() {
        #if canImport(UIKit)
        view?.deleteBackward()
        #else
        view?.textView.deleteBackward(nil)
        #endif
    }

    private func scroll(toLine line: Int) {
        guard let styler = view?.styler else { return }
        let location = styler.lines.starts[min(line, styler.lines.count - 1)]
        #if canImport(UIKit)
        view?.scrollRangeToVisible(NSRange(location: location, length: 0))
        #else
        view?.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        #endif
    }

    /// 屏幕上第一段之后第 n 行的开头。
    private func visibleLineStart(_ offset: Int) -> Int? {
        guard let textView, let manager = textView.textLayoutManager, let styler = view?.styler else { return nil }
        #if canImport(UIKit)
        let top = textView.bounds.minY
        #else
        let top = textView.visibleRect.minY
        #endif
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: top + 40)),
              let range = styler.nsRange(fragment.rangeInElement) else { return nil }
        let line = styler.lines.line(containing: range.location) + offset
        return styler.lines.starts[min(line, styler.lines.count - 1)]
    }

    func run() async {
        #if canImport(AppKit) && !canImport(UIKit)
        NSApp.activate()
        view?.window?.makeKeyAndOrderFront(nil)
        #endif
        await frame(); await frame()
        #if canImport(AppKit) && !canImport(UIKit)
        log("窗口：可见 \(view?.window?.isVisible == true)，没被挡住 \(view?.window?.occlusionState.contains(.visible) == true)")
        #endif
        guard let view, let styler = view.styler, let storage else { log("编辑器没建好"); return finish() }
        log("首屏：建好到第一次显示 \(ms(Date().timeIntervalSince(created)))")
        let text = storage.mutableString
        for name in ["a.swift", "a.js", "a.jsx", "a.ts", "a.tsx", "a.py", "a.go", "a.rs", "a.json", "a.html", "a.css", "a.sh", "a.yaml", "a.toml", "a.md"] {
            let begin = CFAbsoluteTimeGetCurrent()
            let language = CodeLanguage.forPath(name)
            log("语言 \(name)：\(language == nil ? "加载失败" : "好")，\(ms(CFAbsoluteTimeGetCurrent() - begin))")
        }
        log("文件 \(text.length) 个 UTF-16 字、\(styler.lines.count) 行；TextKit 2：\(textView?.textLayoutManager != nil)")
        var start = CFAbsoluteTimeGetCurrent()
        let copy = NSString(string: text as String)
        _ = LineIndex(copy)
        log("建行号索引 \(ms(CFAbsoluteTimeGetCurrent() - start))")
        start = CFAbsoluteTimeGetCurrent()
        _ = CodeLanguage.forPath("probe.swift").flatMap { SyntaxTree(language: $0, text: copy) }
        log("整份解析 \(ms(CFAbsoluteTimeGetCurrent() - start))")
        reportCounts("首屏")

        // 跳到中间
        scroll(toLine: styler.lines.count / 2)
        await frame(); await frame()
        reportCounts("跳到中间")

        // 逐字打一行
        if let location = visibleLineStart(5) {
            #if canImport(UIKit)
            _ = view.becomeFirstResponder()
            #else
            view.window?.makeFirstResponder(view.textView)
            #endif
            await frame()
            resetCounts()
            select(location)
            log("打字从 \(location) 起")
            var times: [Double] = []
            parseTime = 0
            for character in "let probe = \"中文\" + String(42) // 注释\n" {
                let begin = CFAbsoluteTimeGetCurrent()
                type(String(character))
                times.append(CFAbsoluteTimeGetCurrent() - begin)
                await frame()
            }
            log("逐字打 \(times.count) 个字：每个字从按下到处理完 \(stats(times))；其中编辑器解析、行号共 \(ms(parseTime))，平均 \(ms(parseTime / Double(times.count)))")
            reportCounts("打字期间")
        }

        // 打 /* 让后面整片变成注释，再删掉
        if let location = visibleLineStart(2) {
            select(location)
            var begin = CFAbsoluteTimeGetCurrent()
            type("/")
            let slash = CFAbsoluteTimeGetCurrent() - begin
            await frame()
            begin = CFAbsoluteTimeGetCurrent()
            type("*")
            let star = CFAbsoluteTimeGetCurrent() - begin
            await frame(); await frame()
            log("打 /*：/ \(ms(slash))，* \(ms(star))")
            reportCounts("打 /* 之后")
            begin = CFAbsoluteTimeGetCurrent()
            backspace(); backspace()
            log("删掉 /* \(ms(CFAbsoluteTimeGetCurrent() - begin))")
            await frame(); await frame()
            reportCounts("删掉 /* 之后")
        }

        // 输入法：拼音还没上屏时上色会不会打断
        if let location = visibleLineStart(8) {
            select(location)
            #if canImport(UIKit)
            log("输入法从 \(location) 起")
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
            await frame(); await frame()
            log("拼音未上屏：markedTextRange \(view.markedTextRange != nil ? "在" : "没了")")
            view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0))
            await frame()
            log("拼音再打两个字母：markedTextRange \(view.markedTextRange != nil ? "在" : "没了")")
            view.insertText("中文")
            await frame()
            log("上屏后：markedTextRange \(view.markedTextRange == nil ? "清掉了" : "还在")，那里的字 \(text.substring(with: NSRange(location: location, length: 2)).debugDescription)")
            #else
            let textView = view.textView
            log("输入法从 \(location) 起")
            dumpParagraphs(around: location)
            textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await frame(); await frame()
            log("拼音未上屏：hasMarkedText \(textView.hasMarkedText())，markedRange \(textView.markedRange())")
            if let marked = styler.textRange(textView.markedRange()), let manager = textView.textLayoutManager {
                var keys: Set<String> = []
                manager.enumerateRenderingAttributes(from: marked.location, reverse: false) { _, attributes, range in
                    keys.formUnion(attributes.keys.map(\.rawValue))
                    return range.endLocation.compare(marked.endLocation) == .orderedAscending
                }
                log("  拼音那段的显示属性：\(keys.sorted())")
            }
            textView.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await frame()
            log("拼音再打两个字母：hasMarkedText \(textView.hasMarkedText())，markedRange \(textView.markedRange())")
            textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            await frame()
            log("上屏后：hasMarkedText \(textView.hasMarkedText())，那里的字 \(text.substring(with: NSRange(location: location, length: 2)).debugDescription)")
            dumpParagraphs(around: location)
            #endif
            reportCounts("输入法期间")
        }

        // 打 """ 让后面大片变成字符串：重新上色以后系统重不重画
        if let location = visibleLineStart(3) {
            select(location)
            resetCounts()
            drawnStarts = []
            type("\"\"\"\n")
            await frame(); await frame()
            log("打 \"\"\" 以后重画了 \(Set(drawnStarts).count) 段")
            reportCounts("打 \"\"\" 之后")
            drawnStarts = []
            for _ in 0..<4 { backspace() }
            await frame(); await frame()
            log("删掉 \"\"\" 以后重画了 \(Set(drawnStarts).count) 段")
            reportCounts("删掉 \"\"\" 之后")
        }

        // 从头滚到尾
        resetCounts()
        var steps: [Double] = []
        for step in 0...20 {
            let begin = CFAbsoluteTimeGetCurrent()
            scroll(toLine: styler.lines.count * step / 20)
            #if canImport(UIKit)
            view.layoutIfNeeded()
            #else
            view.textView.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            #endif
            steps.append(CFAbsoluteTimeGetCurrent() - begin)
            await frame()
        }
        log("从头滚到尾 21 步：每步排版加画 \(stats(steps))")
        reportCounts("滚动期间")
        log("结束时 TextKit 2：\(textView?.textLayoutManager != nil)")
        finish()
    }

    private func finish() {
        try? lines.joined(separator: "\n").write(to: EditorProbe.reportURL, atomically: true, encoding: .utf8)
        exit(0)
    }
}
#endif
