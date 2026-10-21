import SwiftUI

@main
struct KiteApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if DirectoryVerification.isRequested {
            do {
                let model = AppModel(account: try DirectoryVerification.account())
                _model = State(initialValue: model)
                Task { await DirectoryVerification.run(model: model) }
                return
            } catch {
                print("目录验收启动失败：\(error)")
                exit(1)
            }
        }
        #endif
        let model = AppModel()
        _model = State(initialValue: model)
        LineAttention.shared.install(model: model)
        LineNotifications.shared.install(model: model)
        #if DEBUG && KITE_LAYOUT_AUDIT
        PerfProbe.arm(model: model)
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        Window("Kite", id: "main") {
            AppRoot().dockPreview().connectsToService().cardActionsPreview()
                .environment(model).readsWindowChrome().keepsLayoutEngine().toastHost().appAppearance()
        }
        .kiteWindowStyle()
        .defaultSize(width: 1272, height: 792)
        .commands { KiteCommands(model: model) }

        // 从侧边栏分离出来的工作区，放在松手的地方
        WindowGroup("工作区", id: "workspace", for: String.self) { $id in
            if let id {
                DetachedWorkspace(id: id).environment(model).readsWindowChrome().keepsLayoutEngine().toastHost().appAppearance()
            }
        }
        .kiteWindowStyle()
        .defaultSize(width: 996, height: 696)

        #else
        WindowGroup {
            AppRoot().dockPreview().connectsToService().cardActionsPreview().environment(model).toastHost().appAppearance()
        }
        // iPad 外接键盘的快捷键
        .commands { KiteCommands(model: model) }
        #endif
    }
}

#if os(macOS)
private extension Scene {
    /// 去掉标题栏，底色铺满整个窗口。空白处按住拖窗口、双击缩放（见 windowDragArea），卡片上不行（见 disablesWindowDragging）；
    /// 没有手势的字、图上也能拖。
    func kiteWindowStyle() -> some Scene {
        windowStyle(.hiddenTitleBar).windowBackgroundDragBehavior(.enabled)
    }
}
#endif

struct KiteCommands: Commands {
    let model: AppModel
    /// 当前 App 窗口里的工作区，窗口命令和排布菜单作用在它上面。
    @FocusedValue(WorkArea.self) private var area
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 换掉系统的新建窗口：Mac 上是「新建工作区窗口」，工作区窗口只能从侧栏分离出来，从这里开是空的；iPad 上是再开一个场景，各场景共用一份选择
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                guard let area else { return }
                area.collapseDock()
                area.openChooser()
            }
            .keyboardShortcut("n")
            .disabled(area?.pluginClient == nil)
        }
        // 占了快捷键的系统项（Mac 的关闭、最小化）SwiftUI 会摘掉它们的快捷键，菜单里照旧点得到
        CommandGroup(after: .newItem) {
            Button("关闭窗口") {
                onFocusedPane { area, pane in model.closeWindow(pane, in: area) } otherwise: {
                    #if os(macOS)
                    NSApp.keyWindow?.performClose(nil)
                    #endif
                }
            }
            .keyboardShortcut("w")
        }
        #if os(macOS)
        CommandGroup(before: .toolbar) {
            Button(model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏") {
                model.setSidebarCollapsed(!model.sidebarCollapsed)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Menu("外观") { AppearancePicker() }
        }
        #endif
        CommandMenu("排布") {
            Button("缩小窗口") {
                onFocusedPane { area, pane in area.layout.minimize(pane) } otherwise: {
                    #if os(macOS)
                    NSApp.keyWindow?.performMiniaturize(nil)
                    #endif
                }
            }
            .keyboardShortcut("m")
            Button("展开或还原窗口") {
                onFocusedPane { area, pane in
                    switch area.layout.expansion(of: pane) {
                    case .expand: area.layout.expand(pane)
                    case .restore: area.layout.collapse(pane)
                    case .unavailable: break
                    }
                } otherwise: {}
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(area == nil)
            Divider()
            // 第几格、第几个工作区按下时才数，菜单不随停靠栏、工作区列表重建
            Menu("打开停靠栏里的窗口") {
                ForEach(1...9, id: \.self) { number in
                    Button("第 \(number) 格") {
                        guard let area else { return }
                        model.openDockEntry(at: number - 1, in: area)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                    .disabled(area == nil)
                }
            }
            Menu("切换工作区") {
                ForEach(1...9, id: \.self) { number in
                    Button("第 \(number) 个工作区") { switchWorkspace(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.control, .command])
                }
            }
            #if os(macOS)
            Divider()
            ForEach(Array(Arrangement.allCases.enumerated()), id: \.element) { index, arrangement in
                Button(arrangement.rawValue) { area?.layout.arrange(arrangement) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    .disabled(area == nil)
            }
            #endif
        }
    }

    /// 换到侧栏工作区一栏里第 index 个工作区（从 0 数，收起时那一列圆点也是这个顺序，不含 Line），同点那一行：
    /// Mac 上已分离的把它的窗口提到前面。
    private func switchWorkspace(at index: Int) {
        let areas = model.workspaceGroups.flatMap(\.workspaces)
        guard areas.indices.contains(index) else { return }
        let target = areas[index]
        #if os(macOS)
        if model.detached.contains(target.id) { return openWindow(id: "workspace", value: target.id) }
        #endif
        if model.sidebarSection != .workspaces { withAnimation(.snappy) { model.sidebarSection = .workspaces } }
        model.selectWorkspace(target.id)
    }

    /// 窗口命令作用在台面上聚焦的窗口（最后点过的那个）；台面上没有窗口时做 otherwise：Mac 上关闭、缩小这时照旧作用在 App 窗口上，
    /// iPad 上什么都不做（关掉唯一的场景就回了主屏幕）。紧凑布局里没有台面（不在 WorkspaceContent 里），也走 otherwise。
    /// 拖动、拖缝当中什么都不做。台面的状态只在按下时读：命令的 body 读了，拖缝、拖侧栏时每步都要重建菜单。
    private func onFocusedPane(_ action: (WorkArea, Pane) -> Void, otherwise: () -> Void) {
        guard let area, area.pluginClient != nil else { return otherwise() }
        let layout = area.layout
        guard layout.drag == nil, layout.resizing == nil else { return }
        let shown = layout.shown?.panes ?? []
        if let pane = layout.focused, shown.contains(pane) { action(area, pane) } else if shown.isEmpty { otherwise() }
    }
}
