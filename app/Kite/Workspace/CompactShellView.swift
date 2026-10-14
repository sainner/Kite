#if os(iOS)
import SwiftUI
import UIKit

/// iPhone（和窄的 iPad）紧凑布局的原生外壳。行为、几何和 Mac 窄窗口的 SwiftUI 版（CompactLayout 里的 MacCompactLayout、CompactWindow）
/// 一样（抽屉的状态与手势是 DrawerMotion，几何是 WindowGeometry），只是开合、横滑、键盘升降不逐帧经过 SwiftUI：
/// SwiftUI 的外壳每帧都要把外壳、侧栏平移、标题栏和控制区的补位重新求值一遍，iPhone 真机拉开侧栏时 0.8 秒里主线程约 365 毫秒、掉 9 帧
/// （2026-10-14 测量版）；这里开合整段按同样的弹簧取样交给 Core Animation，跟手时显示链接逐帧摆几个图层。
/// 侧栏一列、底栏页签、单页这些不随开合改尺寸的仍是 SwiftUI，各放进一个岛；窗口里的一行窗口见 CompactRowView。
struct PhoneCompactLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CompactShellHost()
            // 保留 Home 条自动隐藏，不推测系统何时隐藏它。
            .persistentSystemOverlays(.hidden)
            .onChange(of: model.paneGroup?.id, initial: true) { _, _ in
                model.paneGroup?.layout.updateViewport(.zero, presentation: .compact)
            }
            .appDotBackground()
            // App 底色一直画静息点，和开了点阵的窗口连成一块屏，见 CompactWindowDots
            .environment(\.dotBackgroundPlacement, .everywhere)
    }
}

/// 在 appDotBackground 里面读环境（点阵舞台在那里给），交给原生外壳。
private struct CompactShellHost: View {
    @Environment(AppModel.self) private var model
    // 显式读出来交给原生层：只读 context.environment 时这几项变了不一定调 updateUIView，见 StageAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dotStage) private var dotStage

    var body: some View {
        CompactShellRepresentable(model: model, appearance: StageAppearance(
            colorScheme: colorScheme, typeSize: typeSize, reduceMotion: reduceMotion, displayScale: displayScale, isEnabled: isEnabled,
            dotStage: dotStage.map(ObjectIdentifier.init)))
            // 安全区、键盘都由外壳自己读（UIKit 的安全区和键盘通知），SwiftUI 不为它们重排这一层
            .ignoresSafeArea()
    }
}

private struct CompactShellRepresentable: UIViewRepresentable {
    let model: AppModel
    let appearance: StageAppearance

    func makeUIView(context: Context) -> CompactShellView { CompactShellView(model: model) }

    func updateUIView(_ shell: CompactShellView, context: Context) {
        shell.update(environment: context.environment, appearance: appearance)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CompactShellView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleUIView(_ shell: CompactShellView, coordinator: ()) {
        shell.dismantle()
    }
}

// MARK: - 托管视图共读的

/// 外壳量好、托管视图里读的：屏幕、安全区（连同键盘）、侧栏宽，窗口内容停着时让出的安全区，点阵的坐标。
/// 外壳排版时改，只有读到变了的那一项的视图跟着更新；键盘升降时带着键盘的弹簧改，托管视图里的让位跟着键盘走。
@MainActor @Observable final class CompactShellState {
    var screen = CGSize.zero
    /// 屏幕四边被盖着的：状态栏、Home 条，键盘升起时底下是键盘（同 SwiftUI 的安全区）。
    var insets = EdgeInsets()
    var sidebarWidth: CGFloat = 0
    /// 窗口内容停着时让出的安全区和其中 Home 条那一截（卡片坐标），见 WindowGeometry.covered。
    var covered = EdgeInsets()
    var home: CGFloat = 0
    var keyboardShown = false
    var formMargin: CGFloat?
    var geometry: WindowGeometry?
    /// 窗口里的内容开了点阵；开合途中摆在窗口上的图形跟着窗口走时的换算，见 CompactWindowDots。
    var usesDots = false
    var follow: DotCarrier.Mapping?
    /// 占位内容在场（换成一行窗口时淡出，里面摆在点阵上的图形先收回）。
    var placeholderPresented = true
    @ObservationIgnored let carrier = DotCarrier()
    @ObservationIgnored let scope = DotScope()
    @ObservationIgnored let motion: DrawerMotion

