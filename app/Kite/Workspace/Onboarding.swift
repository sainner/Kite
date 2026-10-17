import AuthenticationServices
import SwiftUI

extension AppModel {
    /// 初始配置以登录 Tailscale、设备上线为准；完成后进入统一项目目录。
    var needsOnboarding: Bool { OnboardingPreview.enabled || !account.ready }
}

/// Debug build 带 --onboarding-preview 启动，或编译时开启 KITE_ONBOARDING_PREVIEW，从头走一遍初始配置：
/// 不连接组网，登录只模拟等待，完成后可回到开头。
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

/// 两端登录上线后，直接浏览所有工作机的项目与检出。登录地址出现时（首次配置或登录失效后重新登录）在这里弹出登录页。
struct AppRoot: View {
    @Environment(AppModel.self) private var model
    /// 正在显示的登录页；登录完成或放弃时关掉。
    @State private var login = LoginPage()

    var body: some View {
        Group {
            if model.needsOnboarding {
                Onboarding()
            } else {
                AdaptiveWorkspace()
            }
        }
        // 用户关掉登录页就不再等。
        .onChange(of: model.account.loginURL) { _, url in
            guard let url else { login.close(); return }
            login.open(url) { model.account.cancelJoin() }
        }
    }
}

/// 首次使用的设备配置，两端都铺满整个窗口。
/// 只有「组网」一页：登录 Tailscale，Mac 在同一页里先选执行任务还是仅远程控制。上线后直接进入 App，项目创建留在之后。
/// 从上到下：点阵在背景上拼出标志；标题直接压在背景上；底部的卡片放 Mac 的用途和登录按钮，高度随内容，正在登录时不出卡片。
struct Onboarding: View {
    /// 上线后直接进入 App，没有收尾页。
    enum Phase: Hashable {
        case network
        /// 发起登录之后，直到上线或失败；登录页在浏览器里。
        case connecting

        /// 正在登录时没有要操作的，不出卡片。
        var hasCard: Bool { self == .network }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.self) private var environment
    @State private var stage = DotStage()
    #if os(macOS)
    @State private var role = "worker"
    #endif
    @State private var progress = CardPhase.idle
    private var working: Bool { progress.working }
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
    /// 预览时只模拟等待，上线时回到开头。
    @State private var previewing = false
    #endif

    private static let inset = CardMetrics.inset
    /// 标题与卡片那一栏的宽度：窄窗口里居中，宽窗口里靠右。
    private static let columnWidth: CGFloat = 504

