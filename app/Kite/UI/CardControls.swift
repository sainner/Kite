import SwiftUI

/// 卡片里的控件：初始配置和新建弹窗共用一套输入框、下拉选择、提示与底部按钮。
enum CardMetrics {
    /// 卡片四边的留白。
    static let inset = Metrics.padding * 2
    /// 弹窗正文和底部按钮的左右留白，比卡片窄一些。
    static let sheetInset: CGFloat = 16
    #if os(macOS)
    static let fieldHeight: CGFloat = 36
    #else
    static let fieldHeight: CGFloat = 48
    #endif
}

/// 上面一行标签，下面是不带边框的填充框，聚焦时描主题色。框里放 cardInput 的输入框或 CardSelectStyle 的菜单。
struct CardField<Content: View>: View {
    let label: String
    var focused = false
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
                // 和框里的文字左边对齐
                .padding(.horizontal, 12)
            content
                .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
                .background(Theme.codeBackground, in: shape)
                .overlay { shape.strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5) }
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

extension View {
    /// 填充框里的输入框：无边框、正文字号，整块都能点进去。点它不算点空白处，所在区域的 endsTyping 不收键盘。
    /// 左边已有图标按钮时 leading 收窄。
    func cardInput(leading: CGFloat = 12, focus: @escaping () -> Void) -> some View {
        textFieldStyle(.plain)
            .font(Theme.body)
            .padding(.leading, leading)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(minHeight: CardMetrics.fieldHeight)
            .contentShape(Rectangle())
            .onTapGesture(perform: focus)
            .typingTarget()
    }
}

/// 填充框里的下拉选择：Menu 配 .menuStyle(.button) 用，选中项靠左，右侧上下箭头。
struct CardSelectStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(Theme.caption).foregroundStyle(.secondary)
        }
        .font(Theme.body)
        .padding(.horizontal, 12)
        .frame(minHeight: CardMetrics.fieldHeight)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 卡片里的一条提示，如出错原因。
struct CardCallout: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint = Theme.danger

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).foregroundStyle(tint == .secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 卡片底部的按钮：主按钮占满剩下的宽度，次要按钮在它左边。
struct CardActions: View {
    let primary: String
    var enabled = true
    var prominent = true
    var secondary: String?
    var secondaryEnabled = true
    let action: () -> Void
    var secondaryAction: () -> Void = {}

    var body: some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                if let secondary {
                    Button(secondary, action: secondaryAction)
                        .buttonStyle(.glass)
                        .disabled(!secondaryEnabled)
                }
                let button = Button(action: action) {
                    Text(primary).frame(maxWidth: .infinity)
                }
                .disabled(!enabled)
                if prominent {
                    button.buttonStyle(.glassProminent)
                } else {
                    button.buttonStyle(.glass)
                }
            }
            .font(Theme.body.weight(.semibold))
            #if os(macOS)
            .controlSize(.extraLarge)
            #else
            .controlSize(.large)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

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
    /// 正文是自己会滚动的 Form，不再套 ScrollView。须同时给 size。
    var form = false
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

    init(title: String, subtitle: String? = nil, typing: Bool = false, back: Bool = false, form: Bool = false,
         size: CGSize? = nil, close: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions = { EmptyView() }, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.titleText = title
        self.subtitle = subtitle
        self.typing = typing
        self.back = back
        self.form = form
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

    /// Mac 上按内容定高的弹窗按理想尺寸开出来：放得下时三段直接排列，理想尺寸就是内容本身，不用量，打开时不会从零撑开；
    /// 超出窗口高度时才换成滚动的版本。iPhone 上按量出的高度给 detent，键盘升起时正文滚动。
    var body: some View {
        #if os(macOS)
        Group {
            if let size {
                scrolling.frame(width: size.width, height: size.height)
            } else {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) { header; page; footerBar }
                    scrolling
                }
                .frame(width: 480)
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

    @ViewBuilder private var scrollBody: some View {
        if form {
            content.scrollContentBackground(.hidden)
        } else {
            ScrollView {
                page
                    // 第一次量到的高度直接用，之后内容变化（切换来源、出现报错）才带动画
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                        if old == 0 { bodyHeight = new } else { withAnimation(.snappy) { bodyHeight = new } }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// 正文从两条栏后面滚过，滚到标题栏下时软边模糊。
    private var scrolling: some View {
        scrollBody
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .top, spacing: 0) {
                header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                footerBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
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
                actions
                // 左边没有操作按钮时，标题和正文左边对齐
                title.padding(.leading, Actions.self == EmptyView.self ? CardMetrics.sheetInset - Metrics.paneMargin : 0)
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
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CardMetrics.sheetInset)
            .padding(.vertical, Metrics.padding)
    }

    /// 没有主按钮时只留底边的安全距离。
    private var footerBar: some View {
        Group(subviews: footer) { buttons in
            if buttons.isEmpty {
                Color.clear.frame(height: footerBottom)
            } else {
                VStack(spacing: 0) { buttons }
                    .padding(.horizontal, CardMetrics.sheetInset)
                    .padding(.top, Metrics.padding)
                    .padding(.bottom, footerBottom)
            }
        }
    }
}

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
