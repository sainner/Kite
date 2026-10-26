import SwiftUI

/// 数字徽标：主题色胶囊上的白字。预览指认的编号在画面上的框边、截图里和输入框的缩略图上都是它（截图里经 ImageRenderer 渲成图）。
struct NumberBadge: View {
    let number: Int
    static let size: CGFloat = 18

    var body: some View {
        Text("\(number)")
            .font(Theme.ringValue)
            .foregroundStyle(.white)
            .frame(minWidth: Self.size, minHeight: Self.size)
            .background(Color.accentColor, in: Capsule())
            .allowsHitTesting(false)
    }
}
