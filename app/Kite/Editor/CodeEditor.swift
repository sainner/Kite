import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 浏览窗口的原文编辑器：系统文本视图（TextKit 2）加左边的行号栏，语法颜色见 SyntaxStyler。点进去就能改，历史版本只读。
/// 文字和改没改过记在 SourceDocument；工作机上的新内容换进来时只替换变了的那一段，滚动位置和选区尽量不动。
/// 只碰 textStorage 和 textLayoutManager：读 layoutManager 会让文本视图退回 TextKit 1。
struct CodeEditor {
    let document: SourceDocument
    /// 引用指定的几行：id 变了时选中这几行、滚过去。
    var focus: Focus?
    /// 在文件里找的当前匹配，选中、滚过去。
    var match: Match?
    /// 键盘上按 ⌘S。
    var save: () -> Void = {}

    struct Focus: Equatable {
        let lines: ClosedRange<Int>
        let id: UUID
    }

    /// 第几行（从 1 起）的第几个，按 TextSearch 的算法数。
    struct Match: Equatable {
        let query: String
        let line: Int
        let occurrence: Int
    }
}

/// 两端编辑器共用的文字处理。
@MainActor
enum CodeEditorText {
    /// 第几行到第几行（从 1 起）的范围，含行尾的换行。
    static func range(lines: ClosedRange<Int>, in index: LineIndex, length: Int) -> NSRange {
        let first = min(max(lines.lowerBound, 1), index.count) - 1
        let last = min(max(lines.upperBound, lines.lowerBound), index.count)
        let end = last < index.count ? index.starts[last] : length
        return NSRange(location: index.starts[first], length: max(end - index.starts[first], 0))
    }

    /// 一个匹配在全文里的范围；行或第几个对不上（文字刚改过）时是 nil。
    static func range(of match: CodeEditor.Match, in text: NSString, index: LineIndex) -> NSRange? {
        guard match.line >= 1, match.line <= index.count else { return nil }
        let line = range(lines: match.line...match.line, in: index, length: text.length)
        let string = text.substring(with: line)
        let found = TextSearch.ranges(of: match.query, in: string)
        guard found.indices.contains(match.occurrence) else { return nil }
        let local = NSRange(found[match.occurrence], in: string)
        return NSRange(location: line.location + local.location, length: local.length)
    }

    /// 把文字存储换成新文字，只替换两头相同部分中间的那一段。
    static func replace(_ storage: NSTextStorage, with text: String, attributes: [NSAttributedString.Key: Any]) {
        let old = storage.mutableString, new = text as NSString
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.length - prefix - suffix),
                                  with: NSAttributedString(string: replacement, attributes: attributes))
    }
}

/// 两端编辑器跟上 SourceDocument：换进工作机上的新内容，选中引用的行、查找的当前匹配。
@MainActor
final class CodeEditorSync {
    let document: SourceDocument
    /// 已经换进来的 SourceDocument.revision。
    private var revision: Int
    private var focusID: UUID?
    private var match: CodeEditor.Match?
    /// 换进新内容时文字存储也会报改动，不算用户改的。
    private var replacing = false

    init(document: SourceDocument) {
        self.document = document
        revision = document.revision
    }

    /// 文字存储报了改动（SyntaxStyler.edited）。
    func edited() {
        if !replacing { document.edited() }
    }

    /// attributes 是换进来的文字的字体、字色；换了内容就清掉撤销记录。reveal 选中一段并滚过去。
    func apply(storage: NSTextStorage, styler: SyntaxStyler?, attributes: [NSAttributedString.Key: Any], undo: UndoManager?,
               focus: CodeEditor.Focus?, match: CodeEditor.Match?, reveal: (NSRange) -> Void) {
        if document.revision != revision {
            revision = document.revision
            replacing = true
            CodeEditorText.replace(storage, with: document.text, attributes: attributes)
            replacing = false
            undo?.removeAllActions()
        }
        guard let styler else { return }
        if let focus, focus.id != focusID {
            focusID = focus.id
            reveal(CodeEditorText.range(lines: focus.lines, in: styler.lines, length: storage.length))
        }
        if match != self.match {
            self.match = match
            if let match, let range = CodeEditorText.range(of: match, in: storage.mutableString, index: styler.lines) { reveal(range) }
        }
    }
}

/// 行号栏：给看得见的每一段标行号，段落的第一行对齐。
final class LineNumberGutter: PlatformView {
    weak var textView: PlatformTextView?
    weak var styler: SyntaxStyler?
    let font: PlatformFont

    init(font: PlatformFont) {
        self.font = font
        super.init(frame: .zero)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 按最多几位数定宽。
    var width: CGFloat {
        let digits = max(3, String(styler?.lines.count ?? 1).count)
        return ceil((String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width) + 16
    }

    #if canImport(AppKit) && !canImport(UIKit)
    override var isFlipped: Bool { true }
    #endif

    override func draw(_ rect: CGRect) {
        guard let textView, let styler, let manager = textView.textLayoutManager else { return }
        #if canImport(UIKit)
        let inset = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
        let visible = textView.bounds
        #else
        let inset = textView.textContainerOrigin
        let visible = textView.visibleRect
        #endif
        let attributes: [NSAttributedString.Key: Any] = [.font: font.monospacedDigits, .foregroundColor: PlatformColor.tertiaryLabel]
        let top = CGPoint(x: 0, y: max(visible.minY - inset.y, 0))
        let start = manager.textLayoutFragment(for: top)?.rangeInElement.location ?? manager.documentRange.location
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: inset.x, dy: inset.y)
            guard frame.minY <= visible.maxY else { return false }
            guard let range = styler.nsRange(fragment.rangeInElement), let first = fragment.textLineFragments.first else { return true }
            let label = String(styler.lines.line(containing: range.location) + 1) as NSString
            let size = label.size(withAttributes: attributes)
            // 行号的基线对齐段落第一行的基线
            let baseline = frame.minY + first.typographicBounds.minY + first.glyphOrigin.y
            let origin = convert(CGPoint(x: 0, y: baseline), from: textView)
            label.draw(at: CGPoint(x: bounds.width - size.width - 8, y: origin.y - font.ascender), withAttributes: attributes)
            return true
        }
    }
}

