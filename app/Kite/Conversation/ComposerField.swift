#if os(macOS)
import AppKit

/// Mac 宽屏原生输入区（ControlsBarView）的输入框。和 SwiftUI 竖向 TextField 在 Mac 上用同一个控件：多行 NSTextField，
/// 编辑时由单元格给的独立字段编辑器（TextKit 2 的 NSTextView）接手。配置照现版导出来的逐项设（2026-10-13 macOS 27 导过）：
/// 无边框、不画底、不画焦点环、正文字号、按字折行、最多 8 行，超过 8 行字段编辑器在里面滚；字段编辑器的拼写、替换、补全等开关
/// 和系统默认的字段编辑器一样，只把插入点和选区换成主题色（同现版）。
/// SwiftUI 把它摆得比自己的布局宽 4、往左挪 2，抵掉字段编辑器两边各 2 的行内边距，字和布局的左边对齐；外面照这样摆，见 fieldInset。
/// 键位：回车（含小键盘 Enter）发送，Shift+回车、Option+回车换行，Control+回车插行分隔符（后两个是系统键位）；
/// 组字中的回车由输入法确认组字，不发送。外面改草稿时（发送后清空、语音写入）编辑中的字整段换掉、插入点到末尾，同现版。
final class ComposerField: NSTextField {
    /// 回车发送。
    var submit: (() -> Void)?
    /// 字变了（含组字中的字），交给草稿。
    var textChanged: ((String) -> Void)?
    /// 上下键、Tab 先问它（没按修饰键、没在组字时）：外面要接管（如选 skill 候选）就给出按下时做的事，输入框不再自己处理；给 nil 照常。
    var intercept: ((ComposerKey) -> (() -> Void)?)?
    /// 粘贴、拖进来的东西先给它：收下了文件或图片当附件就返回真，否则照常当字处理。
    var attachments: ((NSPasteboard) -> Bool)?

    /// 字段编辑器两边各留的行内边距，控件比布局宽两倍于它、往左挪它。
    static let fieldInset: CGFloat = 2
    /// 最多显示几行，再多在里面滚。
    static let maximumLines = 8

    private let coordinator = Coordinator()
    /// 量高用的同样配置的控件，不进视图层级：编辑中的字不在单元格里，拿现在的字量。
    private let measure = NSTextField()
    /// 这段字不折行时要多宽、多高（没取整）：拖缝每步宽度都变，比这宽时一行都不折，高不用再量。
    private var unwrapped: (text: String, width: CGFloat, height: CGFloat)?
    /// 折行时上一次按宽量的。
    private var measured: (width: CGFloat, text: String, height: CGFloat)?
    /// 正好 8 行多高（没取整），跟宽度无关（每行一个字），字体变了才重量。
    private var full: CGFloat?
    /// 语音输入的那段字另换的样式，见 VoiceTextStyle。
    private var voiceStyle: VoiceTextStyle?
    /// 上一次给灰字上的颜色：画在字段编辑器里（编辑中）还是单元格里，当时的字，灰的那段，多灰。都一样就不重设：
    /// 换了字（哪怕范围一样）单元格的颜色已经随 stringValue 回到原样，要重上。
    private var voiceShown: (editor: Bool, text: String, gray: NSRange, alpha: Double)?
    /// 等整理时灰字逐帧呼吸。
    private let breathTicker = FrameTicker()
    /// 按同样的配置另排的一份，量字的位置用，见 caret。
    private var caretLayout: (text: String, width: CGFloat, storage: NSTextContentStorage, layout: NSTextLayoutManager)?

