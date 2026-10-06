import SwiftUI

extension AppModel {
    /// 没有项目时整个 App 是初始配置；样本模式不进入，初始配置预览一律进入。
    var needsOnboarding: Bool { OnboardingPreview.enabled || (workspaces.isEmpty && !SampleWorkspace.enabled) }
}

/// Debug build 带 --onboarding-preview 启动，或编译时开启 KITE_ONBOARDING_PREVIEW，从头走一遍初始配置：
/// 不连接服务，启动、连接、扫码和创建都只模拟一段等待，创建完回到开头。
enum OnboardingPreview {
    static var enabled: Bool {
        #if DEBUG && KITE_ONBOARDING_PREVIEW
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("--onboarding-preview")
        #else
        false
        #endif
    }
}

/// 两端的根视图：没有项目时显示初始配置，有了项目才进入工作区布局。
struct AppRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.needsOnboarding {
            Onboarding()
        } else {
            #if os(macOS)
            MainWindow()
            #else
            PhoneLayout()
            #endif
        }
    }
}

/// 首次使用的配置流程，两端都铺满整个窗口。没有工作区时侧栏和窗口区都没有内容可放，所以不沿用工作区布局。
/// 从上到下：点阵在背景上拼出这一步的标志，进入下一步时逐格形变成下一个；标题直接压在背景上；
/// 底部的卡片只放这一步要填的、要做的，高度随内容，没有要操作的步骤不出卡片。
/// 流程是准备工作机、连接（扫码或手动填写）、正在连接、创建第一个项目；启动时先自动连一次已保存的工作机或本机服务，
/// 连上就直接创建项目。登记同时建立项目、检出和根工作区，App 随即回到工作区布局，并在根工作区打开一个空白会话。
struct Onboarding: View {
    /// 连接工作机的两种方式。扫码只在 iPhone 上有：Mac 通常就是工作机自己。
    fileprivate enum Method: Hashable { case scan, manual }

    /// 当前这一步，各有自己的标志。
    fileprivate enum Phase: Hashable {
        /// 启动时自动连接，有结果之前还不知道要走哪一步。
        case launching
        case prepare
        case connect(Method)
        /// 扫码或手动发起连接之后，直到连上或失败。
        case connecting(Method)
        case create

        static let stepCount = 3

        /// 在三步中的第几步；启动时不显示步骤。
        var step: Int? {
            switch self {
            case .launching: nil
            case .prepare: 0
            case .connect, .connecting: 1
            case .create: 2
            }
        }

        /// 正在连接时没有要操作的，不出卡片。
        var hasCard: Bool {
            switch self {
            case .launching, .connecting: false
            default: true
            }
        }
    }

    #if os(iOS)
    private static let defaultMethod = Method.scan
    #else
    private static let defaultMethod = Method.manual
    #endif

    @Environment(AppModel.self) private var model
    @Environment(\.self) private var environment
    @Environment(\.toast) private var toast
    @State private var stage = DotStage()
    /// 连接之前停在哪一页：准备工作机或连接。
    @State private var page = Phase.prepare
    @State private var address = ""
    @State private var code = ""
    @State private var controlURL = Tailnet.customControlURL
    /// 组网服务器一律先收起，大多数人用默认的；已经填过自建的，收起时写出它的地址。
    @State private var showsControlURL = false
    @State private var path = ""
    /// 正在填的输入框；点卡片外、输入框外收起键盘。
    @FocusState private var focus: String?
    @State private var working = false
    /// 用户用哪种方式发起的连接还没有结果；成功后服务重连期间仍算正在连接。
    @State private var connectingBy: Method?
    @State private var error: String?
    /// 标志区在窗口坐标中的范围：标题以上露出背景的那块。
    @State private var logoArea: CGRect?
    /// 卡片正文与底部按钮的高度，卡片按它们定高，放不下时正文滚动。
    @State private var bodyHeight: CGFloat = 0
    /// 标题连同上下留白的高度，卡片最多占到它下面。
    @State private var titleHeight: CGFloat = 0
    /// 步骤点那一格在窗口坐标中的范围，点阵在这里拼出步骤点。
    @State private var stepArea: CGRect?
    @State private var footerHeight: CGFloat = 0
    #if os(iOS)
    @State private var screenRadius: CGFloat = 0
    @State private var homeInset: CGFloat = 0
    #endif
    #if DEBUG
    /// 预览时代替真实的连接状态。
    private struct Simulation: Equatable {
        var launching = true
        var joining = false
        var connected = false
    }
    @State private var simulation: Simulation?
    #endif

