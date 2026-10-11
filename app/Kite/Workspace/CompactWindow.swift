import SwiftUI

/// 紧凑布局的窗口：平时铺满屏幕，拉开侧边栏、action 栏时缩小让开，开合的状态与手势见 DrawerMotion，几何见 WindowGeometry。
/// 窗口内容只按停着的样子排一次；开合时由 WindowShell 在合成层缩放、平移、裁切，帧间插值交给 SwiftUI 的渲染，
/// 动画中窗口内容不求值、不排版。不能让安全区、尺寸这些排版的量随进度变：那样每一帧都要把窗口内容重新排一遍，
/// 内容一长（工作页的段落、长对话）就掉帧（iPhone 实测每帧 37～50 毫秒）。
/// 没有窗口时（单页、工作区里没开窗口、目录未载入）窗口里放占位内容，行为与普通窗口相同，只有底栏按 ActionsRule 走。
struct CompactWindow: View {
    let motion: DrawerMotion
    let geometry: WindowGeometry
    @Environment(AppModel.self) private var model
    /// 卡片停着时在屏幕上的位置，摆在卡片上的点阵图形按它落到点阵上。
    @State private var carrier = DotCarrier()
    /// 限定在这个窗口里的波只由它的点阵层画，见 DotScope。
    @State private var scope = DotScope()

    /// 工作区开着窗口；否则放占位内容。
    private var windowed: Bool { geometry.rule == .free }

    var body: some View {
        WindowShell(motion: motion, geometry: geometry, carrier: carrier, scope: scope) {
            // 外壳的身份不随会话改变，保留变换和形状的动画状态。
            ZStack(alignment: .topLeading) {
                if windowed, let group = model.paneGroup {
                    CompactPaneStack(group: group, motion: motion, width: geometry.screen.width)
                        .modifier(CompactPaneHeaderHost(focused: group.layout.focused, keyboardShown: geometry.keyboardShown))
                        .environment(group.layout)
                        .transition(.opacity.combined(with: .dotsPresence))
                        // 换一组窗口（侧栏切栏目、切工作区）直接替换：交叉淡化时新旧两组的点阵同时半透明，整片会暗一下
                        .transaction(value: group.id) { $0.animation = nil }
                        .id(group.id)
                } else {
                    placeholder
                        .environment(\.keyboardShown, geometry.keyboardShown)
                        .transition(.opacity.combined(with: .dotsPresence))
                }
            }
            .animation(.snappy, value: windowed)
            // 建好就不再换的动作，放在不随开合重算的这一层：开合时读它们的视图不重算。
            // 侧栏入口一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
            .environment(\.openSidebar, motion.openSidebar)
            .environment(\.drawerPull, motion.actionsPull)
        }
        // 规则变了就回到新规则下的收起状态，见 DrawerMotion.setRule
        .onChange(of: geometry.rule, initial: true) { motion.setRule(geometry.rule) }
        .onChange(of: geometry, initial: true) {
            carrier.rest = geometry.mapping(geometry.rest)
            scope.frame = carrier.rest.apply(CGRect(origin: .zero, size: geometry.contentSize))
            motion.extents = (geometry.sidebarWidth, geometry.actionsHeight)
        }
    }

    /// 没有窗口时放的占位内容：单页、目录状态，或工作区没有窗口时的画板。
    @ViewBuilder
    private var placeholder: some View {
        if model.sidebarSection != .workspaces {
            SectionContent()
        } else if let project = model.selectedProject {
            ProjectSettingsPage(project: project).id(project.id)
        } else if let area = model.current {
            Group {
                if area.pluginClient == nil {
                    DirectoryStatus(workspace: area)
                } else {
                    WindowlessStage(dock: "底栏")
                }
            }
            .environment(area)
            .id(area.id)
        } else {
            DirectoryStatus()
        }
    }
}

