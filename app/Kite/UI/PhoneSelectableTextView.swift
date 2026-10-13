#if os(iOS)
import SwiftUI
import UIKit

/// UIKit 的文本视图，用来在 iPhone 上选字：子 agent 做的事、压缩摘要、嵌套的消息这些还在 SwiftUI 里的正文用它，
/// 主对话的原生列表（PhoneTranscriptView）直接用同一个文本视图（PhoneProseTextView）和触摸（PhoneTextInteraction）。
/// 点一下只处理链接与取消选区；长按不动显示操作栏；长按以后接着拖是选字，见 PhoneTextInteraction。
/// 补字、量尺寸、附件重排与 Mac 共用，见 ProseTextCoordinator。
/// fillsWidth：占满给的宽度；不然贴着字的宽度，长的折行。
struct SelectableTextView: UIViewRepresentable {
    @Environment(\.openURL) private var openURL
    let content: TextViewContent
    let inset: CGSize
    let fillsWidth: Bool
    let showActions: () -> Void
    let dismissActions: () -> Void

    private var text: NSAttributedString { content.text }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = PhoneProseTextView.make()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        view.textLayoutManager?.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.interaction = PhoneTextInteraction(text: view, host: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        if let interaction = coordinator.interaction {
            let openURL = openURL
            interaction.openURL = { openURL($0) }
            interaction.showActions = showActions
            interaction.dismissActions = dismissActions
        }
        view.textContainerInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        (view as? PhoneProseTextView)?.source = content.source
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(context.environment))
        let sameScheme = coordinator.colorScheme == context.environment.colorScheme
        guard coordinator.shown != text || !sameScheme else { return }
        // 外观没变、只是接着长时只补末尾的字，不动选区和 isSelectable
        if sameScheme, coordinator.appendTail(of: text) { return }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = coordinator.shown?.string != text.string
        let selection = view.selectedRange
        let selectable = view.isSelectable
        coordinator.interaction?.refreshingAppearance = !textChanged
        coordinator.shown = text
        coordinator.colorScheme = context.environment.colorScheme
        view.attributedText = text
        if !textChanged {
            view.isSelectable = selectable
            view.selectedRange = selection
        }
        coordinator.interaction?.refreshingAppearance = false
    }

    /// 高度照文本视图自己排出来的算，量过的按给的宽度记下：对话一重排（发送、收到回复）就把所有消息各量几遍，
    /// 不记的话主线程卡几百毫秒（2026-10-11 iPhone 实测）。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        context.coordinator.size(inset: inset, environment: context.environment, width: proposal.width) {
            let most = (proposal.width ?? .greatestFiniteMagnitude) - inset.width * 2
            let width = (fillsWidth && proposal.width != nil ? most : ProseTextCoordinator.naturalWidth(of: text, most: most)) + inset.width * 2
            return CGSize(width: width, height: view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
    }

    final class Coordinator: ProseTextCoordinator {
        var interaction: PhoneTextInteraction?
        var colorScheme: ColorScheme?
    }
}
#endif