    private static let inset = Metrics.padding * 2
    /// 完成一步时的波比发送消息的慢，配合标志形变。
    private static let wavePace = 0.15
    /// 标题与卡片那一栏的宽度：窄窗口里居中，宽窗口里靠右。
    private static let columnWidth: CGFloat = 504

    var body: some View {
        GeometryReader { geo in
            // 键盘之外的安全区都忽略了，底部还剩的就是键盘
            let keyboard = geo.safeAreaInsets.bottom > 0
            Group {
                if Self.isWide(geo.size) {
                    wideLayout(size: geo.size)
                } else {
                    narrowLayout(size: geo.size, keyboard: keyboard)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .endsTyping(focus != nil) { focus = nil }
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                if simulation != nil {
                    Button("重新开始", systemImage: "arrow.counterclockwise", action: restartPreview)
                        .buttonStyle(.glass)
                        .padding(Metrics.padding * 2)
                }
            }
            #endif
        }
        #if os(macOS)
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
        .background {
            // 和工作区一样，点阵铺满窗口背景，卡片盖在上面
            ZStack {
                Theme.background
                DotCanvas()
                #if os(iOS)
                ScreenReader { radius, bottom in
                    screenRadius = radius
                    homeInset = bottom
                }
                #endif
            }
            .ignoresSafeArea()
        }
        .environment(\.dotStage, stage)
        #if os(macOS)
        .frame(minWidth: 528, minHeight: 576)
        .resizesByModule()
        #endif
        .onAppear {
            address = model.serverAddress
            // 已配对过的工作机连不上或授权失效，直接回到连接这一步
            if model.connections.selected?.token != nil { page = .connect(.manual) }
            #if DEBUG
            if OnboardingPreview.enabled { restartPreview() }
            #endif
        }
        .onChange(of: model.connected) { error = nil }
        // 后台连接报错就退回连接页，带着错误
        .onChange(of: model.error) { _, message in if message != nil { connectingBy = nil } }
        .onChange(of: model.invite) { _, invite in
            switch invite {
            // 也可能是用系统相机扫的码，从链接打开
            case .joining: connectingBy = .scan
            case .failed: connectingBy = nil; page = .connect(.scan)
            case nil: break
            }
        }
        .onChange(of: logo, initial: true) { refreshLogo() }
        .onChange(of: phase, initial: true) { refreshSteps() }
        .animation(.snappy, value: phase)
    }

    /// 连接状态：预览时用模拟的。
    private var connected: Bool {
        #if DEBUG
        if let simulation { return simulation.connected }
        #endif
        return model.connected
    }

    private var joining: Bool {
        #if DEBUG
        if let simulation { return simulation.joining }
        #endif
        return model.invite == .joining
    }

    /// 服务还没回话：启动时的自动连接，或连接成功后服务重连期间。
    private var awaitingService: Bool {
        #if DEBUG
        if let simulation { return simulation.launching }
        #endif
        return model.error == nil
    }

    private var previewing: Bool {
        #if DEBUG
        simulation != nil
        #else
        false
        #endif
    }

    private var phase: Phase {
        if connected { return .create }
        if joining { return .connecting(.scan) }
        if let connectingBy, working || awaitingService { return .connecting(connectingBy) }
        if awaitingService { return .launching }
        return page
    }

    // MARK: 排布

    /// 宽窗口（Mac 的常见尺寸）左右排：左边标志，右边标题与卡片；窄的（iPhone 竖屏、缩窄的 Mac 窗口）上下排。
    private static func isWide(_ size: CGSize) -> Bool { size.width >= 840 && size.height >= 480 }

    /// 上面露出背景拼标志，下面标题和贴底的卡片。标题和卡片按内容定高，剩下的才给标志；
    /// 键盘弹出等放不下的时候标志先让，卡片最多占到标题以下，再放不下正文才滚动。
    private func narrowLayout(size: CGSize, keyboard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoSpace
            titleBlock
                .padding(.horizontal, Self.inset)
                .padding(.bottom, phase.hasCard ? Self.inset : Self.inset * 2 + bottomInset(keyboard: keyboard))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            if phase.hasCard {
                card(keyboard: keyboard, wide: false, maxHeight: size.height - Metrics.padding * 2 - titleHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, horizontalMargin(width: size.width))
        .padding(.vertical, Metrics.padding)
    }

    /// 左边整片拼标志，右边一栏标题和卡片上下居中；栏的左边落在模块线上。
    private func wideLayout(size: CGSize) -> some View {
        let width = size.width
        let column = DotMetrics.snapDown(width - Self.columnWidth - Metrics.padding * 4)
        return HStack(spacing: Self.inset) {
            logoSpace
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                titleBlock
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
                if phase.hasCard {
                    card(keyboard: false, wide: true, maxHeight: size.height - Metrics.padding * 2 - titleHeight)
                        .transition(.opacity.combined(with: .offset(y: Self.inset)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.columnWidth)
        }
        .padding(.leading, Metrics.padding)
        .padding(.trailing, width - column - Self.columnWidth)
        .padding(.vertical, Metrics.padding)
    }

    /// 露出背景、拼标志的那块；iPhone 扫码时放取景框。
    private var logoSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                logoArea = $0
                // onChange(of: logo) 拿到的区域会慢一拍，区域一变就按当前状态重摆
                refreshLogo()
            }
            #if os(iOS)
            .overlay(alignment: .topLeading) { scanWindow }
            #endif
    }

    /// 窄窗口里一栏居中，左边落在模块线上；iPhone 上卡片两边各留一个模块。
    private func horizontalMargin(width: CGFloat) -> CGFloat {
        #if os(macOS)
        DotMetrics.snapDown(max(Metrics.padding, (width - Self.columnWidth) / 2))
        #else
        Metrics.padding
        #endif
    }

    /// iPhone 上卡片伸到屏幕底边，内容在 Home 条之上结束；键盘弹出时卡片落在键盘上。
    private func bottomInset(keyboard: Bool) -> CGFloat {
        #if os(iOS)
        keyboard ? 0 : max(0, homeInset - Metrics.padding - 8)
        #else
        0
        #endif
    }

    /// 背景上要拼的标志：哪一个、放在哪、是否在等待。标志区放不下整个标志时（键盘弹出、窗口太矮）退回点。
    private struct Logo: Equatable {
        var figure: DotFigure?
        var area: CGRect
        var breathing: Bool
    }

    private var logo: Logo? {
        guard let logoArea else { return nil }
        let colors = OnboardingLogos.colors(accent: DotColor(Color.accentColor.resolve(in: environment)))
        let figure = OnboardingLogos.figure(for: phase, colors: colors)?.trimmed()
        // 标志区放不下时往上借到窗口顶边（iPhone 上是状态栏那一截背景），还放不下才退回点
        let tall = CGRect(x: logoArea.minX, y: 0, width: logoArea.width, height: logoArea.maxY)
        let area = figure.flatMap { figure in
            [logoArea, tall].first {
                CGFloat(figure.rows) * DotMetrics.pitch <= $0.height && CGFloat(figure.columns) * DotMetrics.pitch <= $0.width
            }
        }
        let waiting = switch phase {
        case .launching, .connecting: true
        case .create: working
        case .prepare, .connect: false
        }
        return Logo(figure: area == nil ? nil : figure, area: area ?? logoArea, breathing: waiting)
    }

    /// 按当前状态摆标志；同一个标志在同一处时什么也不做。
    private func refreshLogo() {
        guard let logo else { return }
        let previous = stage.shownFigure()
        stage.show(logo.figure, in: logo.area, breathing: logo.breathing)
        // 连上工作机是完成的时刻，标志换成下一个时从它的外沿推开一道波
        if phase == .create, previous != logo.figure, logo.figure != nil, let frame = stage.figureFrame() {
            stage.emitWave(from: frame, pace: Self.wavePace)
        }
    }

    /// 在标题上方那一格拼出步骤点；没有步骤时退回点。
    private func refreshSteps() {
        let colors = OnboardingLogos.colors(accent: DotColor(Color.accentColor.resolve(in: environment)))
        let figure = phase.step.map { OnboardingLogos.steps(current: $0, count: Phase.stepCount, colors: colors) }
        stage.show(stepArea == nil ? nil : figure, in: stepArea ?? .zero, placement: .leading,
                   breathing: !phase.hasCard, slot: "steps")
    }

    #if os(iOS)
    /// 扫码时取景框占住标志区：正方形，边落在模块线上。
    private func scanFrame(in area: CGRect) -> CGRect {
        let side = DotMetrics.snapDown(min(area.width - Metrics.padding * 2, area.height - Metrics.padding * 2, 336))
        return CGRect(x: DotMetrics.snapDown(area.midX - side / 2), y: DotMetrics.snapDown(area.midY - side / 2),
                      width: side, height: side)
    }

    @ViewBuilder
    private var scanWindow: some View {
        if phase == .connect(.scan), let logoArea {
            let frame = scanFrame(in: logoArea)
            let simulate: (() -> Void)? = previewing ? { simulateScan() } : nil
            QRScanWindow(onScan: { scanned($0) }, onSimulate: simulate)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - logoArea.minX, y: frame.minY - logoArea.minY)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
    #endif

    // MARK: 标题

    /// 步骤、标题与说明，直接压在背景上；换步骤时新的标题从下面浮上来，旧的淡掉，步骤点逐格形变。
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let step = phase.step { stepRow(step) }
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(Theme.display)
                        .fixedSize(horizontal: false, vertical: true)
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .waitingBreath(!phase.hasCard)
                .id(phase)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
            }
        }
    }

