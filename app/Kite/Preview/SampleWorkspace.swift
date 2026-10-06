import SwiftUI

/// Debug build 带 --sample-data 启动，或编译时开启 KITE_SAMPLE_DATA，加载静态样本供用户预览界面。
/// 样本线程没有服务客户端，连接、发送和新建入口不会访问工作机。
enum SampleWorkspace {
    static var enabled: Bool {
        #if DEBUG && KITE_SAMPLE_DATA
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("--sample-data")
        #else
        false
        #endif
    }

    static func makeModel() -> AppModel {
        guard enabled else { return AppModel() }
        let transport = SampleGitTransport()
        let model = AppModel(account: KiteAccount(transport: transport.account),
                             previewClient: KitedClient(address: "https://preview.invalid", machineID: "sample", transport: transport.worker))
        model.workspaces = [
            pluginSidebar(),
            dotGallery(),
            dotStudio(),
            workspace("references", title: "引用 · 文件与历史差异", transcript: ReferenceSamples.transcript, outcome: "completed"),
            workspace("stream-live", title: "流式会话 · 动态预览", transcript: HarnessSampleTranscripts.empty),
            workspace("tool-styles", title: "工具行 · 样式与动画", transcript: HarnessSampleTranscripts.toolStyles),
            workspace("ink", title: "执行动画 · 文件摘要", transcript: HarnessSampleTranscripts.ink),
            workspace("ui", title: "界面开发", transcript: HarnessSampleTranscripts.gallery, outcome: "completed"),
            workspace("notes", title: "文档整理", transcript: HarnessSampleTranscripts.markdown, outcome: "completed"),
            workspace("logs", title: "日志排查", transcript: HarnessSampleTranscripts.errors, outcome: "failed"),
            workspace("draft", title: "空白草稿", transcript: HarnessSampleTranscripts.empty),
            workspace("chip-running", title: "chip · 运行中（样式样本）", transcript: HarnessSampleTranscripts.streaming, inputTokens: 46000, windowTokens: 100000),
            workspace("chip-idle", title: "chip · 空闲（样式样本）", transcript: HarnessSampleTranscripts.empty, inputTokens: 0, windowTokens: 100000),
            workspace("chip-stopping", title: "chip · 停止中（样式样本）", transcript: HarnessSampleTranscripts.running, phase: "stopping", inputTokens: 100000, windowTokens: 100000),
            workspace("chip-finishing", title: "chip · 收尾中（样式样本）", transcript: HarnessSampleTranscripts.gallery, phase: "finishing", inputTokens: 99000, windowTokens: 100000),
            workspace("batches", title: "工具批次", transcript: HarnessSampleTranscripts.batches, outcome: "completed"),
            workspace("gallery", title: "工具与消息", transcript: HarnessSampleTranscripts.gallery, outcome: "completed"),
            workspace("running", title: "工作中与排队", transcript: HarnessSampleTranscripts.running),
            workspace("markdown", title: "长文与排版", transcript: HarnessSampleTranscripts.markdown),
            workspace("errors", title: "工具与模型报错", transcript: HarnessSampleTranscripts.errors, outcome: "failed", inputTokens: 28000),
            workspace("interrupted", title: "停止与退回草稿", transcript: HarnessSampleTranscripts.interrupted, outcome: "interrupted"),
            workspace("recovery", title: "结果未知与恢复", transcript: HarnessSampleTranscripts.recovery, outcome: "failed", recovery: "工具结果未知，确认残留执行停止后才能继续"),
            workspace("output", title: "长输出与截断", transcript: HarnessSampleTranscripts.output),
            workspace("streaming", title: "回复生成中", transcript: HarnessSampleTranscripts.streaming),
            workspace("empty", title: "空白会话", transcript: HarnessSampleTranscripts.empty),
        ]
        model.selected = "sample-plugin-sidebar"
        return model
    }

