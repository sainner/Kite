import SwiftUI

/// 侧边栏里的一行，一个会话。没有自己的底色，选中时垫一层；标题来自真实会话或尚未提交的草稿。
struct SessionRow: View {
    let session: Session
    let current: Bool
    /// 分离成了独立窗口（Mac）。
    var detached = false
    var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.tint).frame(width: 10, height: 10)
            Text(session.title).font(Theme.body).lineLimit(1)
            Spacer(minLength: 0)
            if detached {
                Image(systemName: "macwindow").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(current ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// action 区保持原来的按钮槽位与底部信息行，只把已接通的入口放进对应位置。
struct ActionArea: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            buttons(size: Metrics.actionButton)
            connection(size: Metrics.actionButton)
        }
        #else
        if compact {
            VStack(spacing: 8) {
                buttons(size: 32)
                connection(size: 28).padding(.top, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: Metrics.actionSpacing) {
                HStack(spacing: 8) { buttons(size: Metrics.actionButton) }
                HStack(spacing: 10) {
                    Circle().fill(Theme.placeholder).frame(width: 28, height: 28)
                    Text(model.connected ? "已连接工作机" : "未连接工作机")
                        .font(Theme.secondary).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    connection(size: 28)
                }
                .frame(height: Metrics.accountRow)
            }
        }
        #endif
    }

    @ViewBuilder
    private func buttons(size: CGFloat) -> some View {
        Button { model.showNewSession = true } label: {
            Image(systemName: "square.and.pencil")
                .font(Theme.body)
                .frame(width: size, height: size)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("新会话")
        .accessibilityLabel("新会话")
        .disabled(!model.connected)
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder)
                .frame(width: size, height: size)
        }
    }

    private func connection(size: CGFloat) -> some View {
        Button { model.showConnection = true } label: {
            Image(systemName: "gearshape")
                .font(Theme.secondary)
                .frame(width: size, height: size)
                .background(Theme.placeholder, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("连接工作机")
        .accessibilityLabel("连接工作机")
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

    private func expanded(_ current: String?) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(model.listedSessions) { session in
                    SessionRow(session: session, current: current == session.id, detached: model.detached.contains(session.id))
                        .overlay { source(session) }
                }
            }
            Spacer(minLength: Metrics.gap)
            ActionArea()
        }
        .padding(.leading, Metrics.sidebarLeading)
    }

    private func rail(_ current: String?) -> some View {
        VStack(spacing: 8) {
            ForEach(model.listedSessions) { session in
                // 已经分离成独立窗口的画淡一点
                Circle().fill(session.tint).frame(width: 24, height: 24)
                    .opacity(model.detached.contains(session.id) ? 0.35 : 1)
                    .padding(6)
                    .background(current == session.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { source(session) }
            }
            Spacer(minLength: Metrics.gap)
            ActionArea(compact: true)
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
            guard !session.isDraft, !model.detached.contains(session.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大；窗口左上角放在指针左上方，指针落在标题那一条上。AppKit 的屏幕坐标 y 朝上
            let size = DetachedSession.windowSize(content: model.contentSize, chrome: chrome)
            model.pendingPlacement = CGRect(x: point.x - 60, y: point.y + 16 - size.height, width: size.width, height: size.height)
            openWindow(id: "session", value: session.id)
        }
    }
}
#endif
