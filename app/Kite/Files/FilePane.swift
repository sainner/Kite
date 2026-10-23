import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 浏览窗口（docs/成果查看与位置.md「浏览」）：工作区的文件（目录、原文、渲染与历史差异），本工作区运行中的网页和互联网共用一个窗口。
/// 看什么各设备共用（FileBrowser.selection）；行号定位、网页里点到哪仅属于当前设备。侧栏上面是本工作区监听的端口，下面是文件目录。
/// 网页在设备自己的网页视图里看，控制区同预览的网页画面（WebPageControls），地址栏里能输网址、端口号或 localhost:端口；
/// 网站数据按工作区分开，同一工作区的浏览窗口共用登录状态。
struct FilePane: View {
    let browser: FileBrowser
    @Environment(WorkArea.self) private var area
    @Environment(\.workspacePresentation) private var presentation
    @State private var web = WebBrowser()
    @State private var reload = UUID()
    /// 清除输入：每点一次，地址栏回到打字前的样子。
    @State private var addressReset = 0
    /// 看着文件时点了「打开网址」：控制区换成地址栏，打开了或离开地址栏就换回来。
    @State private var addressing = false
    /// 互联网网页的页面从哪个网址开起；之后换网址在同一个页面里跳过去，前进后退接得上（见 webPage）。
    @State private var webStart: URL?
    /// 窗口够宽，文件和目录可以并排。
    @State private var wide = false
    @State private var searching = false
    @State private var query = ""
    /// 当前是第几个匹配。
    @State private var matchIndex = 0
    /// Markdown 预览报上来的每个匹配在第几块，见 MarkdownMatches。
    @State private var markdownMatches: [Int] = []
    /// PDF 里找到几个。
    @State private var pdfMatches = 0
    /// 交给 PDF 预览的关键字：PDFKit 同步搜整份文档，等输入停下再给。
    @State private var pdfQuery: String?

    private var header: PaneHeader {
        // 网页的主标题是 localhost:端口或网站；文件的是当前文件的名字，还没选时是工作区文件夹的名字
        if browser.displayingWeb { return PaneHeader(title: pageName, subtitle: "网页") }
        return PaneHeader(title: browser.selection.path.map { ($0 as NSString).lastPathComponent } ?? rootName,
                          subtitle: showingDiff ? "历史差异" : "文件")
    }

    private var pageName: String {
        switch browser.selection.page {
        case .port(let port): "localhost:\(port)"
        case .url(let url): url.host() ?? url.absoluteString
        case nil: rootName
        }
    }

    private var compact: Bool { presentation == .compact }

    /// 网页看得见：选了网页，目录没盖着它。
    private var webVisible: Bool { browser.displayingWeb && (!browser.showDirectory || wide) }

    private var livePort: Int? { area.livePort(browser.selection.port) }

    private var showingDiff: Bool { browser.displayingFile && browser.selection.diffId != nil }

    private var sideBySide: Bool { (browser.displayingFile || browser.displayingWeb) && wide }

    /// 文件看得见：选了文件，目录没盖着它。控制区只在这时给文件的操作。
    private var fileVisible: Bool { browser.displayingFile && (!browser.showDirectory || wide) }

    private var rootName: String {
        let cwd = (area.remote.workspace.cwd as NSString).lastPathComponent
        return cwd.isEmpty ? "工作区" : cwd
    }

