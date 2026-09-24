import SwiftUI

/// 侧边栏里的一行，一个会话。没有自己的底色，选中时垫一层；现在只有占位色块，颜色区分是哪个会话。
struct SessionRow: View {
    let session: Session
    let current: Bool
    /// 分离成了独立窗口（Mac）。
    var detached = false
    var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.tint).frame(width: 10, height: 10)
            RoundedRectangle(cornerRadius: 4).fill(Theme.placeholder).frame(height: 10)
            if detached {
                Image(systemName: "macwindow").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(current ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// action 区：一排按钮，比如会话，还有用户（账号和个人设置）。现在只有占位色块。
/// Mac 上在侧边栏底部，按钮一行、用户单独一行；iPhone 上从窗口底部拉出来，只有一行，用户是其中一个按钮。
struct ActionArea: View {
    var body: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            buttons
            Circle().fill(Theme.placeholder)
                .frame(width: Metrics.actionButton, height: Metrics.actionButton)
        }
        #else
        VStack(alignment: .leading, spacing: Metrics.actionSpacing) {
            HStack(spacing: 8) { buttons }
            HStack(spacing: 10) {
                Circle().fill(Theme.placeholder).frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 4).fill(Theme.placeholder).frame(width: 80, height: 12)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder).frame(width: 28, height: 28)
            }
            .frame(height: Metrics.accountRow)
        }
        #endif
    }

    private var buttons: some View {
        ForEach(0..<4, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder)
                .frame(width: Metrics.actionButton, height: Metrics.actionButton)
        }
    }
}

#if os(macOS)
/// Mac 的侧边栏。展开时上面是会话列表、底部是 action 区；收起时只留一列图标。
/// 一行就是一个会话和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        let current = model.current?.id
        Group {
            if model.sidebarCollapsed { rail(current) } else { expanded(current) }
        }
        // 从红绿灯按钮那一条下面开始
        .padding(.top, chrome.top + Metrics.gap - Metrics.padding)
    }

    private func expanded(_ current: Int?) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session, current: current == session.id, detached: model.detached.contains(session.id))
                        .overlay { source(session) }
                }
            }
            Spacer(minLength: Metrics.gap)
            ActionArea()
        }
        .padding(.leading, Metrics.sidebarLeading)
    }

    private func rail(_ current: Int?) -> some View {
        VStack(spacing: 8) {
            ForEach(model.sessions) { session in
                // 已经分离成独立窗口的画淡一点
                Circle().fill(session.tint).frame(width: 24, height: 24)
                    .opacity(model.detached.contains(session.id) ? 0.35 : 1)
                    .padding(6)
                    .background(current == session.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { source(session) }
            }
            Spacer(minLength: Metrics.gap)
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder).frame(width: 32, height: 32)
            }
            Circle().fill(Theme.placeholder).frame(width: 28, height: 28).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func source(_ session: Session) -> some View {
        SessionDragSource(tint: session.tint) {
            // 已经分离的，点一下把它的窗口提到前面
            if model.detached.contains(session.id) {
                openWindow(id: "session", value: session.id)
            } else {
                model.selected = session.id
            }
        } onDetach: { point in
            guard !model.detached.contains(session.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大；窗口左上角放在指针左上方，指针落在标题那一条上
            model.pendingPlacement = CGRect(origin: CGPoint(x: point.x - 60, y: point.y - 16),
                                            size: DetachedSession.windowSize(content: model.contentSize, chrome: chrome))
            openWindow(id: "session", value: session.id)
        }
    }
}
#endif