    init() {
        super.init(frame: .zero)
        cell = ComposerFieldCell(textCell: "")
        for field in [self, measure] { Self.configure(field) }
        coordinator.field = self
        delegate = coordinator
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func configure(_ field: NSTextField) {
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = maximumLines
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.textColor = .controlTextColor
        field.alignment = .natural
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var font: NSFont? {
        didSet {
            measure.font = font
            unwrapped = nil
            measured = nil
            full = nil
        }
    }

    var placeholder: String {
        get { placeholderString ?? "" }
        set { if newValue != placeholderString { placeholderString = newValue } }
    }

    /// 现在的字：编辑中取字段编辑器里的（含组字中的字）。
    var text: String {
        (currentEditor() as? NSTextView)?.string ?? stringValue
    }

    /// 外面改了草稿。编辑中的字整段换掉、插入点到末尾，同现版；和现在一样就不动，组字不被打断。
    /// 换掉的字不进撤销，之前打字记下的撤销也清掉：它们按旧字的范围记，留着的话 ⌘Z 越界抛异常（2026-10-13 在单独的 NSTextView 上试过）。
    /// 给了 undoFrom 时（语音整理完换上去的字）照打字一样经字段编辑器换，记进撤销，⌘Z 换回 undoFrom（定稿）：
    /// 流式整理途中已经换过几次，先不记撤销地换回 undoFrom 再换，同一次更新里看不出来。没在编辑时没有撤销。
    func setText(_ value: String, undoFrom: String? = nil) {
        if let undoFrom, let editor = currentEditor() as? NSTextView, value != undoFrom {
            if editor.string != undoFrom {
                editor.string = undoFrom
                if let storage = editor.textStorage { editor.undoManager?.removeAllActions(withTarget: storage) }
            }
        } else if value == text {
            return
        }
        if let editor = currentEditor() as? NSTextView {
            if undoFrom != nil {
                let range = NSRange(location: 0, length: (editor.string as NSString).length)
                guard editor.shouldChangeText(in: range, replacementString: value) else { return }
                editor.replaceCharacters(in: range, with: value)
                editor.didChangeText()
            } else {
                editor.string = value
                if let storage = editor.textStorage { editor.undoManager?.removeAllActions(withTarget: storage) }
            }
            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        } else {
            stringValue = value
        }
    }

    // MARK: - 语音输入的字

    /// 现在灰着的那段字，扫掠按它判断要不要重画输入框的图（VoiceSweepView）。
    var voiceGray: NSRange? { voiceShown?.gray }

    /// 语音输入的那段字另换样式（见 VoiceTextStyle），nil 回到正文的样子。外面每次改了字也再给一遍，按新字重画。
    func setVoiceStyle(_ style: VoiceTextStyle?) {
        voiceStyle = style
        let breathing = style?.waiting == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if breathing, !breathTicker.running {
            breathTicker.start(in: self) { [weak self] _ in
                guard let self, voiceStyle?.waiting == true else { return false }
                renderVoice()
                return true
            }
        } else if !breathing {
            breathTicker.stop()
        }
        renderVoice()
    }

    /// 编辑中改字段编辑器的显示属性，不动字本身、不进撤销；没在编辑时改单元格的字（设回 stringValue 就回到单元格自己的颜色）。
    private func renderVoice() {
        let editor = currentEditor() as? NSTextView
        let text = (editor?.string ?? stringValue) as NSString
        let gray = voiceStyle?.gray.flatMap { NSMaxRange($0) <= text.length ? $0 : nil }
        // 等整理时按等待呼吸的节奏起伏，同工具行的等待（WaitingBreath）
        let alpha = VoiceTextStyle.dim * (breathTicker.running ? WaitingBreath.opacity(at: .now) : 1)
        if let shown = voiceShown, let gray, shown.editor == (editor != nil), shown.text == text as String, shown.gray == gray,
           abs(shown.alpha - alpha) < 0.01 { return }
        if voiceShown == nil, gray == nil { return }
        let color = (textColor ?? .controlTextColor).withAlphaComponent(alpha)
        if let editor, let layout = editor.textLayoutManager, let content = layout.textContentManager {
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
            if let gray, let start = content.location(content.documentRange.location, offsetBy: gray.location),
               let end = content.location(start, offsetBy: gray.length), let range = NSTextRange(location: start, end: end) {
                layout.addRenderingAttribute(.foregroundColor, value: color, for: range)
            }
            // 只改显示属性时字段编辑器不重画（2026-10-29 屏上截图核对过，重新排版也不画），把它和里面各层都标成要重画
            func redraw(_ view: NSView) {
                view.needsDisplay = true
                view.subviews.forEach(redraw)
            }
            redraw(editor)
        } else if let gray {
            let string = NSMutableAttributedString(string: text as String)
            // 单元格自己的字体、段落和颜色，同设 stringValue 时它给的
            stringValue = text as String
            if text.length > 0 { string.setAttributes(attributedStringValue.attributes(at: 0, effectiveRange: nil), range: NSRange(location: 0, length: text.length)) }
            string.addAttribute(.foregroundColor, value: color, range: gray)
            attributedStringValue = string
        } else {
            stringValue = text as String
        }
        voiceShown = gray.map { (editor != nil, text as String, $0, alpha) }
    }

    /// 单元格里上过色的字交给字段编辑器之前换回原样：编辑器照单元格的字起头，颜色会进编辑中的字、带到接着打的字上。编辑中改显示属性。
    override func becomeFirstResponder() -> Bool {
        if voiceShown?.editor == false { stringValue = stringValue }
        voiceShown = nil
        let became = super.becomeFirstResponder()
        renderVoice()
        return became
    }

    /// 编辑完字回到单元格里画，样式跟过去。
    override func textDidEndEditing(_ notification: Notification) {
        if let editor = currentEditor() as? NSTextView, let layout = editor.textLayoutManager {
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
        }
        super.textDidEndEditing(notification)
        voiceShown = nil
        renderVoice()
    }

    /// 第 offset 个 UTF-16 单元前面那个位置（控件坐标）：x 是这个位置，y、高是它所在的那一行；在行尾时算上一行的末尾。
    /// 按同样的配置另排一份（同字段编辑器：容器和控件一样宽，左右各留 fieldInset；2026-10-29 和字段编辑器逐点比过一致），
    /// 编辑中、没在编辑时都对得上；超过 8 行在里面滚的不算滚动。
    func caret(at offset: Int) -> CGRect? {
        let text = self.text, width = bounds.width
        if caretLayout?.text != text || caretLayout?.width != width {
            let storage = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = Self.fieldInset
            layout.textContainer = container
            storage.addTextLayoutManager(layout)
            measure.stringValue = text
            storage.attributedString = measure.attributedStringValue
            caretLayout = (text, width, storage, layout)
        }
        guard let (_, _, storage, layout) = caretLayout,
              let location = storage.location(storage.documentRange.location, offsetBy: min(max(offset, 0), (text as NSString).length))
        else { return nil }
        var caret: CGRect?
        layout.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired, .upstreamAffinity]) {
            _, frame, _, _ in
            caret = frame
            return false
        }
        return caret
    }

