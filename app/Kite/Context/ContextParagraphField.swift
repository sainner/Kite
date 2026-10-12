import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// 段落正文：文字里嵌着变量胶囊，直接打字；胶囊整块选中、整块删除。Markdown 标记按样式显示，发给模型的仍是原文。
/// Mac 用 NSTextView，iPhone 与 iPad 用 UITextView，都是 TextKit 2，行内代码与引用的装饰和对话正文共用。只有文字，底色与聚焦描边由所在的块卡片给。
struct ContextParagraphField: View {
    @Binding var parts: [ContextPart]
    let variables: [ContextScene.Variable]
    @Binding var focused: Bool
    /// 刚加的段落出现时直接放光标，放好后调 focusHandled。
    var focusRequested = false
    var focusHandled: () -> Void = {}
    @Environment(ContextEditor.self) private var editor: ContextEditor?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let style = ContextTextStyle(variables: variables, colorScheme: colorScheme, scale: displayScale, dynamicTypeSize: dynamicTypeSize)
        ContextTextView(parts: $parts, focused: $focused, style: style, editable: isEnabled, editor: editor,
                        focusRequested: focusRequested, focusHandled: focusHandled)
            .overlay(alignment: .topLeading) {
                if parts.isEmpty {
                    Text("段落文字")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                        .padding(ContextTextStyle.inset)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isEnabled ? 1 : 0.6)
            .typingTarget()
    }
}

/// 在 Kite 的正文之间拷贝时保留变量；拷到别处是纯文字。
private let contextPartsType = "app.kite.context-parts"

private struct ContextTextView {
    @Binding var parts: [ContextPart]
    @Binding var focused: Bool
    let style: ContextTextStyle
    let editable: Bool
    let editor: ContextEditor?
    let focusRequested: Bool
    let focusHandled: () -> Void

    func makeCoordinator() -> ContextTextCoordinator {
        ContextTextCoordinator(parts: $parts, focused: $focused, style: style)
    }

    /// 新加的段落等视图放进窗口后再放光标。
    fileprivate func requestFocus(_ coordinator: ContextTextCoordinator) {
        guard focusRequested else { return }
        Task { @MainActor in
            coordinator.becomeFocused()
            focusHandled()
        }
    }
}

#if os(macOS)
extension ContextTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> ContextNSTextView {
        let coordinator = context.coordinator
        let view = ContextNSTextView(frame: .zero, textContainer: coordinator.makeTextContainer())
        view.coordinator = coordinator
        view.delegate = coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.focusRingType = .none
        view.usesFontPanel = false
        view.usesRuler = false
        // 提示词按原样交给模型，不替换引号、破折号，也不自动改字。
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: ContextTextStyle.inset, height: ContextTextStyle.inset)
        view.typingAttributes = style.attributes
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        coordinator.view = view
        coordinator.editor = editor
        coordinator.load()
        return view
    }

    func updateNSView(_ view: ContextNSTextView, context: Context) {
        view.isEditable = editable
        view.isSelectable = true
        context.coordinator.update(parts: $parts, focused: $focused, style: style, editor: editor)
        requestFocus(context.coordinator)
    }

    static func dismantleNSView(_ view: ContextNSTextView, coordinator: ContextTextCoordinator) {
        coordinator.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ContextNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let inset = view.textContainerInset
        return CGSize(width: width, height: context.coordinator.height(for: width - inset.width * 2) + inset.height * 2)
    }
}

/// 不带滚动的多行文本视图，高度随内容；Tab 换到下一个输入框，Esc 收起光标。
final class ContextNSTextView: NSTextView {
    weak var coordinator: ContextTextCoordinator?

    /// 露出任何一部分就把整段当作视口，和对话正文的 ProseTextView 同一个原因：TextKit 2 只排外层滚动视图可见区里的片段，
    /// 长段落从中间露出时前面按估算高度占位，字先画偏、再跳回去。
    override var visibleRect: NSRect { super.visibleRect.isEmpty ? .zero : bounds }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.focus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.focus(false) }
        return resigned
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.init(contextPartsType), .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.init(contextPartsType), .string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let textStorage else { return false }
        let parts = ContextTextCoordinator.parts(of: textStorage.attributedSubstring(from: selectedRange()))
        switch type {
        case .init(contextPartsType):
            guard let data = try? JSONEncoder().encode(parts) else { return false }
            return pboard.setData(data, forType: type)
        case .string:
            return pboard.setString(parts.plainText, forType: .string)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .init(contextPartsType), let coordinator, let data = pboard.data(forType: type),
           let parts = try? JSONDecoder().decode([ContextPart].self, from: data) {
            insertText(coordinator.attributed(parts), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }
}

extension ContextTextCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { changed() }

    func textViewDidChangeSelection(_ notification: Notification) {
        // 光标停在胶囊后面时，接着打的字不要继承附件；输入法还在拼写时不动。
        if let view, !view.hasMarkedText() { view.typingAttributes = style.attributes }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil)
        case #selector(NSResponder.cancelOperation(_:)): textView.window?.makeFirstResponder(nil)
        default: return false
        }
        return true
    }
}
#else
extension ContextTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> ContextUITextView {
        let coordinator = context.coordinator
        let view = ContextUITextView(frame: .zero, textContainer: coordinator.makeTextContainer())
        view.coordinator = coordinator
        view.delegate = coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.allowsEditingTextAttributes = false
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .none
        view.textContainerInset = UIEdgeInsets(top: ContextTextStyle.inset, left: ContextTextStyle.inset,
                                               bottom: ContextTextStyle.inset, right: ContextTextStyle.inset)
        view.typingAttributes = style.attributes
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        coordinator.view = view
        coordinator.editor = editor
        coordinator.load()
        return view
    }

    func updateUIView(_ view: ContextUITextView, context: Context) {
        view.isEditable = editable
        context.coordinator.update(parts: $parts, focused: $focused, style: style, editor: editor)
        requestFocus(context.coordinator)
    }

    static func dismantleUIView(_ view: ContextUITextView, coordinator: ContextTextCoordinator) {
        coordinator.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ContextUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let inset = view.textContainerInset
        return CGSize(width: width, height: context.coordinator.height(for: width - inset.left - inset.right) + inset.top + inset.bottom)
    }
}

final class ContextUITextView: UITextView {
    weak var coordinator: ContextTextCoordinator?
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        let parts = ContextTextCoordinator.parts(of: textStorage.attributedSubstring(from: selectedRange))
        guard let data = try? JSONEncoder().encode(parts) else { return super.copy(sender) }
        UIPasteboard.general.setItems([[contextPartsType: data, UTType.utf8PlainText.identifier: parts.plainText]])
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.cut(sender) }
        copy(sender)
        deleteBackward()
    }

    override func paste(_ sender: Any?) {
        guard let coordinator, let data = UIPasteboard.general.data(forPasteboardType: contextPartsType),
              let parts = try? JSONDecoder().decode([ContextPart].self, from: data) else { return super.paste(sender) }
        coordinator.insert(parts: parts)
    }
}

extension ContextTextCoordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidBeginEditing(_ textView: UITextView) { focus(true) }
    func textViewDidEndEditing(_ textView: UITextView) { focus(false) }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.markedTextRange == nil { textView.typingAttributes = style.attributes }
    }
}
#endif
