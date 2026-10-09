import SwiftUI

extension View {
    /// 点按正文、标题或控件都交接焦点。
    func paneFocus(_ pane: Pane, in layout: WindowLayout, enabled: Bool = true) -> some View {
        simultaneousGesture(TapGesture().onEnded {
                if enabled { layout.focus(pane) }
            })
    }
}
