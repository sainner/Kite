import SwiftUI

/// 卡片样式的弹窗骨架。标题栏在 iPhone 上依次是关闭、标题、其他操作，Mac 上关闭在右、其他操作在左；
/// 子页面把关闭换成返回，两端都在左边。主按钮贴底，iPhone 上紧挨安全区，Mac 上没有安全区，底边留白同左右。
/// 正文从两条栏后面滚过，滚到标题栏下时由系统的软边滚动边缘效果模糊。
/// 不给 size 时按内容定高，放不下（键盘升起）时正文滚动；给了 size 的（设置、编辑器这类会变长的）Mac 上用这个尺寸，iPhone 上铺满高度。
struct CardSheet<Content: View, Actions: View, Footer: View>: View {
    let titleText: String
    /// 标题下的一行说明。
    var subtitle: String?
    /// 正在打字：iPhone 上键盘升起，弹窗被顶到键盘上方，读到的 Home 条安全区不再可信。
    var typing = false
    /// 子页面：左上角是返回而不是关闭。
    var back = false
    /// 需要把操作组放在关闭按钮旁边的弹窗使用；其他 Mac 弹窗沿用左侧操作区。
    var trailingActions = false
    var size: CGSize?
    let close: () -> Void
    let content: Content
    let actions: Actions
    let footer: Footer
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// 弹窗自身的底部安全区，不含键盘。
    @State private var bottomSafeArea: CGFloat = 0

    init(title: String, subtitle: String? = nil, typing: Bool = false, back: Bool = false, trailingActions: Bool = false, size: CGSize? = nil,
         close: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions = { EmptyView() }, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.titleText = title
        self.subtitle = subtitle
        self.typing = typing
        self.back = back
        self.trailingActions = trailingActions
        self.size = size
        self.close = close
        self.content = content()
        self.actions = actions()
        self.footer = footer()
    }

    private var dismissButton: some View {
        PaneHeaderButtonGroup {
            Button(action: close) {
                PaneHeaderButtonLabel(back ? "返回" : "关闭", systemImage: back ? "chevron.left" : "xmark")
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var title: some View {
        PaneHeaderTitle(header: PaneHeader(title: titleText, subtitle: subtitle))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    /// Mac 弹窗没有安全区，底边留白和左右一样。
    private var footerBottom: CGFloat { CardMetrics.sheetInset }
    #else
    /// 按钮栏不走系统的底部安全区，从弹窗底边起固定留出 Home 条那一截：平时按钮正好在安全区上沿，
    /// 键盘把弹窗顶起、底下没了安全区时，按钮和弹窗高度都不变，不跟着键盘的动画跳。
    private var footerBottom: CGFloat { bottomSafeArea }
    #endif

    /// Mac 用三段的实际高度作为理想尺寸打开并更新同一个 sheet；放不下时正文滚动。
    /// iPhone 上按量出的高度给 detent，键盘升起时正文滚动。
    var body: some View {
        #if os(macOS)
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
        #else
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
        #endif
    }

    /// 正文从两条栏后面滚过，滚到标题栏下时软边模糊。
    private var scrolling: some View {
        ScrollView {
            page
        }
        .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .top, spacing: 0) {
                header
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                footerBar
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var header: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            #if os(macOS)
            if back {
                dismissButton
                title
                actions
            } else {
                if !trailingActions { actions }
                // 左边没有操作按钮时，标题和正文左边对齐
                title.padding(.leading, trailingActions || Actions.self == EmptyView.self ? CardMetrics.sheetInset - Metrics.paneMargin : 0)
                if trailingActions { actions }
                dismissButton
            }
            #else
            dismissButton
            title
            actions
            #endif
        }
        .padding(.leading, Metrics.paneMargin)
        // 窗口标题栏的边距在 Mac 上偏紧，弹窗标题栏上下和右边至少留 padding，角上的关闭按钮离两边一样远
        .padding([.vertical, .trailing], max(Metrics.paneMargin, Metrics.padding))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CardMetrics.sheetInset)
            .padding(.vertical, Metrics.padding)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                if old == 0 { bodyHeight = new } else { withAnimation(.snappy) { bodyHeight = new } }
            }
    }

    /// 没有主按钮时，正文已有一段底边留白，只补足剩下的安全距离。
    private var footerBar: some View {
        Group(subviews: footer) { buttons in
            if buttons.isEmpty {
                Color.clear.frame(height: max(0, footerBottom - Metrics.padding))
            } else {
                VStack(spacing: 0) { buttons }
                    .padding(.horizontal, CardMetrics.sheetInset)
                    .padding(.top, Metrics.padding)
                    .padding(.bottom, footerBottom)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
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

/// 标题栏上的图标操作，如重新读取。
struct CardSheetAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        PaneHeaderButtonGroup {
            Button(action: action) { PaneHeaderButtonLabel(title, systemImage: systemImage) }
                .help(title)
        }
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
