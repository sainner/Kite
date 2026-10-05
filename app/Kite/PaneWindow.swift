import SwiftUI

/// 窗口标题与第二行次级信息，两端共用。
struct PaneHeader {
    var title: String
    var detail: Detail?
    var titleRefresh: TitleRefresh?

    /// 主标题与尾部刷新图标共用点击范围，生成期间保持原题。
    struct TitleRefresh {
        var actionLabel: String
        var progressLabel: String
        var isRefreshing: Bool
        var enabled: Bool
        var action: () -> Void
    }

    enum Detail {
        case text(String)
        /// 路径相对于工作区；目录可点击，末尾文件名只展示。
        case path(root: String, directory: String, file: String?, open: (String) -> Void)
    }
}

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// Mac 标题栏后面垫卡片自己的系统栏材料，iPhone 用系统滚动软边叠渐变；控制区后面垫一层到窗口底边的渐变遮罩。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容、控制区里的东西，
/// 会话状态在 Mac 输入区，iPhone 底部安全区内。
/// 控制区是液态玻璃容器，各个窗口给内部控件提供玻璃形状；左右留边，底部总边距统一取固定留白与安全区高度的较大值。
/// 安全区已由窗口容器让出，控制区补足差额；打字时在键盘上方保留固定留白。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘；不打字时从控制区往上拖拉出 action 栏。
/// iPhone 上标题栏左边有个按钮拉开侧边栏。
struct PaneWindow<Content: View, Controls: View, Status: View, HeaderActions: View>: View {
    let header: PaneHeader
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    let status: Status
    let headerActions: HeaderActions
    @FocusState private var typing: Bool
    /// 窗口底部为 Home 条保留的高度，不含键盘；底栏展开时仍保留。
    @Environment(\.homeIndicatorInset) private var homeInset
    @Environment(\.paneTopSafeInset) private var topInset
    @Environment(\.keyboardShown) private var keyboardShown
    @Environment(\.openSidebar) private var openSidebar

    init(header: PaneHeader, @ViewBuilder content: () -> Content,
         @ViewBuilder controls: @escaping (_ typing: FocusState<Bool>.Binding) -> Controls,
         @ViewBuilder status: () -> Status = { EmptyView() },
         @ViewBuilder headerActions: () -> HeaderActions = { EmptyView() }) {
        self.header = header
        self.content = content()
        self.controls = controls
        self.status = status()
        self.headerActions = headerActions()
    }

