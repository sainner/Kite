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
                Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(current ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 会话的标题和信息。现在只有占位色块。
struct SessionTitle: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(session.tint).frame(width: 10, height: 10)
            RoundedRectangle(cornerRadius: 4).fill(Theme.strongPlaceholder).frame(width: 140, height: 12)
            RoundedRectangle(cornerRadius: 4).fill(Theme.placeholder).frame(width: 80, height: 10)
        }
    }
}

/// action 区：第一行是一排按钮，比如会话；第二行是账号和个人设置。
/// Mac 上在侧边栏底部，iPhone 上从窗口底部拉出来。现在只有占位色块。
struct ActionArea: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.actionSpacing) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder)
                        .frame(width: Metrics.actionButton, height: Metrics.actionButton)
                }
            }
            HStack(spacing: 10) {
                Circle().fill(Theme.placeholder).frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 4).fill(Theme.placeholder).frame(width: 80, height: 12)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder).frame(width: 28, height: 28)
            }
            .frame(height: Metrics.accountRow)
        }
        .frame(height: Metrics.actionArea)
    }
}

#if os(macOS)
/// Mac 的侧边栏。展开时上面是会话列表、底部是 action 区；收起时只留一列图标。
/// 一行就是一个会话和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.sidebarCollapsed { rail } else { expanded }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session, current: model.current?.id == session.id, detached: model.detached.contains(session.id))
                        .overlay { source(session) }
                }
            }
            Spacer(minLength: Metrics.gap)
            ActionArea()
        }
        .padding(.top, Metrics.titleBar - Metrics.padding)
        .padding(.leading, Metrics.sidebarLeading)
    }

    private var rail: some View {
        VStack(spacing: 8) {
            ForEach(model.sessions) { session in
                // 已经分离成独立窗口的画淡一点
                Circle().fill(session.tint).frame(width: 24, height: 24)
                    .opacity(model.detached.contains(session.id) ? 0.35 : 1)
                    .padding(6)
                    .background(model.current?.id == session.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { source(session) }
            }
            Spacer(minLength: Metrics.gap)
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8).fill(Theme.placeholder).frame(width: 32, height: 32)
            }
            Circle().fill(Theme.placeholder).frame(width: 28, height: 28).padding(.top, 4)
        }
        .padding(.top, Metrics.titleBar - Metrics.padding)
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
        } onDetach: { point, window in
            guard !model.detached.contains(session.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大：去掉侧边栏和缝，顶上换成标题那一条；左上角落在指针附近
            let sidebar = model.sidebarCollapsed ? Metrics.rail : model.sidebarWidth
            let size = CGSize(width: window.width - sidebar - Metrics.gap, height: window.height - Metrics.padding + Metrics.windowHeader)
            model.pendingPlacement = CGRect(origin: CGPoint(x: point.x - 60, y: point.y - 16), size: size)
            openWindow(id: "session", value: session.id)
        }
    }
}
#endif