    /// 背景上拼出的步骤点相对留出位置的偏移。
    private var stepOffset: CGSize {
        guard let stepArea, let frame = stage.figureFrame("steps") else { return .zero }
        return CGSize(width: frame.minX - stepArea.minX, height: frame.midY - stepArea.midY)
    }

    /// 前面是背景点阵拼出的步骤点，这里只留出它的位置，后面写「1/3」。步骤点左边贴着标题。
    private func stepRow(_ step: Int) -> some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(Phase.stepCount) * DotMetrics.pitch, height: DotMetrics.pitch)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    stepArea = $0
                    refreshSteps()
                }
                .onDisappear {
                    stepArea = nil
                    refreshSteps()
                }
            Text("\(step + 1)/\(Phase.stepCount)")
                .font(Theme.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                // 点吸附在点阵的格子上，可能和留出的位置差半格；文字跟着挪，左右间距不变，上下对齐点的中线
                .offset(stepOffset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step + 1) 步，共 \(Phase.stepCount) 步")
    }

    private var title: String {
        switch phase {
        case .launching, .connecting: "正在连接工作机"
        case .prepare: "准备工作机"
        case .connect(.scan): "扫码连接"
        case .connect(.manual): "连接工作机"
        case .create: "创建第一个项目"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .launching:
            Text(model.serverAddress).font(Theme.code).foregroundStyle(.secondary)
        case .connecting(let method):
            if method == .scan {
                note("正在加入组网并配对…")
            } else {
                Text(address).font(Theme.code).foregroundStyle(.secondary)
            }
            // 组网节点等待登录时，连接会一直停在这里。
            if let url = Tailnet.status.loginURL {
                Link(destination: url) {
                    Label("在浏览器中登录组网后继续", systemImage: "safari").font(Theme.secondary)
                }
                .buttonStyle(.pointingPlain)
                .foregroundStyle(Color.accentColor)
            }
        case .prepare:
            #if os(macOS)
            note("项目和会话都在工作机上。这台 Mac 还没有运行 Kite 后台服务，在 Kite 源码目录安装后会自动连上。")
            #else
            note("项目和会话都在工作机上。在作为工作机的 Mac 上完成下面三件事。")
            #endif
        case .connect(.scan):
            note("扫描工作机上的配对二维码，App 会自动加入组网并完成配对。")
        case .connect(.manual):
            note("填写工作机的组网地址。远程设备第一次连接还要填配对码，连接时会打开浏览器登录组网。")
        case .create:
            note("项目对应工作机上的一个文件夹。Kite 为它建立工作区，创建后直接在里面开始会话。")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 卡片

    /// 窄窗口里卡片贴底，iPhone 上底边跟着屏幕圆角；宽窗口里是一张四角相同的卡片。
    private func card(keyboard: Bool, wide: Bool, maxHeight: CGFloat) -> some View {
        #if os(iOS)
        let bottomRadius = keyboard || wide ? Metrics.cardRadius : max(Metrics.cardRadius, screenRadius - Metrics.padding)
        #else
        let bottomRadius = Metrics.cardRadius
        #endif
        let shape = UnevenRoundedRectangle(topLeadingRadius: Metrics.cardRadius, bottomLeadingRadius: bottomRadius,
                                           bottomTrailingRadius: bottomRadius, topTrailingRadius: Metrics.cardRadius,
                                           style: .continuous)
        // 卡片总高取模块的整数倍，底边落在模块线上时顶边也在
        let total = DotMetrics.snapUp(bodyHeight + footerHeight)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .connect = phase, Self.defaultMethod == .scan { methodPicker }
                    VStack(alignment: .leading, spacing: 16) { cardBody }
                        .id(phase)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], Self.inset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: max(0, min(total, maxHeight) - footerHeight))
            footer
                .padding(Self.inset)
                .padding(.bottom, wide ? 0 : bottomInset(keyboard: keyboard))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .background(Theme.card, in: shape)
        .clipShape(shape)
        .animation(.snappy, value: total)
    }

    /// 扫码与手动填写之间切换，切换时清掉上一种方式留下的错误。
    private var methodPicker: some View {
        Picker("连接方式", selection: Binding {
            if case .connect(let method) = page { method } else { Self.defaultMethod }
        } set: { method in
            error = nil
            model.invite = nil
            page = .connect(method)
        }) {
            Text("扫码").tag(Method.scan)
            Text("手动填写").tag(Method.manual)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var cardBody: some View {
        switch phase {
        case .launching, .connecting:
            EmptyView()
        case .prepare:
            #if os(macOS)
            CommandRow(command: "./install.command --service-only")
            Text("使用安装包时，双击其中的「安装.command」。")
                .font(Theme.secondary).foregroundStyle(.secondary)
            #else
            instruction(1, "安装 Kite 后台服务")
            instruction(2, "开启组网，并在浏览器中登录", command: "kite net up")
            instruction(3, "显示这台 iPhone 的配对二维码，也可以在工作机 Kite 设置的「远程设备」中生成", command: "kite pair")
            #endif
        case .connect(.scan):
            Text("二维码在工作机终端运行 kite pair 后显示，五分钟内有效。")
                .font(Theme.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = model.invite {
                callout(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
            }
            #if DEBUG
            if simulation != nil {
                callout("预览：轻点取景框模拟扫到二维码", systemImage: "hand.tap", tint: .accentColor)
            }
            #endif
        case .connect(.manual):
            OnboardingField(label: "工作机地址", prompt: "http://100.64.0.1:5483", text: $address, focus: $focus,
                            monospaced: true, submit: connect)
            OnboardingField(label: "配对码", prompt: "远程设备首次连接时填写", text: $code, focus: $focus,
                            monospaced: true, submit: connect)
            if showsControlURL {
                OnboardingField(label: "组网服务器", prompt: "自建 headscale 的地址，留空用 Tailscale",
                                text: $controlURL, focus: $focus, monospaced: true, submit: connect)
                    .transition(.opacity)
            } else {
                Button { withAnimation(.snappy) { showsControlURL = true } } label: {
                    let custom = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if custom.isEmpty {
                        Label("使用自建组网服务器", systemImage: "plus.circle")
                    } else {
                        Label("组网服务器：\(URL(string: custom)?.host() ?? custom)", systemImage: "pencil.circle")
                    }
                }
                .font(Theme.secondary)
                .buttonStyle(.pointingPlain)
                .foregroundStyle(Color.accentColor)
            }
            if error == nil, let message = model.error {
                callout(message, systemImage: "info.circle", tint: .secondary)
            }
        case .create:
            OnboardingField(label: "项目文件夹", prompt: "工作机上的绝对路径，如 /Users/me/Projects/app",
                            text: $path, focus: $focus, monospaced: true, submit: createProject)
        }
        if let error {
            callout(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .launching, .connecting:
            EmptyView()
        case .prepare:
            #if os(macOS)
            buttons(primary: nil, enabled: false, action: {}, secondary: "连接另一台工作机") { go(.connect(.manual)) }
            #else
            buttons(primary: "下一步", enabled: true) { go(.connect(Self.defaultMethod)) }
            #endif
        case .connect(.scan):
            buttons(primary: nil, enabled: false, action: {}, secondary: "返回") { go(.prepare) }
        case .connect(.manual):
            buttons(primary: "连接", enabled: !address.trimmingCharacters(in: .whitespaces).isEmpty, action: connect,
                    secondary: "返回") { go(.prepare) }
        case .create:
            buttons(primary: working ? "正在创建…" : "创建项目", enabled: !working && path.hasPrefix("/"), action: createProject)
        }
    }

    private func instruction(_ number: Int, _ text: String, command: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Theme.secondary.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if let command { CommandRow(command: command) }
            }
        }
    }

    private func callout(_ text: String, systemImage: String, tint: Color) -> some View {
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

    private func buttons(primary: String?, enabled: Bool, action: @escaping () -> Void,
                         secondary: String? = nil, secondaryAction: @escaping () -> Void = {}) -> some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                if let secondary {
                    Button(secondary, action: secondaryAction)
                        .buttonStyle(.glass)
                        .disabled(working)
                }
                if let primary {
                    Button(action: action) {
                        Text(primary).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!enabled)
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

    // MARK: 操作

    private func go(_ page: Phase) {
        error = nil
        model.invite = nil
        self.page = page
    }

    private func connect() {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        connectingBy = .manual
        perform {
            await Tailnet.shared.configure(controlURL: controlURL.trimmingCharacters(in: .whitespacesAndNewlines))
            try await model.addConnection(address: address, code: code)
        } simulated: {
            simulation?.connected = true
        }
    }

    /// 只认 kite://pair 链接；扫到别的码提示一下，取景框继续扫。
    private func scanned(_ text: String) {
        guard !joining, connectingBy == nil, let url = URL(string: text) else { return }
        guard url.scheme == "kite", url.host() == "pair" else {
            error = "这不是 Kite 的配对二维码"
            return
        }
        error = nil
        #if DEBUG
        if simulation != nil { simulateScan(); return }
        #endif
        emitScanWave()
        model.invite = nil
        Task { await model.acceptInvite(url) }
    }

    private func simulateScan() {
        #if DEBUG
        guard simulation != nil, !joining else { return }
        emitScanWave()
        simulation?.joining = true
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            simulation?.joining = false
            simulation?.connected = true
        }
        #endif
    }

    /// 扫到码是完成的时刻，从取景框外沿推开一道波。
    private func emitScanWave() {
        #if os(iOS)
        if let logoArea { stage.emitWave(from: scanFrame(in: logoArea), pace: Self.wavePace) }
        #endif
    }

    private func createProject() {
        guard path.hasPrefix("/") else { return }
        perform {
            let checkout = try await model.registerCheckout(path: path, projectID: "")
            // 根工作区刚登记时还没有窗口，打开一个空白会话作为起点
            guard let area = model.workspaces.first(where: { $0.remote?.checkout.id == checkout && $0.remote?.workspace.kind == .root })
            else { return }
            model.selected = area.id
            if let agent = area.definitions.first(where: { $0.id == "kite.agent.coding" }) { model.createInstance(agent, in: area) }
        } simulated: {
            restartPreview()
            toast?.show("预览走完了，已回到开头", systemImage: "checkmark")
        }
    }

    /// simulated 只用于预览：不执行 action，等一会儿后改模拟的状态。
    private func perform(_ action: @escaping () async throws -> Void, simulated: @escaping () -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            #if DEBUG
            if simulation != nil {
                try? await Task.sleep(for: .seconds(2.5))
                simulated()
                return
            }
            #endif
            do { try await action() } catch {
                self.error = error.localizedDescription
                connectingBy = nil
            }
        }
    }

    /// 预览从启动时的自动连接开始，一会儿后按连不上处理，进入准备工作机。
    private func restartPreview() {
        #if DEBUG
        simulation = Simulation()
        page = .prepare
        connectingBy = nil
        error = nil
        code = ""
        path = ""
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            simulation?.launching = false
        }
        #endif
    }
}

/// 卡片里的输入框：上面一行标签，下面是不带边框的填充框，聚焦时描主题色。焦点由整页共用，按标签区分。
private struct OnboardingField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var focus: FocusState<String?>.Binding
    var monospaced = false
    let submit: () -> Void

    #if os(macOS)
    private static let height: CGFloat = 36
    #else
    private static let height: CGFloat = 48
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let focused = focus.wrappedValue == label
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? Theme.code : Theme.body)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused(focus, equals: label)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .frame(height: Self.height)
                .background(Theme.codeBackground, in: shape)
                .overlay { shape.strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5) }
                .contentShape(shape)
                .onTapGesture { focus.wrappedValue = label }
                .typingTarget()
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// 一行要在工作机终端里运行的命令，右边复制。
private struct CommandRow: View {
    let command: String
    @Environment(\.toast) private var toast

