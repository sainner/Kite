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

/// 填充框的形状。
private let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

/// 填充框上面的标签，和框里的文字左边对齐。
struct CardLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }
}

/// 填充框下面或独立的一段说明。
struct CardNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }
}

/// 上面一行标签，下面是不带边框的填充框，聚焦时描主题色，框下可带一段说明。框里放 cardInput 的输入框或 CardSelectStyle 的菜单。
struct CardField<Content: View>: View {
    let label: String
    var focused = false
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel(label)
            content
                .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
                .background(Theme.codeBackground, in: cardShape)
                .overlay { cardShape.strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5) }
                .animation(.easeOut(duration: 0.15), value: focused)
            if let note { CardNote(note) }
        }
    }
}

/// 一组设置项：标题、填充框里用分隔线隔开的若干行、框下的说明。没有行时只剩标题和说明。
/// 行里直接写 LabeledContent、Toggle、Button、DisclosureGroup，样式由这里统一换掉；进入子页面的一行用 CardLink。
struct CardSection<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { CardLabel(title) }
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id { Divider() }
                            row.cardRow()
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Theme.codeBackground, in: cardShape)
                }
            }
            if let note { CardNote(note) }
        }
        .font(Theme.body)
        .labeledContentStyle(CardLabeledContentStyle())
        .toggleStyle(CardToggleStyle())
        .disclosureGroupStyle(CardDisclosureStyle())
        .buttonStyle(CardRowButtonStyle())
    }
}

private extension View {
    /// 设置组里的一行：至少一个输入框高，多行文字时上下留白。
    func cardRow() -> some View {
        padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
    }
}

/// 左边名称，右边值或控件。只读的值自己标次要色，以免把右边的选择器也染灰。
private struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}

/// 名称占满左边，开关贴右。
private struct CardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
                #if os(macOS)
                .controlSize(.small)
                #endif
        }
    }
}

/// 点整行展开，右侧箭头转向下；展开的各行缩进一级，同样用分隔线隔开。
private struct CardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .frame(minHeight: CardMetrics.fieldHeight - 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                Group(subviews: configuration.content) { rows in
                    ForEach(rows) { row in
                        Divider().padding(.top, 6)
                        row.padding(.leading, 12).padding(.top, 6)
                            .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight - 6, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// 按钮里的加载转圈：照系统转圈的样子画辐条，颜色跟着按钮文字。
/// 不用 ProgressView：Mac 上它按外观自己取色，在玻璃按钮上会先灰后黑。
struct CardSpinner: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let spokes = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Double(spokes), paused: reduceMotion)) { timeline in
            // 一秒转一圈，最亮的一根顺时针前进，后面的逐根变淡
            let lead = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * Double(spokes)) % spokes
            ZStack {
                ForEach(0..<spokes, id: \.self) { index in
                    let age = (lead - index + spokes) % spokes
                    Capsule()
                        .frame(width: size * 0.13, height: size * 0.3)
                        .offset(y: -size * 0.32)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(spokes)))
                        .opacity(1 - Double(age) / Double(spokes) * 0.8)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("正在处理")
    }
}

/// 设置组里的操作：主题色文字，整行可点。
private struct CardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight - 12, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}

/// 设置组里进入子页面的一行：正文色名称，右侧箭头。
struct CardLink: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(Theme.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
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

/// 一次提交的进度，主按钮据此变样子。
enum CardPhase: Equatable {
    case idle, working, succeeded
    /// 失败的原因，和重试要做的事。
    case failed(String, retry: () -> Void)

    var working: Bool { self == .working }
    var error: String? { if case .failed(let message, _) = self { message } else { nil } }

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.working, .working), (.succeeded, .succeeded): true
        case let (.failed(x, _), .failed(y, _)): x == y
        default: false
        }
    }
}

extension Binding where Value == CardPhase {
    /// 跑一次请求：期间是加载态，失败记下原因、重试再跑同一件事。succeeds 为真时成功后停在成功态（保存后弹窗不关的），
    /// 否则回到平常（读取这类，或成功后弹窗直接关掉的）。
    func run(succeeds: Bool = false, _ action: @escaping () async throws -> Void) {
        guard !wrappedValue.working else { return }
        wrappedValue = .working
        Task {
            do {
                try await action()
                wrappedValue = succeeds ? .succeeded : .idle
            } catch {
                wrappedValue = .failed(error.localizedDescription) { run(succeeds: succeeds, action) }
            }
        }
    }
}

/// 卡片底部的按钮：主按钮占满剩下的宽度，次要按钮在它左边。
/// 给了 phase 时主按钮跟着进度变：加载中转圈；成功打勾，直到再次能提交（又改了内容）才变回来；
/// 失败变成错误色，按钮里一行写原因，点它把完整原因复制到剪贴板，左边冒出圆形的重试。几个状态之间的形变交给玻璃效果的容器。
struct CardActions: View {
    let primary: String
    var enabled: Bool
    var prominent: Bool
    var secondary: String?
    var secondaryEnabled: Bool
    var phase: Binding<CardPhase>
    var succeeded: String
    var working: String?
    let action: () -> Void
    var secondaryAction: () -> Void
    @Namespace private var glass
    /// 刚复制了报错，按钮里短暂换成已复制。
    @State private var copied = false