    var body: some View {
        let bottomSafeArea = keyboardShown ? 0 : homeInset
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 加在控制区外面这一层，点控制区不算
            .endsTyping($typing)
            .paneBar(edge: .bottom) {
                GlassEffectContainer(spacing: Metrics.paneButtonGap) {
                    controls($typing)
                }
                    .padding(.horizontal, Metrics.paneMargin)
                    // 总底边距取 max(固定留白, 安全区)，容器已经让出的安全区只计算一次。
                    // 键盘显示时容器已让出键盘，在它上方补固定留白；和键盘自己的动画同步。
                    .padding(.bottom, max(Metrics.paneMargin, bottomSafeArea) - bottomSafeArea)
                    .frame(maxWidth: .infinity)
                    .background { bottomFade }
                    #if os(iOS)
                    .overlay(alignment: .bottom) {
                        if !keyboardShown && homeInset >= 20 {
                            status
                                .frame(maxWidth: .infinity)
                                .frame(height: homeInset)
                                .offset(y: homeInset)
                        }
                    }
                    #endif
                    // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                    .pullsDrawer(enabled: !typing)
            }
            .paneBar(edge: .top) {
                HeaderBar(header: header, actions: headerActions, openSidebar: sidebarAction)
                    .padding(.top, max(Metrics.paneMargin, topInset) - topInset)
                    .padding(.bottom, Metrics.paneMargin)
                    #if os(macOS)
                    .coordinateSpace(name: "pane-header")
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PaneHeaderHeight.self, value: proxy.size.height)
                        }
                    }
                    .background(.bar, in: Rectangle())
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                    #endif
                    #if os(iOS)
                    .background { topFade }
                    .contentShape(Rectangle())
                    .onTapGesture { typing = false }
                    #endif
            }
            // Mac 的模糊材料只属于当前卡片，避免系统把贴近窗口顶边的多个滚动区合并到同一个软边合成组。
            // iPhone 继续叠系统软边；滚动区都铺到顶边，不用额外留出无法滚入的空白。
            #if os(macOS)
            .scrollEdgeEffectHidden(true, for: .top)
            #else
            .scrollEdgeEffectStyle(.soft, for: .top)
            #endif
            // 控制区后面用自己的渐变遮罩，见 bottomFade
            .scrollEdgeEffectHidden(true, for: .bottom)
    }

    /// 标题栏左边按钮的动作：先收起键盘，再拉开侧边栏。
    private var sidebarAction: (@MainActor () -> Void)? {
        guard let openSidebar else { return nil }
        return {
            typing = false
            openSidebar()
        }
    }

    #if os(iOS)
    /// 标题栏遮罩从窗口顶边的不透明渐变到透明，与底部遮罩上下对称。
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

    /// 控制区后面的渐变遮罩：用窗口的底色，从控制区顶边的全透明过渡到不透明，往下伸过 Home 条那一截到窗口底边，
    /// 内容滚到这里渐渐淡掉。不透明度是 1 − h²，h 是离窗口底边的距离占整段高度的比例：底下一截接近不透，越往上掉得越快。
    private var bottomFade: some View {
        let stops = (0...10).map { i in
            let h = 1 - Double(i) / 10
            return Gradient.Stop(color: Theme.card.opacity(1 - h * h), location: 1 - h)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -homeInset)
            .allowsHitTesting(false)
    }

}

private extension View {
    /// Mac 的栏只调整安全区，不向系统标题栏登记滚动边缘效果。
    @ViewBuilder
    func paneBar<Bar: View>(edge: VerticalEdge, @ViewBuilder content: () -> Bar) -> some View {
        #if os(macOS)
        safeAreaInset(edge: edge, spacing: 0, content: content)
        #else
        safeAreaBar(edge: edge, spacing: 0, content: content)
        #endif
    }
}

/// 卡片标题栏按平台排列标题、侧栏入口与窗口菜单。
private struct HeaderBar<Actions: View>: View {
    let header: PaneHeader
    let actions: Actions
    @Environment(\.paneHeaderControlsInset) private var controlsInset
    @Environment(\.paneHeaderMinHeight) private var controlsHeight
    let openSidebar: (@MainActor () -> Void)?
    var body: some View {
        #if os(macOS)
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderTitle(header: header)
                .padding(.leading, Metrics.paneTitleInset)
            Spacer(minLength: 0)
            actions
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PaneHeaderActionsWidth.self, value: proxy.size.width)
                    }
                }
                .padding(.leading, controlsInset)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.paneMargin)
            .frame(minHeight: controlsHeight)
        #else
        HStack(spacing: Metrics.paneButtonGap) {
            sidebarButton
            PaneHeaderTitle(header: header)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, Metrics.paneMargin)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var sidebarButton: some View {
        if let openSidebar {
            PaneButtonGroup {
                Button(action: openSidebar) {
                    PaneButtonLabel("侧边栏", systemImage: "sidebar.left")
                }
                .buttonBorderShape(.circle)
            }
        }
    }
    #endif
}

