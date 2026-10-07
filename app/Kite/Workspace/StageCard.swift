import SwiftUI

/// 内容区不放窗口时的占位卡片，上面放两种内容：没有窗口时的画板（EmptyStage），和一栏只有一页的单页（SectionPage）。
/// - 宽屏：半透明（浅色白、深色黑，不描边），点阵从底下透出来，与同在点阵上的侧栏分界。
/// - 紧凑布局：放在窗口里，底色和形状都是窗口的；只有空状态画板绘制图案，普通单页不接管背景点阵。
private struct StageCard: ViewModifier {
    var showsFigures = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspacePresentation) private var presentation

    func body(content: Content) -> some View {
        if presentation == .compact {
            content.background {
                if showsFigures { DotCanvas(figuresOnly: true) }
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            content
                .background {
                    ZStack {
                        if showsFigures { DotCanvas(figuresOnly: true) }
                        shape.fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.5))
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
        }
    }
}

extension View {
    func stageCard(showsFigures: Bool = false) -> some View { modifier(StageCard(showsFigures: showsFigures)) }
}


/// 单页：扩展、设置这类一栏只有一页内容，不是窗口，没有控制区和窗口操作。
/// 标题栏沿用窗口标题栏的样子，容器给出侧边栏入口时左边带按钮（iPhone）；内容从标题栏后面滚过去。
struct SectionPage<Content: View, Actions: View>: View {
    let header: PaneHeader
    let content: Content
    let actions: Actions
    @Environment(\.openSidebar) private var openSidebar
    /// 窗口已让出的顶部安全区（iPhone），标题栏同窗口一样只补足固定边距。
    @Environment(\.paneTopSafeInset) private var topInset

    init(header: PaneHeader, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.header = header
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) {
                PaneHeaderBar(header: header, status: EmptyView(), actions: actions, openSidebar: openSidebar)
                    .padding(.top, max(Metrics.paneMargin, topInset) - topInset)
                    .padding(.bottom, Metrics.paneMargin)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .stageCard()
    }
}

/// 工作区没有窗口时的画板，只展示信息：新建和恢复窗口的入口常驻在停靠栏（宽屏右侧、紧凑布局的底栏）。
struct WindowlessStage: View {
    /// 停靠栏在哪，如「右侧停靠栏」「底栏」。
    let dock: String

    var body: some View {
        EmptyStage(scene: .idle, title: "这里还没有窗口", details: ["从\(dock)的添加按钮新建窗口。"])
    }
}