    /// 窗口现在的情况，正文只放目录和文件内容：正在搜索、正在读取、目录或文件是空的、还没选文件。
    private var status: PaneNotice? {
        if searching, searchTarget == .directory, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if browser.searchingFiles { return .info("正在搜索…", symbol: "magnifyingglass") }
            if let results = browser.searchResults {
                if results.entries.isEmpty { return .info("没有名字含「\(results.query)」的文件", symbol: "magnifyingglass") }
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
        if browser.showDirectory { return browser.root?.entries.isEmpty == true ? .info("工作区是空的") : nil }
        return browser.selection.path == nil && !browser.displayingWeb ? .info("选择文件或网页，或点击消息中的引用") : nil
    }

    /// 信息区：失败优先，其次是窗口现在的情况（见 status），再是指定行定位不到这类关于文件的说明。
    private var notice: PaneNotice? {
        let contentError = browser.displayingFile ? browser.textError ?? browser.pageError : browser.displayingWeb ? browser.pageError : nil
        if let error = contentError ?? browser.directoryError { return .failure(error) }
        if let status { return status }
        let unversioned = browser.selection.diffId == nil && ((browser.content?.info ?? browser.info)?.unversioned ?? false)
        guard browser.displayingFile, let message = browser.locationMessage
                ?? (browser.format == .other ? nil : browser.infoNote)
                ?? (unversioned ? "超过 10 MiB 的文件不进工作区快照，没有历史版本" : nil) else { return nil }
        return .info(message)
    }

    var body: some View {
        PaneWindow(header: header, notice: notice, actions: PaneHeaderActions(groups: [[
            // 目录开关改的是整个窗口的排布，放在标题栏
            PaneHeaderAction(title: "目录", systemImage: "sidebar.right", help: browser.showDirectory ? "隐藏文件与网页" : "显示文件与网页",
                             on: browser.showDirectory) {
                browser.showDirectory.toggle()
            },
        ]])) {
            ZStack(alignment: .topTrailing) {
                // 文件不参与目录的动画：排布在开关时当场变好，窄窗口里留在原地让目录盖住，网页、PDF 也不用重新加载
                HStack(spacing: 0) {
                    preview
                    if browser.showDirectory && sideBySide {
                        HStack(spacing: 0) { Divider(); Color.clear.frame(width: Self.directoryWidth) }.hidden()
                    }
                }
                .accessibilityHidden(browser.showDirectory && !sideBySide)
                .transaction { $0.animation = nil }
                if browser.showDirectory {
                    // 从右边划进划出，和标题栏的目录开关同一边。左右挪时目录的顶边一直贴着标题栏，标题栏后面的模糊照常；
                    // 上下挪的话滚动区的软边跟着走，划过标题栏的那一截没有模糊
                    directoryColumn(sideBySide: sideBySide)
                        .background(Theme.card)
                        .transition(.move(edge: .trailing))
                        // ZStack 里移除的视图划出时会排到下面，文件就画在目录的底色上面了
                        .zIndex(1)
                }
            }
            // 开关、从目录或引用打开文件、打开目录，目录都这样划进划出
            .animation(Self.directoryMotion, value: browser.showDirectory)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide = $0 }
        } controls: { typing in
            Group {
                if webVisible || addressing { webControls(typing: typing) } else { controls }
            }
            // 目录盖住或露出文件时，按钮组跟着换，玻璃按系统的过渡变形
            .animation(.snappy, value: fileVisible)
        }
        .task(id: browser.connectionRevision) { await browser.list() }
        .task(id: browser.requestKey) { await browser.loadSelection() }
        .task(id: "\(searching) \(String(describing: searchTarget)) \(query) \(browser.selection.revision) \(browser.diff?.id ?? "")") {
            await runSearch()
        }
        // 文本的当前匹配不在这一页时，先读到它所在的地方
        .task(id: currentMatch) {
            guard searchTarget == .text, let line = currentMatch?.line, let page = browser.page,
                  line < page.offset || line >= page.nextOffset ?? page.totalLines + 1 else { return }
            await browser.read(offset: max(1, line - 50))
        }
        // 在目录和文件之间换了搜的对象，搜索框收起来；文件换了看法（原文、预览）接着找
        .onChange(of: searchTarget) { old, new in
            guard searching, new == nil || (old == .directory) != (new == .directory) else { return }
            query = ""
            withAnimation { searching = false }
        }
        .onChange(of: browser.selection.port) { area.portChanged(browser.instanceID, to: browser.selection.port) }
        .onChange(of: browser.selection.url, initial: true) { _, url in
            // 换网址在同一个页面里跳过去；从别的内容换到网址时从这个网址开起
            guard let url = url.flatMap(URL.init(string:)), webStart != nil else {
                webStart = url.flatMap(URL.init(string:))
                return
            }
            web.open(url)
        }
    }

    // MARK: - 网页

