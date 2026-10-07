import SwiftUI

extension AppModel {
    /// 初始配置以账号和设备入网为准；完成后进入统一项目目录。
    var needsOnboarding: Bool { OnboardingPreview.enabled || !account.ready }
}

/// Debug build 带 --onboarding-preview 启动，或编译时开启 KITE_ONBOARDING_PREVIEW，从头走一遍初始配置：
/// 不连接服务，登录和入网只模拟等待，完成后可回到开头。
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

/// 两端完成设备入网后，直接浏览所有工作机的项目与检出。
struct AppRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.needsOnboarding {
            Onboarding()
        } else {
            AdaptiveWorkspace()
        }
    }
}

/// 首次使用的账号与设备配置，两端都铺满整个窗口。
/// 从上到下：点阵在背景上拼出这一步的标志，进入下一步时逐格形变成下一个；标题直接压在背景上；
/// 底部的卡片只放这一步要填的、要做的，高度随内容，没有要操作的步骤不出卡片。
/// 先登录或扫码加入账号，Mac 再选择执行任务或仅远程控制；入网完成直接进入 App，项目创建留在之后。
struct Onboarding: View {
    /// 登录账号的两种方式；扫码在 iPhone 和 iPad 上提供。
    fileprivate enum Method: Hashable { case scan, manual }

