import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

/// 浏览窗口（docs/成果查看与位置.md「浏览」）：工作区的文件（目录、原文、渲染与历史差异），本工作区运行中的网页和互联网共用一个窗口。
/// 看什么各设备共用（FileBrowser.selection）；行号定位、网页里点到哪仅属于当前设备。侧栏上面是本工作区监听的端口，下面是文件目录，
/// 从右边划进划出：宽排时是右边一列，和内容并排，有没有选东西都一样；窄排时铺满窗口、盖住内容。开关在标题栏右边，侧栏打开时伸成搜索框，
/// 按名字搜本工作区的网页和整个工作区的文件。并排时控制区的按钮在右边让出侧栏那一列。
/// 控制区左边翻页（网页是后退、前进），中间是路径或地址，右边在文件里找；文件的路径点开是它的时间线（工作区快照里的历史版本，从旧到新），能换看哪一版。
/// 能渲染的文件在标题栏里切换原文和预览。
/// 网页在设备自己的网页视图里看，地址栏里能输网址、端口号或 localhost:端口；
/// 网站数据按工作区分开，同一工作区的浏览窗口共用登录状态。
struct FilePane: View {
    let browser: FileBrowser
    @Environment(WorkArea.self) private var area
    @Environment(\.narrowPane) private var narrow
    @State private var web = WebBrowser()
    @State private var reload = UUID()
    /// 清除输入：每点一次，地址栏回到打字前的样子。
    @State private var addressReset = 0
    /// 看着文件时点了「打开网址」：控制区换成地址栏，打开了或离开地址栏就换回来。
    @State private var addressing = false
    /// 侧栏搜索框里的字，侧栏收起时清掉。
    @State private var directoryQuery = ""
    /// 在文件里找。
    @State private var searching = false
    @State private var query = ""
    /// 当前是第几个匹配。
    @State private var matchIndex = 0
    /// 确认放弃原文编辑器里没保存的改动。
    @State private var confirmDiscard = false
    /// Markdown 预览报上来的每个匹配在第几块，见 MarkdownMatches。
    @State private var markdownMatches: [Int] = []
    /// PDF 里找到几个。
    @State private var pdfMatches = 0
    /// 交给 PDF 预览的关键字：PDFKit 同步搜整份文档，等输入停下再给。
    @State private var pdfQuery: String?
    /// 控制区的翻页那组开着：按读完时的样子，读着的时候不跟着变。原文先按页读一次、接着整篇读进编辑器，
    /// 跟着变的话翻页那组先分出来又并回去。
    @State private var paged = false
    @Namespace private var barGlass

    private var header: PaneHeader {
        // 网页的主标题是 localhost:端口或网站；文件的是当前文件的名字，还没选时是工作区文件夹的名字
        if browser.displayingWeb { return PaneHeader(title: pageName, subtitle: "网页") }
        return PaneHeader(title: browser.selection.path.map { ($0 as NSString).lastPathComponent } ?? rootName,
                          subtitle: showingDiff ? "历史差异" : browser.selection.version != nil ? versionSubtitle : "文件")
    }

