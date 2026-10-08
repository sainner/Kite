import SwiftUI

/// 旧窗口保留到移出屏幕，与新窗口在同一动画中平移；不复用旧视图上一次插入时的转场方向。
struct CompactPaneStack: View {
    let group: PaneGroup
    let width: CGFloat
    let canSwitch: Bool
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
                    .background(Theme.card)
                    .offset(x: pane == departing ? -distance : 0)
                    .transition(distance == 0 ? .opacity : .offset(x: distance))
                    .zIndex(pane == group.layout.focused ? 1 : 0)
                    .allowsHitTesting(pane == group.layout.focused)
            }
        }
        .animation(.snappy, value: group.layout.focused)
        .environment(\.switchPane, canSwitch ? switchPane : nil)
    }

    /// 与底栏采用同一窗口顺序；到头就停，只切焦点，不改宽屏排布。
    private func switchPane(_ step: Int) {
        let layout = group.layout
        let panes = layout.panes
        guard canSwitch, let focused = layout.focused,
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
