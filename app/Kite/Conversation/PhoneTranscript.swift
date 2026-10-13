#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 主对话的滚动：原生会话窗口外框建好列表后接上，发送时让它滑，见 PhoneTranscriptView.send。
/// Mac 是 MacTranscriptScroll。
@MainActor final class PhoneTranscriptScroll {
    weak var list: PhoneTranscriptView?

    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        guard let list else {
            _ = append()
            alongside()
            return
        }
        list.send(append, alongside: alongside)
    }
}
#endif