/// 窗口的外壳：按抽屉的进度在合成层摆放窗口，进度一变只有这一层与侧栏平移、标题栏和控制区的补位重算。
/// 外壳的排版框盖住整个屏幕（拉开时比屏幕还大），整块缩小、平移到窗口的位置，卡片底色垫在里面，按圆角裁掉
/// （与外壳同大的圆角矩形，系统直接裁图层，不另画遮罩）。点阵层反着外壳的缩放和位移摆回去，静息网点在屏幕上不动，窗口就是取景框；
/// 内容整块缩放、平移，贴着窗口左下角。外壳逐帧重排，但里面的点阵层和内容都是定尺寸的，不跟着排。
///
/// SwiftUI 按排版位置算安全区，参与布局的变换（offset、未加 ignoredByLayout 的 GeometryEffect）也算在内：
/// 排版位置的边缘落进状态栏、Home 条（横屏时左右两侧）那一带时，安全区等于到屏幕边缘的距离，离开时回到 0。
/// 开合时它逐帧在变，窗口内容跟着重排，控制区在窗口底边离开 Home 条时跳一下（iPhone 实测约 33 点）。
/// 所以外壳的排版框四边总在屏幕边缘或屏幕外，开合的缩放、平移都只在渲染时做（ignoredByLayout），安全区停在停着时的样子。
/// 只在渲染时做的变换不参与点按命中，点按按排版位置算：外壳的底色和点阵层不接点按，内容停着时的摆放照常参与布局（见 RestPlacement），
/// 只在停着时接点按；接手势的一层按窗口实际的位置排在外壳外面。
private struct WindowShell<Content: View>: View {
    let motion: DrawerMotion
    let geometry: WindowGeometry
    let carrier: DotCarrier
    let scope: DotScope
    let content: Content
    /// 窗口里的内容开了点阵。
    @State private var usesDots = false

    init(motion: DrawerMotion, geometry: WindowGeometry, carrier: DotCarrier, scope: DotScope, @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.geometry = geometry
        self.carrier = carrier
        self.scope = scope
        self.content = content()
    }

    var body: some View {
        // 第一次配好底栏规则之前按停着的样子摆，不先铺满再缩
        let openness = motion.configured ? motion.target : geometry.rest
        let size = geometry.contentSize
        let covered = geometry.covered(geometry.rest)
        ZStack(alignment: .topLeading) {
            if usesDots {
                WindowDots(openness: openness, geometry: geometry)
                    .frame(width: geometry.screen.width, height: geometry.screen.height)
                    .modifier(ScreenFixed(openness: openness, geometry: geometry).ignoredByLayout())
                    .allowsHitTesting(false)
            }
            content
                // 停着时的量，开合时不变。键盘升没升由内容自己给（见 CompactWindow）：横滑那一行只给外壳上的控制区，不进窗口正文
                .environment(\.homeIndicatorInset, covered.home)
                .environment(\.paneTopSafeInset, covered.insets.top)
                // 状态栏、Home 条和键盘按停着的样子让位。传进来的安全区只看停着的摆放（铺满时是 0），开合时不变
                .safeAreaPadding(covered.insets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .ignoresSafeArea()
                .frame(width: size.width, height: size.height)
                // 卡片坐标：缩放前的内容，摆在卡片上的点阵图形按它换算到屏幕，见 DotCarrier
                .coordinateSpace(.named(DotCarrier.space))
                .onPreferenceChange(WindowDotsActive.self) { usesDots = $0 }
                .modifier(RestPlacement(geometry: geometry))
                .modifier(WindowTransform(openness: openness, geometry: geometry, motion: motion).ignoredByLayout())
                // 只在停着时接点按：拉开或正在走时按停着的范围命中，会挡住露出来的侧边栏、底栏
                .allowsHitTesting(motion.shown == nil || motion.shown == motion.rest)
        }
        .modifier(ShellFrame(openness: openness, geometry: geometry))
        .environment(\.dotScope, scope)
        .environment(\.dotCarrier, carrier)
        .environment(\.drawerMotion, motion)
        .environment(\.windowGeometry, geometry)
        .modifier(ShellPlacement(openness: openness, geometry: geometry).ignoredByLayout())
        .overlay(alignment: .topLeading) { catcher(window: geometry.windowRect(openness)) }
        .frame(width: geometry.screen.width, height: geometry.screen.height, alignment: .topLeading)
        .ignoresSafeArea()
        .sensoryFeedback(.impact(weight: .light), trigger: motion.crossings)
    }

    /// 盖在窗口上接手势的：打开时盖住窗口，点了收起、拖了往回收；铺满（或底栏钉着）时只有窗口左边缘一条，往右拖拉出侧边栏。
    /// 按窗口实际的位置排，不盖住露出来的侧边栏、底栏；拖动途中不换，手势才不会断。
    @ViewBuilder
    private func catcher(window: CGRect) -> some View {
        if let drawer = motion.open, drawer != motion.rest {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: geometry.placement(motion.target).radius))
                .onTapGesture { motion.settle(nil) }
                .gesture((drawer == .sidebar ? motion.sidebarPull : motion.actionsPull).gesture)
                .frame(width: window.width, height: window.height)
                .padding(EdgeInsets(top: window.minY, leading: window.minX, bottom: 0, trailing: 0))
        } else {
            Color.clear
                .frame(width: Metrics.edgeZone, height: window.height)
                .contentShape(Rectangle())
                .gesture(motion.sidebarPull.gesture)
                .padding(EdgeInsets(top: window.minY, leading: window.minX, bottom: 0, trailing: 0))
        }
    }
}