/// 所有窗口共用同一套标题排版，次级信息可为文字或目录导航。
struct PaneHeaderTitle: View {
    let header: PaneHeader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.paneTitleSpacing) {
            title
            detail
        }
        .lineLimit(1)
    }

    private var title: some View {
        Group {
            if let refresh = header.titleRefresh {
                Button(action: refresh.action) {
                    HStack(spacing: 4) {
                        Text(header.title)
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                            .symbolEffect(.rotate, options: .repeating, isActive: refresh.isRefreshing && !reduceMotion)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointingPlain)
                .disabled(!refresh.enabled)
                .help(refresh.isRefreshing ? refresh.progressLabel : "点击\(refresh.actionLabel)")
                .accessibilityLabel(refresh.actionLabel)
                .accessibilityValue(header.title)
                .background { interactiveBoundary }
            } else {
                Text(header.title)
            }
        }
        #if os(macOS)
        .font(Theme.title.weight(.semibold))
        #else
        .font(Theme.secondary.weight(.semibold))
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = header.detail {
            Group {
                switch detail {
                case .text(let text):
                    Text(text)
                case .path(let root, let directory, let file, let open):
                    PaneHeaderPath(root: root, directory: directory, file: file, open: open)
                        .background { interactiveBoundary }
                }
            }
            .font(Theme.status)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var interactiveBoundary: some View {
        #if os(macOS)
        GeometryReader { proxy in
            Color.clear.preference(key: PaneHeaderNavigationBounds.self,
                value: proxy.frame(in: .named("pane-header")))
        }
        #endif
    }
}

private struct PaneHeaderPath: View {
    let root: String
    let directory: String
    let file: String?
    let open: (String) -> Void

    private var components: [String] {
        directory.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                directoryButton(root, path: ".")
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Text("/").foregroundStyle(.tertiary)
                    directoryButton(name, path: components.prefix(index + 1).joined(separator: "/"))
                }
                if let file {
                    Text("/").foregroundStyle(.tertiary)
                    Text(file)
                }
            }
            .fixedSize()
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .defaultScrollAnchor(.leading, for: .alignment)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func directoryButton(_ title: String, path: String) -> some View {
        Button { open(path) } label: {
            Text(title)
                #if os(iOS)
                .padding(.vertical, 2)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .help("打开目录：\(title)")
    }
}

/// 每个窗口按目标引用取得自己的线程或插件实例，不共享“当前线程”槽位。
struct PaneBody: View {
    let pane: Pane
    @Environment(WorkArea.self) private var area

    var body: some View {
        let renderer = area.view(in: pane)?.renderer
        Group {
            if let thread = area.thread(in: pane) {
                ThreadPane().environment(thread).id(thread.id)
            } else if let browser = area.files(in: pane), renderer == "files" {
                FilePane(browser: browser).id(pane.id)
            } else if renderer == "web", let target = area.windows.first(where: { $0.id == pane.id })?.target,
                      let instance = area.instances.first(where: { $0.id == target.instanceId }),
                      let client = area.pluginClient {
                PluginPane(target: target, title: area.appearance(of: pane).name, client: client,
                           state: instance.state?.plugin, connection: area.pluginConnection)
                    .id(pane.id)
            } else {
                PlaceholderPane(appearance: area.appearance(of: pane))
            }
        }
        .environment(\.paneInstance, area.windows.first(where: { $0.id == pane.id }).flatMap { window in
            area.instances.first { $0.id == window.target.instanceId }
        })
        .modifier(ReferenceNavigation())
    }
}

/// 插件内容接入之前仍使用原来的窗口占位。
private struct PlaceholderPane: View {
    let appearance: WindowAppearance

    var body: some View {
        PaneWindow(header: PaneHeader(title: appearance.name)) {
            RoundedRectangle(cornerRadius: 8).fill(appearance.tint.opacity(0.12))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        } controls: { _ in
            Color.clear.frame(height: Metrics.paneToolbarHeight)
        }
    }
}

extension EnvironmentValues {
    /// 供当前窗口标题栏进入实例设置；空白工作区没有实例。
    @Entry var paneInstance: RemotePluginInstance?
    /// Mac 窗口操作按钮位于标题与菜单之间，出现时在菜单前留出的宽度。
    @Entry var paneHeaderControlsInset: CGFloat = 0
    /// 隐藏的窗口操作组仍为标题栏保留系统按钮需要的高度，悬停时标题栏不跳动。
    @Entry var paneHeaderMinHeight: CGFloat = 0
    /// 窗口底部为 Home 条保留的高度，不含键盘；底栏展开时仍保留。SwiftUI 的安全区读出来是合在一起的，分不出键盘，
    /// PhoneLayout 从 UIKit 读了给出；Mac 上是 0。
    @Entry var homeIndicatorInset: CGFloat = 0
    /// 窗口容器已让出的顶部安全区，标题栏只补足固定边距；Mac 为 0。
    @Entry var paneTopSafeInset: CGFloat = 0
    /// iPhone 上键盘升起来了。PhoneLayout 在屏幕这一层比出来：SwiftUI 的安全区比 Home 条那一截高。
    /// 不能在窗口里比：拉开、收起抽屉时窗口里读到的安全区跟着动画逐帧变，还会冲过 Home 条那一截，会被当成键盘。Mac 上总是 false。
    @Entry var keyboardShown = false

    /// iPhone 上拉开侧边栏，标题栏左边的按钮调它。PhoneLayout 给出，没有就不显示按钮。
    @Entry var openSidebar: (@MainActor () -> Void)?
    /// iPhone 上从控制区往上拖拉出 action 栏：窗口给出拖动的处理，控制区接手势。没有就不接。
    @Entry var drawerPull: DrawerPull?
}

/// 卡片拖动层按菜单的实际宽度留空，菜单接收自己的点击。
nonisolated struct PaneHeaderActionsWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏高度跟随系统控件，Mac 的拖动和悬停范围使用同一实际高度。
nonisolated struct PaneHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏中可点击文字的范围，Mac 的拖动把手避开这一行。
nonisolated struct PaneHeaderNavigationBounds: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// 拉抽屉的处理：拖动中手指的位移和速度、松手时的速度，屏幕坐标。窗口拖着缩小时拖的地方自己也在动，不能按它自己的坐标算。
struct DrawerPull {
    let changed: @MainActor (_ translation: CGSize, _ velocity: CGSize) -> Void
    let ended: @MainActor (_ velocity: CGSize) -> Void

    /// 一次拖动往哪个方向：挪过 dragThreshold 时看横着挪得多还是竖着挪得多，定了就不改。
    /// 抽屉和控制区里要横着拖的控件（比如选 effort）都按它定，同一次拖动两边不会都接或都不接。
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    var gesture: some Gesture {
        DragGesture(minimumDistance: Metrics.dragThreshold, coordinateSpace: .global)
            .onChanged { changed($0.translation, $0.velocity) }
            .onEnded { ended($0.velocity) }
    }
}

private extension View {
    /// 打字时点这里收起键盘，只在 iPhone 上。和这里原有的点按（展开折起来的一行等）同时生效，不抢它们。
    @ViewBuilder
    func endsTyping(_ typing: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        simultaneousGesture(TapGesture().onEnded { typing.wrappedValue = false }, isEnabled: typing.wrappedValue)
        #else
        self
        #endif
    }

    /// 在这里往上拖拉出 action 栏，只在 iPhone 上。和控制区里的点按、输入同时生效，不抢它们。
    @ViewBuilder
    func pullsDrawer(enabled: Bool) -> some View {
        #if os(iOS)
        modifier(DrawerPullModifier(enabled: enabled))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct DrawerPullModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.drawerPull) private var pull

    // 有没有 pull 都是同一个结构，没有时只停掉手势。分成两支的话，拉开、收起抽屉时 pull 在有无之间切换，
    // 控制区会被当成换了一个视图，淡出再淡入
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture((pull ?? DrawerPull(changed: { _, _ in }, ended: { _ in })).gesture,
                                 isEnabled: enabled && pull != nil)
    }
}
#endif
