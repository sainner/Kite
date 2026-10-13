#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 主对话的滚动：原生列表建好后接上，发送时让它滑，见 PhoneTranscriptView.send。Mac 是 MacTranscriptScroll。
@MainActor final class PhoneTranscriptScroll {
    fileprivate weak var list: PhoneTranscriptView?

    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        guard let list else {
            _ = append()
            alongside()
            return
        }
        list.send(append, alongside: alongside)
    }
}

/// 把对话的行和环境交给原生列表。insets 是标题栏、控制区、键盘和左右安全区让出的距离：列表铺满窗口，内容从它们后面滚过去。
/// 让出的距离按帧取值：SwiftUI 带动画改它（控制区长高、收回）时按 Animatable 逐帧重算 body、逐帧交给列表，和控制区同一帧动；
/// 在 updateUIView 里用 context.animate 交给 UIKit 动画会比 SwiftUI 早一帧起步，贴底时对话和控制区错开（spikes/ios-native-transcript V3，
/// 改成按帧取值后同样的场景每帧差 ±0.2 pt 以内）。键盘升降时 SwiftUI 不带动画、在系统键盘的 UIKit 动画块里交下来，列表当场排好，
/// 跟着键盘同一条曲线走。
struct PhoneTranscript: View, Animatable {
    let rows: [TranscriptRow]
    let scroll: PhoneTranscriptScroll
    var insets: EdgeInsets
    /// 开着操作栏的那一行，变了要重排浮层、换托管的行，见 PhoneTranscriptView.update。
    let selected: RowID?

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(insets.top, insets.bottom), AnimatablePair(insets.leading, insets.trailing)) }
        set {
            insets = EdgeInsets(top: newValue.first.first, leading: newValue.second.first,
                                bottom: newValue.first.second, trailing: newValue.second.second)
        }
    }

    var body: some View {
        PhoneTranscriptList(rows: rows, scroll: scroll, insets: insets, selected: selected)
    }
}

private struct PhoneTranscriptList: UIViewRepresentable {
    let rows: [TranscriptRow]
    let scroll: PhoneTranscriptScroll
    let insets: EdgeInsets
    let selected: RowID?

    func makeUIView(context: Context) -> PhoneTranscriptView {
        let list = PhoneTranscriptView()
        scroll.list = list
        return list
    }

    func updateUIView(_ list: PhoneTranscriptView, context: Context) {
        let environment = context.environment
        let selection = environment.selectedRow
        list.update(rows, context: TranscriptRowContext(environment: environment, actionable: true,
                                                        toggleActions: { selection.toggle($0) }),
                    presence: environment.panePresence)
        list.setInsets(insets)
    }

    /// 尺寸由外面给。不给的话 SwiftUI 按 Auto Layout 量。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneTranscriptView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif
