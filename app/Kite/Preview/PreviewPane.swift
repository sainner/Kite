import SwiftUI

/// 预览窗口（docs/成果查看与位置.md「预览」）：一个实例是一种目标跑起来的全部进程加画面。视图三个：画面、并排（只有网页画面有）与输出（进程的终端画面）。
/// 画面的种类由进程产生什么决定（PreviewStatus.screen）：网页默认在设备自己的网页视图里看（DeviceWebPreview），也可以换到工作机上的浏览器；
/// 工作机上的浏览器、模拟器和 App 窗口都是传过来的画面（ScreenPreview），人和 agent 操作同一个页面、同一块屏幕；还没有画面时画面视图就是输出。
/// 在哪看各设备共用，改的是实例状态（AppModel.selectPreview）。网页画面的画面视图可以打开指认（PreviewPointing.swift）。
struct PreviewPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    /// 窗口当前视图的渲染方式（定义里声明的）：terminal 是输出，preview-grid 是并排，其余是画面。
    let renderer: String?
    @Environment(WorkArea.self) private var area

    var body: some View {
        let status = area.previewStatus(of: instance) ?? PreviewStatus()
        switch renderer {
        case "terminal":
            TerminalPane(instance: instance, client: client, connection: connection, preview: true)
        case "preview-grid":
            GridPreview(instance: instance, client: client, connection: connection, status: status)
        default:
            switch status.screen {
            case .none: TerminalPane(instance: instance, client: client, connection: connection, preview: true)
            case .web where status.choice == .device: DeviceWebPreview(instance: instance, client: client, status: status)
            default: ScreenPreview(instance: instance, client: client, connection: connection, status: status)
            }
        }
    }
}

extension WorkArea {
    /// 预览窗口标题栏右边的进程动作：在跑时停止，结束了重新起。
    @MainActor func previewActions(_ instance: RemotePluginInstance, model: AppModel, report: @escaping (String?) -> Void) -> [PaneHeaderAction] {
        guard previewStatus(of: instance) != nil else { return [] }
        if instance.state?.terminal?.running == true {
            return [PaneHeaderAction(title: "停止预览", systemImage: "stop.fill", tint: Theme.danger) {
                self.stop(instance, model: model, report: report)
            }]
        }
        return [PaneHeaderAction(title: "重新运行", systemImage: "arrow.clockwise", help: "在这个窗口里重新起这个目标") { model.restartPreview(instance, in: self) }]
    }

    /// 预览的副标题：画面种类与进程状态。
    func previewSubtitle(_ instance: RemotePluginInstance, status: PreviewStatus) -> String {
        if let process = instance.state?.terminal, !process.running { return process.summary }
        return switch status.screen {
        case .web: [status.port.map { "localhost:\($0)" }, status.choice.title].compactMap { $0 }.joined(separator: " · ")
        case .simulator: "模拟器"
        case .app: status.app.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "App 窗口"
        case .none: "输出"
        }
    }
}

