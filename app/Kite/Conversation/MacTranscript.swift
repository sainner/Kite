#if os(macOS)
import AppKit
import SwiftUI

/// Mac 主对话的滚动：原生列表建好后接上，发送时让它滑，见 TranscriptListView.send。iPhone 用 TranscriptScroll。
@MainActor final class MacTranscriptScroll {
    fileprivate weak var list: TranscriptListView?

    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        guard let list else {
            _ = append()
            alongside()
            return
        }
        list.send(append, alongside: alongside)
    }
}

/// 把对话的行和环境交给原生列表。insets 是标题栏、控制区让出的高：列表铺满窗口，内容从它们后面滚过去。
struct MacTranscript: NSViewRepresentable {
    let rows: [TranscriptRow]
    let scroll: MacTranscriptScroll
    let insets: EdgeInsets
    /// 开着操作栏的那一行，变了要重排浮层、换托管的行，见 TranscriptListView.update。
    let selected: RowID?

    func makeNSView(context: Context) -> TranscriptListView {
        let list = TranscriptListView()
        scroll.list = list
        return list
    }

    func updateNSView(_ list: TranscriptListView, context: Context) {
        let selection = context.environment.selectedRow
        list.update(rows, context: TranscriptRowContext(environment: context.environment, actionable: true,
                                                        toggleActions: { selection.toggle($0) }),
                    insets: NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
    }

    /// 尺寸由外面给。不给的话 SwiftUI 按 Auto Layout 量 fittingSize，见 HostedContent。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptListView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif
