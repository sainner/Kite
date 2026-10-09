import SwiftUI

extension EnvironmentValues {
    @Entry var headerPane: Pane?
    /// 紧凑窗口的标题栏由外壳显示，正文只为它让出实际高度。
    @Entry var sharedPaneHeaderHeight: CGFloat?
}

struct CompactPaneHeader {
    let pane: Pane
    let header: PaneHeader
    let status: AnyView?
    let actions: AnyView
    let environment: EnvironmentValues
    let openSidebar: (@MainActor () -> Void)?
    let endTyping: () -> Void
}

struct CompactPaneHeaders: PreferenceKey {
    static var defaultValue: [CompactPaneHeader] { [] }
    static func reduce(value: inout [CompactPaneHeader], nextValue: () -> [CompactPaneHeader]) {
        value += nextValue()
    }
}

/// 标题栏留在外壳上，只有正文和底部控制区进入横向切换层。
struct CompactPaneHeaderHost: ViewModifier {
    let focused: Pane?
    @State private var height: CGFloat?
    @Environment(\.paneTopSafeInset) private var topInset

    func body(content: Content) -> some View {
        content
            .environment(\.sharedPaneHeaderHeight, height ?? Metrics.paneHeaderButton + Metrics.paneMargin
                         + max(Metrics.paneMargin, topInset) - topInset)
            .overlayPreferenceValue(CompactPaneHeaders.self) { headers in
                if let source = headers.first(where: { $0.pane == focused }) {
                    CompactPaneHeaderBar(source: source)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .animation(.snappy, value: focused)
    }
}

private struct CompactPaneHeaderBar: View {
    let source: CompactPaneHeader

    var body: some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            PaneHeaderBar(header: source.header, status: Group {
                if let status = source.status {
                    status.id(source.pane).transition(.opacity)
                }
            }, actions: source.actions.id(source.pane).transition(.opacity), openSidebar: source.openSidebar)
        }
        .modifier(PaneHeaderPlacement(endTyping: source.endTyping))
        // 标题栏移出正文后仍使用源窗口的会话、实例与动作环境。
        .environment(\.self, source.environment)
    }
}

struct PaneHeaderPlacement: ViewModifier {
    let endTyping: () -> Void
    @Environment(\.paneTopSafeInset) private var topInset

    func body(content: Content) -> some View {
        content
            .padding(.top, max(Metrics.paneMargin, topInset) - topInset)
            .padding(.bottom, Metrics.paneMargin)
            .coordinateSpace(name: "pane-header")
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PaneHeaderHeight.self, value: proxy.size.height)
                }
            }
            // 软边会糊掉后面的点阵，标题栏底下再画一次，铺到和 topFade 一样大
            .background {
                ScrollEdgeDots()
                    #if os(iOS)
                    .padding(.bottom, -Metrics.topFadeOverhang)
                    .ignoresSafeArea(.container, edges: .top)
                    #endif
            }
            #if os(iOS)
            .background { topFade }
            .contentShape(Rectangle())
            .onTapGesture(perform: endTyping)
            #endif
    }

    #if os(iOS)
    /// 从窗口顶边的不透明渐变到透明，与底部遮罩上下对称。
    private var topFade: some View {
        let stops = (0...10).map { i in
            let h = Double(i) / 10
            return Gradient.Stop(color: Theme.card.opacity(1 - h * h), location: h)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -Metrics.topFadeOverhang)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
    }
    #endif
}
