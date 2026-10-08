import SwiftUI

extension View {
    /// 同一窗口组只有聚焦窗口显示点阵；点按正文、标题或控件都交接焦点。
    func paneFocus(_ pane: Pane, in layout: WindowLayout, enabled: Bool = true) -> some View {
        environment(\.windowDotsFocused, enabled && layout.focused == pane)
            .simultaneousGesture(TapGesture().onEnded {
                if enabled { layout.focus(pane) }
            })
    }
}
