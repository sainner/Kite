#if os(iOS)
import SwiftUI

/// iPhone：会话窗口平时铺满屏幕，盖住 App 的底色。从左边缘往右滑，窗口跟着手指右移，露出底色上的侧边栏；
/// 从底部往上滑，窗口上移，露出底色上的 action 栏。打开时点窗口或往回拖收起。
struct PhoneLayout: View {
    private enum Drawer { case sidebar, actions }

    @State private var open: Drawer?
    /// 手指正在拖的一侧和拖动的距离，松手后按惯性决定打开还是收起。
    @State private var dragging: Drawer?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let sidebarWidth = min(geo.size.width * 0.8, 320)
            // 窗口底边要升到 action 栏上面，action 栏在 Home 条上面
            let actionsHeight = Metrics.actionBar + geo.safeAreaInsets.bottom + Metrics.padding
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()
                // 一次只露出一侧，另一侧藏起来，免得窗口移开时从边上露出来
                Sidebar()
                    .padding(Metrics.padding * 2)
                    .frame(width: sidebarWidth)
                    .opacity(showing(.sidebar) ? 1 : 0)
                ActionBar()
                    .frame(height: Metrics.actionBar)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(showing(.actions) ? 1 : 0)
                window(sidebarWidth: sidebarWidth, actionsHeight: actionsHeight, bottomInset: geo.safeAreaInsets.bottom)
            }
        }
    }

    private func window(sidebarWidth: CGFloat, actionsHeight: CGFloat, bottomInset: CGFloat) -> some View {
        PaneContent(pane: .session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Metrics.phoneCardRadius).fill(Theme.card).ignoresSafeArea()
            }
            .overlay {
                if let drawer = open {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { settle(nil) }
                        .gesture(drag(drawer, extent: drawer == .sidebar ? sidebarWidth : actionsHeight))
                }
            }
            .overlay(alignment: .leading) {
                if open == nil {
                    Color.clear
                        .frame(width: Metrics.edgeZone)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .gesture(drag(.sidebar, extent: sidebarWidth))
                }
            }
            .overlay(alignment: .bottom) {
                // 盖住 Home 条那一段再往上一点。从屏幕最底边起滑仍是系统回主屏幕的手势
                if open == nil {
                    Color.clear
                        .frame(height: Metrics.edgeZone + bottomInset)
                        .contentShape(Rectangle())
                        .offset(y: bottomInset)
                        .gesture(drag(.actions, extent: actionsHeight))
                }
            }
            .offset(x: offset(.sidebar, extent: sidebarWidth), y: -offset(.actions, extent: actionsHeight))
    }

    private func showing(_ drawer: Drawer) -> Bool {
        open == drawer || dragging == drawer
    }

    /// 窗口朝打开方向移开的距离。
    private func offset(_ drawer: Drawer, extent: CGFloat) -> CGFloat {
        let base = open == drawer ? extent : 0
        guard dragging == drawer else { return base }
        let moved = drawer == .sidebar ? translation.width : -translation.height
        return min(max(base + moved, 0), extent)
    }

    private func drag(_ drawer: Drawer, extent: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                dragging = drawer
                translation = value.translation
            }
            .onEnded { value in
                let end = value.predictedEndTranslation
                let moved = drawer == .sidebar ? end.width : -end.height
                let base = open == drawer ? extent : 0
                settle(base + moved > extent / 2 ? drawer : nil)
            }
    }

    private func settle(_ drawer: Drawer?) {
        withAnimation(.snappy) {
            open = drawer
            dragging = nil
            translation = .zero
        }
    }
}

/// action 栏，比如切换会话。现在只有占位色块。
private struct ActionBar: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12).fill(Theme.placeholder)
            }
        }
        .padding(.horizontal, Metrics.padding * 2)
    }
}
#endif
