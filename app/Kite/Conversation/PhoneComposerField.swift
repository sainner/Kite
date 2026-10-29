#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPhone、iPad 原生输入区（ControlsBarView）的输入框。配置照现版 SwiftUI 竖向 TextField 底下的 UITextView 逐项设
/// （2026-10-14 iPad 真机导过，见下）：TextKit 2，容器宽跟着视图、高不限，无内边距、行内边距 0，正文字号、字色 label、
/// 插入点主题色，开着滚动但不显示滚动条、竖向不总回弹，自动大写按句；占位是一个 UILabel，正文字号、placeholderText 色，
/// 和第一行同一条基线，有字时藏起。行高是字体的 lineHeight 加 leading（17 点正文 22.008）；高 = 字的总高向上取整到点，
/// 最多 8 行（8 行字加 7 个 leading），再多在里面滚；外面改了字不滚，停在开头，同现版。
/// 回车照现版是换行，不发送（发送只走发送键）；组字照系统。没在打字时停掉它自己的拖动：框里拖是拉抽屉、横滑换窗口，
/// 同 TextScrollLock。外面改草稿时（发送后清空、语音写入）整段换掉、插入点到末尾、清掉撤销，同 Mac 版。
final class ComposerField: UITextView, UITextViewDelegate {
    /// 字变了（含组字中的字），交给草稿。
    var textChanged: ((String) -> Void)?
    /// 上下键、Tab 先问它（没按修饰键、没在组字时）：外面要接管（如选 skill 候选）就给出按下时做的事，输入框不再自己处理；给 nil 照常。
    /// 每次取快捷键时问一遍，给了的键登记成优先于系统行为的快捷键，按到时再问一遍、照着做。
    var intercept: ((ComposerKey) -> (() -> Void)?)?
    /// 成为、交出第一响应者。
    var focusChanged: ((Bool) -> Void)?
    /// 粘贴板上只有图片时（截图、拷的照片）交给它当附件，PNG 数据；有字的照常粘贴。能收附件时才开（acceptsImages）。
    var pasteImage: ((Data) -> Void)?
    var acceptsImages = false

    /// 最多显示几行，再多在里面滚。
    static let maximumLines = 8