/// 网页在哪看：设备自己的网页视图或工作机上的浏览器；按钮上是主端口。
private struct PreviewBrowserMenu: View {
    let instance: RemotePluginInstance
    let status: PreviewStatus
    let report: (String?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        Menu {
            Section("在哪看") {
                ForEach(PreviewBrowser.allCases) { choice in
                    Button { select(choice) } label: {
                        let title = choice == .device ? "本设备的网页视图" : "工作机上的 \(choice.title)"
                        if choice == status.choice { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: { PaneHeaderButtonLabel(status.port.map(String.init) ?? "网页") }
            .foregroundStyle(Color.primary)
            .help("选在哪看")
    }

    private func select(_ browser: PreviewBrowser) {
        report(nil)
        Task {
            do { try await model.selectPreview(instance.id, browser: browser, in: area) }
            catch { report(error.localizedDescription) }
        }
    }
}

// MARK: - 设备自己的网页视图

/// 在设备自己的网页视图里看预览的网页画面。经端口转发打开（PortPreview），页面里的跳转、滚动与登录状态按设备各自保存（store 按实例分开）。
/// 控制区见 WebPageControls，地址栏是站点图标、localhost:、在哪看的菜单（按钮上是主端口）、路径。路径跟着页面显示，改了回车打开；
/// 都在同一个页面里跳转（WebBrowser），前进后退接得上。主端口没在监听时只有菜单。
private struct DeviceWebPreview: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let status: PreviewStatus
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.narrowPane) private var narrow
    @State private var browser: WebBrowser
    /// 指认在设备上的页面里问元素、截当时的视图。
    @State private var pointer: PreviewPointer
    @State private var webFailure: String?
    @State private var selectError: String?
    @State private var reload = UUID()
    /// 清除输入：每点一次，地址栏的路径回到打字前的样子。
    @State private var pathReset = 0

    init(instance: RemotePluginInstance, client: KitedClient, status: PreviewStatus) {
        self.instance = instance
        self.client = client
        self.status = status
        let browser = WebBrowser()
        _browser = State(initialValue: browser)
        _pointer = State(initialValue: PreviewPointer(locate: { await browser.element(at: $0) }, snapshot: { await browser.snapshot(size: $0) }))
    }

    private var port: Int? { area.livePort(status.port) }
    private var notice: PaneNotice? {
        if let error = selectError ?? (port == nil ? nil : webFailure) { return .failure(error) }
        if let pointing = pointer.notice { return pointing }
        guard port == nil, let selected = status.port else { return nil }
        return .info("localhost:\(selected) 现在没有在监听，服务起来后接着显示", symbol: "pause.circle")
    }
    private var headerActions: PaneHeaderActions {
        let actions = area.previewActions(instance, model: model) { selectError = $0 }
        return actions.isEmpty ? PaneHeaderActions() : PaneHeaderActions(groups: [actions])
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: area.previewSubtitle(instance, status: status)), notice: notice, actions: headerActions) {
            if let port, let store = UUID(uuidString: instance.id) {
                PortPreview(client: client, port: port, store: store, link: area.webLink(for: instance.id, port: port), browser: browser,
                            report: { webFailure = $0 })
                    .id("\(port) \(reload)")
                    .overlay { if pointer.active { PointingLayer(pointer: pointer) } }
            } else {
                // 正文不能是空的：PaneWindow 的标题栏和控制区挂在正文上，正文为空时一起不见（没选端口时整张卡片空白）
                Color.clear
            }
        } controls: { typing in
            WebControls(typing: typing.wrappedValue) {
                if let port {
                    WebPageControls(browser: browser) {
                        address(port: port, typing: typing)
                    } trailing: {
                        pointer.button(area: area, client: client, preview: instance.title)
                    }
                } else {
                    HStack(spacing: Metrics.paneButtonGap) {
                        Spacer(minLength: 0)
                        address(port: nil, typing: typing)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .onChange(of: port) {
            webFailure = nil
            area.portChanged(instance.id, to: port)
        }
    }

    /// 地址栏：站点图标、localhost:、菜单、路径，端口和路径之间不留空，最右边是网页操作的菜单（WebPageMenu）。还没打开端口时只有端口菜单。
    /// 窄排时宽度不够，省掉 localhost:。
    private func address(port: Int?, typing: FocusState<Bool>.Binding) -> some View {
        PaneHeaderButtonGroup(expands: port != nil) {
            HStack(spacing: Metrics.paneHeaderLogoGap) {
                WebSiteIcon(icon: port == nil ? nil : browser.icon)
                if !narrow {
                    Text("localhost:")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Metrics.paneHeaderButtonGap / 2)
            PreviewBrowserMenu(instance: instance, status: status) { selectError = $0 }
            if let port {
                WebPathField(path: LocalPort.displayPath(of: browser.url), typing: typing, reset: pathReset) { open($0, on: port) }
                    // 路径框压住端口按钮右边那半个按钮间距，端口的悬停高亮仍按整个按钮画
                    .padding(.leading, -Metrics.paneHeaderButtonGap / 2)
                WebPageMenu(browser: browser, typing: typing.wrappedValue, home: { open("/", on: port) },
                            reload: reloadPage, clear: { pathReset += 1 })
            }
        }
    }

    /// 重新加载；还没打开成功过的重建网页视图。
    private func reloadPage() {
        webFailure = nil
        if !browser.reload() { reload = UUID() }
    }

    /// 地址栏里输入的路径、首页，和消息里点的链接一样在页面里打开到它（见 WorkArea.webLinks）。
    private func open(_ path: String, on port: Int) {
        guard let target = LocalPort(path: path, port: port) else { return }
        webFailure = nil
        area.webLinks[instance.id] = WebLink(target: target)
    }
}

// MARK: - 工作机上的画面

/// 工作机上的浏览器页面、模拟器屏幕或 App 窗口，画面经 PreviewSession 传过来。工作机本机默认实时，其他设备默认逐帧：做一个动作，等画面稳定后来一帧，
/// 等的期间画面上显示等待中、再点会被丢掉；刚点的位置在画面上标出来。想看动画切实时画面。拖动、滑动在松手时作为一个动作发出；
/// 长按、捏合（模拟器）和右键（App 窗口）另给按钮。网页的视口跟着最近操作的那台设备的窗口；模拟器屏幕和 App 窗口的尺寸由它们自己定，按比例放进窗口。
/// 打字：Mac 和接了键盘的 iPad 点一下画面就能直接打；输入法和触屏键盘用控制区的「输入文字」。
/// 在另一台 Mac 上看 App 窗口时，可以把这个 App 装到这台 Mac 上直接用（AppModel.openAppHere）。
private struct ScreenPreview: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    let status: PreviewStatus
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var session: PreviewSession
    /// 指认经画面接入问工作机元素在哪，截图用打开时停住的那一帧。
    @State private var pointer: PreviewPointer
    @State private var actionError: String?
    /// 下一次点按发成长按（模拟器）或右键（App 窗口）。
    @State private var longPress = false
    @State private var composing = false
    @State private var text = ""
    @State private var openingHere = false
    /// 清除输入：每点一次，地址栏的路径回到打字前的样子。
    @State private var pathReset = 0
    @FocusState private var textFocused: Bool

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, status: PreviewStatus) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.status = status
        // 看的设备就是工作机时链路不成问题，默认实时；其他设备默认逐帧，想看动画再切
        let session = PreviewSession(instanceID: instance.id, live: client.isLocal)
        _session = State(initialValue: session)
        _pointer = State(initialValue: PreviewPointer(locate: { await session.element(at: $0) }, snapshot: { _ in session.frame }, hold: { session.hold($0) }))
    }

    private var notice: PaneNotice? {
        if let actionError { return .failure(actionError) }
        if let pointing = pointer.notice { return pointing }
        if case .failed(let message) = session.link { return .failure(message) }
        if let error = session.error { return .failure(error) }
        if session.dropped { return .info("画面还在变，刚才的操作没有发出", symbol: "hand.raised") }
        switch session.link {
        case .waiting, .connecting: return .info("正在连接…", symbol: "hourglass")
        case .connected, .failed: break
        }
        switch session.phase {
        case "waiting": return .info("进程还没产生画面", symbol: "hourglass")
        case "starting":
            let message = switch status.screen {
            case .web: status.choice == .safari ? "正在打开工作机上的 Safari…" : "正在打开\(status.choice.title)，第一次用要先下载，需要几分钟…"
            case .simulator: "正在连上模拟器，第一次要开机，半分钟到一分钟…"
            case .app: "正在打开 App 的窗口…"
            case .none: "正在打开…"
            }
            return .info(message, symbol: "hourglass")
        default: return nil
        }
    }

    /// 消息里点的链接（见 AppModel.openLocalPort）：连上工作机后在页面里打开到它的路径；窗口刚开、还没连上时等连上。
    private var linkToOpen: UUID? { session.link == .connected ? area.webLinks[instance.id]?.id : nil }

    /// 实时画面开关与进程的停止、重新运行放在标题栏右边。
    private var headerActions: PaneHeaderActions {
        PaneHeaderActions(groups: [[
            PaneHeaderAction(title: "刷新画面", systemImage: "camera.viewfinder", disabled: session.live) { session.refresh() },
            PaneHeaderAction(title: "实时画面", systemImage: "play.rectangle", help: session.live ? "切回逐帧：做完一个动作等画面稳定再来一帧" : "画面变了就传过来，链路慢时会卡",
                             on: session.live) { session.setLive(!session.live) },
        ], area.previewActions(instance, model: model) { actionError = $0 }].filter { !$0.isEmpty })
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: area.previewSubtitle(instance, status: status)), notice: notice, actions: headerActions) {
            ScreenView(session: session, screen: status.screen, longPress: $longPress, acceptsInput: !pointer.active)
                .overlay { if pointer.active { PointingLayer(pointer: pointer, pictureSize: session.frameSize) } }
                .padding(.horizontal, Metrics.padding)
                .padding(.bottom, Metrics.padding)
        } controls: { typing in
            WebControls(typing: typing.wrappedValue || composing) {
                if composing { compose } else {
                    switch status.screen {
                    case .web: webControls(typing: typing)
                    case .simulator: simulatorControls
                    case .app, .none: appControls
                    }
                }
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
            }
            PaneHeaderButtonGroup(expands: true) {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
                    .padding(.leading, Metrics.paneHeaderButtonGap / 2)
                    .accessibilityHidden(true)
                PreviewBrowserMenu(instance: instance, status: status) { actionError = $0 }
                WebPathField(path: LocalPort.displayPath(of: session.url), typing: typing, reset: pathReset) { act(["type": "navigate", "path": $0]) }
                    .padding(.leading, -Metrics.paneHeaderButtonGap / 2)
                WebPageMenu(browser: nil, typing: typing.wrappedValue, home: { act(["type": "navigate", "path": "/"]) },
                            reload: { act(["type": "reload"]) }, clear: { pathReset += 1 })
            }
            PaneHeaderButtonGroup {
                ActionButton("输入文字", icon: "keyboard") { startComposing() }
            }
            pointer.button(area: area, client: client, preview: instance.title)
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

    private var appControls: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup {
                ActionButton(longPress ? "右键（下一次点按）" : "右键", icon: longPress ? "contextualmenu.and.cursorarrow" : "cursorarrow.click.2") { longPress.toggle() }
            }
            Spacer(minLength: 0)
            PaneHeaderButtonGroup {
                #if os(macOS)
                // 看的就是工作机时 App 本来就在这台 Mac 上；直接跑的可执行文件（不是 .app）传不过来
                if !client.isLocal, status.app?.hasSuffix(".app") == true {
                    ActionButton(openingHere ? "正在装到这台 Mac…" : "在这台 Mac 上打开", icon: "arrow.down.app") { openHere() }
                        .disabled(openingHere)
                }
                #endif
                ActionButton("输入文字", icon: "keyboard") { startComposing() }
            }
        }
    }

    #if os(macOS)
    private func openHere() {
        actionError = nil
        openingHere = true
        Task {
            do { try await model.openAppHere(instance.id, in: area) }
            catch { actionError = error.localizedDescription }
            openingHere = false
        }
    }
    #endif

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

// MARK: - 并排

/// 并排视图：同一个预览的网页在工作机上几种浏览器、几种尺寸同时看，每格一个 {浏览器, 视口尺寸} 的页面，按比例放进格子。
/// 哪几格由各设备自己定，记在本机（PreviewGrid.cells），不共享；agent 的 preview_action 带同样的浏览器与尺寸时，操作的就是那一格的页面。
private struct GridPreview: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    let status: PreviewStatus
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var cells = PreviewGrid.cells
    @State private var actionError: String?

    private var notice: PaneNotice? {
        if let actionError { return .failure(actionError) }
        if status.screen != .web { return .info("只有网页画面能并排：这个预览现在没有能打开的网页端口", symbol: "square.grid.2x2") }
        if cells.isEmpty { return .info("用右上角的「添加一格」选浏览器和尺寸", symbol: "plus") }
        return nil
    }

    private var headerActions: PaneHeaderActions {
        PaneHeaderActions(groups: [area.previewActions(instance, model: model) { actionError = $0 }]
            .filter { !$0.isEmpty })
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: area.previewSubtitle(instance, status: status)), notice: notice, actions: headerActions) {
            if status.screen == .web {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.padding) {
                        ForEach(cells) { cell in
                            GridCell(instance: instance, client: client, connection: connection, cell: cell) { remove(cell) }
                        }
                    }
                    .padding(.horizontal, Metrics.padding)
                    .padding(.bottom, Metrics.padding)
                }
            } else {
                Color.clear
            }
        } controls: { _ in
            HStack(spacing: Metrics.paneButtonGap) {
                Spacer(minLength: 0)
                PaneHeaderButtonGroup {
                    Menu {
                        ForEach(PreviewBrowser.allCases.filter { $0 != .device }) { browser in
                            Section(browser.title) {
                                ForEach(PreviewGrid.sizes, id: \.title) { size in
                                    Button("\(size.title) \(size.width)×\(size.height)") { add(PreviewCell(browser: browser, width: size.width, height: size.height)) }
                                }
                            }
                        }
                    } label: { PaneHeaderButtonLabel("添加一格") }
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    private func add(_ cell: PreviewCell) {
        guard !cells.contains(cell) else { return }
        cells.append(cell)
        PreviewGrid.cells = cells
    }

    private func remove(_ cell: PreviewCell) {
        cells.removeAll { $0 == cell }
        PreviewGrid.cells = cells
    }
}

/// 并排的格子记在本机，所有预览共用一套；没记过时是 WebKit 的手机与 Chromium 的桌面两格。
enum PreviewGrid {
    static let sizes: [(title: String, width: Int, height: Int)] = [("手机", 390, 844), ("平板", 820, 1180), ("桌面", 1280, 800)]
    private static let key = "KitePreviewGridCells"
    static var cells: [PreviewCell] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key), let cells = try? JSONDecoder().decode([PreviewCell].self, from: data) else {
                let phone = sizes[0], desktop = sizes[2]
                return [PreviewCell(browser: .webkit, width: phone.width, height: phone.height), PreviewCell(browser: .chromium, width: desktop.width, height: desktop.height)]
            }
            return cells
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// 并排的一格：上面一行是浏览器与尺寸、移除，下面是这一格的画面，逐帧操作。
private struct GridCell: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    let cell: PreviewCell
    let remove: () -> Void
    @State private var session: PreviewSession
    @State private var longPress = false

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, cell: PreviewCell, remove: @escaping () -> Void) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.cell = cell
        self.remove = remove
        _session = State(initialValue: PreviewSession(instanceID: instance.id, live: false, cell: cell))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(cell.browser.title) \(cell.width)×\(cell.height)").font(Theme.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let error = session.error { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger).help(error) }
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.pointingPlain)
                    .font(Theme.caption)
                    .help("移除这一格")
            }
            ScreenView(session: session, screen: .web, longPress: $longPress)
                .aspectRatio(CGFloat(cell.width) / CGFloat(cell.height), contentMode: .fit)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: connection) { await session.run(client: client) }
    }
}