    /// 同时展示收起窗口、多视图实例、无窗口 agent 和纯后台实例，供两端预览停靠栏。
    private static func pluginSidebar() -> WorkArea {
        let area = workspace("plugin-sidebar", title: "插件 · 侧栏样式", transcript: HarnessSampleTranscripts.empty)
        let mainWindow = area.windows[0]
        area.definitions += [
            .init(id: "sample.plugin.todo", title: "待办（样式样本）", lifetime: .persistent,
                  views: [.init(id: "list", title: "待办列表", renderer: "web"),
                          .init(id: "completed", title: "已完成", renderer: "web")],
                  defaultView: "list", agent: nil, runtime: "bun"),
            .init(id: "sample.plugin.background", title: "后台插件（样式样本）", lifetime: .persistent,
                  views: [], defaultView: "", agent: nil, runtime: "bun"),
        ]
        let threads = ["检查侧栏布局", "整理窗口交互反馈"].map { title in
            let thread = WorkThread(workspace: area.remote?.workspace.cwd ?? "", project: "插件 · 样式样本")
            thread.title = title
            thread.transcript = HarnessSampleTranscripts.empty
            thread.connected = true
            return thread
        }
        area.threads += threads
        area.instances += threads.map { thread in
            .init(id: thread.id, workspaceId: area.id, definitionId: "kite.agent.coding", title: thread.title,
                  status: .open, presentation: .window, createdAt: 0, config: .init(agent: sampleAgent))
        }
        area.instances += [
            .init(id: "sample-todo-windows", workspaceId: area.id, definitionId: "sample.plugin.todo",
                  title: "待办 · 多视图（样式样本）", status: .open, presentation: .window, createdAt: 0),
            .init(id: "sample-todo-windowless", workspaceId: area.id, definitionId: "sample.plugin.todo",
                  title: "待办 · 无窗口（样式样本）", status: .open, presentation: .window, createdAt: 0),
            .init(id: "sample-background", workspaceId: area.id, definitionId: "sample.plugin.background",
                  title: "后台插件（样式样本）", status: .open, presentation: .background, createdAt: 0),
        ]
        for target in [WindowTarget(instanceId: threads[0].id, viewId: "conversation"),
                       WindowTarget(instanceId: "sample-todo-windows", viewId: "list"),
                       WindowTarget(instanceId: "sample-todo-windows", viewId: "completed")] {
            openWindow(.init(id: UUID().uuidString, content: .open(target)), in: area)
        }
        area.layout.expand(Pane(mainWindow.id))
        area.layout.activate(Pane(mainWindow.id))
        return area
    }

    /// 点阵视觉语言的样式样本，窗口只在预览中存在。
    private static func dotGallery() -> WorkArea {
        let area = workspace("dots", title: "点阵 · 视觉语言", transcript: HarnessSampleTranscripts.empty)
        area.definitions.append(.init(id: "sample.dots", title: "点阵（样式样本）", lifetime: .window,
                                      views: [.init(id: "gallery", title: "点阵", renderer: DotGallery.renderer)],
                                      defaultView: "gallery", agent: nil))
        let id = UUID().uuidString
        openWindow(.init(id: id, content: .create("sample.dots")), in: area)
        area.layout.expand(Pane(id))
        return area
    }

    /// 图案创造台，窗口只在预览中存在。
    private static func dotStudio() -> WorkArea {
        let area = workspace("dot-studio", title: "点阵 · 图案创造台", transcript: HarnessSampleTranscripts.empty)
        area.definitions.append(.init(id: "sample.dotStudio", title: "图案创造台（预览工具）", lifetime: .window,
                                      views: [.init(id: "studio", title: "图案创造台", renderer: DotStudio.renderer)],
                                      defaultView: "studio", agent: nil))
        let id = UUID().uuidString
        openWindow(.init(id: id, content: .create("sample.dotStudio")), in: area)
        area.layout.expand(Pane(id))
        return area
    }

    private static func workspace(_ id: String, title: String, transcript: Transcript,
                                  phase: String? = nil, outcome: String? = nil, recovery: String? = nil,
                                  inputTokens: Int? = nil, windowTokens: Int? = nil) -> WorkArea {
        let remote = RemoteWorkspace(
            machine: RemoteMachine(id: "sample", name: "预览工作机", createdAt: 0),
            project: RemoteProject(id: "sample", name: "harness · 假数据", remote: "github.com/sample/harness", createdAt: 0),
            // 侧栏每个检出只列一个根工作区，样本各占一个检出才能都列出来
            checkout: RemoteCheckout(id: "sample-" + id, projectId: "sample", machineId: "sample",
                                     path: transcript.root, remote: "github.com/sample/harness", createdAt: 0),
            workspace: WorkspaceInfo(id: "sample-" + id, checkoutId: "sample-" + id, name: title, cwd: transcript.root,
                                     kind: .root, branch: nil, base: nil, status: .open, createdAt: 0),
            threads: [], instances: [], windows: []
        )
        let area = WorkArea(remote: remote, definitions: definitions)
        let thread = WorkThread(workspace: remote.id, project: remote.project.name)
        thread.title = title
        thread.transcript = transcript
        let phase = phase ?? (transcript.running ? "running" : "idle")
        let running = phase != "idle"
        if thread.transcript.running != running { thread.transcript.running = running }
        let failure = transcript.records.reversed().lazy.compactMap { record -> String? in
            if case .apiError(let message) = record.block { return message }
            return nil
        }.first
        thread.state = RemoteState(phase: phase, busy: running,
                                   waitingForResume: outcome == "failed",
                                   lastOutcome: outcome.map { .init(kind: $0, message: $0 == "failed" ? failure : nil) },
                                   recovery: recovery.map { .init(message: $0) }, status: "open", error: nil,
                                   capabilities: .init(send: false, interrupt: transcript.running, resume: outcome == "failed" && recovery == nil, cancel: false))
        thread.connected = true
        thread.isStreamingPreview = id == "stream-live"
        // 仅用于 chip 样式预览；100000 是虚构窗口上限，不代表任何真实模型。
        thread.state?.context = inputTokens.map {
            ContextUsage(requestId: "sample-" + id, inputTokens: $0, windowTokens: windowTokens,
                         measuredAt: Date.now.timeIntervalSince1970 * 1000)
        }
        if outcome == "interrupted" {
            thread.draft = transcript.pending.map(\.typed).joined(separator: "\n\n")
            thread.transcript.pending = []
        }
        area.threads = [thread]
        area.instances = [.init(id: thread.id, workspaceId: area.id, definitionId: "kite.agent.coding", title: title,
                                status: .open, presentation: .window, createdAt: 0, config: .init(agent: sampleAgent))]
        openWindow(.init(id: UUID().uuidString, content: .open(WindowTarget(instanceId: thread.id, viewId: "conversation"))), in: area)
        openWindow(.init(id: UUID().uuidString, content: .create("kite.files")), in: area)
        openWindow(.init(id: UUID().uuidString, content: .create("kite.terminal")), in: area)
        area.layout.arrange(.oneAndTwo)
        area.activateWindow(for: WindowTarget(instanceId: thread.id, viewId: "conversation"))
        return area
    }
    /// 预览中的定义与工作机声明同形，预览时不请求网络。
    private static let sampleAgent = AgentConfiguration(runtime: "harness",
        model: .init(model: AgentModelCatalog.bundled.defaultModel.id, reasoning: "medium"), tools: ["read", "patch", "shell"],
        context: ["version": 2, "id": "sample", "title": "样式样本", "scene": "thread.create", "blocks": []], maxRequestsPerTurn: 50)

