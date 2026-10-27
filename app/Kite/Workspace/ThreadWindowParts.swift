import SwiftUI

/// 原生的会话窗口外框（Mac 的 ThreadWindowView、iPhone 和 iPad 的 PhoneThreadWindowView）里，几个托管视图里放的 SwiftUI，两端共用。

/// 原生外框量好的几项，托管视图里读：正文底下让出多高（输入区连同它顶上那段边距，同 PaneControlsBar；录音时底部那一带也按它），标题栏摆在窗口的哪儿、多大。
@MainActor @Observable final class ThreadWindowMetrics {
    struct Header: Equatable {
        var origin = CGPoint.zero
        var size = CGSize.zero
    }

    var contentBottom: CGFloat = 0
    var header = Header()
}

extension ThreadPaneModel {
    /// 对话的行：读会话记录、选中的行、刚发出的消息（行的样子跟着后两样变），在 ModelTracking 的登记里读。
    func transcriptRows(of thread: WorkThread) -> [TranscriptRow] {
        _ = selected
        _ = arriving.ids
        return TranscriptRow.rows(items: thread.transcript.items, pending: thread.transcript.pending)
    }

    /// 行看到的环境：窗口的环境加上正文字号、刚发出的消息、选中的行、工作目录。
    func rowContext(environment: EnvironmentValues, thread: WorkThread) -> TranscriptRowContext {
        var environment = environment
        environment.font = Theme.body
        environment.arrivingMessages = arriving.ids
        let selection = Binding<RowID?>(get: { self.selected }, set: { self.selected = $0 })
        environment.selectedRow = selection
        environment.workingDirectory = thread.transcriptRoot
        environment.attachmentSource = thread.attachmentSource
        return TranscriptRowContext(environment: environment, actionable: true, toggleActions: { selection.toggle($0) })
    }
}

/// 标题栏摆在从窗口原点铺起的托管视图里正文的位置上，同 HostedPlaced。
struct ThreadHeaderPlacement: ViewModifier {
    let metrics: ThreadWindowMetrics

    func body(content: Content) -> some View {
        let header = metrics.header
        content
            .frame(width: header.size.width, height: header.size.height)
            .offset(x: header.origin.x, y: header.origin.y)
            .frame(width: max(header.origin.x + header.size.width, 0), height: max(header.origin.y + header.size.height, 0),
                   alignment: .topLeading)
    }
}

// MARK: - 托管的 SwiftUI

/// 外框里各个托管视图共有的环境：随模型变的几项在托管视图里自己算，不靠桥接时交过来的那份（同 PaneBody、WorkspacePaneBody、PaneCardBody）：
/// 窗口指向的实例、所属工作机的连接提示、窗口按钮让位和收进菜单、选中的行、工作目录。
struct ThreadIslandEnvironment: ViewModifier {
    let group: PaneGroup
    let pane: Pane
    let header: PaneCardHeader
    let model: ThreadPaneModel
    @Environment(AppModel.self) private var app
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .environment(\.selectedRow, $model.selected)
            .environment(\.workingDirectory, thread.transcriptRoot)
            .environment(\.attachmentSource, thread.attachmentSource)
            .modifier(PaneHeaderEnvironment(header: header, group: group, pane: pane))
            .environment(\.paneInstance, area.instance(of: pane))
            .environment(\.paneConnectionNotice, app.connectionNotice(app.connection(for: area)))
    }
}

/// 标题栏：同 PaneWindow 的 safeAreaBar(.top) 里那一条，信息区是会话的状态圆环（提示出现时虚化盖住）。
/// 在 safeAreaBar 里放，SwiftUI 照旧给它建滚动软边的容器；报上来的高、菜单宽和可点控件的范围交给卡片。
/// iOS 上对话列表也放在这下面（below）：UIKit 的滚动软边只认同一个 SwiftUI 软边容器里的滚动视图，
/// 原生的 UIScrollEdgeElementContainerInteraction 在 SwiftUI 托管的窗口里连不上（2026-10-14 iPad 真机导过：软边高 0）。
struct ThreadHeaderRoot: View {
    let pane: ThreadPaneModel
    let header: PaneCardHeader
    let regions: HeaderRegions
    let motion: WindowMotion
    /// 标题栏下面铺的：Mac 什么也不放（对话列表另挂，经私有接口登记软边）；iOS 是原生的对话列表，见 PhoneTranscriptSlot。
    var below = AnyView(Color.clear)
    let endTyping: () -> Void
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.paneConnectionNotice) private var connectionNotice

    var body: some View {
        let initial = thread.isInitial
        below
            .safeAreaBar(edge: .top, spacing: 0) {
                PaneHeaderBar(header: pane.header(thread: thread, model: model, area: area, initial: initial),
                              status: ThreadStatusRing().environment(\.paneNotice, connectionNotice ?? model.threadNotice(thread, in: area)),
                              actions: ThreadHeaderActions(), openSidebar: sidebarAction)
                    .modifier(PaneHeaderPlacement(endTyping: endTyping))
            }
            // 同 PaneWindow：标题栏后面是系统滚动软边，底边不要
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .modifier(PaneHeaderReports(header: header, regions: regions, motion: motion))
    }

    /// 标题栏左边按钮：先收起输入，再拉开侧边栏。
    private var sidebarAction: (@MainActor () -> Void)? {
        guard let openSidebar else { return nil }
        let endTyping = endTyping
        return {
            endTyping()
            openSidebar()
        }
    }
}

/// 铺满窗口、压在最下面的：还没有消息时的点阵签名（连同标题栏和输入区后面），已有对话时录音的那一带。
/// 坐标同卡片正文；摆在点阵上的图形报给卡片。
struct ThreadBackdropRoot: View {
    let pane: ThreadPaneModel
    let metrics: ThreadWindowMetrics
    let windowFrame: PaneWindowFrame
    let reports: PaneCardBodyReports
    @Environment(WorkThread.self) private var thread

    var body: some View {
        Group {
            if thread.isInitial {
                // 标题和说明排在标题栏和输入区之间，同 PaneWindow 的正文让出 safeAreaBar；图案照样铺满整个窗口（按 paneWindowFrame）
                NewThreadStage(slot: pane.patternSlot)
                    .padding(.top, metrics.header.size.height)
                    .padding(.bottom, metrics.contentBottom)
            } else if thread.hasTranscript {
                ThreadVoiceBand(pane: pane, bottom: metrics.contentBottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.paneWindowFrame, windowFrame)
        .coordinateSpace(.named(DotCarrier.space))
        // 隔一拍交出去：托管视图可能在外框这次排版当中更新
        .onPreferenceChange(DotSlots.self) { slots in Task { @MainActor in reports.threadSlots = slots } }
    }
}
