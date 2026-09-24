import SwiftUI

/// 侧边栏的列表，比如会话。没有自己的底色，现在只有占位色块。
struct SidebarList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Theme.placeholder).frame(height: 28)
            }
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
