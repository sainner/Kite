import SwiftUI

/// 状态用一个小圆点加文字：可用为主题色，需要处理为警示色（文字也用警示色），其余灰色。列表里每一项自己的状态用它。
struct StatusDotLabel: View {
    let title: String
    let color: Color
    var warns = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(Theme.caption)
        .foregroundStyle(warns ? Theme.warning : .secondary)
    }
}