#if canImport(UIKit)
/// iPhone、iPad 的代码编辑器：折行的 UITextView，行号栏是它的子视图，随滚动挪到看得见的地方。
final class CodeEditorView: UITextView {
    let gutter: LineNumberGutter
    private(set) var styler: SyntaxStyler?
    var save: () -> Void = {}
    private let sync: CodeEditorSync
    /// TextKit 2 的一套自己搭、由这里拿着，同 PhoneProseTextView：容器到排版管理器、排版管理器到内容存储都是弱引用。
    private let stack: (content: NSTextContentStorage, layout: NSTextLayoutManager)

    init(document: SourceDocument) {
        let font = SelectableText.phoneFonts.code
        gutter = LineNumberGutter(font: font)
        sync = CodeEditorSync(document: document)
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        let content = NSTextContentStorage()
        content.addTextLayoutManager(layout)
        content.primaryTextLayoutManager = layout
        stack = (content, layout)
        super.init(frame: .zero, textContainer: container)
        self.font = font
        textColor = .label
        backgroundColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        isFindInteractionEnabled = true
        isEditable = document.editable
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        text = document.text
        document.storage = textStorage
        if let manager = textLayoutManager { styler = SyntaxStyler(layoutManager: manager, language: CodeLanguage.forPath(document.path)) }
        styler?.edited = { [sync] in sync.edited() }
        gutter.textView = self
        gutter.styler = styler
        addSubview(gutter)
        styler?.changed = { [weak self] in self?.relayoutGutter() }
        relayoutGutter()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "保存", action: #selector(saveCommand), input: "s", modifierFlags: .command)]
    }

    @objc private func saveCommand() { save() }

    /// 跟上 SourceDocument：新内容、引用的行、查找的当前匹配。
    func apply(focus: CodeEditor.Focus?, match: CodeEditor.Match?) {
        sync.apply(storage: textStorage, styler: styler, attributes: [.font: font as Any, .foregroundColor: UIColor.label], undo: undoManager,
                   focus: focus, match: match, reveal: reveal)
    }

    private func reveal(_ range: NSRange) {
        selectedRange = range
        scrollRangeToVisible(range)
    }

    private func relayoutGutter() {
        let width = gutter.width
        if textContainerInset.left != width { textContainerInset = UIEdgeInsets(top: 8, left: width, bottom: 8, right: 8) }
        setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: bounds.minX, y: bounds.minY, width: textContainerInset.left, height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

extension CodeEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> CodeEditorView {
        CodeEditorView(document: document)
    }

    func updateUIView(_ view: CodeEditorView, context: Context) {
        view.save = save
        view.apply(focus: focus, match: match)
    }
}
#else
/// Mac 的代码编辑器：折行的 NSTextView，行号栏在滚动视图左边，跟着滚动重画。撤销记录各编辑器自己一份，不和窗口里别的输入框混在一起。
final class CodeEditorView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = CodeEditorTextView(usingTextLayoutManager: true)
    let gutter: LineNumberGutter
    private(set) var styler: SyntaxStyler?
    private let sync: CodeEditorSync
    private let undo = UndoManager()

    init(document: SourceDocument) {
        let font = Theme.code.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        gutter = LineNumberGutter(font: font)
        sync = CodeEditorSync(document: document)
        super.init(frame: .zero)
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = document.editable
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.inlinePredictionType = .no
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // 折行：不折行时 TextKit 要排完全文才知道最宽的一行，打开 2 MB 的文件要排 5 万多段（docs/research/2026-10-23-代码编辑器上色验证.md）
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = document.text
        textView.delegate = self
        document.storage = textView.textStorage
        if let manager = textView.textLayoutManager { styler = SyntaxStyler(layoutManager: manager, language: CodeLanguage.forPath(document.path)) }
        styler?.edited = { [sync] in sync.edited() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.textView = textView
        gutter.styler = styler
        addSubview(gutter)
        addSubview(scrollView)
        styler?.changed = { [weak self] in
            self?.needsLayout = true
            self?.gutter.needsDisplay = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    @objc private func scrolled() { gutter.needsDisplay = true }

    /// 跟上 SourceDocument：新内容、引用的行、查找的当前匹配。
    func apply(focus: CodeEditor.Focus?, match: CodeEditor.Match?) {
        guard let storage = textView.textStorage else { return }
        sync.apply(storage: storage, styler: styler, attributes: [.font: textView.font as Any, .foregroundColor: NSColor.labelColor], undo: undo,
                   focus: focus, match: match, reveal: reveal)
    }

    private func reveal(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if range.length > 0 { textView.showFindIndicator(for: range) }
    }

    override func layout() {
        super.layout()
        let width = gutter.width
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
        gutter.needsDisplay = true
    }
}

/// 编辑器的文本视图：⌘S 交给浏览窗口保存。
final class CodeEditorTextView: NSTextView {
    var save: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s" {
            save()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension CodeEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> CodeEditorView {
        CodeEditorView(document: document)
    }

    func updateNSView(_ view: CodeEditorView, context: Context) {
        view.textView.save = save
        view.apply(focus: focus, match: match)
    }
}
#endif