    static let definitions: [RemotePluginDefinition] = [
        .init(id: "kite.agent.coding", title: "代理", lifetime: .persistent, views: [.init(id: "conversation", title: "会话", renderer: "conversation")],
              defaultView: "conversation", agent: .init(runtime: .harness, model: sampleAgent.model)),
        .init(id: "kite.files", title: "文件", lifetime: .window, views: [.init(id: "files", title: "文件", renderer: "files")],
              defaultView: "files", agent: nil),
        .init(id: "kite.terminal", title: "终端", lifetime: .window, views: [.init(id: "terminal", title: "终端", renderer: "terminal")], defaultView: "terminal", agent: nil),
    ]

    /// 静态预览中的添加与关闭只修改内存，使用和真实窗口相同的目标绑定。
    static func openWindow(_ request: OpenWindowRequest, in area: WorkArea) {
        let target: WindowTarget
        switch request.content {
        case .create(let definitionID):
            guard let definition = area.definitions.first(where: { $0.id == definitionID }) else { return }
            let id: String
            let title: String
            if definition.agent != nil {
                let thread = WorkThread(workspace: UUID().uuidString, project: area.remote?.project.name ?? "Kite")
                thread.transcript = Transcript(root: area.remote?.workspace.cwd ?? "")
                thread.title = "新会话 \(area.threads.count + 1)"
                area.threads.append(thread)
                id = thread.id
                title = thread.title
            } else {
                id = UUID().uuidString
                let titles = Set(area.instances.filter { $0.definitionId == definitionID }.map(\.title))
                var number = 1
                while titles.contains("\(definition.title) \(number)") { number += 1 }
                title = "\(definition.title) \(number)"
            }
            area.instances.append(.init(id: id, workspaceId: area.id, definitionId: definitionID, title: title,
                                        status: .open, presentation: definition.views.isEmpty ? .background : .window, createdAt: 0,
                                        config: definition.agent == nil ? nil : .init(agent: sampleAgent)))
            guard !definition.views.isEmpty else { return }
            target = WindowTarget(instanceId: id, viewId: definition.defaultView)
        case .open(let existing): target = existing
        }
        area.windows.append(.init(id: request.id, workspaceId: area.id, target: target, state: .open, createdAt: 0))
        area.layout.reconcile(area.windows.map { Pane($0.id) })
        area.updateFiles()
        area.layout.activate(Pane(request.id))
    }

    static func closeWindow(_ pane: Pane, in area: WorkArea) {
        guard let window = area.windows.first(where: { $0.id == pane.id }) else { return }
        area.windows.removeAll { $0.id == pane.id }
        if let instance = area.instances.first(where: { $0.id == window.target.instanceId }),
           area.definition(of: instance)?.lifetime == .window,
           !area.windows.contains(where: { $0.target.instanceId == instance.id }) {
            area.instances.removeAll { $0.id == instance.id }
            if area.settingsInstance?.id == instance.id { area.settingsInstance = nil }
        }
        area.updateFiles()
        area.layout.reconcile(area.windows.map { Pane($0.id) })
    }

}

extension View {
    /// 预览也保留设置入口；是否连接服务由 ServiceConnection 判断。
    func connectsToService() -> some View {
        modifier(ServiceConnection())
    }
}
