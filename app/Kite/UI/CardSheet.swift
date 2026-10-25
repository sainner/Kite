import SwiftUI

/// 卡片样式的弹窗骨架。标题栏两端都是关闭、标题、其他操作，关闭固定在左上角。
/// 弹窗可以有几页（实例设置和它的子页面、添加项目的两步）。多页弹窗是一种界面场景，只用这一个视图：标题栏和底栏只有这里的一份，
/// 各页用 cardSheetPage 交出标题、副行、失败原因、操作和底栏按钮，自己只画正文；子页面给 back，左上角的关闭换成返回。
/// 换页时标题栏和底栏原地变（标题模糊替换、关闭换成返回、操作从旁边分出或并回、主按钮换字），正文模糊替换、回到顶部，高度跟着新的一页变。
/// 各页各画一份骨架时，两页的标题栏是两个视图，只能整块淡入淡出或硬切。
/// 保存放在哪按弹窗的用途：编辑内容、填表的放在标题栏的操作区，同窗口；信息展示、步骤引导的主按钮（下一步、提交、推送）贴底，
/// iPhone 上紧挨安全区，Mac 上没有安全区，底边留白同左右。没有信息区，失败原因换掉副行（error），其余状态写在正文。
/// iPhone 键盘升起时底栏放收起键盘：有主按钮时由 CardActions 放，底栏是工具栏时由工具栏放，底栏空着时由这里放。
/// 正文从两条栏后面滚过，滚到标题栏下时由系统的软边滚动边缘效果模糊。
/// 不给 size 时按内容定高，放不下（键盘升起）时正文滚动；给了 size 的（设置、编辑器这类会变长的）Mac 上用这个尺寸，iPhone 上铺满高度。
/// 按内容定高时，影响排版的初始状态（默认选项、预填的字）在弹窗视图的 init 里定好：放到 onAppear 里改，Mac 上窗口先按改前量出的高度打开，
/// 随后跳高。
struct CardSheet<Pages: View>: View {
    var size: CGSize?
    /// 关掉弹窗；子页面左上角是返回，见 CardSheetPage.back。
    let close: () -> Void
    let pages: Pages
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// 弹窗自身的底部安全区，不含键盘。
    @State private var bottomSafeArea: CGFloat = 0
    /// 几页共用一个滚动容器，换页时回到顶部。
    @State private var scroll = ScrollPosition(edge: .top)

    /// 有几页的弹窗：pages 按现在在哪一页给出那一页，每页带 cardSheetPage。
    init(size: CGSize? = nil, close: @escaping () -> Void, @ViewBuilder pages: () -> Pages) {
        self.size = size
        self.close = close
        self.pages = pages()
    }

    #if os(macOS)
    /// Mac 弹窗没有安全区，底边留白和左右一样。
    private var footerBottom: CGFloat { CardMetrics.sheetInset }
    private var keyboardShown: Bool { false }
    #else
    private var keyboardShown: Bool { ScreenKeyboard.shared.shown }
    /// 按钮栏不走系统的底部安全区，从弹窗底边起固定留出 Home 条那一截：平时按钮正好在安全区上沿，
    /// 键盘把弹窗顶起、底下没了安全区时，按钮和弹窗高度都不变，不跟着键盘的动画跳。
    private var footerBottom: CGFloat { bottomSafeArea }
    #endif

    var body: some View {
        // pages 里只有现在这一页；换走的那页由 ForEach 留着做完过渡
        Group(subviews: pages) { pages in
            let page = pages.last?.containerValues.cardSheetPage ?? CardSheetPage()
            sized(scrolling(pages, page: page), typing: page.typing)
                // 换页时标题栏、底栏、正文和高度一起过渡
                .animation(.snappy, value: pages.last?.id)
                .onChange(of: pages.last?.id) { scroll.scrollTo(edge: .top) }
        }
    }

