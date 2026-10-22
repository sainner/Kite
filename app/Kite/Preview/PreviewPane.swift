import SwiftUI

/// 预览窗口（docs/成果查看与位置.md「预览」）：一个实例是一个要看的对象，网页或本工作区的模拟器。
/// 网页默认在设备自己的网页视图里看（DeviceWebPreview），也可以换到工作机上的浏览器；工作机上的浏览器和模拟器都是传过来的画面（ScreenPreview），
/// 人和 agent 操作同一个页面、同一块屏幕。端口与在哪看各设备共用，改的是实例状态（AppModel.selectPreview）。
struct PreviewPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    @Environment(WorkArea.self) private var area

    var body: some View {
        let web = area.previewKind(of: instance) != .simulator
        let status = instance.state?.preview ?? PreviewStatus()
        if web, status.choice == .device {
            DeviceWebPreview(instance: instance, client: client, status: status)
        } else {
            ScreenPreview(instance: instance, client: client, connection: connection, web: web, status: status)
        }
    }
}

/// 网页预览的端口与在哪看：一个菜单，上半是本工作区运行中终端监听的端口，下半是设备自己的网页视图或工作机上的浏览器。
private struct PreviewTargetMenu: View {
    let instance: RemotePluginInstance
    let status: PreviewStatus
    let report: (String?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        let ports = area.workspacePortStatus
        Menu {
            Section("端口") {
                if ports.isEmpty { Text("还没有监听的端口") }
                ForEach(ports, id: \.port) { item in
                    Button { select(port: item.port) } label: {
                        let title = item.http ? "\(item.port)" : "\(item.port)（不是网页）"
                        if item.port == status.port { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            Section("在哪看") {
                ForEach(PreviewBrowser.allCases) { choice in
                    Button { select(browser: choice) } label: {
                        let title = choice == .device ? "本设备的网页视图" : "工作机上的 \(choice.title)"
                        if choice == status.choice { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: { PaneHeaderButtonLabel(status.port.map(String.init) ?? "选端口") }
            .foregroundStyle(Color.primary)
            .help("选要打开的端口和在哪看")
    }

    private func select(port: Int? = nil, browser: PreviewBrowser? = nil) {
        report(nil)
        Task {
            do { try await model.selectPreview(instance.id, port: port, browser: browser, in: area) }
            catch { report(error.localizedDescription) }
        }
    }
}

// MARK: - 设备自己的网页视图

/// 在设备自己的网页视图里看网页：经端口转发打开（PortPreview），页面里的跳转、滚动与登录状态按设备各自保存（store 按实例分开）。
/// 控制区：左边后退、前进、首页，中间地址栏（站点图标、localhost:、端口与在哪看的菜单、路径），右边重新加载，Mac 上还有开发者工具、在浏览器中打开。
/// 路径跟着页面显示，改了回车打开；都在同一个页面里跳转（WebBrowser），前进后退接得上。
/// 宽屏卡片里控制区随悬停显隐，同窗口按钮（见 WebControls）。紧凑布局里左边只有后退，有下一页时才出现前进，首页挪到地址栏最右边；
/// 键盘升起时收起键盘顶替左边这组，在地址栏里打字时清除输入顶替重新加载，点了路径回到打字前的样子、接着打字。
private struct DeviceWebPreview: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let status: PreviewStatus
    @Environment(WorkArea.self) private var area
    @Environment(\.workspacePresentation) private var presentation
    @State private var browser = WebBrowser()
    @State private var webFailure: String?
    @State private var selectError: String?
    @State private var reload = UUID()
    /// 清除输入：每点一次，地址栏的路径回到打字前的样子。
    @State private var pathReset = 0

    private var compact: Bool { presentation == .compact }
    /// 端口还在被本工作区的终端监听才打开；服务停了预览留着，同一端口再被监听时接着显示。
    private var port: Int? { status.port.flatMap { area.workspacePorts.contains($0) ? $0 : nil } }
    /// 消息里点的链接，端口对得上才打开到它的路径（见 AppModel.openLocalPort）。
    private var link: WebLink? { area.webLinks[instance.id].flatMap { $0.target.port == port ? $0 : nil } }
    private var notice: PaneNotice? {
        if let error = selectError ?? (port == nil ? nil : webFailure) { return .failure(error) }
        guard port == nil else { return nil }
        if let selected = status.port { return .info("localhost:\(selected) 现在没有终端在监听，服务起来后接着显示", symbol: "pause.circle") }
        return .info(area.workspacePorts.isEmpty ? "还没有监听的端口，先在终端里起服务" : "选要打开的端口")
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: status.port.map { "localhost:\($0)" } ?? "网页预览"), notice: notice) {
            if let port, let store = UUID(uuidString: instance.id) {
                PortPreview(client: client, port: port, workspacePorts: area.workspacePorts, store: store, link: link, browser: browser,
                            report: { webFailure = $0 })
                    .id("\(port) \(reload)")
            }
        } controls: { typing in
            WebControls(typing: typing.wrappedValue) {
                HStack(spacing: Metrics.paneButtonGap) {
                    if let port {
                        KeyboardSwap {
                            PaneHeaderButtonGroup {
                                ActionButton("后退", icon: "chevron.left", action: browser.back)
                                    .disabled(!browser.canGoBack)
                                if !compact || browser.canGoForward {
                                    ActionButton("前进", icon: "chevron.right", action: browser.forward)
                                        .disabled(!browser.canGoForward)
                                }
                                if !compact {
                                    ActionButton("首页", icon: "house") { open("/", on: port) }
                                }
                            }
                        } shown: {
                            KeyboardDismissButton()
                        }
                        address(port: port, typing: typing)
                        KeyboardSwap(active: typing.wrappedValue) {
                            PaneHeaderButtonGroup {
                                ActionButton("重新加载", icon: "arrow.clockwise") {
                                    webFailure = nil
                                    if !browser.reload() { reload = UUID() }
                                }
                                #if os(macOS)
                                // iPhone、iPad 没有自带的检查器，只能接上 Mac 从 Safari 打开（见 WebPreview）。
                                ActionButton("开发者工具", icon: "wrench.and.screwdriver", action: browser.inspect)
                                // 只在 Mac 上：其他设备上页面开在本机转发上（PortRelay），转发随这个窗口的网页视图开着；
                                // iPhone、iPad 切到浏览器后 App 进后台，转发停下，打不开。
                                // 不走环境里的 openURL：本机地址会被它接回网页预览（见 ReferenceNavigation）。
                                ActionButton("在浏览器中打开", icon: "arrow.up.right.square") {
                                    if let url = browser.url { NSWorkspace.shared.open(url) }
                                }
                                .disabled(browser.url == nil)
                                #endif
                            }
                        } shown: {
                            PaneHeaderButtonGroup {
                                ActionButton("清除输入", icon: "xmark") { pathReset += 1 }
                            }
                        }
                    } else {
                        Spacer(minLength: 0)
                        address(port: nil, typing: typing)
                        Spacer(minLength: 0)
                    }
                }
                // 没选端口时只有地址栏，收起键盘仍在最左边
                .containerValue(\.placesKeyboardButton, port != nil)
            }
        }
        .onChange(of: port) {
            webFailure = nil
            // 换到别的端口就从首页看起，回到原来的端口也不再停在之前点的链接上
            if area.webLinks[instance.id]?.target.port != port { area.webLinks[instance.id] = nil }
        }
    }

    /// 地址栏：站点图标、localhost:、端口与在哪看的菜单、路径，端口和路径之间不留空。还没打开端口时只有菜单。
    /// 紧凑布局里宽度不够，省掉 localhost:，首页放在地址栏最右边。
    private func address(port: Int?, typing: FocusState<Bool>.Binding) -> some View {
        PaneHeaderButtonGroup(expands: port != nil) {
            HStack(spacing: Metrics.paneHeaderLogoGap) {
                Group {
                    if let icon = browser.icon, port != nil {
                        icon.resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
                .accessibilityHidden(true)
                if !compact {
                    Text("localhost:")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Metrics.paneHeaderButtonGap / 2)
            PreviewTargetMenu(instance: instance, status: status) { selectError = $0 }
            if let port {
                WebPathField(path: LocalPort.displayPath(of: browser.url), typing: typing, reset: pathReset) { open($0, on: port) }
                    // 路径框压住端口按钮右边那半个按钮间距，端口的悬停高亮仍按整个按钮画
                    .padding(.leading, -Metrics.paneHeaderButtonGap / 2)
                if compact {
                    ActionButton("首页", icon: "house") { open("/", on: port) }
                }
            }
        }
    }

    /// 地址栏里输入的路径、首页，和消息里点的链接一样在页面里打开到它（见 WorkArea.webLinks）。
    private func open(_ path: String, on port: Int) {
        guard let target = LocalPort(path: path, port: port) else { return }
        webFailure = nil
        area.webLinks[instance.id] = WebLink(target: target)
    }
}

// MARK: - 工作机上的画面

/// 工作机上的浏览器页面或模拟器屏幕，画面经 PreviewSession 传过来。工作机本机默认实时，其他设备默认逐帧：做一个动作，等画面稳定后来一帧，
/// 等的期间画面上显示等待中、再点会被丢掉；刚点的位置在画面上标出来。想看动画切实时画面。拖动、滑动在松手时作为一个动作发出；
/// 长按、捏合另给按钮。网页的视口跟着最近操作的那台设备的窗口；模拟器屏幕尺寸固定，按比例放进窗口。
/// 打字：Mac 和接了键盘的 iPad 点一下画面就能直接打；输入法和触屏键盘用控制区的「输入文字」。
private struct ScreenPreview: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    let web: Bool
    let status: PreviewStatus
    @Environment(WorkArea.self) private var area
    @State private var session: PreviewSession
    @State private var actionError: String?
    @State private var longPress = false
    @State private var composing = false
    @State private var text = ""
    @FocusState private var textFocused: Bool

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, web: Bool, status: PreviewStatus) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.web = web
        self.status = status
        // 看的设备就是工作机时链路不成问题，默认实时；其他设备默认逐帧，想看动画再切
        _session = State(initialValue: PreviewSession(instanceID: instance.id, live: client.isLocal))
    }

    private var subtitle: String {
        guard web else { return "模拟器" }
        return [status.port.map { "localhost:\($0)" }, status.choice.title].compactMap { $0 }.joined(separator: " · ")
    }

    private var notice: PaneNotice? {
        if let actionError { return .failure(actionError) }
        if case .failed(let message) = session.link { return .failure(message) }
        if let error = session.error { return .failure(error) }
        if session.dropped { return .info("画面还在变，刚才的操作没有发出", symbol: "hand.raised") }
        switch session.link {
        case .waiting, .connecting: return .info("正在连接…", symbol: "hourglass")
        case .connected, .failed: break
        }
        switch session.phase {
        case "waiting": return .info("选要打开的端口")
        case "starting": return .info(web ? "正在打开\(status.choice.title)，第一次用要先下载，需要几分钟…" : "正在启动模拟器，第一次要半分钟左右…", symbol: "hourglass")
        default: return nil
        }
    }

    /// 消息里点的链接（见 AppModel.openLocalPort）：连上工作机后在页面里打开到它的路径；窗口刚开、还没连上时等连上。
    private var linkToOpen: UUID? { session.link == .connected ? area.webLinks[instance.id]?.id : nil }

    /// 实时画面开关放在标题栏右边。
    private var headerActions: PaneHeaderActions {
        PaneHeaderActions(groups: [[
            PaneHeaderAction(title: "刷新画面", systemImage: "camera.viewfinder", disabled: session.live) { session.refresh() },
            PaneHeaderAction(title: "实时画面", systemImage: "play.rectangle", help: session.live ? "切回逐帧：做完一个动作等画面稳定再来一帧" : "画面变了就传过来，链路慢时会卡",
                             on: session.live) { session.setLive(!session.live) },
        ]])
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: subtitle), notice: notice, actions: headerActions) {
            ScreenView(session: session, web: web, longPress: $longPress)
                .padding(.horizontal, Metrics.padding)
                .padding(.bottom, Metrics.padding)
        } controls: { typing in
            WebControls(typing: typing.wrappedValue || composing) {
                if composing { compose } else if web { webControls(typing: typing) } else { simulatorControls }
            }
        }
        .task(id: connection) { await session.run(client: client) }
        .onChange(of: linkToOpen, initial: true) {
            guard linkToOpen != nil, let link = area.webLinks[instance.id], link.target.port == status.port else { return }
            area.webLinks[instance.id] = nil
            act(["type": "navigate", "path": link.target.path.isEmpty ? "/" : link.target.path])
        }
    }

    private func webControls(typing: FocusState<Bool>.Binding) -> some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup {
                ActionButton("后退", icon: "chevron.left") { act(["type": "back"]) }
                ActionButton("前进", icon: "chevron.right") { act(["type": "forward"]) }
                ActionButton("首页", icon: "house") { act(["type": "navigate", "path": "/"]) }
            }
            PaneHeaderButtonGroup(expands: true) {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
                    .padding(.leading, Metrics.paneHeaderButtonGap / 2)
                    .accessibilityHidden(true)
                PreviewTargetMenu(instance: instance, status: status) { actionError = $0 }
                if status.port != nil {
                    WebPathField(path: LocalPort.displayPath(of: session.url), typing: typing) { act(["type": "navigate", "path": $0]) }
                        .padding(.leading, -Metrics.paneHeaderButtonGap / 2)
                }
            }
            PaneHeaderButtonGroup {
                ActionButton("重新加载", icon: "arrow.clockwise") { act(["type": "reload"]) }
                ActionButton("输入文字", icon: "keyboard") { startComposing() }
            }
        }
    }

    private var simulatorControls: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup {
                ActionButton("主屏幕", icon: "house") { act(["type": "home"]) }
                ActionButton(longPress ? "长按（下一次点按）" : "长按", icon: longPress ? "hand.point.up.left.fill" : "hand.point.up.left") { longPress.toggle() }
                Menu {
                    Button("放大") { pinch(2) }
                    Button("缩小") { pinch(0.5) }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: Metrics.paneHeaderButton, height: Metrics.paneHeaderButton) }
                    .menuIndicator(.hidden)
                    .help("在画面中央捏合")
            }
            Spacer(minLength: 0)
            PaneHeaderButtonGroup {
                ActionButton("输入文字", icon: "keyboard") { startComposing() }
            }
        }
    }

    /// 输入文字：回车把这段文字打进去（不带回车），「回车」键单独发。
    private var compose: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup(expands: true) {
                TextField("输入文字", text: $text, prompt: Text("要打进去的文字"))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.paneHeaderButton)
                    .padding(.leading, Metrics.paneHeaderButtonGap)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($textFocused)
                    .onSubmit(sendText)
            }
            PaneHeaderButtonGroup {
                ActionButton("回车", icon: "return") {
                    sendText()
                    act(["type": "key", "key": "Enter"])
                }
                ActionButton("删除", icon: "delete.left") { act(["type": "key", "key": "Backspace"]) }
                ActionButton("完成", icon: "checkmark") {
                    composing = false
                    textFocused = false
                }
            }
        }
    }

    private func startComposing() {
        composing = true
        textFocused = true
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        act(["type": "type", "text": text])
        text = ""
    }

    private func pinch(_ scale: Double) {
        guard session.frameSize != .zero else { return }
        act(["type": "pinch", "x": session.frameSize.width / 2, "y": session.frameSize.height / 2, "scale": scale])
    }

    private func act(_ action: [String: Any]) {
        actionError = nil
        session.send(action)
    }
}