    init(motion: DrawerMotion) { self.motion = motion }
}

/// 窗口内容里的托管视图（一行窗口里的各个窗口、它们的标题栏和控制区、占位内容）共有的摆放和环境，同 WindowShell 交给内容的：
/// 按停着的样子让出安全区，卡片坐标，点阵、抽屉、侧栏入口、拉底栏。托管视图自己不算安全区，见 HostIsland。
/// native 是外框已经原生的会话窗口：岛里只剩桥，让位由原生外框自己做，安全区、几何这几项不读，键盘升降时这个岛不跟着逐帧重排。
struct CompactContentPlacement: ViewModifier {
    let state: CompactShellState
    var native = false

    func body(content: Content) -> some View {
        let covered = native ? EdgeInsets() : state.covered
        content
            .environment(\.homeIndicatorInset, native ? 0 : state.home)
            .environment(\.paneTopSafeInset, covered.top)
            .safeAreaPadding(covered)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .coordinateSpace(.named(DotCarrier.space))
            .environment(\.formMargin, state.formMargin)
            .environment(\.dotScope, state.scope)
            .environment(\.dotCarrier, state.carrier)
            .environment(\.drawerMotion, state.motion)
            .environment(\.windowGeometry, native ? nil : state.geometry)
            .environment(\.openSidebar, state.motion.openSidebar)
            .environment(\.drawerPull, state.motion.actionsPull)
    }
}

/// 侧栏一列：贴着屏幕左边，宽是侧栏宽，安全区由外壳给（岛自己不算），按抽屉进度整块平移（外壳在图层上做）。
private struct CompactSidebarRoot: View {
    let state: CompactShellState
    let collapse: () -> Void

    var body: some View {
        let insets = state.insets
        CompactSidebarColumn(logoTop: CompactSidebarColumn.logoBarTop(screen: state.screen, insets: insets), collapse: collapse)
            .frame(width: state.sidebarWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaPadding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: 0))
    }
}

/// 底栏页签那一行，贴着安全区底边。
private struct CompactTabsRoot: View {
    let state: CompactShellState
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if model.paneGroup != nil {
                CompactTabBar(motion: state.motion).frame(height: Metrics.tabBar)
                    .padding(.horizontal, Metrics.padding)
            }
        }
        .padding(.horizontal, Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .safeAreaPadding(state.insets)
    }
}

/// 窗口的点阵层：铺满屏幕、不随窗口动，窗口的形状是取景框（外壳裁）。摆在窗口上的图形跟着窗口走（follow：开合途中逐帧、拉开停着时停在拉开的位置），
/// 同 WindowDots；窗口上没有图形时不换算，停着时不插值、不发虚。
private struct CompactWindowDots: View {
    let state: CompactShellState
    @Environment(\.dotStage) private var stage

    var body: some View {
        if state.usesDots {
            let follows = stage?.carries(state.carrier) == true
            DotCanvas(follow: follows ? state.follow : nil)
                .environment(\.dotCarrier, state.carrier)
                .environment(\.dotScope, state.scope)
        }
    }
}

/// 占位内容：单页、目录状态，或工作区没有窗口时的画板。标题栏、控制区的补位在 SwiftUI 里跟着 DrawerMotion 的弹簧走（drawerShift）。
private struct CompactPlaceholderRoot: View {
    let state: CompactShellState
    let usesDots: (Bool) -> Void

    var body: some View {
        CompactPlaceholder()
            .environment(\.keyboardShown, state.keyboardShown)
            .modifier(DotsPresence(presented: state.placeholderPresented))
            .modifier(CompactContentPlacement(state: state))
            // 隔一拍交出去：托管视图可能在外壳这次排版当中更新
            .onPreferenceChange(WindowDotsActive.self) { uses in Task { @MainActor in usesDots(uses) } }
    }
}

// MARK: - 外壳

/// 外壳：最底下侧栏一列和底栏页签两个岛，上面是窗口（按窗口形状裁切、垫卡片底色，里面是铺满屏幕不动的点阵层和按停着的样子排的内容），
/// 最上面是接手势的一层（边缘往右拉侧栏，拉开时盖住窗口：点了收起、拖了往回收）。
/// 抽屉的进度只由这里摆：外壳、内容的缩放平移、侧栏平移、标题栏和控制区的补位都按 WindowGeometry 从同一个 Openness 算，见 DrawerPose。
final class CompactShellView: UIView, DrawerDriving {
    let model: AppModel
    let drawer = DrawerMotion()
    let state: CompactShellState
    private(set) var environment = EnvironmentValues()
    private(set) var look: StageAppearance?

