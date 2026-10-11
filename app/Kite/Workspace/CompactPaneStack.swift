import SwiftUI

/// 旧窗口保留到移出屏幕，与新窗口在同一动画中平移；不复用旧视图上一次插入时的转场方向。
/// 窗口不垫底色：卡片底色与点阵由窗口外壳画，见 WindowShell。
struct CompactPaneStack: View {
    let group: PaneGroup
    let motion: DrawerMotion
    let width: CGFloat
    @State private var departing: Pane?
    @State private var distance: CGFloat = 0
    @State private var switchID: UUID?

    private var visiblePanes: [Pane] {
        group.layout.panes.filter { $0 == group.layout.focused || $0 == departing }
    }

    var body: some View {
        ZStack {
            ForEach(visiblePanes, id: \.self) { pane in
                PaneBody(group: group, pane: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: pane == departing ? -distance : 0)
                    .transition((distance == 0 ? AnyTransition.opacity : .offset(x: distance)).combined(with: .dotsPresence))
                    // 滑走的窗口一开始离场，图案就收回
                    .modifier(DotsPresence(presented: pane != departing))
                    .zIndex(pane == group.layout.focused ? 1 : 0)
                    .allowsHitTesting(pane == group.layout.focused)
            }
        }
        .animation(.snappy, value: group.layout.focused)
        // 一直给着，拉开抽屉时在切换时判断：有无来回切的话，开合起止时读环境的视图都要重算
        .environment(\.switchPane, switchPane)
    }

    /// 与底栏采用同一窗口顺序；到头就停，只切焦点，不改宽屏排布。窗口没铺满（抽屉拉开或正在走）时不切。
    private func switchPane(_ step: Int) {
        let layout = group.layout
        let panes = layout.panes
        guard motion.collapsed, let focused = layout.focused,
              let index = panes.firstIndex(of: focused), panes.indices.contains(index + step) else { return }
        let id = UUID()
        // 完成回调只清理离场视图，不承担交互解锁；下一次操作可以直接接续本次动画。
        withAnimation(.snappy, completionCriteria: .logicallyComplete) {
            switchID = id
            distance = CGFloat(step) * width
            departing = focused
            layout.focus(panes[index + step])
        } completion: {
            guard switchID == id else { return }
            // 旧窗口已经在屏幕外，清理时不再触发第二段转场。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                departing = nil
                distance = 0
                switchID = nil
            }
        }
    }
}