/// 传过来的画面：按比例放进窗口，点按、拖动换成画面坐标发回去。点按不到 6 点的移动算点按，按钮选了时模拟器上发成长按、App 窗口上发成右键；
/// 再远是拖动，网页和 App 窗口上换成滚动（同触屏上划页面），模拟器上就是滑动。点一下画面后，Mac 和接了键盘的 iPad 的按键直接发过去。
private struct ScreenView: View {
    let session: PreviewSession
    let screen: PreviewScreen
    @Binding var longPress: Bool
    /// 为假时按键不发给工作机：指认开着时（点按由盖在上面的 PointingLayer 接走）。
    var acceptsInput = true
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let fitted = ScreenGeometry.fit(session.frameSize, in: geometry.size)
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
                guard let start = ScreenGeometry.point(value.startLocation, in: fitted, frame: session.frameSize),
                      let end = ScreenGeometry.point(value.location, in: fitted, frame: session.frameSize) else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 6 {
                    if longPress {
                        longPress = false
                        if screen == .app { session.send(["type": "click", "x": start.x, "y": start.y, "button": "right"]) }
                        else { session.send(["type": "long_press", "x": start.x, "y": start.y]) }
                    } else {
                        session.send(["type": "click", "x": start.x, "y": start.y])
                    }
                } else if screen == .simulator {
                    session.send(["type": "drag", "from": ["x": start.x, "y": start.y], "to": ["x": end.x, "y": end.y]])
                } else {
                    session.send(["type": "scroll", "x": start.x, "y": start.y, "dx": start.x - end.x, "dy": start.y - end.y])
                }
            })
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                guard acceptsInput, let action = Self.action(for: press) else { return .ignored }
                session.send(action)
                return .handled
            }
            .onChange(of: geometry.size, initial: true) { _, size in session.laidOut(size) }
        }
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

/// 传过来的画面在窗口里的摆法：按比例放进、居中，窗口里的一点换成画面坐标。ScreenView 与指认的 PointingLayer 共用。
enum ScreenGeometry {
    /// 画面按比例放进窗口、居中。
    static func fit(_ frame: CGSize, in area: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, area.width > 0, area.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = min(area.width / frame.width, area.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// 窗口里的一点换成画面坐标；落在画面外的不算。
    static func point(_ location: CGPoint, in fitted: CGRect, frame: CGSize) -> (x: Double, y: Double)? {
        guard frame.width > 0, fitted.contains(location) else { return nil }
        return (Double((location.x - fitted.minX) / fitted.width * frame.width).rounded(), Double((location.y - fitted.minY) / fitted.height * frame.height).rounded())
    }
}