    private let reader = ScreenReader.Probe()
    private let sidebar = HostIsland()
    private let tabs = HostIsland()
    /// 窗口：bounds 的原点跟着窗口挪，里面按屏幕坐标摆；按窗口圆角裁切。
    private let clip = UIView()
    private let dots = HostIsland()
    /// 窗口内容：按停着的样子排（WindowGeometry.contentSize），开合时整块缩放平移，锚点在左上角。
    private let content = UIView()
    private let catcher = DrawerCatcher()
    private(set) var row: CompactRowView?
    private var placeholder: HostIsland?
    /// 正在淡出的（一行窗口和占位内容换的时候），淡完拿掉。
    private var leaving: [UIView] = []

    private let tracking = ModelTracking()
    private var laying = false
    private var screenRadius: CGFloat = 0
    private var homeReading: CGFloat?
    private var keyboard: CGFloat = 0
    private(set) var geometry: WindowGeometry?
    private var placedRule: ActionsRule?
    private var focusedGroupID: String?
    private var focusedNil = true
    private var crossings = 0
    private let feedback = UIImpactFeedbackGenerator(style: .rigid)
    private var placeholderDots = false

    // 抽屉的弹簧：每一侧当前的一段，跟手时显示链接逐帧摆，否则整段交给 Core Animation
    private var segments: [WorkspaceDrawer: DrawerSegment] = [:]
    private var settled = Openness()
    private var finishing: [WorkspaceDrawer: [@MainActor () -> Void]] = [:]
    private var link: CADisplayLink?
    private var flightGeneration = 0
    /// 交给 Core Animation 的那一段走完的时刻；途中点阵层要跟着窗口走时显示链接也跑到这时。
    private var flightEnd: CFTimeInterval = 0

