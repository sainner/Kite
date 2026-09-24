import SwiftUI

/// 一个会话和它的窗口组：会话窗口、文件、终端这些卡片怎么排。会话窗口显示假的会话记录，其余窗口还是占位。
@Observable
final class Session: Identifiable {
    let id: Int
    /// 占位用的颜色，区分是哪个会话。
    let tint: Color
    var title: String
    /// 会话所在的项目。
    let project: String
    let workspace: Workspace
    var transcript: Transcript
    /// 输入框里还没发出去的话，切到别的会话再回来还在。
    var draft = ""
    /// 下一次调模型用的 effort。
    var effort = Effort.high
    /// 上下文窗口用了几成；还没调过模型是 nil。现在是假数据，接上 kited 后由它给。
    var context: Double?
    /// 工作区里改了多少行，现在是假数据。
    var changes: (added: Int, removed: Int)

    /// 会话窗口标题栏的信息：会话的标题、所在的项目。会话窗口和 Mac 独立窗口的顶栏都用它。
    var header: PaneHeader {
        PaneHeader(title: title, detail: project)
    }

    init(id: Int, tint: Color, title: String, project: String, arrangement: Arrangement, transcript: Transcript,
         context: Double? = nil, changes: (added: Int, removed: Int) = (0, 0)) {
        self.id = id
        self.tint = tint
        self.title = title
        self.project = project
        self.workspace = Workspace(arrangement)
        self.transcript = transcript
        self.context = context
        self.changes = changes
    }
}

/// 调模型时的 effort：花多少力气想、写多长。Claude Code 的五档，发请求时放在 output_config 里；extra 是它的 xhigh。
/// 按从低到高排，序号就是第几档。
enum Effort: Int, CaseIterable {
    case low, medium, high, extra, max

    /// 界面上直接显示档位名。
    var name: String { "\(self)" }
}

@Observable
final class AppModel {
    let sessions = [
        Session(id: 1, tint: .blue, title: "修招行账单导入", project: "ledger",
                arrangement: .oneAndTwo, transcript: SampleTranscripts.gallery, context: 0.46, changes: (126, 41)),
        Session(id: 2, tint: .purple, title: "侧边栏显示会话标题", project: "kite",
                arrangement: .sideBySide, transcript: SampleTranscripts.running, context: 0.72, changes: (38, 12)),
        Session(id: 3, tint: .orange, title: "统一第二章图注", project: "thesis",
                arrangement: .stacked, transcript: SampleTranscripts.thesis, context: 0.31, changes: (17, 17)),
        Session(id: 4, tint: .teal, title: "新会话", project: "notes",
                arrangement: .oneAndThree, transcript: SampleTranscripts.empty),
        Session(id: 5, tint: .pink, title: "README 翻译成英文", project: "blog",
                arrangement: .oneAndTwo, transcript: SampleTranscripts.edgeCases, context: 0.88, changes: (214, 198)),
    ]
    var selected = 1
    /// 分离成独立窗口的会话。独立窗口出现时加进来，关掉时去掉。
    var detached: Set<Int> = []
    /// 下一个分离出去的窗口放在哪：左上角和大小，屏幕坐标，左上角是原点（和 SwiftUI 摆窗口用的一致）。
    var pendingPlacement: CGRect?
    var sidebarWidth = Metrics.sidebarWidth
    var sidebarCollapsed = false
    /// 主窗口内容区的大小，分离出去的窗口照它开。
    var contentSize: CGSize = .zero


    func session(_ id: Int) -> Session? {
        sessions.first { $0.id == id }
    }

    /// 主窗口内容区显示的会话：选中的那个分离出去了，就显示下一个还在主窗口里的。
    var current: Session? {
        if !detached.contains(selected), let session = session(selected) { return session }
        return sessions.first { !detached.contains($0.id) }
    }
}