    var body: some View {
        GeometryReader { geo in
            Group {
                if Self.isWide(geo.size) {
                    wideLayout(size: geo.size)
                } else {
                    narrowLayout(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                if previewing {
                    Button("重新开始", systemImage: "arrow.counterclockwise", action: restartPreview)
                        .buttonStyle(.pointingGlass)
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
                ScreenReader { radius, bottom, _ in
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
        #endif
        .onAppear {
            #if DEBUG
            if OnboardingPreview.enabled { restartPreview() }
            #endif
        }
        .onChange(of: logo, initial: true) { refreshLogo() }
        .animation(.snappy, value: phase)
    }

    private var phase: Phase {
        model.account.joining || working ? .connecting : .network
    }

    // MARK: 排布

    /// 宽窗口（Mac 的常见尺寸）左右排：左边标志，右边标题与卡片；窄的（iPhone 竖屏、缩窄的 Mac 窗口）上下排。
    private static func isWide(_ size: CGSize) -> Bool { size.width >= 840 && size.height >= 480 }

    /// 上面露出背景拼标志，下面标题和贴底的卡片。标题和卡片按内容定高，剩下的才给标志；
    /// 放不下的时候标志先让，卡片最多占到标题以下，再放不下正文才滚动。
    private func narrowLayout(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoSpace
            titleBlock
                .padding(.horizontal, Self.inset)
                .padding(.bottom, phase.hasCard ? Self.inset : Self.inset * 2 + bottomInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            if phase.hasCard {
                card(wide: false, maxHeight: size.height - Metrics.padding * 2 - titleHeight)
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
                    card(wide: true, maxHeight: size.height - Metrics.padding * 2 - titleHeight)
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

    /// 露出背景、拼标志的那块。
    private var logoSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                logoArea = $0
                // onChange(of: logo) 拿到的区域会慢一拍，区域一变就按当前状态重摆
                refreshLogo()
            }
    }

    /// 窄布局里一栏居中，左边落在模块线上；放不下一栏时卡片两边各留一个模块。
    private func horizontalMargin(width: CGFloat) -> CGFloat {
        DotMetrics.snapDown(max(Metrics.padding, (width - Self.columnWidth) / 2))
    }

    /// iPhone 上卡片伸到屏幕底边，内容在 Home 条之上结束。
    private var bottomInset: CGFloat {
        #if os(iOS)
        max(0, homeInset - Metrics.padding - 8)
        #else
        0
        #endif
    }

    /// 背景上要拼的标志：放在哪、是否在等待。标志区放不下整个标志时（窗口太矮）退回点。
    private struct Logo: Equatable {
        var figure: DotFigure?
        var area: CGRect
        var breathing: Bool
    }

    private var logo: Logo? {
        guard let logoArea else { return nil }
        let colors = DotFigure.letters(accent: DotColor(Color.accentColor.resolve(in: environment)))
        let figure = OnboardingLogos.figure(colors: colors).trimmed()
        // 标志区放不下时往上借到窗口顶边（iPhone 上是状态栏那一截背景），还放不下才退回点
        let tall = CGRect(x: logoArea.minX, y: 0, width: logoArea.width, height: logoArea.maxY)
        let area = [logoArea, tall].first {
            CGFloat(figure.rows) * DotMetrics.pitch <= $0.height && CGFloat(figure.columns) * DotMetrics.pitch <= $0.width
        }
        return Logo(figure: area == nil ? nil : figure, area: area ?? logoArea, breathing: !phase.hasCard)
    }

    /// 按当前状态摆标志；同一个标志在同一处时什么也不做。
    private func refreshLogo() {
        guard let logo else { return }
        stage.show(logo.figure, in: logo.area, breathing: logo.breathing)
    }

    // MARK: 标题

    /// 标题与说明直接压在背景上；开始登录时新的标题从下面浮上来，旧的淡掉。
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
        case .network: "组网"
        case .connecting: "正在登录"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .connecting:
            note("在打开的页面里登录 Tailscale，完成后自动继续。")
        case .network:
            note("用 Tailscale 完成设备组网。")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 卡片

    /// 窄窗口里卡片贴底，iPhone 上底边跟着屏幕圆角；宽窗口里是一张四角相同的卡片。
    private func card(wide: Bool, maxHeight: CGFloat) -> some View {
        #if os(iOS)
        let bottomRadius = wide ? Metrics.cardRadius : max(Metrics.cardRadius, screenRadius - Metrics.padding)
        #else
        let bottomRadius = Metrics.cardRadius
        #endif
        let shape = UnevenRoundedRectangle(topLeadingRadius: Metrics.cardRadius, bottomLeadingRadius: bottomRadius,
                                           bottomTrailingRadius: bottomRadius, topTrailingRadius: Metrics.cardRadius,
                                           style: .continuous)
        // 卡片总高取模块的整数倍，底边落在模块线上时顶边也在
        let total = DotMetrics.snapUp(bodyHeight + footerHeight)
        return VStack(spacing: 0) {
            // iPhone、iPad 只做控制端，卡片里只有按钮
            #if os(macOS)
            ScrollView {
                roles
                    .padding([.horizontal, .top], Self.inset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: max(0, min(total, maxHeight) - footerHeight))
            #endif
            CardActions(primary: "用 Tailscale 登录", icon: Image("BrandTailscale"), enabled: !working,
                        phase: $progress, action: joinDevice)
                .padding(Self.inset)
                .padding(.bottom, wide ? 0 : bottomInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .background(Theme.card, in: shape)
        .clipShape(shape)
        .animation(.snappy, value: total)
    }

    #if os(macOS)
    /// 这台 Mac 的用途，两张卡片并排。
    private var roles: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("选择这台设备的用途")
            HStack(spacing: 12) {
                CardChoice(title: "控制端", detail: "远程控制其他工作机", symbol: .remote, selected: role == "controller") { role = "controller" }
                CardChoice(title: "执行端", detail: "在这台 Mac 上运行任务", symbol: .cloudComputing, selected: role == "worker") { role = "worker" }
            }
        }
        .disabled(working)
    }
    #endif

    // MARK: 操作

    private func joinDevice() {
        perform {
            #if os(macOS)
            try await model.account.join(role: role)
            #else
            try await model.account.join(role: "controller")
            #endif
        } simulated: { restartPreview() }
    }

    /// simulated 只用于预览：不执行 action，等一会儿后改模拟的状态。
    private func perform(_ action: @escaping () async throws -> Void, simulated: @escaping () -> Void) {
        $progress.run {
            #if DEBUG
            if previewing {
                try? await Task.sleep(for: .seconds(2.5))
                simulated()
                return
            }
            #endif
            try await action()
        }
    }

    /// 预览从头开始，上线后回到这里。
    private func restartPreview() {
        #if DEBUG
        previewing = true
        progress = .idle
        #endif
    }
}

/// 登录页：在 App 里弹出的网页登录（ASWebAuthenticationSession），App 停在前台，iPhone 不会因切到浏览器而关掉组网节点。
/// Tailscale 登录完不会跳回 App，登录页由 App 在设备上线后关掉；用户自己关掉时调 cancelled。
@MainActor final class LoginPage: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var url: URL?

    func open(_ url: URL, cancelled: @escaping @MainActor () -> Void) {
        guard url != self.url else { return }
        close()
        self.url = url
        // 回调在系统的 XPC 队列上（登录完成后 close 取消会话时也会回调），闭包不能继承主线程隔离，否则一进来就被运行时的隔离检查终止
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable [weak self] _, error in
            Task { @MainActor in
                guard let self, self.url == url else { return }
                self.session = nil
                self.url = nil
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { cancelled() }
            }
        }
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    func close() {
        url = nil
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