    /// 当前这一步，各有自己的标志。
    /// 入网完成后直接进入 App，没有收尾页。
    fileprivate enum Phase: Hashable {
        case prepare
        case connect(Method)
        /// 扫码或手动发起连接之后，直到连上或失败。
        case connecting(Method)

        /// 正在连接时没有要操作的，不出卡片。
        var hasCard: Bool {
            if case .connecting = self { false } else { true }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.self) private var environment
    @State private var stage = DotStage()
    /// 连接之前停在哪一页：准备工作机或连接。
    @State private var page = Phase.connect(.manual)
    @State private var address = ""
    @State private var code = ""
    @State private var registering = false
    @State private var role = "worker"
    /// 正在填的输入框；点卡片外、输入框外收起键盘。
    @FocusState private var focus: String?
    @State private var working = false
    @State private var error: String?
    /// 标志区在窗口坐标中的范围：标题以上露出背景的那块。
    @State private var logoArea: CGRect?
    /// 卡片正文与底部按钮的高度，卡片按它们定高，放不下时正文滚动。
    @State private var bodyHeight: CGFloat = 0
    /// 标题连同上下留白的高度，卡片最多占到它下面。
    @State private var titleHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    #if os(iOS)
    @State private var screenRadius: CGFloat = 0
    @State private var homeInset: CGFloat = 0
    #endif
    #if DEBUG
    /// 预览时代替真实的账号状态；入网完成时回到开头。
    private struct Simulation: Equatable {
        var signedIn = false
        var joining = false
    }
    @State private var simulation: Simulation?
    #endif

    private static let inset = CardMetrics.inset
    /// 完成一步时的波比发送消息的慢，配合标志形变。
    private static let wavePace = 0.24
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

            #if DEBUG
            if OnboardingPreview.enabled { restartPreview() }
            #endif
        }
        #if os(iOS)
        .onChange(of: model.invite) { _, invite in
            // 也可能是用系统相机扫的码，从链接打开
            if case .failed(let message) = invite { error = message; page = .connect(.scan) }
        }
        #endif
        .onChange(of: logo, initial: true) { refreshLogo() }
        .animation(.snappy, value: phase)
    }

    /// 账号状态：预览时用模拟的。
    private var signedIn: Bool {
        #if DEBUG
        if let simulation { return simulation.signedIn }
        #endif
        return model.account.signedIn
    }

    private var joining: Bool {
        #if DEBUG
        if let simulation { return simulation.joining }
        #endif
        #if os(iOS)
        return model.invite == .joining
        #else
        return false
        #endif
    }

    private var previewing: Bool {
        #if DEBUG
        simulation != nil
        #else
        false
        #endif
    }

    private var phase: Phase {
        if joining || model.account.joining { return .connecting(.scan) }
        if working { return .connecting(.manual) }
        if signedIn { return .prepare }
        return page == .prepare ? .connect(.manual) : page
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

    /// 露出背景、拼标志的那块；iPhone 和 iPad 扫码时放取景框。
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
        let colors = DotFigure.letters(accent: DotColor(Color.accentColor.resolve(in: environment)))
        let figure = OnboardingLogos.figure(for: phase, colors: colors)?.trimmed()
        // 标志区放不下时往上借到窗口顶边（iPhone 上是状态栏那一截背景），还放不下才退回点
        let tall = CGRect(x: logoArea.minX, y: 0, width: logoArea.width, height: logoArea.maxY)
        let area = figure.flatMap { figure in
            [logoArea, tall].first {
                CGFloat(figure.rows) * DotMetrics.pitch <= $0.height && CGFloat(figure.columns) * DotMetrics.pitch <= $0.width
            }
        }
        return Logo(figure: area == nil ? nil : figure, area: area ?? logoArea, breathing: !phase.hasCard)
    }

    /// 按当前状态摆标志；同一个标志在同一处时什么也不做。
    private func refreshLogo() {
        guard let logo else { return }
        let previous = stage.shownFigure()
        let previousFrame = stage.figureFrame()
        stage.show(logo.figure, in: logo.area, breathing: logo.breathing)
        // 登录完成、换到选择用途时，从刚完成的登录标志发波。
        if phase == .prepare, previous != nil, previous != logo.figure, logo.figure != nil, let frame = previousFrame {
            stage.emitWave(from: frame, pace: Self.wavePace)
        }
    }

    #if os(iOS)
    /// 扫码时取景框占住标志区：正方形，边落在模块线上。
    /// 中线取离区域中线最近的模块线或模块中线，边长的模块数随之取奇偶，两侧露出的点数相同，不会一边宽一边窄。
    private func scanFrame(in area: CGRect) -> CGRect {
        let half = DotMetrics.module / 2
        let center = (area.midX / half).rounded()
        var modules = Int(min(area.width - Metrics.padding * 2, area.height - Metrics.padding * 2, 336) / DotMetrics.module)
        if (Int(center) - modules) % 2 != 0 { modules -= 1 }
        let side = CGFloat(modules) * DotMetrics.module
        return CGRect(x: center * half - side / 2, y: DotMetrics.snapDown(area.midY - side / 2),
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

    /// 标题与说明直接压在背景上；换步骤时新的标题从下面浮上来，旧的淡掉。
    private var titleBlock: some View {
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

    private var title: String {
        switch phase {
        case .connecting: signedIn ? "正在加入设备" : "正在登录"
        case .prepare: "这台设备用来做什么"
        case .connect(.scan): "扫码登录 Kite"
        case .connect(.manual): registering ? "创建 Kite 账号" : "登录 Kite"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .connecting:
            note("正在完成账号登录和设备入网，请稍候。")
        case .prepare:
            note("同一账号下的设备会自动加入网络，随时可以选择工作机。")
        case .connect(.scan):
            note("扫描已登录设备在“我的设备”中显示的二维码。")
        case .connect(.manual):
            note("使用一个账号管理你的设备。")
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

    @ViewBuilder
    private var cardBody: some View {
        switch phase {
        case .connecting:
            EmptyView()
        case .prepare:
            #if os(macOS)
            Picker("设备用途", selection: Binding(get: { model.account.role ?? role }, set: { role = $0 })) {
                Text("在这台 Mac 上运行任务").tag("worker")
                Text("仅远程控制").tag("controller")
            }.pickerStyle(.radioGroup).disabled(model.account.role != nil)
            note((model.account.role ?? role) == "worker" ? "安装 kited，让任务在这台 Mac 上运行。你也可以控制其他工作机。" : "加入设备网络，控制账号下的工作机。这台 Mac 不安装 kited。")
            #else
            note("这台设备用来控制账号下的工作机。")
            #endif
        case .connect(.scan):
            note("二维码五分钟内有效，只能使用一次。")
            #if os(iOS)
            if case .failed(let message) = model.invite {
                callout(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
            }
            #endif
        case .connect(.manual):
            OnboardingField(label: "邮箱", prompt: "you@example.com", text: $address, focus: $focus,
                            submit: connect, scan: { registering = false; go(.connect(.scan)) })
            CardField(label: "密码", focused: focus == "密码") {
                SecureField(registering ? "至少 10 个字符" : "账号密码", text: $code)
                    .textContentType(registering ? .newPassword : .password)
                    .focused($focus, equals: "密码")
                    .onSubmit(connect)
                    .cardInput { focus = "密码" }
            }
            Button(registering ? "已有账号，去登录" : "没有账号？创建一个") { registering.toggle(); error = nil }
                .buttonStyle(.pointingPlain).font(Theme.secondary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        if let error {
            callout(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .connecting:
            EmptyView()
        case .prepare:
            buttons(primary: "加入设备", enabled: !working, action: joinDevice, secondary: "退出登录") {
                perform { try await model.account.signOut() } simulated: { restartPreview() }
            }
        case .connect(.scan):
            buttons(primary: "账号密码登录", enabled: !working, action: { go(.connect(.manual)) }, prominent: false)
        case .connect(.manual):
            buttons(primary: registering ? "创建账号" : "登录", enabled: !working && address.contains("@") && (registering ? code.count >= 10 : !code.isEmpty), action: connect)
        }
    }

    private func callout(_ text: String, systemImage: String, tint: Color) -> some View {
        CardCallout(text: text, systemImage: systemImage, tint: tint)
    }

    private func buttons(primary: String, enabled: Bool, action: @escaping () -> Void,
                         prominent: Bool = true,
                         secondary: String? = nil, secondaryAction: @escaping () -> Void = {}) -> some View {
        CardActions(primary: primary, enabled: enabled, prominent: prominent, secondary: secondary,
                    secondaryEnabled: !working, action: action, secondaryAction: secondaryAction)
    }

    // MARK: 操作

    private func go(_ page: Phase) {
        focus = nil
        error = nil
        #if os(iOS)
        model.invite = nil
        #endif
        self.page = page
    }

    private func connect() {
        perform {
            try await model.account.signIn(email: address, password: code, register: registering)
            code = ""
            #if os(iOS)
            try await model.account.join(role: "controller", name: AppModel.deviceName)
            #endif
        } simulated: {
            #if DEBUG && os(macOS)
            simulation?.signedIn = true
            #elseif os(iOS)
            restartPreview()
            #endif
        }
    }

    private func joinDevice() {
        perform {
            #if os(macOS)
            try await model.account.join(role: role, name: AppModel.deviceName)
            #else
            try await model.account.join(role: "controller", name: AppModel.deviceName)
            #endif
        } simulated: { restartPreview() }
    }

    #if os(iOS)
    /// 只认 kite://join 链接；扫到别的码提示一下，取景框继续扫。
    private func scanned(_ text: String) {
        guard !joining, let url = URL(string: text) else { return }
        guard url.scheme == "kite", url.host() == "join" else {
            error = "这不是 Kite 的登录二维码"
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
            restartPreview()
        }
        #endif
    }

    /// 扫到码时从镜头取景框外沿推开一道波。
    private func emitScanWave() {
        if let logoArea { stage.emitWave(from: scanFrame(in: logoArea), pace: Self.wavePace) }
    }
    #endif

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
            }
        }
    }

    /// 预览从未登录开始，入网完成后回到这里。
    private func restartPreview() {
        #if DEBUG
        simulation = Simulation()
        page = .connect(.manual)
        error = nil
        code = ""
        #endif
    }
}

/// 卡片里的邮箱输入框，iPhone 上右侧带扫码登录。焦点由整页共用，按标签区分。
private struct OnboardingField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var focus: FocusState<String?>.Binding
    let submit: () -> Void
    let scan: () -> Void

    var body: some View {
        CardField(label: label, focused: focus.wrappedValue == label) {
            HStack(spacing: 0) {
                TextField(prompt, text: $text)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused(focus, equals: label)
                    .onSubmit(submit)
                    .cardInput { focus.wrappedValue = label }
                #if os(iOS)
                Button(action: scan) {
                    PaneButtonLabel("扫码登录", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PaneButtonStyle())
                .padding(.trailing, 4)
                #endif
            }
        }
    }
}

/// 每一步的点阵标志，逐行字符画，字母表见 DotFigure.letters。显示器与二维码 23×23 格，登录的风筝组 29×23 格。
private enum OnboardingLogos {
    /// 这一步的标志，各配一个小动画：风筝各自浮动，显示器的光标闪烁，二维码的黄格错开闪烁。
    /// 扫码时标志区让给取景框，没有标志。正在连接时沿用发起连接那一步的标志，在等待里呼吸。
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
        case .connect(.manual), .connecting(.manual):
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
        case .connect(.scan):
            return nil
        case .connecting(.scan):
            // 二维码里的黄格分三组，错开闪烁
            return (0..<3).reduce(part(map(qr) { $2 == "Y" ? "." : $2 })) { figure, group in
                figure.adding(part(map(qr) { $2 == "Y" && ($1 * 7 + $0) % 3 == group ? $2 : "." },
                                   .blink(period: 1.8, duty: 0.6, phase: -Double(group) / 3)), column: 0, row: 0)
            }
        }
    }

    /// 登录时主风筝旁边的小风筝。
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

    /// 登录时：主风筝向右倾斜，笔画仍落在点阵格位上。
    static let kite = [
        ".......................",
        "...............B.......",
        "...........BBYBB.......",
        ".......BBYYYYYBLB......",
        "......BBYYYYYBLLB......",
        "......BBBYYYYBLLB......",
        "......BLLBBYBLLLB......",
        "......BLLLLBBLLLB......",
        "......BLLLLBYBLLB......",
        "......BLLLBYYYBBB......",
        "......BLLLBYYYYYBB.....",
        ".......BLBYYYYYBB......",
        ".......BLBYYYYBB.......",
        ".......BBYBBBB.........",
        ".......BBYB............",
        ".......B...............",
        "......B................",
        ".....DBD...............",
        ".....BB................",
        "...DBD.................",
        "...B...................",
        ".......................",
        ".......................",
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
}
