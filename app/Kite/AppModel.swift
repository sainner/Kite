import SwiftUI

/// 一个会话和它的窗口组：会话窗口、文件、终端这些卡片怎么排。现在都是占位。
@Observable
final class Session: Identifiable {
    let id: Int
    /// 占位用的颜色，区分是哪个会话。
    let tint: Color
    let workspace: Workspace

    init(id: Int, tint: Color, arrangement: Arrangement) {
        self.id = id
        self.tint = tint
        self.workspace = Workspace(arrangement)
    }
}

@Observable
final class AppModel {
    let sessions = [
        Session(id: 1, tint: .blue, arrangement: .oneAndTwo),
        Session(id: 2, tint: .purple, arrangement: .sideBySide),
        Session(id: 3, tint: .orange, arrangement: .stacked),
        Session(id: 4, tint: .teal, arrangement: .oneAndThree),
        Session(id: 5, tint: .pink, arrangement: .oneAndTwo),
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

    /// 侧边栏实际占的宽度：收起时是一列图标。
    var sidebarShown: CGFloat { sidebarCollapsed ? Metrics.rail : sidebarWidth }

    func session(_ id: Int) -> Session? {
        sessions.first { $0.id == id }
    }

    /// 主窗口内容区显示的会话：选中的那个分离出去了，就显示下一个还在主窗口里的。
    var current: Session? {
        if !detached.contains(selected), let session = session(selected) { return session }
        return sessions.first { !detached.contains($0.id) }
    }
}