    var body: some View {
        HStack(spacing: 8) {
            Text("$").foregroundStyle(.tertiary)
            Text(command).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { copyToPasteboard(command, toast: toast) } label: {
                Image("CodeCopy").resizable().scaledToFit().frame(width: 16, height: 16)
            }
            .buttonStyle(PaneButtonStyle())
            .help("复制命令")
            .accessibilityLabel("复制命令")
        }
        .font(Theme.code)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 每一步的点阵标志，23×23 格，逐行字符画：B 主题色，M Morning Breeze，L Dewy Blue，Y Sunwashed，D Sunwashed 深一档，
/// . 是静息的点。同一尺寸的标志之间逐格形变，格子对得上。
private enum OnboardingLogos {
    static func colors(accent: DotColor) -> [Character: DotColor] {
        ["B": accent, "M": DotColor(hex: 0x7FA8D6), "L": DotColor(hex: 0xA8C6E7),
         "Y": DotColor(hex: 0xFFE08A), "D": DotColor(hex: 0xF5C95C)]
    }

    /// 这一步的标志，各配一个小动画：风筝各自浮动，显示器的光标闪烁，连接线上一段亮光从手机走向工作机，二维码的黄格错开闪烁，
    /// 文件夹的加号慢闪。扫码时标志区让给取景框，没有标志。正在连接时沿用发起连接那一步的标志，在等待里呼吸。
    static func figure(for phase: Onboarding.Phase, colors: [Character: DotColor]) -> DotFigure? {
        func part(_ lines: [String], _ motion: FigureMotion = .still) -> DotFigure {
            DotFigure(lines, colors: colors, motion: motion)
        }
        /// 逐格改写字符画：transform 拿到列、行和原字符，给出新字符。
        func map(_ lines: [String], _ transform: (Int, Int, Character) -> Character) -> [String] {
            lines.enumerated().map { row, line in
                String(line.enumerated().map { column, character in transform(column, row, character) })
            }
        }
        switch phase {
        case .launching:
            return DotFigure(columns: 29, rows: 23)
                .adding(part(kite, .float(4, period: 5)), column: 3, row: 0)
                .adding(part(smallKite, .float(6, period: 3.6, phase: 0.3)), column: 0, row: 0)
                .adding(part(smallKiteMirrored, .float(6, period: 4.2, phase: 0.7)), column: 24, row: 10)
                .adding(part(tinyKite, .float(5, period: 3.2, phase: 0.5)), column: 1, row: 15)
        case .prepare:
            // 提示符后面那条下划线是光标，熄掉时露出屏幕底色
            let cursor = { (column: Int, row: Int) in row == 9 && (8..<12).contains(column) }
            return part(map(desktop) { cursor($0, $1) ? "L" : $2 })
                .adding(part(map(desktop) { cursor($0, $1) ? $2 : "." }, .blink(period: 1.1)), column: 0, row: 0)
        case .connect(.manual), .connecting(.manual):
            // 手机与工作机之间是一条连续的线，一段亮光从手机走向工作机，像信号在走
            let line = Array(7..<12)
            return line.enumerated().reduce(part(link)) { figure, cell in
                figure.adding(part(map(link) { column, row, _ in row == 8 && column == cell.element ? "Y" : "." },
                                   .blink(period: 1.4, duty: 0.22, phase: -Double(cell.offset) * 0.1)), column: 0, row: 0)
            }
        case .connect(.scan):
            return nil
        case .connecting(.scan):
            // 二维码里的黄格分三组，错开闪烁
            return (0..<3).reduce(part(map(qr) { $2 == "Y" ? "." : $2 })) { figure, group in
                figure.adding(part(map(qr) { $2 == "Y" && ($1 * 7 + $0) % 3 == group ? $2 : "." },
                                   .blink(period: 1.8, duty: 0.6, phase: -Double(group) / 3)), column: 0, row: 0)
            }
        case .create:
            return part(map(folder) { $2 == "Y" ? "L" : $2 })
                .adding(part(map(folder) { $2 == "Y" ? $2 : "." }, .blink(period: 1.6, duty: 0.6)), column: 0, row: 0)
        }
    }

    /// 步骤点，紧挨着：大小表示完成没有，走过的满格，当前这步和还没到的半格；当前这步主题色，还没到的 Dewy Blue。
    static func steps(current: Int, count: Int, colors: [Character: DotColor]) -> DotFigure {
        let cells = (0..<count).map { $0 < current ? "B" : $0 == current ? "b" : "l" }
        var colors = colors
        colors["b"] = colors["B"]
        colors["l"] = colors["L"]
        return DotFigure([cells.joined()], colors: colors, shapes: ["b": 0.5, "l": 0.5])
    }

    /// 启动时风筝旁边的小风筝。
    static let smallKite = [
        "..B..",
        ".BYB.",
        "BYBLB",
        ".BLB.",
        "..B..",
        "..D..",
        ".D...",
        "..D..",
    ]

    static let smallKiteMirrored = [
        "..B..",
        ".BLB.",
        "BLBYB",
        ".BYB.",
        "..B..",
        "..D..",
        "...D.",
        "..D..",
    ]

    static let tinyKite = [
        ".B.",
        "BYB",
        ".B.",
        ".D.",
        "D..",
    ]

    /// 启动时自动连接：Kite 的风筝。
    static let kite = [
        "...........B...........",
        "..........BBB..........",
        ".........BYBLB.........",
        "........BYYBLLB........",
        ".......BYYYBLLLB.......",
        "......BYYYYBLLLLB......",
        ".....BYYYYYBLLLLLB.....",
        "....BBBBBBBBBBBBBBB....",
        ".....BLLLLLBYYYYYB.....",
        "......BLLLLBYYYYB......",
        "......BLLLLBYYYYB......",
        ".......BLLLBYYYB.......",
        "........BLLBYYB........",
        ".........BLBYB.........",
        ".........BLBYB.........",
        "..........BBB..........",
        "...........B...........",
        "...........B...........",
        "...........DBD.........",
        "............B..........",
        "...........B...........",
        ".........DBD...........",
        "..........B............",
    ]

    /// 准备工作机：带提示符的显示器。
    static let desktop = [
        ".......................",
        ".......................",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLYLLLLLLLLLLLLLLLLB.",
        ".BLLLYLLLLLLLLLLLLLLLB.",
        ".BLLLLYLLLLLLLLLLLLLLB.",
        ".BLLLYLLLLLLLLLLLLLLLB.",
        ".BLLYLLLYYYYLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLMMMMMMMLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        "..........BBB..........",
        "..........BBB..........",
        "..........BBB..........",
        "......BBBBBBBBBBB......",
        ".......................",
        ".......................",
        ".......................",
    ]

    /// 连接：手机、一条连线、矮而宽的工作机显示器。
    static let link = [
        "BBBBBBB....................",
        "BBBBBBB....................",
        "BLLLLLB....................",
        "BLLLLLB.....BBBBBBBBBBBBBBB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLBMMMMMBLLLLLLLLLLLLLB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLB.....BLLLLLLLLLLLLLB",
        "BLLLLLB.....BBBBBBBBBBBBBBB",
        "BLLLLLB............B.......",
        "BLLLLLB.........BBBBBBB....",
        "BBBBBBB....................",
        "BLLYLLB....................",
        "BBBBBBB....................",
    ]

    /// 扫码后正在连接：二维码。
    static let qr = [
        "BBBBBBB.Y.BY.BY.BBBBBBB",
        "B.....B...B...B.B.....B",
        "B.BBB.B.BYB.B.B.B.BBB.B",
        "B.BBB.B.YB.B.B..B.BBB.B",
        "B.BBB.B.B...BB..B.BBB.B",
        "B.....B.BB...B..B.....B",
        "BBBBBBB.......B.BBBBBBB",
        "...........B.BY........",
        "BBBB....BB.YB..YB......",
        "B...BBYYYYBB.BBB...YB.Y",
        "..BB...BB..B......BYBB.",
        "....BYB.....B....BB.B..",
        "YB.B..BY.......BB.BBB..",
        ".....BY.B..B..BB.......",
        "..........B..Y.BB..B.B.",
        "........BB..B.YBB.B..B.",
        "BBBBBBB..BBY...Y...Y..B",
        "B.....B...BB.B.Y.YYBBBB",
        "B.BBB.B.BB.B.B...BBBB..",
        "B.BBB.B.BYBYB..BBBBYBBB",
        "B.BBB.B.B..BBBYB..BBB.B",
        "B.....B..B.B....B......",
        "BBBBBBB...YBB.....B....",
    ]

    /// 创建项目：加号文件夹。
    static let folder = [
        ".......................",
        ".......................",
        ".......................",
        ".BBBBBBBB..............",
        ".BLLLLLLLB.............",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLYYYLLLLLLLLB.",
        ".BLLLLLLLLYYYLLLLLLLLB.",
        ".BLLLLLLYYYYYYYLLLLLLB.",
        ".BLLLLLLYYYYYYYLLLLLLB.",
        ".BLLLLLLYYYYYYYLLLLLLB.",
        ".BLLLLLLLLYYYLLLLLLLLB.",
        ".BLLLLLLLLYYYLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        ".......................",
        ".......................",
        ".......................",
    ]
}