    /// 把现在显示的字画成图（同 snapshot，不画插入点和选区，不留边），给语音整理的扫掠用。
    func sweepImage() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let editor = currentEditor() as? NSTextView
        let selection = editor?.selectedRanges
        if let editor { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        let shown = (editor.map { Self.indicators(in: $0) } ?? []).filter { !$0.isHidden }
        shown.forEach { $0.isHidden = true }
        // 画出来的图带着遮罩（扫掠挖掉的那一截），先摘下，画完挂回去
        let mask = layer?.mask
        layer?.mask = nil
        cacheDisplay(in: bounds, to: rep)
        layer?.mask = mask
        shown.forEach { $0.isHidden = false }
        if let editor, let selection { editor.selectedRanges = selection }
        return rep.cgImage
    }

    /// 这么宽（控件的宽，含两边的行内边距）时显示 text 要多高：最少一行（空的时候是占位那一行），最多 8 行。
    /// 照现版四舍五入到像素：9 行以上时单元格给的是 8 行半截多一点，2 倍屏上取整后比正好 8 行矮半点，排版按这个矮的算，见 drawHeight。
    func height(width: CGFloat, text: String) -> CGFloat {
        pixel(cellHeight(width: width, text: text), rounding: .toNearestOrAwayFromZero)
    }

    /// 控件本身摆多高：单元格要的高向上取整到像素，可以比排版的高（height）高一点，多出的伸到下面的留白里。
    /// 单元格画字时放不下整行就不画那一行：每行要 16.006 点（13 点正文，2026-10-27 macOS 27.2 量过），2 到 8 行四舍五入后
    /// 都少那一点，没在编辑时最后一行不见了（编辑中的字由字段编辑器画，不受影响）。
    /// 9 行以上时单元格量出来比正好 8 行矮一点，现版照样画满 8 行（2026-10-13 逐像素比过），这里把控件摆成正好 8 行高。
    func drawHeight(width: CGFloat, text: String) -> CGFloat {
        let height = cellHeight(width: width, text: text), full = fullHeight
        // 不到 8 行时比正好 8 行矮至少一行；超过 8 行时只矮那 1 点
        return pixel(height < full && full - height < 8 ? full : height, rounding: .up)
    }