    init(primary: String, enabled: Bool = true, prominent: Bool = true, secondary: String? = nil, secondaryEnabled: Bool = true,
         phase: Binding<CardPhase>, succeeded: String = "已保存", working: String? = nil,
         action: @escaping () -> Void, secondaryAction: @escaping () -> Void = {}) {
        self.primary = primary
        self.enabled = enabled
        self.prominent = prominent
        self.secondary = secondary
        self.secondaryEnabled = secondaryEnabled
        self.phase = phase
        self.succeeded = succeeded
        self.working = working
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        let state = phase.wrappedValue
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                if let secondary {
                    Button(secondary, action: secondaryAction)
                        .buttonStyle(.glass)
                        .disabled(!secondaryEnabled || state.working)
                        .glassEffectID("secondary", in: glass)
                }
                if case .failed(_, let retry) = state {
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise").accessibilityLabel("重试")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("重试")
                    .glassEffectID("retry", in: glass)
                }
                main(state).glassEffectID("primary", in: glass)
            }
            .font(Theme.body.weight(.semibold))
            #if os(macOS)
            .controlSize(.extraLarge)
            #else
            .controlSize(.large)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.snappy, value: state)
        .onChange(of: enabled) { _, enabled in
            if enabled, phase.wrappedValue == .succeeded { phase.wrappedValue = .idle }
        }
    }

    @ViewBuilder private func main(_ state: CardPhase) -> some View {
        let button = Button {
            if let message = state.error { copy(message) } else { action() }
        } label: {
            ZStack {
                switch state {
                case .idle:
                    Text(primary).transition(.blurReplace)
                case .working:
                    HStack(spacing: 8) {
                        CardSpinner()
                        if let working { Text(working) }
                    }
                    .transition(.blurReplace)
                case .succeeded:
                    Label(succeeded, systemImage: "checkmark").transition(.blurReplace)
                case .failed(let message, _):
                    Label {
                        Text(copied ? "已复制报错" : message).lineLimit(1).truncationMode(.tail)
                            .contentTransition(.interpolate)
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "exclamationmark.triangle.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("\(message)\n点按复制")
                    .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // 加载和成功时不可点但不变灰
        .disabled(state == .idle && !enabled)
        .allowsHitTesting(state != .working && state != .succeeded)
        .tint(state.error != nil ? Theme.danger : nil)
        if prominent || state.error != nil {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private func copy(_ message: String) {
        copyToPasteboard(message, toast: nil)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { copied = false }
        }
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

    /// Mac 首次按理想尺寸打开，后续用三段的实际高度更新同一个 sheet；放不下时正文滚动。
    /// iPhone 上按量出的高度给 detent，键盘升起时正文滚动。
    var body: some View {
        #if os(macOS)
        Group {
            if let size {
                scrolling.frame(width: size.width, height: size.height)
            } else {
                Group {
                    if bodyHeight == 0 {
                        // 首次尚未量出正文，用内容本身给出理想高度，避免从空滚动区撑开。
                        VStack(spacing: 0) { header; page; footerBar }
                    } else {
                        // 保持同一个滚动容器，长内容缩回后仍能读到新的完整高度。
                        scrolling.frame(idealHeight: headerHeight + bodyHeight + footerHeight)
                    }
                }
                .frame(width: 480)
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

#if DEBUG
/// Debug build 带 --card-actions-preview 启动，窗口里只放底部按钮的演示，不连接服务：
/// 保存模拟一次 1.5 秒的请求，结果按选的来；成功后打开「有改动」变回保存。
struct CardActionsPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--card-actions-preview") }

    @State private var phase = CardPhase.idle
    @State private var fails = true
    @State private var changed = true
    @State private var secondary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("请求失败", isOn: $fails)
            Toggle("有改动（成功后打开，按钮变回保存）", isOn: $changed)
            Toggle("带次要按钮", isOn: $secondary)
            Spacer(minLength: 0)
            CardActions(primary: "保存", enabled: changed, secondary: secondary ? "返回" : nil, phase: $phase) {
                $phase.run(succeeds: true) {
                    try await Task.sleep(for: .seconds(1.5))
                    if fails { throw KitedError(message: "工作机连接已断开：请求 /instances/agent/execution-grants 超时（25 秒），请检查组网状态与 kited 是否仍在运行后重试。") }
                    changed = false
                }
            }
        }
        .padding(CardMetrics.sheetInset)
        .frame(maxWidth: 400, maxHeight: 320)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous))
        .padding(CardMetrics.sheetInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
#endif

extension View {
    /// Debug build 带 --card-actions-preview 启动时用按钮演示换掉整个窗口的内容，原内容（连同其中的服务连接）不再创建。
    @ViewBuilder func cardActionsPreview() -> some View {
        #if DEBUG
        if CardActionsPreview.enabled { CardActionsPreview() } else { self }
        #else
        self
        #endif
    }
}