    #if os(macOS)
    /// Mac 用三段的实际高度作为理想尺寸打开并更新同一个 sheet；放不下时正文滚动。
    private func sized(_ scrolling: some View, typing: Bool) -> some View {
        Group {
            if let size {
                scrolling.frame(width: size.width, height: size.height)
            } else {
                // 始终是同一个滚动容器，长内容缩回后仍能读到新的完整高度。三段在窗口显示前的首次排版里就已量出，
                // 不必先换一套不滚动的排法：那时 sheet 窗口还是 0×0，换下来的那份按零尺寸居中，淡出时停在左上角。
                scrolling
                    .frame(width: 480)
                    .frame(idealHeight: headerHeight + bodyHeight + footerHeight)
                    .background(CardSheetWindowSize(height: headerHeight + bodyHeight + footerHeight))
            }
        }
        .presentationBackground(Theme.card)
        .presentationSizing(.fitted)
    }
    #else
    /// iPhone 上按量出的高度给 detent，键盘升起时正文滚动。
    private func sized(_ scrolling: some View, typing: Bool) -> some View {
        scrolling
            .ignoresSafeArea(.container, edges: .bottom)
            .background {
                // 只在没打字时记下 Home 条的安全区，键盘带来的变化不算进去
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
                        if !typing { bottomSafeArea = $0 }
                    }
                    .ignoresSafeArea(.keyboard)
            }
            .presentationBackground(Theme.card)
            // Home 条那一截已算在按钮栏里
            .presentationDetents(size == nil ? [.height(headerHeight + bodyHeight + footerHeight)] : [.large])
    }
    #endif

    /// 正文从两条栏后面滚过，滚到标题栏下时软边模糊。换页时新旧两页叠着过渡，不上下排开。
    private func scrolling(_ pages: SubviewsCollection, page: CardSheetPage) -> some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(pages) { subview in
                    pageBody(subview).transition(.blurReplace)
                }
            }
        }
        .scrollPosition($scroll)
        .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .top, spacing: 0) {
                header(page)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                footerBar(page)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func header(_ page: CardSheetPage) -> some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup {
                Button(action: page.back ?? close) {
                    PaneHeaderButtonLabel(page.back == nil ? "关闭" : "返回", systemImage: page.back == nil ? "xmark" : "chevron.left")
                        .contentTransition(.symbolEffect(.replace))
                }
                .keyboardShortcut(.cancelAction)
            }
            PaneHeaderTitle(header: PaneHeader(title: page.title, subtitle: page.subtitle, failure: page.error))
                .frame(maxWidth: .infinity, alignment: .leading)
            PaneHeaderActions(groups: page.actions, menus: page.menus)
        }
        // 窗口标题栏的边距在 Mac 上偏紧，弹窗标题栏四周至少留 padding，角上的关闭按钮离两边一样远
        .padding(max(Metrics.paneMargin, Metrics.padding))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    /// 高度按新的一页量：换走的那页过渡时还占着地方，大小不再变，不会报上来。
    private func pageBody(_ subview: Subview) -> some View {
        subview
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CardMetrics.sheetInset)
            .padding(.vertical, Metrics.padding)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if bodyHeight == 0 { bodyHeight = height } else { withAnimation(.snappy) { bodyHeight = height } }
            }
    }

    /// 底栏空着时，正文已有一段底边留白，只补足剩下的安全距离；键盘升起时放收起键盘。
    /// 收起键盘撑高的那截不算进弹窗高度：按内容定高的弹窗不跟着键盘变高，正文滚动。
    private func footerBar(_ page: CardSheetPage) -> some View {
        Group(subviews: page.footer) { buttons in
            if !buttons.isEmpty || keyboardShown {
                VStack(spacing: 0) {
                    if buttons.isEmpty { KeyboardDismissButton().frame(maxWidth: .infinity, alignment: .leading) } else { buttons }
                }
                .padding(.horizontal, CardMetrics.sheetInset)
                .padding(.top, Metrics.padding)
                .padding(.bottom, footerBottom)
            } else {
                Color.clear.frame(height: max(0, footerBottom - Metrics.padding))
            }
        }
        // 弹窗由系统顶到键盘上方，底栏里的工具栏也放收起键盘
        .environment(\.keyboardShown, true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !keyboardShown { footerHeight = $0 } }
    }
}

extension CardSheet {
    /// 只有一页的弹窗。
    init<Content: View, Footer: View>(title: String, subtitle: String? = nil, error: String? = nil, typing: Bool = false,
                                      size: CGSize? = nil, menus: AnyView? = nil, close: @escaping () -> Void,
                                      @ViewBuilder content: () -> Content, actions: () -> [[PaneHeaderAction]] = { [] },
                                      @ViewBuilder footer: () -> Footer = { EmptyView() })
    where Pages == CardSheetPageContent<Content> {
        let page = content().cardSheetPage(title, subtitle: subtitle, error: error, typing: typing,
                                           actions: actions(), menus: menus, footer: footer)
        self.init(size: size, close: close) { page }
    }
}