    /// 单元格显示 text 要的高，没取整。单元格比字宽时量出来的高和宽无关（2026-10-13 在同样配置的 NSTextField 上逐宽比过），
    /// 所以先按字量一次不折行的宽和高，给的宽不比它窄就直接用；折行时才按宽量。
    private func cellHeight(width: CGFloat, text: String) -> CGFloat {
        if unwrapped?.text != text {
            let size = cellSize(width: 1e7, text: text)
            unwrapped = (text, size.width, size.height)
        }
        if let unwrapped, width >= unwrapped.width { return unwrapped.height }
        if let measured, measured.width == width, measured.text == text { return measured.height }
        let height = cellSize(width: width, text: text).height
        measured = (width, text, height)
        return height
    }

    /// 正好 8 行多高，没取整。
    private var fullHeight: CGFloat {
        if let full { return full }
        let text = Array(repeating: "行", count: Self.maximumLines).joined(separator: "\n")
        let height = cellSize(width: 1e7, text: text).height
        full = height
        return height
    }

    private func pixel(_ value: CGFloat, rounding: FloatingPointRoundingRule) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded(rounding) / scale
    }

    private func cellSize(width: CGFloat, text: String) -> CGSize {
        measure.stringValue = text
        return measure.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 1e7)) ?? .zero
    }

    /// 把现在显示的字画成图，四周留 FadingText.bleed 的边，发送时盖在原处淡掉（见 FadingSnapshotView）。不画插入点和选区。
    func snapshot() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let editor = currentEditor() as? NSTextView
        let selection = editor?.selectedRanges
        if let editor { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        let indicators = editor.map { Self.indicators(in: $0) } ?? []
        let shown = indicators.filter { !$0.isHidden }
        shown.forEach { $0.isHidden = true }
        cacheDisplay(in: bounds, to: rep)
        shown.forEach { $0.isHidden = false }
        if let editor, let selection { editor.selectedRanges = selection }
        guard let image = rep.cgImage else { return nil }
        let bleed = FadingText.bleed, scale = CGFloat(image.width) / bounds.width
        let width = Int((bounds.width + 2 * bleed) * scale), height = Int((bounds.height + 2 * bleed) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: bleed * scale, y: bleed * scale, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    private static func indicators(in view: NSView) -> [NSView] {
        view.subviews.flatMap { $0 is NSTextInsertionIndicator ? [$0] : indicators(in: $0) }
    }

    /// 字段编辑器把命令先交给控件的代理：上下键、Tab、Esc 先问 intercept，回车发送，Shift+回车换行，其余照系统的。
    /// 系统没给 Shift+回车单独的命令，同样是 insertNewline，要看按键时的修饰键。
    private final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: ComposerField?

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .control, .option, .command]) ?? []
            if modifiers.isEmpty {
                let key: ComposerKey? = switch commandSelector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                case #selector(NSResponder.insertTab(_:)): .tab
                case #selector(NSResponder.cancelOperation(_:)): .escape
                default: nil
                }
                if let key, let action = field?.intercept?(key) {
                    action()
                    return true
                }
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                field?.submit?()
            }
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            field.textChanged?(editor.string)
        }
    }
}

/// 给输入框一个自己的字段编辑器，同现版：窗口共用的那个改了颜色会带到别的输入框。
private final class ComposerFieldCell: NSTextFieldCell {
    private var editor: NSTextView?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if let editor { return editor }
        let editor = ComposerEditor(usingTextLayoutManager: true)
        editor.field = controlView as? ComposerField
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.writingToolsBehavior = .limited
        editor.insertionPointColor = .controlAccentColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        self.editor = editor
        return editor
    }
}

/// 组字中的字变了也交给输入框：系统只在确认组字、删字这类改动后发文字变化的通知，拼音一个个打进去时不发
/// （2026-10-18 macOS 27.2 在 NSTextField 的字段编辑器上试过），草稿跟不上，新代理图案的打字活跃度也就只在选字、删字时动。
private final class ComposerEditor: NSTextView {
    weak var field: ComposerField?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        field?.textChanged?(self.string)
    }

    /// 粘贴的是文件、截图这类：当附件，不把文件名或图片塞进字里。
    override func paste(_ sender: Any?) {
        if field?.attachments?(.general) == true { return }
        super.paste(sender)
    }

    /// 拖进输入框的文件同样当附件，不插入路径。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if field?.attachments?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }
}
#endif