    private let placeholderLabel = UILabel()
    /// 量高用的同样配置的一套 TextKit 2，不进视图层级：拖缝每步宽度都变，不能拿视图自己去量。
    private let measureStorage = NSTextContentStorage()
    private let measureLayout = NSTextLayoutManager()
    private let measureContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    /// 这段字不折行时多宽、多高：比这宽时一行都不折，高不用再量。
    private var unwrapped: (text: String, font: UIFont, width: CGFloat, height: CGFloat)?
    /// 折行时上一次按宽量的。
    private var measured: (width: CGFloat, text: String, font: UIFont, height: CGFloat)?
    /// 语音输入的那段字另换的样式，见 VoiceTextStyle。
    private var voiceStyle: VoiceTextStyle?
    /// 上一次给灰字上的颜色：当时的字，灰的那段。都一样就不重设。
    private var voiceShown: (text: String, gray: NSRange)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), acceptsImages, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        // 有现成的 PNG 就直接用，没有时才从图片转
        if acceptsImages, board.hasImages, !board.hasStrings,
           let data = board.data(forPasteboardType: UTType.png.identifier) ?? board.image?.pngData() {
            pasteImage?(data)
            return
        }
        super.paste(sender)
    }

    static func make() -> ComposerField {
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.textContainer = container
        let content = NSTextContentStorage()
        content.addTextLayoutManager(layout)
        content.primaryTextLayoutManager = layout
        let field = ComposerField(frame: .zero, textContainer: container)
        field.stack = (content, layout)
        return field
    }

    /// TextKit 2 的一套自己留着：视图只弱引用容器所在的排版器。
    private var stack: (content: NSTextContentStorage, layout: NSTextLayoutManager)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        // 文本视图也是滚动视图：开着的话和对话列表一起算点状态栏回顶的候选，系统一个都不滚
        scrollsToTop = false
        textColor = .label
        tintColor = UIColor(named: "AccentColor")
        allowsEditingTextAttributes = false
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        measureContainer.lineFragmentPadding = 0
        measureLayout.textContainer = measureContainer
        measureStorage.addTextLayoutManager(measureLayout)
        measureStorage.primaryTextLayoutManager = measureLayout
        panGestureRecognizer.isEnabled = false
        applyFont(UIFont.preferredFont(forTextStyle: .body))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil, let intercept else { return super.keyCommands }
        let keys = ComposerKey.allCases.filter { intercept($0) != nil }
        guard !keys.isEmpty else { return super.keyCommands }
        let commands = keys.map { key in
            let command = UIKeyCommand(input: Self.input(key), modifierFlags: [], action: #selector(interceptKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func interceptKey(_ command: UIKeyCommand) {
        guard markedTextRange == nil, let key = ComposerKey.allCases.first(where: { Self.input($0) == command.input }) else { return }
        intercept?(key)?()
    }

    private static func input(_ key: ComposerKey) -> String {
        switch key {
        case .up: UIKeyCommand.inputUpArrow
        case .down: UIKeyCommand.inputDownArrow
        case .tab: "\t"
        case .escape: UIKeyCommand.inputEscape
        }
    }

    /// 段落样式同现版：折行策略只有 hangulWordPriority（见 FadingSnapshotView.render）。
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .hangulWordPriority
        return style
    }()

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label, .paragraphStyle: Self.paragraph]
    }

    /// 正文字号；字体随环境（动态字体）变时外面再设一次。
    func applyFont(_ font: UIFont) {
        guard font != self.font || placeholderLabel.font != font else { return }
        self.font = font
        placeholderLabel.font = font
        typingAttributes = attributes
        if !text.isEmpty, let storage = textStorage as NSTextStorage? {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        unwrapped = nil
        measured = nil
        setNeedsLayout()
    }

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            guard newValue != placeholderLabel.text else { return }
            placeholderLabel.text = newValue
            // 读屏念的名字是占位文字，同 SwiftUI 的 TextField 以占位作标题
            accessibilityLabel = newValue
        }
    }

    /// 外面改了草稿。整段换掉、插入点到末尾，同现版；和现在一样就不动，组字不被打断。
    /// 换掉的字不进撤销，之前打字记下的撤销也清掉：它们按旧字的范围记，留着的话撤销会越界。
    func setText(_ value: String) {
        guard value != text else { return }
        attributedText = NSAttributedString(string: value, attributes: attributes)
        typingAttributes = attributes
        undoManager?.removeAllActions()
        let end = (value as NSString).length
        selectedRange = NSRange(location: end, length: 0)
        placeholderLabel.isHidden = !value.isEmpty
    }

    // MARK: - 语音输入的字

    /// 语音输入的那段字另换样式（见 VoiceTextStyle），nil 回到正文的样子。外面每次改了字也再给一遍，按新字重画。
    func setVoiceStyle(_ style: VoiceTextStyle?) {
        voiceStyle = style
        renderVoice()
    }

    /// 改字的颜色属性：外面给的字都不进撤销（见 setText），改属性也不经输入系统、不进撤销；改完把 typingAttributes 换回正文的，
    /// 接着打的字不带灰。组字中不动，免得打断输入法。
    private func renderVoice() {
        let text = self.text ?? ""
        let gray = voiceStyle?.gray.flatMap { NSMaxRange($0) <= (text as NSString).length ? $0 : nil }
        if let shown = voiceShown, let gray, shown.text == text, shown.gray == gray { return }
        guard voiceShown != nil || gray != nil, markedTextRange == nil else { return }
        let storage = textStorage
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: storage.length))
        if let gray { storage.addAttribute(.foregroundColor, value: UIColor.label.withAlphaComponent(VoiceTextStyle.dim), range: gray) }
        storage.endEditing()
        typingAttributes = attributes
        voiceShown = gray.map { (text, $0) }
    }

    // MARK: - 量高

    /// 这么宽时显示 text 要多高：最少一行（空的时候是占位那一行），最多 8 行。行高、取整照现版（见文件头）。
    /// 不折行时量出来的高和宽无关：先按字量一次不折行的宽和高，给的宽不比它窄就直接用；折行时才按宽量。
    func height(width: CGFloat, text: String) -> CGFloat {
        let font = font ?? UIFont.preferredFont(forTextStyle: .body)
        if unwrapped?.text != text || unwrapped?.font != font {
            let size = measure(text, width: 1e7, font: font)
            unwrapped = (text, font, size.width, size.height)
        }
        let content: CGFloat
        if let unwrapped, width >= unwrapped.width {
            content = unwrapped.height
        } else if let measured, measured.width == width, measured.text == text, measured.font == font {
            content = measured.height
        } else {
            content = measure(text, width: width, font: font).height
            measured = (width, text, font, content)
        }
        return min(ceil(content), maximumHeight(font))
    }

    /// 8 行多高：8 行字加 7 个 leading，不取整（17 点正文 174.345）；摆到屏上时和别的边一起取整到像素，
    /// 同 SwiftUI（2 倍屏上现版摆出来是 174.5，2026-10-14 iPad 真机量过）。
    private func maximumHeight(_ font: UIFont) -> CGFloat {
        let lines = CGFloat(Self.maximumLines)
        return lines * font.lineHeight + (lines - 1) * font.leading
    }

    /// 字排出来多宽、多高（空的时候是一行）。
    private func measure(_ text: String, width: CGFloat, font: UIFont) -> CGSize {
        measureContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let sample = text.isEmpty ? " " : text
        measureStorage.attributedString = NSAttributedString(string: sample, attributes: [.font: font, .paragraphStyle: Self.paragraph])
        var size = CGSize.zero
        measureLayout.enumerateTextLayoutFragments(from: measureLayout.documentRange.location, options: .ensuresLayout) { fragment in
            let frame = fragment.layoutFragmentFrame
            size.height = max(size.height, frame.maxY)
            for line in fragment.textLineFragments {
                size.width = max(size.width, ceil(line.typographicBounds.width))
            }
            return true
        }
        // 以换行结尾时最后那个空行 TextKit 2 已经算在里面（2026-10-14 真机和现版比过）
        if text.isEmpty { size.width = 0 }
        return size
    }

    // MARK: - 排版、焦点

    override func layoutSubviews() {
        super.layoutSubviews()
        // 占位和第一行同一条基线：第一行的基线在字体的 ascender 处，UILabel 的基线在取整到像素的 ascender 处
        let font = placeholderLabel.font ?? UIFont.preferredFont(forTextStyle: .body)
        let scale = max(traitCollection.displayScale, 1)
        let baseline = (font.ascender * scale).rounded() / scale
        let height = (font.lineHeight * scale).rounded(.up) / scale
        placeholderLabel.frame = CGRect(x: 0, y: font.ascender - baseline, width: bounds.width, height: height)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusUpdated() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusUpdated() }
        return resigned
    }

    private func focusUpdated() {
        // 没在打字时框里拖不滚字，拖动留给所在的地方，同 TextScrollLock
        panGestureRecognizer.isEnabled = isFirstResponder
        focusChanged?(isFirstResponder)
    }

    /// 没在打字时自己的拖动不起：框里往上拖是拉底栏、横着拖是换窗口。只关 panGestureRecognizer 关不住：2026-10-14 iPhone 真机
    /// 进程内看手势状态，刚开 App 和不在当前的窗口里，没在打字的输入框的拖动都是开着的，UIKit 会把它重新打开（哪一步打开的没查）。
    /// 在这里拦住，谁再打开都不起；打字时照常滚，8 行以上的草稿在框里滚。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, !isFirstResponder { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !text.isEmpty
        textChanged?(text)
    }
}
#endif
