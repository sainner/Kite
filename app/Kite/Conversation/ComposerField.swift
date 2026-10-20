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

    /// 字段编辑器两边各留的行内边距，控件比布局宽两倍于它、往左挪它。
    static let fieldInset: CGFloat = 2
    /// 最多显示几行，再多在里面滚。
    static let maximumLines = 8

    private let coordinator = Coordinator()
    /// 量高用的同样配置的控件，不进视图层级：编辑中的字不在单元格里，拿现在的字量。
    private let measure = NSTextField()
    /// 这段字不折行时要多宽、多高：拖缝每步宽度都变，比这宽时一行都不折，高不用再量。
    private var unwrapped: (text: String, scale: CGFloat, width: CGFloat, height: CGFloat)?
    /// 折行时上一次按宽量的。
    private var measured: (width: CGFloat, text: String, scale: CGFloat, height: CGFloat)?
    /// 正好 8 行多高，跟宽度无关（每行一个字），字体、屏幕倍数变了才重量。
    private var full: (scale: CGFloat, height: CGFloat)?

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
    func setText(_ value: String) {
        guard value != text else { return }
        if let editor = currentEditor() as? NSTextView {
            editor.string = value
            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            if let storage = editor.textStorage { editor.undoManager?.removeAllActions(withTarget: storage) }
        } else {
            stringValue = value
        }
    }

    /// 这么宽（控件的宽，含两边的行内边距）时显示 text 要多高：最少一行（空的时候是占位那一行），最多 8 行。
    /// 照现版取整到像素：9 行以上时单元格给的是 8 行半截多一点，2 倍屏上取整后比正好 8 行矮半点，排版按这个矮的算，见 drawHeight。
    /// 单元格比字宽时量出来的高和宽无关（2026-10-13 在同样配置的 NSTextField 上逐宽比过），所以先按字量一次不折行的宽和高，
    /// 给的宽不比它窄就直接用；折行时才按宽量。
    func height(width: CGFloat, text: String) -> CGFloat {
        let scale = scale
        if unwrapped?.text != text || unwrapped?.scale != scale {
            let size = cellSize(width: 1e7, text: text)
            unwrapped = (text, scale, size.width, pixel(size.height, scale))
        }
        if let unwrapped, width >= unwrapped.width { return unwrapped.height }
        if let measured, measured.width == width, measured.text == text, measured.scale == scale { return measured.height }
        let height = pixel(cellSize(width: width, text: text).height, scale)
        measured = (width, text, scale, height)
        return height
    }

    /// 控件本身摆多高：排版的高（height）。只有 9 行以上时排版比正好 8 行矮一点，单元格放不下第 8 行就只画 7 行；
    /// 现版照样画满 8 行、多出的一点伸到下面的留白里（2026-10-13 逐像素比过），这里把控件摆成正好 8 行高。
    func drawHeight(width: CGFloat, text: String) -> CGFloat {
        let height = height(width: width, text: text), full = fullHeight
        // 不到 8 行时比正好 8 行矮至少一行；超过 8 行时只矮那 1 点
        return height < full && full - height < 8 ? full : height
    }

    /// 正好 8 行多高。
    private var fullHeight: CGFloat {
        let scale = scale
        if let full, full.scale == scale { return full.height }
        let text = Array(repeating: "行", count: Self.maximumLines).joined(separator: "\n")
        let height = pixel(cellSize(width: 1e7, text: text).height, scale)
        full = (scale, height)
        return height
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func pixel(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

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

    /// 字段编辑器把命令先交给控件的代理：回车发送，Shift+回车换行，其余照系统的。
    /// 系统没给 Shift+回车单独的命令，同样是 insertNewline，要看按键时的修饰键。
    private final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: ComposerField?

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
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
}
#endif