    init(model: AppModel) {
        self.model = model
        state = CompactShellState(motion: drawer)
        super.init(frame: .zero)
        drawer.driver = self
        #if DEBUG && KITE_LAYOUT_AUDIT
        PerfProbe.drawer = drawer
        #endif
        reader.isUserInteractionEnabled = false
        reader.cornerConfiguration = .corners(radius: .containerConcentric())
        reader.onRead = { [weak self] radius, bottom, margin in self?.read(radius: radius, bottom: bottom, margin: margin) }
        addSubview(reader)
        addSubview(sidebar)
        addSubview(tabs)
        addSubview(clip)
        addSubview(catcher)
        clip.layer.anchorPoint = .zero
        clip.layer.cornerCurve = .continuous
        clip.clipsToBounds = true
        clip.addSubview(dots)
        clip.addSubview(content)
        content.layer.anchorPoint = .zero
        dots.isUserInteractionEnabled = false
        dots.accessibilityElementsHidden = true
        tabs.alpha = 0
        sidebar.hitRegion = { [weak self] in self?.sidebarRegion }
        tabs.hitRegion = { [weak self] in self?.tabsRegion }
        catcher.shell = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 环境

    func update(environment: EnvironmentValues, appearance: StageAppearance) {
        self.environment = environment
        guard appearance != look else { return }
        look = appearance
        installIslands()
        row?.environmentChanged()
        updateColors()
        setNeedsLayout()
    }

    /// 岛里的 SwiftUI 环境：外面给的整份。
    func rooted(_ view: some View) -> AnyView {
        AnyView(view.environment(\.self, environment))
    }

    private func installIslands() {
        let state = state, drawer = drawer
        // 侧栏是独立的 SwiftUI 根：只传它使用的数据和外观，保留自己宿主的事件环境。
        // 整份覆盖 EnvironmentValues 会把外层宿主的内部环境一起带进来，窗口换岛时影响普通按钮的手势注册。
        sidebar.rootView = AnyView(CompactSidebarRoot(state: state) {
            drawer.settle(nil)
        }
            .environment(model)
            .environment(\.workspacePresentation, environment.workspacePresentation)
            .environment(\.toast, environment.toast)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .buttonStyle(.pointingAutomatic))
        tabs.rootView = rooted(CompactTabsRoot(state: state))
        dots.rootView = rooted(CompactWindowDots(state: state))
        placeholder?.rootView = placeholderRoot
    }

    private var placeholderRoot: AnyView {
        rooted(CompactPlaceholderRoot(state: state) { [weak self] uses in
            guard let self, placeholderDots != uses else { return }
            placeholderDots = uses
            updateDots()
        })
    }

    private func updateColors() {
        clip.backgroundColor = resolved(Theme.card, traits: traitCollection, in: environment)
    }

    func dismantle() {
        link?.invalidate()
        link = nil
        tracking.cancel()
        drawer.driver = nil
        row?.dismantle()
        row = nil
        for island in [sidebar, tabs, dots] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
        }
        placeholder?.rootView = AnyView(EmptyView())
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 读屏幕

    /// 屏幕圆角、Home 条那一截、根视图的左右边距，读法见 ScreenReader。
    private func read(radius: CGFloat, bottom: CGFloat, margin: CGFloat?) {
        screenRadius = radius
        homeReading = bottom
        if state.formMargin != margin { state.formMargin = margin }
        setNeedsLayout()
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let info = note.userInfo, let window else { return }
        var overlap: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification, let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let frame = convert(window.screen.coordinateSpace.convert(end, to: window), from: window)
            let shared = frame.intersection(bounds)
            overlap = shared.isNull ? 0 : max(bounds.maxY - shared.minY, 0)
        }
        guard overlap != keyboard else { return }
        keyboard = overlap
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        // 原生的跟着键盘的曲线走；托管视图里按键盘那条弹簧（曲线 7：质量 3、刚度 1000、阻尼 500，SwiftUI 按临界阻尼算，约 0.6 秒走完）
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
            withAnimation(duration > 0 ? .spring(Spring(mass: 3, stiffness: 1000, damping: 500)) : nil) {
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    // MARK: - 排版

    /// 外壳这一轮读的模型。
    private struct Read {
        var group: PaneGroup?
        var windowed = false
        var windowless = false
        var avoidsKeyboard = false
        var focusedNil = true
        var open: WorkspaceDrawer?
        var shown: WorkspaceDrawer?
        var rest: WorkspaceDrawer?
        var crossings = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard look != nil else { return }
        laying = true
        defer { laying = false }
        place(reader, bounds)
        let read = tracking.track({ readModel() }) { [weak self] in self?.invalidate() }

        // 几何，同 CompactLayout：侧栏拉开后窗口收成竖着的胶囊，宽度等于此时圆角的直径；底栏连同页签、Home 条与边距
        let safe = safeAreaInsets
        let screen = bounds.size
        let home = homeReading ?? safe.bottom
        let insets = EdgeInsets(top: safe.top, leading: safe.left, bottom: max(safe.bottom, keyboard), trailing: safe.right)
        let capsule = 2 * (screenRadius - Metrics.padding)
        let sidebarWidth = capsule >= Metrics.phoneMinCapsule
            ? screen.width - Metrics.padding - capsule
            : DotMetrics.snapDown(min(screen.width - Metrics.padding - Metrics.phoneMinWindow, 312))
        let drawerHeight = read.group != nil ? Metrics.tabBar : 0
        let geometry = WindowGeometry(screen: screen, insets: insets, homeInset: home, avoidsKeyboard: read.avoidsKeyboard,
                                      sidebarWidth: sidebarWidth, actionsHeight: drawerHeight + home + Metrics.padding, screenRadius: screenRadius,
                                      rule: read.windowed ? .free : read.windowless ? .pinned : .none,
                                      padding: Metrics.padding, margin: Metrics.paneMargin)
        let geometryChanged = geometry != self.geometry
        self.geometry = geometry
        let covered = geometry.covered(geometry.rest)
        tracking.quietly {
            if state.screen != screen { state.screen = screen }
            if state.insets != insets {
                // 侧栏、底栏页签只在露出来时跟着键盘动画；藏着时直接到位，键盘升降时不逐帧重排整列侧栏
                if drawer.shown != nil { state.insets = insets } else { withTransaction(Transaction(animation: nil)) { state.insets = insets } }
            }
            if state.sidebarWidth != sidebarWidth { state.sidebarWidth = sidebarWidth }
            if state.covered != covered.insets { state.covered = covered.insets }
            if state.home != covered.home { state.home = covered.home }
            if state.keyboardShown != geometry.keyboardShown { state.keyboardShown = geometry.keyboardShown }
            if state.geometry != geometry { state.geometry = geometry }
        }

        // 侧栏按抽屉进度在图层上平移，不经 frame（有变换时 frame 是变换后的范围）
        let sidebarSize = CGSize(width: insets.leading + sidebarWidth, height: screen.height)
        if sidebar.bounds.size != sidebarSize {
            sidebar.bounds = CGRect(origin: .zero, size: sidebarSize)
            sidebar.center = CGPoint(x: sidebarSize.width / 2, y: sidebarSize.height / 2)
        }
        place(tabs, bounds)
        place(dots, CGRect(origin: .zero, size: screen))
        let size = geometry.contentSize
        if content.bounds.size != size { content.bounds = CGRect(origin: .zero, size: size) }

        // 窗口里放一行窗口还是占位内容；换一组窗口直接替换，一行窗口和占位内容之间淡入淡出（snappy）
        arrangeContent(read, size: size)
        tabs.alpha = read.shown == .actions ? 1 : 0
        sidebar.accessibilityElementsHidden = read.shown != .sidebar
        // 拉开着、正往开里走时不接点按，会挡住露出来的侧边栏、底栏。正往回收的从收起那一刻就接：弹簧走完要 0.7 秒，
        // 看着 0.4 秒左右就停了，原来要等走完，这中间点窗口里的东西没反应（2026-10-14 用户说触控有点不灵敏，查出的一处）
        content.isUserInteractionEnabled = read.shown == nil || read.shown == read.rest || read.open == read.rest
        updateCatcher(geometry)

        // 只在同一组里开出第一个窗口时收起；切栏目可能换到已有窗口的一组，侧栏仍应留着供继续选择。
        let groupID = read.group?.id
        let openedFirstWindow = groupID != nil && focusedGroupID == groupID && focusedNil && !read.focusedNil
        focusedGroupID = groupID
        focusedNil = read.focusedNil
        // 观察之外：规则、几何交给抽屉，越过一半轻震。
        let crossings = read.crossings
        let rule = geometry.rule
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if geometryChanged {
                state.carrier.rest = geometry.mapping(geometry.rest)
                state.scope.frame = state.carrier.rest.apply(CGRect(origin: .zero, size: geometry.contentSize))
                drawer.extents = (geometry.sidebarWidth, geometry.actionsHeight)
            }
            if placedRule != rule {
                placedRule = rule
                drawer.setRule(rule)
            }
            if openedFirstWindow, model.paneGroup?.id == groupID, model.paneGroup?.layout.focused != nil {
                drawer.settle(nil)
            }
            if self.crossings != crossings {
                self.crossings = crossings
                feedback.impactOccurred()
            }
        }
        // 几何变了（转屏、键盘、规则、读到屏幕圆角）：停着的直接摆到新几何下；正在走的按新几何重新取样，接着走完
        if geometryChanged {
            if segments.isEmpty {
                apply(DrawerPose(geometry, settled))
                tracking.quietly { updateFollow(settled) }
            } else {
                refresh(at: CACurrentMediaTime())
            }
        }
    }

    private func readModel() -> Read {
        var read = Read()
        let group = model.paneGroup
        read.group = group
        read.windowed = group.map { $0.layout.focused != nil && $0.canShowWindows } ?? false
        if model.sidebarSection == .workspaces, model.selectedProject == nil, let area = model.current {
            read.windowless = area.layout.focused == nil && area.pluginClient != nil
        }
        read.avoidsKeyboard = read.windowed || model.sidebarSection != .workspaces || model.selectedProject != nil
        read.focusedNil = group?.layout.focused == nil
        read.open = drawer.open
        read.shown = drawer.shown
        read.rest = drawer.rest
        read.crossings = drawer.crossings
        return read
    }

    private func invalidate() {
        setNeedsLayout()
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    private func place(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// 进度只更新命中区域，不进外壳的观察范围；跟手和换终点由原生动画驱动调用。
    private func updateCatcher(_ geometry: WindowGeometry) {
        catcher.update(open: drawer.open, rest: drawer.rest, target: drawer.target, geometry: geometry)
    }

    /// 窗口里的内容：开着窗口时是一行窗口（CompactRowView），否则是占位内容的岛。
    private func arrangeContent(_ read: Read, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        if read.windowed, let group = read.group {
            if let row, row.groupID != group.id {
                // 换一组窗口（侧栏切栏目、切工作区）直接替换：交叉淡化时新旧两组的点阵同时半透明，整片会暗一下
                row.dismantle()
                row.removeFromSuperview()
                self.row = nil
            }
            if row == nil {
                let made = CompactRowView(group: group, shell: self)
                row = made
                content.insertSubview(made, at: 0)
                made.frame = bounds
                // 抽屉开着时才建出来的（工作区连上、开出第一个窗口）：标题栏、控制区按这一刻的进度补位
                if let geometry {
                    let pose = DrawerPose(geometry, presented)
                    made.shift(header: pose.header, controls: pose.controls)
                    if !segments.isEmpty { refresh(at: CACurrentMediaTime()) }
                }
                fadeIn(made, from: placeholder)
                if let placeholder {
                    self.placeholder = nil
                    tracking.quietly { state.placeholderPresented = false }
                    leave(placeholder) { [weak self] in
                        placeholder.rootView = AnyView(EmptyView())
                        self?.placeholderDots = false
                    }
                }
            }
            row?.update(group: group)
            row.map { place($0, bounds) }
        } else {
            if placeholder == nil {
                let island = HostIsland()
                placeholder = island
                content.insertSubview(island, at: 0)
                island.frame = bounds
                tracking.quietly { state.placeholderPresented = true }
                island.rootView = placeholderRoot
                fadeIn(island, from: row)
                if let row {
                    self.row = nil
                    row.setPresented(false)
                    leave(row) { row.dismantle() }
                }
            }
            placeholder.map { place($0, bounds) }
        }
        updateDots()
    }

    /// 新的淡入（替换另一样时），snappy；减少动态效果时直接换。透明度设在图层上，见 setLayerOpacity。
    private func fadeIn(_ view: UIView, from previous: UIView?) {
        guard previous != nil, look?.reduceMotion != true else { return }
        setLayerOpacity(view, 0, animated: false)
        setLayerOpacity(view, 1, animated: true)
    }

    private func leave(_ view: UIView, finished: @escaping () -> Void) {
        view.isUserInteractionEnabled = false
        guard look?.reduceMotion != true else {
            view.removeFromSuperview()
            finished()
            return
        }
        leaving.append(view)
        setLayerOpacity(view, 0, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Spring.snappy.settlingDuration) { [weak self] in
            view.removeFromSuperview()
            self?.leaving.removeAll { $0 === view }
            finished()
        }
    }

    /// 窗口的点阵层：一行窗口里露出来的窗口开了点阵，或者占位内容开了。
    func updateDots() {
        let uses = row?.usesDots ?? placeholderDots
        if state.usesDots != uses { tracking.quietly { state.usesDots = uses } }
    }

    // MARK: - 命中

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        // 页面切换与抽屉转场各自更新，窗口的接手势层不能挡住已经露出的侧栏导航。
        if drawer.open == .sidebar, let geometry, point.x < geometry.windowRect(drawer.target).minX,
           let hit = sidebar.hitTest(sidebar.convert(point, from: self), with: event) {
            return hit
        }
        return super.hitTest(point, with: event)
    }

    private var sidebarRegion: CGRect? {
        drawer.open == .sidebar || drawer.shown == .sidebar ? sidebar.bounds : nil
    }

    private var tabsRegion: CGRect? {
        guard drawer.shown == .actions else { return nil }
        let insets = state.insets
        return CGRect(x: 0, y: bounds.height - insets.bottom - Metrics.tabBar, width: bounds.width, height: Metrics.tabBar)
    }

    // MARK: - 抽屉的弹簧（DrawerDriving）

    var presented: Openness { openness(at: CACurrentMediaTime()) }

    private func openness(at time: CFTimeInterval) -> Openness {
        var openness = settled
        for (side, segment) in segments { openness[side] = CGFloat(segment.value(at: time)) }
        return openness
    }

    func place(_ openness: Openness) {
        segments = [:]
        settled = openness
        stopLink()
        if let geometry {
            updateCatcher(geometry)
            apply(DrawerPose(geometry, openness))
        }
        finish(at: CACurrentMediaTime())
    }

    func animate(_ drawer: WorkspaceDrawer, to value: CGFloat, spring: Spring, completion: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        start(drawer, to: value, spring: spring, tracking: false, at: now)
        finishing[drawer, default: []].append(completion)
        refresh(at: now)
    }

    func track(_ drawer: WorkspaceDrawer, to value: CGFloat) {
        let now = CACurrentMediaTime()
        start(drawer, to: value, spring: DrawerMotion.trackingSpring, tracking: true, at: now)
        refresh(at: now)
    }

    /// 那一侧从这一刻的样子、带着当时的速度起一段新的弹簧（SwiftUI 的弹簧动画接着换终点也是这样）。
    private func start(_ side: WorkspaceDrawer, to value: CGFloat, spring: Spring, tracking: Bool, at time: CFTimeInterval) {
        let from = Double(openness(at: time)[side])
        let velocity = segments[side]?.velocity(at: time) ?? 0
        segments[side] = DrawerSegment(from: from, to: Double(value), velocity: velocity, spring: spring, start: time, tracking: tracking)
        settled[side] = value
    }

    /// 有跟手的一段时显示链接逐帧摆；否则整段按 1/120 秒取样交给 Core Animation，模型值停在终点。
    private func refresh(at time: CFTimeInterval) {
        flightGeneration += 1
        guard let geometry else { return }
        updateCatcher(geometry)
        if segments.values.contains(where: \.tracking) {
            stopFlight()
            startLink()
            apply(DrawerPose(geometry, openness(at: time)))
            return
        }
        let end = segments.values.map(\.end).max() ?? time
        guard end > time else {
            stopLink()
            apply(DrawerPose(geometry, settled))
            finish(at: time)
            return
        }
        let steps = max(Int(((end - time) * 120).rounded(.up)), 1)
        let poses = (0...steps).map { DrawerPose(geometry, openness(at: time + (end - time) * Double($0) / Double(steps))) }
        animate(poses, duration: end - time)
        flightEnd = end
        // 摆在窗口上的图形跟着窗口走时，点阵层逐帧换算（同 WindowDots），其余的不逐帧
        if carriesFigures { startLink() } else { stopLink() }
        let generation = flightGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (end - time)) { [weak self] in
            guard let self, flightGeneration == generation else { return }
            finish(at: CACurrentMediaTime() + 0.001)
        }
    }

    /// 走完的那几侧收掉，回调；都走完了停在终点。
    private func finish(at time: CFTimeInterval) {
        for (side, segment) in segments where segment.end <= time { segments[side] = nil }
        for side in [WorkspaceDrawer.sidebar, .actions] where segments[side] == nil {
            let callbacks = finishing[side] ?? []
            finishing[side] = nil
            for callback in callbacks { callback() }
        }
        if segments.isEmpty {
            stopLink()
            updateFollow(settled)
        }
    }

    /// 摆在窗口上的图形这一刻怎么跟着窗口：停在收起的位置时不换算。点阵层只在窗口上真有图形时用它，见 CompactWindowDots。
    private func updateFollow(_ openness: Openness) {
        guard let geometry else { return }
        let follow = openness == geometry.rest ? nil : geometry.follow(openness)
        if state.follow != follow { state.follow = follow }
    }

    private var carriesFigures: Bool {
        environment.dotStage?.carries(state.carrier) == true
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let geometry else { return }
        let time = CACurrentMediaTime()
        let openness = openness(at: time)
        if segments.values.contains(where: \.tracking) {
            apply(DrawerPose(geometry, openness))
            finish(at: time)
        }
        if carriesFigures { updateFollow(openness) }
        if segments.isEmpty || (!segments.values.contains(where: \.tracking) && !carriesFigures) { stopLink() }
    }

    // MARK: - 摆到一帧

    /// 抽屉一帧的样子：窗口的范围和圆角（屏幕坐标），内容的缩放和左上角，标题栏、控制区补位，侧栏平移，同 WindowShell 与 DrawerShift。
    struct DrawerPose {
        var window: CGRect
        var radius: CGFloat
        var origin: CGPoint
        var scale: CGFloat
        var header: CGFloat
        var controls: CGFloat
        var sidebar: CGFloat

        init(_ geometry: WindowGeometry, _ openness: Openness) {
            window = geometry.windowRect(openness)
            radius = geometry.placement(openness).radius
            let mapping = geometry.mapping(openness)
            origin = mapping.origin
            scale = mapping.scale
            header = geometry.headerShift(openness)
            controls = geometry.controlsShift(openness)
            sidebar = (Openness.shown(openness.sidebar, extent: geometry.sidebarWidth) - 1) * geometry.sidebarWidth
        }
    }

    private func apply(_ pose: DrawerPose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopFlight()
        setModel(pose)
        CATransaction.commit()
    }

    private func setModel(_ pose: DrawerPose) {
        clip.layer.bounds = CGRect(origin: pose.window.origin, size: pose.window.size)
        clip.layer.position = pose.window.origin
        clip.layer.cornerRadius = pose.radius
        content.layer.position = pose.origin
        content.layer.transform = CATransform3DMakeScale(pose.scale, pose.scale, 1)
        sidebar.layer.transform = CATransform3DMakeTranslation(pose.sidebar, 0, 0)
        row?.shift(header: pose.header, controls: pose.controls)
    }

    private func animate(_ poses: [DrawerPose], duration: TimeInterval) {
        guard let last = poses.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopFlight()
        setModel(last)
        func add(_ layer: CALayer, _ keyPath: String, _ values: [Any]) {
            layer.add(StageKeyframes.make(keyPath, values, duration: duration), forKey: "drawer.\(keyPath)")
        }
        add(clip.layer, "bounds", poses.map { NSValue(cgRect: CGRect(origin: $0.window.origin, size: $0.window.size)) })
        add(clip.layer, "position", poses.map { NSValue(cgPoint: $0.window.origin) })
        add(clip.layer, "cornerRadius", poses.map(\.radius))
        add(content.layer, "position", poses.map { NSValue(cgPoint: $0.origin) })
        add(content.layer, "transform", poses.map { NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1)) })
        add(sidebar.layer, "transform", poses.map { NSValue(caTransform3D: CATransform3DMakeTranslation($0.sidebar, 0, 0)) })
        row?.animateShift(header: poses.map(\.header), controls: poses.map(\.controls), duration: duration)
        CATransaction.commit()
    }

    private func stopFlight() {
        for (layer, keys) in [(clip.layer, ["bounds", "position", "cornerRadius"]), (content.layer, ["position", "transform"]),
                              (sidebar.layer, ["transform"])] {
            for key in keys { layer.removeAnimation(forKey: "drawer.\(key)") }
        }
        row?.stopShift()
    }

    // MARK: - 读屏

    /// 读屏的「返回」手势（双指划 Z）：拉开着侧栏或底栏时收起。
    override func accessibilityPerformEscape() -> Bool {
        guard let open = drawer.open, open != drawer.rest else { return false }
        drawer.settle(nil)
        return true
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if drawer.shown == .sidebar { elements.append(sidebar) }
            elements.append(content)
            if drawer.shown == .actions { elements.append(tabs) }
            return elements
        }
        set {}
    }
}

/// 透明度直接设在图层上，要动画时按 snappy 取样交给 Core Animation：UIView.alpha 在 0 和非 0 之间变时 UIKit 把整棵子树通知一遍看不看得见，
/// 窗口里有好几个托管视图和对话，换窗口时一次十几毫秒（2026-10-14 iPhone 真机 Time Profiler）。点按照样按透明度判断（alpha 读的就是图层的）。
/// 和现在一样就不动，正在走的淡入淡出不被排版打断。
@MainActor func setLayerOpacity(_ view: UIView, _ opacity: Float, animated: Bool) {
    let layer = view.layer
    guard layer.opacity != opacity else { return }
    let from = layer.presentation()?.opacity ?? layer.opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = opacity
    if animated {
        layer.add(StageAnimation.spring("opacity", from: Double(from), to: Double(opacity), spring: .snappy), forKey: "fade.opacity")
    } else {
        layer.removeAnimation(forKey: "fade.opacity")
    }
    CATransaction.commit()
}

/// 抽屉一侧的一段弹簧：从 from 带着 velocity 走到 to。
private struct DrawerSegment {
    let from: Double
    let to: Double
    let velocity: Double
    let spring: Spring
    let start: CFTimeInterval
    let tracking: Bool
    let end: CFTimeInterval

    init(from: Double, to: Double, velocity: Double, spring: Spring, start: CFTimeInterval, tracking: Bool) {
        self.from = from
        self.to = to
        self.velocity = velocity
        self.spring = spring
        self.start = start
        self.tracking = tracking
        end = start + spring.settlingDuration(fromValue: from, toValue: to, initialVelocity: velocity, epsilon: 0.0005)
    }

    func value(at time: CFTimeInterval) -> Double {
        guard time < end else { return to }
        return spring.value(fromValue: from, toValue: to, initialVelocity: velocity, time: max(time - start, 0))
    }

    func velocity(at time: CFTimeInterval) -> Double {
        guard time < end else { return 0 }
        return spring.velocity(fromValue: from, toValue: to, initialVelocity: velocity, time: max(time - start, 0))
    }
}

// MARK: - 接手势的一层

/// 盖在窗口上接手势的：拉开时盖住窗口，点了收起、拖了往回收；铺满（或底栏钉着）时只有窗口左边缘一条，往右拖拉出侧边栏。
/// 按窗口停到终点的位置排，不盖住露出来的侧边栏、底栏；拖动途中换了样子手势也不断，接手时定下拉哪一侧。同 WindowShell.catcher。
private final class DrawerCatcher: UIView {
    weak var shell: CompactShellView?
    private let drag = ThresholdDrag()
    private var covering = false
    private var radius: CGFloat = 0
    private var pull: DrawerPull?

    override init(frame: CGRect) {
        super.init(frame: frame)
        drag.addTarget(self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(open: WorkspaceDrawer?, rest: WorkspaceDrawer?, target: Openness, geometry: WindowGeometry) {
        let window = geometry.windowRect(target)
        if let open, open != rest {
            covering = true
            radius = geometry.placement(target).radius
            if frame != window { frame = window }
        } else {
            covering = false
            let strip = CGRect(x: window.minX, y: window.minY, width: Metrics.edgeZone, height: window.height)
            if frame != strip { frame = strip }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard covering else { return bounds.contains(point) }
        return UIBezierPath(roundedRect: bounds, cornerRadius: radius).contains(point)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard covering, recognizer.state == .ended else { return }
        shell?.drawer.settle(nil)
    }

    @objc private func dragged(_ recognizer: ThresholdDrag) {
        guard let drawer = shell?.drawer else { return }
        switch recognizer.state {
        case .began:
            pull = covering && drawer.open == .actions ? drawer.actionsPull : drawer.sidebarPull
            pull?.changed(recognizer.translation, recognizer.velocity)
        case .changed:
            pull?.changed(recognizer.translation, recognizer.velocity)
        case .ended, .cancelled:
            pull?.ended(recognizer.state == .ended ? recognizer.velocity : .zero)
            pull = nil
        default:
            break
        }
    }
}
#endif