/// 传过来的画面：按比例放进窗口，点按、拖动换成画面坐标发回去。点按不到 6 点的移动算点按，长按模式下发成长按；
/// 再远是拖动，网页上换成滚动（同触屏上划页面），模拟器上就是滑动。点一下画面后，Mac 和接了键盘的 iPad 的按键直接发过去。
private struct ScreenView: View {
    let session: PreviewSession
    let web: Bool
    @Binding var longPress: Bool
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fit(session.frameSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                if let frame = session.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                }
                if let point = session.point, !session.live, session.frameSize.width > 0 {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Circle().fill(Color.accentColor.opacity(0.25)))
                        .frame(width: 22, height: 22)
                        .offset(x: fitted.minX + point.x / session.frameSize.width * fitted.width - 11,
                                y: fitted.minY + point.y / session.frameSize.height * fitted.height - 11)
                        .allowsHitTesting(false)
                }
                if session.settling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("等画面稳定…").font(Theme.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                focused = true
                guard let start = Self.point(value.startLocation, in: fitted, frame: session.frameSize),
                      let end = Self.point(value.location, in: fitted, frame: session.frameSize) else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 6 {
                    if longPress {
                        longPress = false
                        session.send(["type": "long_press", "x": start.x, "y": start.y])
                    } else {
                        session.send(["type": "click", "x": start.x, "y": start.y])
                    }
                } else if web {
                    session.send(["type": "scroll", "x": start.x, "y": start.y, "dx": start.x - end.x, "dy": start.y - end.y])
                } else {
                    session.send(["type": "drag", "from": ["x": start.x, "y": start.y], "to": ["x": end.x, "y": end.y]])
                }
            })
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                guard let action = Self.action(for: press) else { return .ignored }
                session.send(action)
                return .handled
            }
            .onChange(of: geometry.size, initial: true) { _, size in session.laidOut(size) }
        }
    }

    /// 画面按比例放进窗口、居中。
    private static func fit(_ frame: CGSize, in area: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, area.width > 0, area.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = min(area.width / frame.width, area.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// 窗口里的一点换成画面坐标；落在画面外的不算。
    private static func point(_ location: CGPoint, in fitted: CGRect, frame: CGSize) -> (x: Double, y: Double)? {
        guard frame.width > 0, fitted.contains(location) else { return nil }
        return (Double((location.x - fitted.minX) / fitted.width * frame.width).rounded(), Double((location.y - fitted.minY) / fitted.height * frame.height).rounded())
    }

    /// 一次按键换成动作：功能键与带 ⌘、⌃、⌥ 的组合按键名发，其余字符照打。
    private static func action(for press: KeyPress) -> [String: Any]? {
        let named: [KeyEquivalent: String] = [.return: "Enter", .delete: "Backspace", .deleteForward: "Delete", .escape: "Escape", .tab: "Tab",
                                              .upArrow: "ArrowUp", .downArrow: "ArrowDown", .leftArrow: "ArrowLeft", .rightArrow: "ArrowRight",
                                              .home: "Home", .end: "End", .pageUp: "PageUp", .pageDown: "PageDown"]
        var modifiers: [String] = []
        if press.modifiers.contains(.command) { modifiers.append("Meta") }
        if press.modifiers.contains(.control) { modifiers.append("Control") }
        if press.modifiers.contains(.option) { modifiers.append("Alt") }
        if let name = named[press.key] {
            return ["type": "key", "key": (modifiers + (press.modifiers.contains(.shift) ? ["Shift"] : []) + [name]).joined(separator: "+")]
        }
        guard !press.characters.isEmpty else { return nil }
        if !modifiers.isEmpty { return ["type": "key", "key": (modifiers + [press.characters.lowercased()]).joined(separator: "+")] }
        return ["type": "type", "text": press.characters]
    }
}

/// 宽屏卡片里的网页控制区：指针在卡片上、或正在地址栏里打字时才有，同窗口按钮（见 PaneHeaderControls）；触屏一直有。
/// 藏起来时控制区是空的，不接点击，后面的页面照常可点（见 PaneControlsBar）。不在卡片里（紧凑布局）时一直有。
/// 悬停只在这一层读，窗口不跟着重算。
private struct WebControls<Content: View>: View {
    let typing: Bool
    @ViewBuilder let content: Content
    @Environment(\.paneHeaderControlsSpace) private var card

    var body: some View {
        if typing || card.map({ InputMode.current.revealsControls(hovered: $0.hovered) }) ?? true {
            content
        }
    }
}

/// 地址栏里的路径：平时跟着页面显示当前路径，打字时不被页面的跳转改掉；回车打开，没打开就离开（Mac 上按 Esc 也是）回到当前路径。
/// reset 变了（清除输入）也回到当前路径，接着打字。
private struct WebPathField: View {
    let path: String
    let typing: FocusState<Bool>.Binding
    var reset = 0
    let open: (String) -> Void
    @State private var text = ""
    /// 刚按回车打开：留着输入的路径等页面跳过去，不先退回旧路径。
    @State private var submitted = false

    var body: some View {
        TextField("网页路径", text: $text, prompt: Text("/"))
            .textFieldStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.paneHeaderButton)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .focused(typing)
            .onSubmit {
                submitted = true
                open(text)
                typing.wrappedValue = false
            }
            #if os(macOS)
            .onExitCommand { typing.wrappedValue = false }
            #endif
            .onChange(of: path, initial: true) {
                if !typing.wrappedValue { text = path }
            }
            .onChange(of: reset) { text = path }
            .onChange(of: typing.wrappedValue) { _, editing in
                if editing { submitted = false } else if !submitted { text = path }
            }
    }
}