    /// 本工作区的网页经端口转发打开，互联网的直接打开；页面里可以去任何网址，只是进不了工作机服务自己的地址（WebRoaming）。
    /// 互联网网页的来源是开起时的网址，换网址不重建页面。
    @ViewBuilder
    private var webPage: some View {
        if let client = browser.connection, let store = UUID(uuidString: browser.workspaceID) {
            switch browser.selection.page {
            case .port(let port) where port == livePort:
                PortPreview(client: client, port: port, store: store, roaming: client.roaming, link: area.webLink(for: browser.instanceID, port: port),
                            browser: web, report: { browser.pageError = $0 })
                    .id("\(port) \(reload)")
            case .url(let url):
                WebPreview(source: .address(webStart ?? url, store: store, roaming: client.roaming), report: { browser.pageError = $0 }, browser: web)
                    .id(reload)
            default:
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    private func webControls(typing: FocusState<Bool>.Binding) -> some View {
        WebControls(typing: typing.wrappedValue || addressing) {
            if webVisible {
                WebPageControls(browser: web, compact: compact, typing: typing.wrappedValue, home: goHome, reload: reloadPage, clear: { addressReset += 1 }) {
                    addressField(typing: typing)
                }
            } else {
                // 看着文件时点了「打开网址」：只有地址栏，打开了或离开地址栏就换回文件的控制区
                HStack(spacing: Metrics.paneButtonGap) {
                    addressField(typing: typing)
                    PaneHeaderButtonGroup {
                        ActionButton("取消", icon: "xmark") { addressing = false }
                    }
                }
                .task { typing.wrappedValue = true }
                .onChange(of: typing.wrappedValue) { _, editing in if !editing { addressing = false } }
            }
        }
    }

    /// 地址栏：站点图标和地址。紧凑布局里首页放在地址栏最右边。
    private func addressField(typing: FocusState<Bool>.Binding) -> some View {
        PaneHeaderButtonGroup(expands: true) {
            WebSiteIcon(icon: webVisible ? web.icon : nil)
                .padding(.leading, Metrics.paneHeaderButtonGap / 2)
            WebPathField(path: webVisible ? address : "", typing: typing, reset: addressReset, prompt: "网址或端口号", open: go)
            if compact, webVisible {
                ActionButton("首页", icon: "house", action: goHome)
            }
        }
    }

    /// 地址栏显示的地址：本机的写 localhost:端口 加路径，https 省掉前缀。
    private var address: String {
        if let local = web.url.flatMap(LocalPort.init) {
            let path = LocalPort.displayPath(of: web.url)
            return "localhost:\(local.port)" + (path == "/" ? "" : path)
        }
        if web.url == nil, let port = browser.selection.port { return "localhost:\(port)" }
        guard let url = web.url ?? browser.selection.url.flatMap(URL.init(string:)) else { return "" }
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
        webStart = browser.selection.url.flatMap(URL.init(string:))
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

    private static let directoryMotion = Animation.smooth(duration: 0.3)

    private var controls: some View {
        FileControlsLayout(spacing: Metrics.paneButtonGap) {
            if searchTarget != nil {
                ExpandingSearch(presented: $searching, text: $query, submit: { step(1) }) {
                    EmptyView()
                } accessory: {
                    searchAccessory
                }
                .layoutValue(key: FileControlsLayout.Fills.self, value: searching)
            }
            if !searching {
                viewControls
                fileControls.layoutValue(key: FileControlsLayout.Trailing.self, value: true)
            }
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

    /// 搜索框搜什么：文件看得见、格式支持查找时在文件里找，否则按名字搜目录。网页预览、系统预览不支持查找。
    private enum SearchTarget: Equatable { case directory, text, diff, markdown, pdf }

    private var searchTarget: SearchTarget? {
        if fileVisible {
            if browser.selection.diffId != nil { return .diff }
            switch browser.format {
            case .text: return .text
            case .markdown: return browser.rendered ? .markdown : .text
            case .html: if !browser.rendered { return .text }
            case .pdf: return .pdf
            case .quickLook, .other: break
            }
        }
        return browser.showDirectory ? .directory : nil
    }

    /// 在文件里找的关键字；没在找、在搜目录或关键字为空是 nil。
    private var fileQuery: String? {
        guard searching, !query.isEmpty, let target = searchTarget, target != .directory else { return nil }
        return query
    }

    private var matchCount: Int {
        switch searchTarget {
        case .text, .diff: browser.matches.count
        case .markdown: markdownMatches.count
        case .pdf: pdfMatches
        case .directory, nil: 0
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

    /// 输入停一下再找。目录按名字搜整个工作区，文本和差异在模型里找，Markdown 预览和 PDF 由视图自己找、报个数上来。
    private func runSearch() async {
        matchIndex = 0
        guard searching, let target = searchTarget else {
            browser.endSearch()
            browser.endFind()
            pdfQuery = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        switch target {
        case .directory: await browser.search(query)
        case .text, .diff: await browser.find(query)
        case .pdf: pdfQuery = fileQuery
        case .markdown: break
        }
    }

    /// 查找时一行里的匹配标出来。
    private func searched(_ text: String, at line: Int) -> Text {
        guard let query = fileQuery, searchTarget == .text || searchTarget == .diff else { return Text(verbatim: text) }
        let current = currentMatch.flatMap { $0.line == line ? $0.occurrence : nil }
        return Text(SearchHighlight(query: query, current: current).apply(to: text))
    }

    /// 左边是正文怎么看：原文开关，或者从历史差异回到当前文件。
    private var viewControls: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            if fileVisible, browser.selection.diffId != nil {
                PaneHeaderButtonGroup {
                    Button {
                        if let path = browser.selection.path { Task { try? await browser.navigate(FileReference(path: path)) } }
                    } label: { PaneHeaderButtonLabel("回到当前文件") }
                        .foregroundStyle(Color.primary)
                        .help("回到这个文件现在的内容")
                }
            } else if fileVisible, browser.format.renderable {
                PaneHeaderActions(groups: [[PaneHeaderAction(title: "显示原文", systemImage: "chevron.left.forwardslash.chevron.right",
                                                             help: browser.rendered ? "显示原文" : "显示预览", on: !browser.rendered) { browser.rendered.toggle() }]])
            }
        }
    }

    /// 右边是对文件的操作：翻页一组，打开、下载、共享与刷新一组。
    private var fileControls: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            if fileVisible, let page = browser.page, browser.selection.diffId == nil,
               !(browser.format.renderable && browser.rendered) {
                PaneHeaderButtonGroup {
                    ActionButton("上一页", icon: "chevron.left") { Task { await browser.read(offset: max(1, page.offset - 200)) } }
                        .disabled(page.offset <= 1)
                    ActionButton("下一页", icon: "chevron.right") { if let offset = page.nextOffset { Task { await browser.read(offset: offset) } } }
                        .disabled(page.nextOffset == nil)
                }
            }
            PaneHeaderButtonGroup {
                #if os(macOS)
                if let url = defaultAppURL {
                    ActionButton("用默认 App 打开", icon: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                }
                #endif
                if fileVisible, browser.format == .other, browser.content == nil, !browser.isLocal {
                    ActionButton("下载", icon: "arrow.down.circle") { Task { await browser.fetch() } }
                        .disabled(browser.loadingText)
                }
                if fileVisible, let content = browser.content {
                    ShareLink(item: content.url) { PaneHeaderButtonLabel("共享", systemImage: "square.and.arrow.up") }
                        .foregroundStyle(Color.primary)
                        .help("共享")
                }
                ActionButton("刷新", icon: "arrow.clockwise", action: refresh)
                    .disabled(browser.loadingDirectory || browser.loadingText)
                ActionButton("打开网址", icon: "globe") { addressing = true }
            }
        }
    }

    /// 认不出的格式用默认 App 打开：工作机就是本机时开工作区里的原文件，其他设备开下载好的副本。
    private var defaultAppURL: URL? {
        guard fileVisible, browser.format == .other, let path = browser.selection.path else { return nil }
        if browser.isLocal { return URL(filePath: area.remote.workspace.cwd).appending(path: path) }
        return browser.content?.url
    }

    /// 目录和文件看得见哪个就刷新哪个。
    private func refresh() {
        if browser.showDirectory || !browser.displayingFile { Task { await browser.list() } }
        if fileVisible { Task { await browser.loadSelection() } }
    }

    private static let directoryWidth: CGFloat = 210

    /// 文件在旁边时目录是右边一列，左边带分隔线；否则占满窗口。
    private func directoryColumn(sideBySide: Bool) -> some View {
        HStack(spacing: 0) {
            if sideBySide { Divider() }
            directory.frame(width: sideBySide ? Self.directoryWidth : nil)
        }
    }

    private static let treeIndent: CGFloat = 16

    /// 从工作区根目录起的折叠列表：点目录展开、收起，点文件打开。按名字搜目录时换成搜到的结果。
    private var directory: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if searching, searchTarget == .directory, let results = browser.searchResults {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(results.entries) { resultRow($0) }
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
            // 收起搜索后目录树才出来，这时再滚
            .onChange(of: searching) { scrollToRevealed(proxy) }
        }
    }

    /// 目录树滚到刚展开的目录。搜到的结果盖着目录树时（比如点了消息里的目录引用）先清空搜索，目录树出来再滚。
    private func scrollToRevealed(_ proxy: ScrollViewProxy) {
        guard let path = browser.revealed else { return }
        if searching, searchTarget == .directory {
            query = ""
            withAnimation { searching = false }
            return
        }
        withAnimation { proxy.scrollTo(path, anchor: .center) }
        browser.revealed = nil
    }

    /// 一个搜到的文件或目录，后面是它所在的目录。点文件打开，点目录收起搜索、在目录树里展开到它。
    private func resultRow(_ entry: FileDirectory.Entry) -> some View {
        let folder = entry.kind == "directory"
        let parent = (entry.path as NSString).deletingLastPathComponent
        return entryButton(entry) {
            if folder {
                query = ""
                withAnimation { searching = false }
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
            WebPreview(source: .workspaceFile(client: client, workspace: browser.workspaceID, path: path, version: content.version),
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
        } else {
            textPreview
        }
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

/// 控制区的排布：前面的组靠左、Trailing 的组靠右排一行；放不下时前面的一行、后面的一行。搜索框展开时（Fills）占满所在一行剩下的宽度。
/// 按钮始终是同一批视图，换状态时玻璃和按钮走过渡；ViewThatFits 会把两种排法各建一份，里面按钮的出现、消失没有过渡。
private struct FileControlsLayout: Layout {
    let spacing: CGFloat

    struct Trailing: LayoutValueKey { static let defaultValue = false }
    struct Fills: LayoutValueKey { static let defaultValue = false }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(subviews, sizes: sizes, width: proposal.width)
        let natural = rows.map { width(of: $0, sizes: sizes) }.max() ?? 0
        let height = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(subviews, sizes: sizes, width: bounds.width) {
            let height = row.map { sizes[$0].height }.max() ?? 0
            let free = max(bounds.width - width(of: row, sizes: sizes), 0)
            // 空着的视图（比如这时没有按钮的一组）也摆上，免得里面正在消失的按钮跳到别处；只是不占间距
            var x = bounds.minX
            for index in row where !subviews[index][Trailing.self] {
                let width = sizes[index].width + (subviews[index][Fills.self] ? free : 0)
                subviews[index].place(at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2),
                                      proposal: ProposedViewSize(width: width, height: sizes[index].height))
                if width > 0 { x += width + spacing }
            }
            var right = bounds.maxX
            for index in row.reversed() where subviews[index][Trailing.self] {
                right -= sizes[index].width
                subviews[index].place(at: CGPoint(x: right, y: y + (height - sizes[index].height) / 2), proposal: ProposedViewSize(sizes[index]))
                if sizes[index].width > 0 { right -= spacing }
            }
            y += height + spacing
        }
    }

    /// 一行放得下（伸满的按自己的宽算）就一行，否则前后各一行。
    private func rows(_ subviews: Subviews, sizes: [CGSize], width: CGFloat?) -> [[Int]] {
        let all = Array(subviews.indices)
        guard let width, self.width(of: all, sizes: sizes) > width else { return [all] }
        return [all.filter { !subviews[$0][Trailing.self] }, all.filter { subviews[$0][Trailing.self] }].filter { !$0.isEmpty }
    }

    private func width(of row: [Int], sizes: [CGSize]) -> CGFloat {
        let widths = row.map { sizes[$0].width }.filter { $0 > 0 }
        return widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
    }
}
