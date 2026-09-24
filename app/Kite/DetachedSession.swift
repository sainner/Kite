#if os(macOS)
import SwiftUI

/// 一个会话的窗口组，放在主窗口的内容区或独立窗口里。
struct SessionContent: View {
    let session: Session

    var body: some View {
        TilesLayer()
            .environment(session.workspace)
            .focusedSceneValue(session.workspace)
            .id(session.id)
    }
}

/// 从侧边栏分离出来的会话：没有侧边栏，顶上一条是会话的标题和信息，红绿灯在它左边，拖这一条移动窗口。
/// 卡片从这一条下面开始，不会伸进系统当作标题栏的区域。关掉窗口，会话回到主窗口。
struct DetachedSession: View {
    let id: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session(id) {
            VStack(spacing: 0) {
                SessionTitle(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Metrics.trafficLights)
                    .frame(height: Metrics.windowHeader)
                SessionContent(session: session)
                    .padding([.horizontal, .bottom], Metrics.padding)
            }
            .frame(minWidth: 600, minHeight: 400)
            .background(Theme.background)
            .ignoresSafeArea()
            .onAppear {
                model.detached.insert(id)
                model.pendingPlacement = nil
            }
            .onDisappear { model.detached.remove(id) }
        }
    }
}
#endif