/// 外壳的排版框、底色与圆角，逐帧按 openness 排：尺寸和缩放不是进度的线性函数，交给 SwiftUI 插值的话中途会对不上窗口。
/// 里面的点阵层和内容都是定尺寸的，外壳重排时不跟着排。
private struct ShellFrame: ViewModifier, Animatable {
    var openness: Openness
    let geometry: WindowGeometry

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { openness.animatableData }
        set { openness.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        let shell = geometry.shell(openness)
        content
            .frame(width: shell.size.width, height: shell.size.height, alignment: .topLeading)
            // 排版框比窗口大，底色不接点按，免得挡住窗口外的侧边栏、底栏
            .background { Theme.card.allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: shell.radius))
    }
}

/// 把外壳整块缩到窗口那么大、左上角放到窗口左上角。
private struct ShellPlacement: GeometryEffect {
    var openness: Openness
    let geometry: WindowGeometry

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { openness.animatableData }
        set { openness.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(geometry.shell(openness).mapping.transform)
    }
}

/// 抵消外壳的缩放与位移，点阵层在屏幕上不动。
private struct ScreenFixed: GeometryEffect {
    var openness: Openness
    let geometry: WindowGeometry

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { openness.animatableData }
        set { openness.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(geometry.shell(openness).mapping.inverted.transform)
    }
}

/// 内容停着时在屏幕上的摆放（卡片坐标到屏幕），参与布局：底栏钉着时窗口停在缩小的样子，里面的按钮按这个位置接点按。
/// 外壳的排版框在屏幕原点，这里的位置就是屏幕上的位置。铺满时什么也不变。它不随开合变，安全区也就不随开合变。
private struct RestPlacement: GeometryEffect {
    let geometry: WindowGeometry

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(geometry.mapping(geometry.rest).transform)
    }
}

/// 从停着的摆放（RestPlacement）挪到 openness 下：连同外壳的缩放与位移，内容贴着窗口左下角，正好是窗口里该有的大小。
/// 逐帧顺带记下弹簧这一帧走到几成，手指半路接住时从这里接着拖，不引起视图更新。
private struct WindowTransform: GeometryEffect {
    var openness: Openness
    let geometry: WindowGeometry
    let motion: DrawerMotion

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { openness.animatableData }
        set { openness.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        motion.presented = openness
        // 屏幕上停着的位置 → 卡片坐标 → 这一帧在屏幕上的位置 → 外壳缩放前的坐标
        let card = geometry.mapping(openness).after(geometry.mapping(geometry.rest).inverted)
        return ProjectionTransform(geometry.shell(openness).mapping.inverted.after(card).transform)
    }
}

/// 窗口的点阵层：铺满屏幕、不随窗口动，窗口的形状是取景框。静息网点和波都在屏幕上不动；
/// 摆在窗口上的图形与图案跟着窗口走：动画中逐帧把屏幕上的格子换算回窗口停着时的位置取样，落在两格之间由相邻格插值。
/// 只有这一层读舞台上有没有摆在窗口上的图形：别处的图形一摆、一变，外壳不跟着重算。
private struct WindowDots: View {
    let openness: Openness
    let geometry: WindowGeometry
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier

    var body: some View {
        FollowingDots(openness: openness, geometry: geometry, follows: carrier.flatMap { stage?.carries($0) } == true)
    }
}

/// 窗口里没有图形时不逐帧求值；停着时不换算，图形和图案不插值、不发虚。
private struct FollowingDots: View, Animatable {
    var openness: Openness
    let geometry: WindowGeometry
    let follows: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { follows ? openness.animatableData : .zero }
        set { if follows { openness.animatableData = newValue } }
    }

    var body: some View {
        DotCanvas(follow: follows && openness != geometry.rest ? geometry.follow(openness) : nil)
    }
}
