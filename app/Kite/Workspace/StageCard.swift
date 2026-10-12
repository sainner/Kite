import SwiftUI

/// 内容区不放窗口时的占位卡片，上面放两种内容：没有窗口时的画板（EmptyStage），和一栏只有一页的单页（SectionPage）。
/// 宽屏使用不透明窗口底色，紧凑布局沿用窗口外壳。点阵画在底色上方。
private struct StageCard: ViewModifier {
    var usesDots = false
    var drawsRest = true
    @Environment(\.workspacePresentation) private var presentation
    @Environment(\.stageCardOpacity) private var opacity

    func body(content: Content) -> some View {
        if presentation == .compact {
            content.windowDots(usesDots, drawsRest: drawsRest)
        } else {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            content
                .windowDots(usesDots, drawsRest: drawsRest)
                .background(shape.fill(Theme.card).opacity(opacity))
                .clipShape(shape)
        }
    }
}

extension EnvironmentValues {
    /// 宽屏占位卡片的实色底和上面的文字、按钮有多不透明；点阵不跟着淡，摆在上面的图形照样按自己的节奏长出、收回。见 SettledWindowlessStage。
    @Entry var stageCardOpacity = 1.0
}

extension View {
    /// drawsRest 为 false 时点阵不铺静息的点，卡片是实色底，只画摆在上面的图形。
    func stageCard(usesDots: Bool = false, drawsRest: Bool = true) -> some View {
        modifier(StageCard(usesDots: usesDots, drawsRest: drawsRest))
    }

    /// 单页里的分组表单，底色透出卡片。
    func pageForm() -> some View { modifier(PageForm()) }
}

/// iPhone 上分组表单由 UIKit 托管，左右边距从根视图继承，只有表单盖住屏幕边上那一截边距时才继承得到。
/// 紧凑布局拉开侧边栏时窗口右移，左边距就退回 UIKit 默认的 8 点，所以按 formMargin 固定；没给时用系统默认。
private struct PageForm: ViewModifier {
    @Environment(\.formMargin) private var margin

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, margin, for: .scrollContent)
    }
}


/// 单页：扩展、设置这类一栏只有一页内容，不是窗口，没有控制区和窗口操作。
/// 标题栏沿用窗口标题栏的样子，容器给出侧边栏入口时左边带按钮（iPhone）；内容从标题栏后面滚过去。
struct SectionPage<Content: View, Actions: View>: View {
    let header: PaneHeader
    let usesDots: Bool
    let content: Content
    let actions: Actions
    @Environment(\.openSidebar) private var openSidebar
    /// 窗口已让出的顶部安全区（iPhone），标题栏同窗口一样只补足固定边距。
    @Environment(\.paneTopSafeInset) private var topInset

    init(header: PaneHeader, usesDots: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.header = header
        self.usesDots = usesDots
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            // 单页没有底栏，收起键盘放在键盘上方
            .keyboardDismissToolbar()
            .safeAreaBar(edge: .top, spacing: 0) {
                PaneHeaderBar(header: header, status: EmptyView(), actions: actions, openSidebar: openSidebar)
                    .padding(.top, max(Metrics.paneMargin, topInset) - topInset)
                    .padding(.bottom, Metrics.paneMargin)
                    .background { ScrollEdgeDots() }
                    .drawerShift(.top)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .stageCard(usesDots: usesDots)
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