/// 弹窗的一页交给标题栏和底栏的东西，由 CardSheet 统一画。
struct CardSheetPage {
    var title = ""
    /// 标题下一句简短的说明，写这一页做什么；不放状态，也不放所作用的对象。
    var subtitle: String?
    /// 失败原因，有时换掉副行。
    var error: String?
    /// 正在打字：iPhone 上键盘升起，弹窗被顶到键盘上方，读到的 Home 条安全区不再可信。
    var typing = false
    /// 子页面回到上一页：左上角是返回而不是关闭。
    var back: (() -> Void)?
    /// 标题栏的操作，同窗口的右组：每组一块玻璃，换页时按位置原地变，多出来的从旁边分出、少了的并回去。
    var actions: [[PaneHeaderAction]] = []
    /// 操作前面的菜单，同 PaneHeaderActions.menus。
    var menus: AnyView?
    var footer = AnyView(EmptyView())
}

extension ContainerValues {
    @Entry var cardSheetPage: CardSheetPage?
}

/// 弹窗的一页：正文各段竖排，带着交给 CardSheet 的标题栏和底栏。
struct CardSheetPageContent<Content: View>: View {
    let page: CardSheetPage
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .containerValue(\.cardSheetPage, page)
    }
}

extension View {
    /// 把这个视图作为弹窗的一页放进 CardSheet，见 CardSheetPage。back 排在 footer 后面：不带标签的尾随闭包只会给到底栏，
    /// 排在前面时会被当成返回，底栏没了、左上角变成返回也照样编得过。
    func cardSheetPage<Footer: View>(_ title: String, subtitle: String? = nil, error: String? = nil, typing: Bool = false,
                                     actions: [[PaneHeaderAction]] = [], menus: AnyView? = nil,
                                     @ViewBuilder footer: () -> Footer = { EmptyView() },
                                     back: (() -> Void)? = nil) -> CardSheetPageContent<Self> {
        CardSheetPageContent(page: CardSheetPage(title: title, subtitle: subtitle, error: error, typing: typing, back: back,
                                                 actions: actions, menus: menus, footer: AnyView(footer())),
                             content: self)
    }
}


#if os(macOS)
/// 系统有时只更新 sheet 的尺寸约束，既有窗口仍停留在初始高度；按内容更新原窗口，不重建登录流程。
private struct CardSheetWindowSize: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ view: Reader, context: Context) {
        view.contentHeight = height
        view.scheduleResize()
    }

    final class Reader: NSView {
        var contentHeight: CGFloat = 0
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleResize() }
        override func layout() { super.layout(); scheduleResize() }

        func scheduleResize() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.resizeSheet()
            }
        }

        private func resizeSheet() {
            guard contentHeight > 0, let window, let parent = window.sheetParent else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            let decoration = window.frame.height - current.height
            let screen = parent.screen ?? window.screen
            let available = screen.map { max(1, window.frame.maxY - $0.visibleFrame.minY - decoration) } ?? contentHeight
            let height = min(contentHeight, available)
            guard abs(current.height - height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height - decoration
            frame.size.height = height + decoration
            window.setFrame(frame, display: true)
        }
    }
}
#endif


extension PaneHeaderAction {
    /// 弹窗标题栏上的操作，在忙时换成转圈，同窗口的右组。重新读取这类给图标；不给图标的是保存、创建这类确认动作，
    /// 显示文字、用主题色，见 prominent。分步骤的弹窗（添加项目）的下一步与最后的确认不放这里，用底部的 CardActions。
    static func sheet(_ title: String, systemImage: String? = nil, busy: Bool = false, disabled: Bool = false,
                      action: @escaping () -> Void) -> PaneHeaderAction {
        PaneHeaderAction(title: title, systemImage: systemImage, busy: busy, disabled: disabled, prominent: systemImage == nil, action: action)
    }
}

extension View {
    /// 放弃未保存修改前的确认：居中的警告框，放弃标成危险操作，另有取消；message 说明会丢掉什么。
    func discardAlert(_ title: String, isPresented: Binding<Bool>, discardLabel: String = "放弃修改", message: String? = nil,
                      discard: @escaping () -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            Button(discardLabel, role: .destructive, action: discard)
            Button("取消", role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }

    /// 同上，item 记着放弃之后要接着做的事，关掉警告框时清空。
    func discardAlert<Item>(_ title: String, item: Binding<Item?>, discard: @escaping (Item) -> Void) -> some View {
        alert(title, isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
              presenting: item.wrappedValue) { value in
            Button("放弃修改", role: .destructive) { discard(value) }
            Button("取消", role: .cancel) {}
        }
    }
}
