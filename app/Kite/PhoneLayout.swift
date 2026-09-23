#if os(iOS)
import SwiftUI
import UIKit

/// iPhone：会话窗口平时铺满屏幕，盖住 App 的底色。从左边缘往右滑，窗口右移，上下边距同时出现，露出底色上的侧边栏；
/// 从窗口底部往上滑，窗口上移，左右边距同时出现，露出底色上的 action 栏。圆角同时从屏幕圆角变成屏幕圆角减去边距。
/// 打开时点窗口或往回拖收起。
struct PhoneLayout: View {
    private enum Drawer { case sidebar, actions }

    @State private var open: Drawer?
    /// 手指正在拖的一侧和拖动的距离，松手后按惯性决定打开还是收起。
    @State private var dragging: Drawer?
    @State private var translation: CGSize = .zero
    /// 屏幕圆角，读到之前按 0 算：铺满时窗口的角本来就被屏幕圆角盖住。
    @State private var screenRadius: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)
            let sidebarWidth = min(screen.width * 0.8, 320)
            // 窗口底边要升到 action 栏上面，action 栏在 Home 条上面
            let actionsHeight = Metrics.actionBar + insets.bottom + Metrics.padding
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()
                ScreenCornerReader { screenRadius = $0 }.ignoresSafeArea()
                // 一次只露出一侧，另一侧藏起来，免得窗口移开时从边上露出来
                Sidebar()
                    .padding(.top, Metrics.padding * 2)
                    .padding(.leading, Metrics.padding + Metrics.sidebarLeading)
                    .padding(.trailing, Metrics.gap)
                    .frame(width: sidebarWidth)
                    .opacity(showing(.sidebar) ? 1 : 0)
                ActionBar()
                    .frame(height: Metrics.actionBar)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(showing(.actions) ? 1 : 0)
            }
            // 窗口铺满整个屏幕，放在 overlay 里，不把上面这层撑出安全区，action 栏才能留在 Home 条上面
            .overlay(alignment: .topLeading) {
                window(screen: screen, insets: insets, sidebarWidth: sidebarWidth, actionsHeight: actionsHeight)
            }
        }
    }

    private func window(screen: CGSize, insets: EdgeInsets, sidebarWidth: CGFloat, actionsHeight: CGFloat) -> some View {
        let s = progress(.sidebar, extent: sidebarWidth)
        let a = progress(.actions, extent: actionsHeight)
        let pad = Metrics.padding
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: max(screenRadius - (s + a) * pad, 0)).fill(Theme.card)
            // 内容始终让开状态栏和 Home 条
            PaneContent(pane: .session).padding(insets)
        }
        .frame(width: screen.width - 2 * a * pad, height: screen.height - 2 * s * pad)
        .overlay {
            if let drawer = open {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { settle(nil) }
                    .gesture(drag(drawer, extent: drawer == .sidebar ? sidebarWidth : actionsHeight))
            }
        }
        .overlay(alignment: .leading) {
            if open == nil {
                Color.clear
                    .frame(width: Metrics.edgeZone)
                    .contentShape(Rectangle())
                    .gesture(drag(.sidebar, extent: sidebarWidth))
            }
        }
        .overlay(alignment: .bottom) {
            // 盖住 Home 条那一段再往上一点。从屏幕最底边起滑仍是系统回主屏幕的手势
            if open == nil {
                Color.clear
                    .frame(height: Metrics.edgeZone + insets.bottom)
                    .contentShape(Rectangle())
                    .gesture(drag(.actions, extent: actionsHeight))
            }
        }
        .offset(x: s * sidebarWidth + a * pad, y: s * pad - a * actionsHeight)
        .ignoresSafeArea()
    }

    private func showing(_ drawer: Drawer) -> Bool {
        open == drawer || dragging == drawer
    }

    /// 打开到几成，0 是铺满，1 是完全打开。
    private func progress(_ drawer: Drawer, extent: CGFloat) -> CGFloat {
        let base: CGFloat = open == drawer ? 1 : 0
        guard dragging == drawer, extent > 0 else { return base }
        let moved = drawer == .sidebar ? translation.width : -translation.height
        return min(max(base + moved / extent, 0), 1)
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
                let base: CGFloat = open == drawer ? 1 : 0
                settle(base + moved / extent > 0.5 ? drawer : nil)
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

/// 读屏幕圆角：铺满屏幕、圆角和容器同心的 UIView，它的实际圆角就是屏幕圆角（iOS 26 起的公开接口）。
private struct ScreenCornerReader: UIViewRepresentable {
    let onRead: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.cornerConfiguration = .corners(radius: .containerConcentric())
        view.onRead = onRead
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onRead = onRead
    }

    final class Probe: UIView {
        var onRead: ((CGFloat) -> Void)?
        private var last: CGFloat?

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = effectiveRadius(corner: .topLeft)
            guard radius != last, let onRead else { return }
            last = radius
            // 不在布局过程中改 SwiftUI 的状态
            Task { onRead(radius) }
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