    /// 信息区：网页是站点图标，文件是文件类型图标，还没选时是文件夹；占圆环的位置，提示出现时同圆环一样虚化盖住。说明是完整的路径或网址。
    /// 换内容时同标题一起换：文件类型图标之间按系统的图标替换，文件和网页之间、换了网站或读到站点图标时模糊替换。
    private var kindIcon: some View {
        let symbol = browser.selection.path == nil ? "folder" : browser.format.symbol
        let site = "\(pageName) \(web.icon != nil)"
        return Group {
            if browser.displayingWeb {
                WebSiteIcon(icon: web.icon)
                    .id(site)
            } else {
                Image(systemName: symbol)
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .transition(.blurReplace)
        .animation(.snappy, value: browser.displayingWeb ? site : symbol)
        .paneHeaderRing(lineWidth: 0, status: browser.displayingWeb ? address : browser.selection.path ?? rootName)
    }

    /// 看历史版本时的副标题：哪个时候的版本。
    private var versionSubtitle: String {
        guard let version = browser.history?.versions.first(where: { $0.commit == browser.selection.version }) else { return "历史版本" }
        return "\(Self.time(version.date)) 的版本"
    }

    private var pageName: String {
        switch browser.selection.page {
        case .port(let port): "localhost:\(port)"
        case .url(let url): url.host() ?? url.absoluteString
        case nil: rootName
        }
    }

    /// 宽排时目录是右边一列，和内容并排；窄排时铺满窗口，盖住内容。
    private var sideBySide: Bool { !narrow }

    /// 网页看得见：选了网页，目录没盖着它。
    private var webVisible: Bool { browser.displayingWeb && (!browser.showDirectory || sideBySide) }

    private var livePort: Int? { area.livePort(browser.selection.port) }

    private var showingDiff: Bool { browser.displayingFile && browser.selection.diffId != nil }

    /// 文件看得见：选了文件，目录没盖着它。控制区只在这时给文件的操作。
    private var fileVisible: Bool { browser.displayingFile && (!browser.showDirectory || sideBySide) }

    private var directoryTerm: String { directoryQuery.trimmingCharacters(in: .whitespaces) }

    private var rootName: String {
        let cwd = (area.remote.workspace.cwd as NSString).lastPathComponent
        return cwd.isEmpty ? "工作区" : cwd
    }

    /// 窗口现在的情况，正文只放目录和文件内容：正在搜索、正在读取、目录或文件是空的、还没选文件。
    private var status: PaneNotice? {
        if browser.showDirectory, !directoryTerm.isEmpty {
            if browser.searchingFiles { return .info("正在搜索…", symbol: "magnifyingglass") }
            if let results = browser.searchResults {
                if results.entries.isEmpty && matchedPorts.isEmpty { return .info("没有名字含「\(results.query)」的文件或网页", symbol: "magnifyingglass") }
                if results.truncated { return .info("只列出最相近的 \(results.entries.count) 个", symbol: "magnifyingglass") }
            }
        }
        if browser.displayingFile {
            if browser.download != nil { return .info("正在下载文件…", symbol: "arrow.down.circle") }
            if browser.loadingText { return .info("正在读取文件…", symbol: "hourglass") }
            return browser.diff != nil && browser.diffRows.isEmpty ? .info("文件内容为空") : nil
        }
        if let port = browser.selection.port, livePort == nil, webVisible {
            return .info("localhost:\(port) 现在没有终端或预览在监听，服务起来后接着显示", symbol: "pause.circle")
        }
        if browser.loadingDirectory { return .info("正在读取目录…", symbol: "hourglass") }
        if browser.showDirectory, browser.root?.entries.isEmpty == true { return .info("工作区是空的") }
        // 目录铺满时用不着提示；并排时左边空着，照样提示
        if browser.showDirectory && !sideBySide { return nil }
        return browser.selection.path == nil && !browser.displayingWeb ? .info("选择文件或网页，或点击消息中的引用") : nil
    }

    /// 信息区：失败优先，其次是窗口现在的情况（见 status），再是指定行定位不到这类关于文件的说明。
    private var notice: PaneNotice? {
        let contentError = browser.displayingFile ? browser.saveError ?? browser.textError ?? browser.pageError
            : browser.displayingWeb ? browser.pageError : nil
        if let error = contentError ?? browser.directoryError { return .failure(error) }
        if let status { return status }
        let unversioned = browser.selection.diffId == nil && ((browser.content?.info ?? browser.info)?.unversioned ?? false)
        guard browser.displayingFile, let message = browser.locationMessage
                ?? (browser.format == .other ? nil : browser.infoNote)
                ?? (unversioned ? "超过 10 MiB 的文件不进工作区快照，没有历史版本" : nil) else { return nil }
        return .info(message)
    }

    var body: some View {
        PaneWindow(header: header, notice: notice, status: AnyView(kindIcon), actions: headerActions) {
            ZStack(alignment: .topTrailing) {
                // 文件不参与目录的动画：排布在开关时当场变好，窄排时留在原地让目录盖住，网页、PDF 也不用重新加载
                HStack(spacing: 0) {
                    preview
                    if browser.showDirectory && sideBySide {
                        Color.clear.frame(width: Self.directoryWidth)
                    }
                }
                .accessibilityHidden(browser.showDirectory && !sideBySide)
                .transaction { $0.animation = nil }
                if browser.showDirectory {
                    // 从右边划进划出，和标题栏的侧栏开关同一边
                    directoryColumn
                        .transition(.move(edge: .trailing))
                        // ZStack 里移除的视图划出时会排到下面，文件就画在目录的底色上面了
                        .zIndex(1)
                }
            }
            // 开关、从目录或引用打开文件、打开目录，目录都这样划进划出
            .animation(Self.directoryMotion, value: browser.showDirectory)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } controls: { typing in
            // 目录铺满时控制区空着；并排时按钮在右边让出侧栏那一列
            if !browser.showDirectory || sideBySide {
                Group {
                    if addressing && !webVisible {
                        addressBar(typing: typing)
                    } else {
                        contentBar(typing: typing)
                    }
                }
                // 目录盖住或露出文件时，按钮组跟着换，玻璃按系统的过渡变形
                .animation(.snappy, value: fileVisible)
                .padding(.trailing, browser.showDirectory ? Self.directoryWidth : 0)
            }
        }
        .task(id: browser.connectionRevision) { await browser.list() }
        .task(id: browser.requestKey) { await browser.loadSelection() }
        .task(id: browser.historyKey) { await browser.loadHistory() }
        .task(id: "\(searching) \(String(describing: searchTarget)) \(query) \(browser.selection.revision) \(browser.diff?.id ?? "")") {
            await runFind()
        }
        .task(id: directoryTerm) { await searchDirectory() }
        // 文本的当前匹配不在这一页时，先读到它所在的地方
        .task(id: currentMatch) {
            guard searchTarget == .text, browser.document == nil, let line = currentMatch?.line, let page = browser.page,
                  line < page.offset || line >= page.nextOffset ?? page.totalLines + 1 else { return }
            await browser.read(offset: max(1, line - 50))
        }
        // 文件看不见了（目录盖住、换成网页）或格式不支持查找，搜索框收起来；文件换了看法（原文、预览）接着找
        .onChange(of: searchTarget) { _, new in
            guard searching, new == nil else { return }
            query = ""
            withAnimation { searching = false }
        }
        .onChange(of: browser.showDirectory) { _, shown in if !shown { directoryQuery = "" } }
        .onChange(of: browser.loadingText ? nil : filePage != nil, initial: true) { _, value in if let value { paged = value } }
        .onChange(of: sideBySide, initial: true) { browser.sideBySide = sideBySide }
        .discardAlert("放弃未保存的修改？", isPresented: $confirmDiscard) { Task { await browser.discard() } }
        .alert("文件在你打开以后被改过", isPresented: Bindable(browser).saveConflict) {
            Button("覆盖", role: .destructive) { Task { await browser.save(force: true) } }
            Button("放弃我的修改") { Task { await browser.discard() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("覆盖会盖掉别人的改动；放弃会换成现在的内容。")
        }
        .onChange(of: browser.selection.port) { area.portChanged(browser.instanceID, to: browser.selection.port) }
    }

    // MARK: - 网页

    /// 本工作区的网页经端口转发打开，互联网的直接打开；页面里可以去任何网址，只是进不了工作机服务自己的地址（WebRoaming）。
    /// 互联网网页从开起时的网址开，换网址不重建页面（AddressPreview）。
    @ViewBuilder
    private var webPage: some View {
        if let client = browser.connection, let store = UUID(uuidString: browser.workspaceID) {
            switch browser.selection.page {
            case .port(let port) where port == livePort:
                PortPreview(client: client, port: port, store: store, roaming: client.roaming, link: area.webLink(for: browser.instanceID, port: port),
                            browser: web, report: { browser.pageError = $0 })
                    .id("\(port) \(reload)")
            case .url(let url):
                AddressPreview(url: url, store: store, roaming: client.roaming, browser: web, report: { browser.pageError = $0 })
                    .id(reload)
            default:
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    /// 看着文件时点了「打开网址」：只有地址栏，打开了或离开地址栏就换回文件的控制区。
    private func addressBar(typing: FocusState<Bool>.Binding) -> some View {
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup(expands: true) {
                WebPathField(path: "", typing: typing, reset: addressReset, prompt: "网址或端口号", centered: true, open: go)
            }
            PaneHeaderButtonGroup {
                ActionButton("取消", icon: "xmark") { addressing = false }
            }
        }
        .task { typing.wrappedValue = true }
        .onChange(of: typing.wrappedValue) { _, editing in if !editing { addressing = false } }
    }

    /// 浏览记录：这个窗口里去过的页面从旧到新往下排，同文件的时间线；正在看的打勾，点了跳过去。
    private var webHistory: some View {
        ForEach(web.history) { item in
            Toggle(isOn: Binding {
                web.currentItem == item
            } set: { chosen in
                if chosen { web.go(to: item) }
            }) {
                Text(Self.label(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.address(item.url)))
            }
        }
    }

    /// 地址栏显示的地址。
    private var address: String {
        if let url = web.url { return Self.address(url) }
        if let port = browser.selection.port { return "localhost:\(port)" }
        return browser.selection.url.flatMap(URL.init(string:)).map(Self.address) ?? ""
    }

    /// 本机的写 localhost:端口 加路径，https 省掉前缀。
    private static func address(_ url: URL) -> String {
        if let local = LocalPort(url) {
            let path = LocalPort.displayPath(of: url)
            return "localhost:\(local.port)" + (path == "/" ? "" : path)
        }
        let text = url.absoluteString
        return text.hasPrefix("https://") ? String(text.dropFirst("https://".count)) : text
    }

    /// 地址栏里回车：只写端口号、localhost:端口（可带路径）的是本工作区的网页，/ 开头的是当前网站上的路径，其余没写协议的补上 https://。
    private func go(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        browser.pageError = nil
        if text.hasPrefix("/"), webVisible, let current = web.url, let target = URL(string: text, relativeTo: current)?.absoluteURL {
            web.open(target)
            return
        }
        if let local = Int(text).flatMap({ LocalPort(path: "/", port: $0) }) ?? (LocalPort.bare(text) ?? URL(string: text)).flatMap(LocalPort.init) {
            area.webLinks[browser.instanceID] = WebLink(target: local)
            open(.port(local.port))
            return
        }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host() != nil else {
            browser.pageError = "「\(text)」不是网址"
            return
        }
        if browser.selection.page == .url(url) { web.open(url) } else { open(.url(url)) }
    }

    /// 首页：本工作区的网页回到根路径，互联网的回到打开时的网址。
    private func goHome() {
        switch browser.selection.page {
        case .port(let port): if let target = LocalPort(path: "/", port: port) { area.webLinks[browser.instanceID] = WebLink(target: target) }
        case .url(let url): web.open(url)
        case nil: break
        }
    }

    /// 重新加载当前页面；还没打开成功过的重建网页视图，互联网网页从现在选的网址开起。
    private func reloadPage() {
        browser.pageError = nil
        guard !web.reload() else { return }
        reload = UUID()
    }

    private func open(_ page: BrowsePage) {
        Task { try? await browser.openPage(page) }
    }

    /// 侧栏里本工作区运行中终端与预览监听的一个端口，点了在这个窗口里打开它的网页。
    private func pageRow(_ item: TerminalStatus.Port) -> some View {
        let selected = browser.selection.port == item.port
        return rowButton(selected: selected) { try? await browser.openPage(.port(item.port)) } label: {
            HStack(spacing: 8) {
                Label("localhost:\(item.port)", systemImage: "globe").lineLimit(1)
                Spacer(minLength: 0)
                if !item.http { Text("不是网页").foregroundStyle(.tertiary) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 侧栏划进划出、标题栏里开关伸成搜索框都用它；悬停时的窗口按钮藏到它走完。
    private static let directoryMotion = Animation.paneHeaderActions

    /// 标题栏右边的侧栏开关。打开后伸成的搜索框和关闭按钮占侧栏一列的宽，两边各留窗口边距，同标题栏到窗口边的距离；
    /// 窄排侧栏铺满时也是这么宽，左边留着标题。
    private var directorySearch: some View {
        let open = browser.showDirectory
        return DirectorySearch(open: open, text: $directoryQuery) { shown in
            withAnimation(Self.directoryMotion) { browser.showDirectory = shown }
        }
        .frame(width: open ? Self.directoryWidth - 2 * Metrics.paneMargin : nil)
        // 从目录或引用打开文件时收起侧栏不经这里的按钮，也跟着变形
        .animation(Self.directoryMotion, value: open)
    }

    /// 标题栏右边：能渲染的文件（Markdown、HTML）在原文和预览之间切换，最右边是侧栏开关。
    private var headerActions: PaneHeaderActions {
        var actions = PaneHeaderActions(trailing: AnyView(directorySearch))
        if fileVisible, browser.format.renderable, browser.selection.diffId == nil {
            actions.switcher = PaneViewSwitcher(items: [
                .init(id: "source", title: "原文", systemImage: "chevron.left.forwardslash.chevron.right"),
                .init(id: "preview", title: "预览", systemImage: "eye"),
            ], current: browser.rendered ? "preview" : "source") { [browser] in browser.rendered = $0 == "preview" }
        }
        // 原文改过：放弃修改、保存
        if fileVisible, let document = browser.document, document.editable, document.dirty {
            actions.groups.append([
                PaneHeaderAction(title: "放弃修改", systemImage: "xmark", disabled: browser.saving) { confirmDiscard = true },
                PaneHeaderAction(title: "保存", systemImage: "checkmark", help: "保存（⌘S）", busy: browser.saving) {
                    Task { await browser.save() }
                },
            ])
        }
        return actions
    }

    /// 控制区：文件和网页同一套排法，换着看时几块玻璃原地变形，里面的字和图标换过去。左边翻页（网页是后退、前进），
    /// 中间是路径或地址，右边在文件里找；用不着的那块并进中间（见 GlassRow）。找的时候搜索框占满一行。
    private func contentBar(typing: FocusState<Bool>.Binding) -> some View {
        let showsWeb = webVisible
        let paging = !showsWeb && paged
        let findable = searchTarget != nil
        let finding = searching && findable
        let pagerMerged = !(showsWeb || paging)
        // 并着的那块和中间那块并成同一块玻璃：点中间那块里的菜单时，系统把这块玻璃整个拿去变形成菜单，
        // 不在原地留下并着的那个圆（2026-10-27 iPhone）。分开的那一刻解除，照常从中间那块分出来
        let union: (Bool) -> String? = { $0 ? "info" : nil }
        return GlassRow(spacing: Metrics.paneButtonGap) {
            if !finding {
                pager(web: showsWeb, merge: pagerMerged ? .merged(.trailing) : .open)
                    .glassEffectUnion(id: union(pagerMerged), namespace: barGlass)
                info(web: showsWeb, typing: typing)
                    .glassEffectUnion(id: union(pagerMerged || !findable), namespace: barGlass)
                    .glassRowFills()
            }
            ExpandingSearch(presented: $searching, text: $query, submit: { step(1) }) {
                EmptyView()
            } accessory: {
                searchAccessory
            }
            .glassMerge(findable ? .open : .merged(.leading))
            .glassEffectUnion(id: union(!findable), namespace: barGlass)
            .glassRowFills(finding)
        }
        .containerValue(\.placesKeyboardButton, showsWeb)
        .animation(.snappy, value: showsWeb)
        .animation(.snappy, value: paging)
        .animation(.snappy, value: findable)
        .animation(.snappy, value: browser.selection.path)
    }

    /// 文件能翻页时的这一页：没在原文编辑器里打开、不是差异、不是渲染出来的长文件。
    private var filePage: FilePage? {
        guard fileVisible, browser.document == nil, browser.selection.diffId == nil, !(browser.format.renderable && browser.rendered) else { return nil }
        return browser.page
    }

    /// 控制区左边：文件翻页，网页后退、前进。两边是同样的两个按钮，换着看时这块玻璃不动；网页的在 iPhone 上键盘升起时换成收起键盘。
    /// 并没并着直接标在按钮组上，不隔着 KeyboardSwap：隔着的话 iPhone 上控制区换窗口整块插进来时，按钮组读不到并着，
    /// 按开着的大小画在中间那块的左端，要等下一次环境变化才缩回去（2026-10-27 真机；直接标在按钮组上的搜索关闭按钮一直正常）。
    private func pager(web showsWeb: Bool, merge: GlassMerge) -> some View {
        KeyboardSwap(active: showsWeb) {
            PaneHeaderButtonGroup {
                ActionButton(showsWeb ? "后退" : "上一页", icon: "chevron.left") {
                    if showsWeb { web.back() } else if let page = filePage { Task { await browser.read(offset: max(1, page.offset - 200)) } }
                }
                .disabled(showsWeb ? !web.canGoBack : (filePage?.offset ?? 1) <= 1)
                ActionButton(showsWeb ? "前进" : "下一页", icon: "chevron.right") {
                    if showsWeb { web.forward() } else if let offset = filePage?.nextOffset { Task { await browser.read(offset: offset) } }
                }
                .disabled(showsWeb ? !web.canGoForward : filePage?.nextOffset == nil)
            }
            .glassMerge(merge)
        } shown: {
            KeyboardDismissButton().glassMerge(merge)
        }
    }

    /// 在文件里找时跟在输入框后面：第几个、共几个，上一个、下一个。
    @ViewBuilder
    private var searchAccessory: some View {
        if fileQuery != nil {
            Text(matchCount == 0 ? "无结果" : "\(matchIndex + 1)/\(matchCount)")
                .font(Theme.secondary.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, Metrics.paneHeaderButtonGap / 2)
            ActionButton("上一个", icon: "chevron.up") { step(-1) }.disabled(matchCount == 0)
            ActionButton("下一个", icon: "chevron.down") { step(1) }.disabled(matchCount == 0)
        }
    }

    /// 控制区的搜索框在文件里找：文件看得见、格式支持查找时才有。网页预览、系统预览不支持查找。按名字搜目录在侧栏的搜索框（directorySearch）。
    private enum SearchTarget: Equatable { case text, diff, markdown, pdf }

    private var searchTarget: SearchTarget? {
        guard fileVisible else { return nil }
        if browser.selection.diffId != nil { return .diff }
        switch browser.format {
        case .text: return .text
        case .markdown: return browser.rendered ? .markdown : .text
        case .html: return browser.rendered ? nil : .text
        case .pdf: return .pdf
        case .quickLook, .other: return nil
        }
    }

    /// 在文件里找的关键字；没在找或关键字为空是 nil。
    private var fileQuery: String? {
        guard searching, !query.isEmpty, searchTarget != nil else { return nil }
        return query
    }

    private var matchCount: Int {
        switch searchTarget {
        case .text, .diff: browser.matches.count
        case .markdown: markdownMatches.count
        case .pdf: pdfMatches
        case nil: 0
        }
    }

    /// 文本和差异里当前的匹配。
    private var currentMatch: FileMatch? {
        guard fileQuery != nil, searchTarget == .text || searchTarget == .diff, browser.matches.indices.contains(matchIndex) else { return nil }
        return browser.matches[matchIndex]
    }

    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
    }

    /// 输入停一下再找。文本和差异在模型里找，Markdown 预览和 PDF 由视图自己找、报个数上来。
    private func runFind() async {
        matchIndex = 0
        guard searching, let target = searchTarget else {
            browser.endFind()
            pdfQuery = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        switch target {
        case .text, .diff: await browser.find(query)
        case .pdf: pdfQuery = fileQuery
        case .markdown: break
        }
    }

    /// 侧栏搜索框里输入停一下，按名字搜整个工作区；清空了回到目录树。
    private func searchDirectory() async {
        guard !directoryTerm.isEmpty else {
            browser.endSearch()
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        await browser.search(directoryTerm)
    }

    /// 查找时一行里的匹配标出来。
    private func searched(_ text: String, at line: Int) -> Text {
        guard let query = fileQuery, searchTarget == .text || searchTarget == .diff else { return Text(verbatim: text) }
        let current = currentMatch.flatMap { $0.line == line ? $0.occurrence : nil }
        return Text(SearchHighlight(query: query, current: current).apply(to: text))
    }

    /// 控制区中间：居中的路径或地址，左边是文件的时间线或网页的浏览记录，右边是文件或网页操作的菜单，两边的图标文件和网页相同；
    /// 地址平时是居中的一行字，点了才输入。文件类型图标、站点图标在标题栏的信息区。
    private func info(web showsWeb: Bool, typing: FocusState<Bool>.Binding) -> some View {
        PaneHeaderButtonGroup(expands: true) {
            Menu {
                if showsWeb { webHistory } else { timeline }
            } label: {
                PaneHeaderButtonLabel(showsWeb ? "浏览记录" : "时间线", systemImage: "clock.arrow.circlepath")
            }
            .foregroundStyle(Color.primary)
            .disabled(showsWeb ? web.history.isEmpty : browser.selection.path == nil)
            .help(showsWeb ? "浏览记录" : "时间线")
            Group {
                if showsWeb {
                    WebPathField(path: address, typing: typing, reset: addressReset, prompt: "网址或端口号", centered: true, open: go)
                } else {
                    Text(browser.selection.path ?? rootName)
                        .font(Theme.body)
                        .foregroundStyle(browser.selection.path == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .id(browser.selection.path)
                }
            }
            .transition(.blurReplace)
            // 两边的菜单是同一个图标，当场换
            Group {
                if showsWeb {
                    WebPageMenu(browser: web, typing: typing.wrappedValue, home: goHome, reload: reloadPage, clear: { addressReset += 1 })
                } else {
                    fileMenu
                }
            }
            .transition(.identity)
        }
    }

    /// 时间线：内容变过的工作区快照从旧到新往下排，最下面是现在的内容，点了换看那一版。
    /// 现在的内容和最新那一版一样时合成一行。看着历史差异时点「当前」回到现在的内容。
    @ViewBuilder
    private var timeline: some View {
        let selection = browser.selection
        let history = browser.history
        let current = history?.versions.first { $0.commit == history?.current }
        if history?.truncated == true {
            Text("只列出最近 \(history?.versions.count ?? 0) 个版本")
        } else if let error = browser.historyError {
            Text("读不到历史版本：\(error)")
        } else if history?.versions.isEmpty == true, selection.path != nil {
            Text("还没有历史版本")
        }
        // 工作机给的是新的在前
        ForEach(history?.versions.filter { $0.commit != history?.current }.reversed() ?? []) { version in
            Toggle(isOn: versionBinding(version.commit)) {
                Text("\(Self.time(version.date)) \(Self.label(version.label))")
            }
        }
        Toggle(isOn: versionBinding(nil)) {
            Text(current.map { "当前 · \(Self.time($0.date)) \(Self.label($0.label))" } ?? "当前")
        }
    }

    /// 时间线里的一行选没选中：version 为 nil 是现在的内容。
    private func versionBinding(_ version: String?) -> Binding<Bool> {
        Binding {
            browser.selection.diffId == nil && browser.selection.version == version
        } set: { chosen in
            guard chosen else { return }
            Task { await browser.selectVersion(version) }
        }
    }

    /// 时间线里的时间：今天的只写时刻。
    private static func time(_ date: Date) -> String {
        date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute())
    }

    /// 快照的标签是那一回合的标题，太长的截掉。
    private static func label(_ text: String) -> String {
        text.count > 30 ? text.prefix(30) + "…" : text
    }

    /// 文件操作的菜单：打开网址、刷新，有本机副本时共享，认不出的格式用默认 App 打开或下载。
    private var fileMenu: some View {
        Menu {
            MenuButton("打开网址", systemImage: "globe") { addressing = true }
            MenuButton("刷新", systemImage: "arrow.clockwise", action: refresh)
                .disabled(browser.loadingDirectory || browser.loadingText)
            if fileVisible, let content = browser.content {
                ShareLink(item: content.url) { Label("共享", systemImage: "square.and.arrow.up") }
            }
            #if os(macOS)
            if let url = defaultAppURL {
                MenuButton("用默认 App 打开", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            }
            #endif
            if fileVisible, browser.format == .other, browser.content == nil, !opensOriginal {
                MenuButton("下载", systemImage: "arrow.down.circle") { Task { await browser.fetch() } }
                    .disabled(browser.loadingText)
            }
        } label: {
            PaneHeaderButtonLabel("文件操作", systemImage: "ellipsis")
        }
        .foregroundStyle(Color.primary)
        .help("文件操作")
    }

    /// 认不出的格式用默认 App 打开：能开原文件时开工作区里的，其他时候开下载好的副本。
    private var defaultAppURL: URL? {
        guard fileVisible, browser.format == .other, let path = browser.selection.path else { return nil }
        if opensOriginal { return URL(filePath: area.remote.workspace.cwd).appending(path: path) }
        return browser.content?.url
    }

    /// 能直接开工作区里的原文件：工作机就是本机、看的是现在的内容。不能时要先下载。
    private var opensOriginal: Bool { browser.isLocal && browser.selection.version == nil }

    /// 目录和文件看得见哪个就刷新哪个。
    private func refresh() {
        if browser.showDirectory || !browser.displayingFile { Task { await browser.list() } }
        if fileVisible {
            Task { await browser.loadSelection() }
            Task { await browser.loadHistory() }
        }
    }

    private static let directoryWidth: CGFloat = 210

    /// 并排时目录是右边一列，底色是很淡的灰，从窗口顶边铺到底边，标题栏、控制区浮在上面；铺满时是窗口的底色。
    /// 两种都是列表从标题栏、控制区后面滚过去。
    private var directoryColumn: some View {
        directory
            .frame(width: sideBySide ? Self.directoryWidth : nil)
            // 用直角矩形铺底：直接给颜色时，Mac 上侧栏铺到窗口底边的左下角是圆角
            .background { Rectangle().fill(sideBySide ? Theme.panel : Theme.card).ignoresSafeArea() }
    }

    private static let treeIndent: CGFloat = 16

    /// 侧栏搜索框里的字搜到的网页：名字（localhost:端口）里含这些字的，不分大小写。
    private var matchedPorts: [TerminalStatus.Port] {
        guard !directoryTerm.isEmpty else { return [] }
        return area.workspacePortStatus.filter { "localhost:\($0.port)".localizedCaseInsensitiveContains(directoryTerm) }
    }

    /// 从工作区根目录起的折叠列表：点目录展开、收起，点文件打开。侧栏搜索框里有字时换成搜到的网页和文件。
    private var directory: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if !directoryTerm.isEmpty, browser.searchResults != nil || !matchedPorts.isEmpty {
                        let entries = browser.searchResults?.entries ?? []
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(matchedPorts, id: \.port) { pageRow($0) }
                            if !matchedPorts.isEmpty && !entries.isEmpty { Divider().padding(.vertical, 4) }
                            ForEach(entries) { resultRow($0) }
                        }
                    } else {
                        let rows = browser.treeRows
                        let ports = area.workspacePortStatus
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ports, id: \.port) { pageRow($0) }
                            if !ports.isEmpty { Divider().padding(.vertical, 4) }
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(rows) { treeRow($0).id($0.id) }
                            }
                            .animation(.smooth(duration: 0.2), value: rows.map(\.id))
                        }
                    }
                }
                .font(Theme.secondary).padding(Metrics.padding).frame(maxWidth: .infinity, alignment: .leading)
                .separateScrollPocket()
            }
            .onChange(of: browser.revealed, initial: true) { scrollToRevealed(proxy) }
            // 清空搜索后目录树才出来，这时再滚
            .onChange(of: directoryQuery.isEmpty) { scrollToRevealed(proxy) }
        }
    }

    /// 目录树滚到刚展开的目录。搜到的结果盖着目录树时（比如点了消息里的目录引用）先清空搜索，目录树出来再滚。
    private func scrollToRevealed(_ proxy: ScrollViewProxy) {
        guard let path = browser.revealed else { return }
        if !directoryQuery.isEmpty {
            directoryQuery = ""
            return
        }
        withAnimation { proxy.scrollTo(path, anchor: .center) }
        browser.revealed = nil
    }

    /// 一个搜到的文件或目录，后面是它所在的目录。点文件打开，点目录清空搜索、在目录树里展开到它。
    private func resultRow(_ entry: FileDirectory.Entry) -> some View {
        let folder = entry.kind == "directory"
        let parent = (entry.path as NSString).deletingLastPathComponent
        return entryButton(entry) {
            if folder {
                directoryQuery = ""
                await browser.reveal(entry.path)
            } else {
                try? await browser.navigate(FileReference(path: entry.path))
            }
        } label: {
            HStack(spacing: 8) {
                Label(entry.name, systemImage: folder ? "folder" : FileFormat(path: entry.path).symbol).lineLimit(1)
                Spacer(minLength: 0)
                Text(parent).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .accessibilityValue(parent)
    }

    /// 目录树和搜索结果里的一行：整行都能点，不只是文字和图标；选中的垫底色。只有文件和目录能点。
    private func entryButton(_ entry: FileDirectory.Entry, action: @escaping () async -> Void, @ViewBuilder label: () -> some View) -> some View {
        rowButton(selected: entry.path == browser.selection.path, enabled: ["file", "directory"].contains(entry.kind), action: action, label: label)
    }

    /// 侧栏里的一行（端口、目录树、搜索结果）：整行都能点，选中的垫底色。
    private func rowButton(selected: Bool, enabled: Bool = true, action: @escaping () async -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button { Task { await action() } } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                .contentShape(.rect)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.12))
                            .padding(.horizontal, -6)
                    }
                }
        }
        .buttonStyle(.pointingPlain).disabled(browser.selecting || !enabled)
    }

    @ViewBuilder
    private func treeRow(_ row: FileTreeRow) -> some View {
        let indent = CGFloat(row.depth) * Self.treeIndent
        switch row.kind {
        case .entry(let entry, let open):
            let folder = entry.kind == "directory"
            let selected = entry.path == browser.selection.path
            entryButton(entry) {
                if folder { await browser.toggle(entry.path) }
                else { try? await browser.navigate(FileReference(path: entry.path)) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: Self.treeIndent - 4)
                        .opacity(folder ? 1 : 0)
                    Label(entry.name, systemImage: folder ? "folder" : FileFormat(path: entry.path).symbol).lineLimit(1)
                }
                .padding(.leading, indent)
            }
            .accessibilityValue(folder ? (open ? "已展开" : "已收起") : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
        case .loading:
            Text("正在读取…").foregroundStyle(.tertiary)
                .padding(.leading, indent + Self.treeIndent).padding(.vertical, 5)
        case .more(let path, let remaining):
            Button { Task { await browser.loadMore(path) } } label: {
                Text("还有 \(remaining) 项")
                    .padding(.leading, indent + Self.treeIndent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    .contentShape(.rect)
            }
            .buttonStyle(.pointingPlain).foregroundStyle(.secondary)
            .disabled(browser.loadingPaths.contains(path))
        }
    }

    /// 历史差异和文本在可滚动的正文里；PDF、系统预览自己滚动，不套在外面的滚动视图里。
    @ViewBuilder
    private var preview: some View {
        if browser.displayingWeb {
            webPage
        } else if let download = browser.download {
            ProgressView(download).padding(Metrics.padding).frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.diff != nil || browser.selection.diffId != nil {
            textPreview
        } else if browser.format == .other {
            FileInfoView(browser: browser)
        } else if let content = browser.content, browser.format == .pdf {
            PDFPreview(url: content.url, search: pdfQuery.map { SearchHighlight(query: $0, current: matchIndex) },
                       found: { pdfMatches = $0 })
        } else if let content = browser.content, browser.format == .quickLook {
            QuickLookPreview(url: content.url)
        } else if browser.rendered, browser.format == .html, let content = browser.content, let client = browser.connection,
                  let path = browser.selection.path {
            WebPreview(source: .workspaceFile(client: client, workspace: browser.workspaceID, path: path, version: content.version,
                                              snapshot: browser.selection.version),
                       report: { browser.pageError = $0 })
        } else if browser.rendered, let markdown = browser.markdown, browser.format == .markdown, let path = browser.selection.path {
            ScrollViewReader { proxy in
                ScrollView {
                    MarkdownView(markdown)
                        .environment(\.markdownImages, MarkdownImageLoader(id: browser.instanceID + path) { [browser] in try await browser.image($0) })
                        .environment(\.searchHighlight, fileQuery.map { SearchHighlight(query: $0, current: matchIndex) })
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(Metrics.padding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .separateScrollPocket()
                }
                .onPreferenceChange(MarkdownMatches.self) { markdownMatches = $0 }
                // 只看当前匹配落在哪一块，不拿整个匹配数组当 id。
                .task(id: [matchIndex, markdownMatches.indices.contains(matchIndex) ? markdownMatches[matchIndex] : -1]) {
                    guard fileQuery != nil, markdownMatches.indices.contains(matchIndex) else { return }
                    withAnimation { proxy.scrollTo(MarkdownView.blockID(markdownMatches[matchIndex]), anchor: .center) }
                }
            }
        } else if let document = browser.document {
            sourceEditor(document)
        } else {
            textPreview
        }
    }

    /// 原文编辑器：引用指定的行选中滚过去，在文件里找时选中当前的匹配，⌘S 保存。
    private func sourceEditor(_ document: SourceDocument) -> some View {
        CodeEditor(document: document,
                   focus: browser.focus?.startLine.map { CodeEditor.Focus(lines: $0...max($0, browser.focus?.endLine ?? $0), id: browser.focusID) },
                   match: currentMatch.flatMap { match in fileQuery.map { CodeEditor.Match(query: $0, line: match.line, occurrence: match.occurrence) } },
                   save: { [browser] in Task { await browser.save() } })
            .id(ObjectIdentifier(document))
    }

    private var textPreview: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 8) {
                    if let diff = browser.diff {
                        if diff.files.count > 1 {
                            HStack {
                                ForEach(diff.files, id: \.path) { file in
                                    let current = file.path == browser.selection.path
                                    Button((file.path as NSString).lastPathComponent) {
                                        Task { try? await browser.navigate(FileReference(path: file.path, diffID: diff.id)) }
                                    }
                                    .fontWeight(current ? .semibold : .regular)
                                    .foregroundStyle(current ? .primary : .secondary)
                                    .accessibilityAddTraits(current ? .isSelected : [])
                                }
                            }.buttonStyle(.pointingPlain).font(Theme.secondary)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(browser.diffRows) { row in
                                diffRow(row).id(row.id)
                            }
                        }
                    } else if let page = browser.page, !(browser.format.renderable && browser.rendered) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(page.text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, text in
                                let line = page.offset + index
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(line)).foregroundStyle(.tertiary).frame(width: 48, alignment: .trailing)
                                    searched(text.isEmpty ? " " : text, at: line).fixedSize()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .background(highlight(line) ? Color.accentColor.opacity(0.12) : .clear)
                                .id(line)
                            }
                        }
                    }
                }
                .font(Theme.code).textSelection(.enabled).padding(Metrics.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .separateScrollPocket()
            }
            .task(id: browser.contentRevision) {
                await Task.yield()
                guard currentMatch == nil else { return }
                if browser.diff != nil, let row = browser.focusedRow { proxy.scrollTo(row, anchor: .top) }
                else if let line = browser.focus?.startLine { proxy.scrollTo(line, anchor: .top) }
            }
            // 查找时滚到当前匹配；它所在的页读回来以后再滚一次
            .task(id: "\(browser.contentRevision) \(currentMatch.map { "\($0.line) \($0.occurrence)" } ?? "")") {
                await Task.yield()
                if let match = currentMatch { withAnimation { proxy.scrollTo(match.line, anchor: .center) } }
            }
        }
    }

    private func highlight(_ line: Int?) -> Bool {
        guard let line, let start = browser.focus?.startLine else { return false }
        return line >= start && line <= (browser.focus?.endLine ?? start)
    }

    private func diffRow(_ row: FileDiffRow) -> some View {
        let color: Color = row.kind == .added ? Color.accentColor : row.kind == .removed ? Theme.danger : .primary
        let focused = highlight(row.newLine)
        return HStack(alignment: .top, spacing: 8) {
            Text(row.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(row.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
            searched(row.text.isEmpty ? " " : row.text, at: row.id).fixedSize()
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(focused ? Color.accentColor.opacity(0.18) : color.opacity(row.kind == .same ? 0 : 0.07))
    }
}

/// 浏览窗口标题栏右边的侧栏开关：收着时是一个按钮；打开时伸成搜索框，关闭按钮从组里分出来，停稳后是两块玻璃，同 ExpandingSearch。
/// 打开时不把焦点交给搜索框，iPhone 上不弹键盘，点放大镜或输入框才开始打字。关闭收起侧栏。
private struct DirectorySearch: View {
    let open: Bool
    @Binding var text: String
    let show: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        // 玻璃容器是标题栏右组的（PaneHeaderActions）
        GlassSplit(open: open) {
            PaneHeaderButtonGroup(expands: open) { controls }
        } close: {
            ActionButton("隐藏文件与网页", icon: "xmark") {
                focused = false
                show(false)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if open {
            ActionButton("搜索", icon: "magnifyingglass") { focused = true }
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.paneHeaderButton)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .keyboardDismissToolbar()
                #if os(macOS)
                .onExitCommand {
                    text = ""
                    focused = false
                }
                #endif
        } else {
            ActionButton("显示文件与网页", icon: "sidebar.right") { show(true) }
        }
    }
}
