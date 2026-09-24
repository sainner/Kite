import SwiftUI

enum Theme {
    /// 整个 App 的底色，侧边栏直接铺在它上面，没有自己的底色。
    static let background = Color(red: 0.93, green: 0.92, blue: 0.90)
    static let card = Color.white
    /// 还没有内容时的占位色块。
    static let placeholder = Color.black.opacity(0.06)
}

enum Metrics {
    /// 窗口内边距。
    static let padding: CGFloat = 10
    /// 卡片之间的缝，也是拖动调整大小的把手。
    static let gap: CGFloat = 10
    static let sidebarWidth: CGFloat = 240
    /// 侧边栏自己的左边距，加上窗口内边距，和红绿灯按钮对齐。
    static let sidebarLeading: CGFloat = 10
    /// 红绿灯按钮占的高度，侧边栏的内容从它下面开始。
    static let titleBar: CGFloat = 40
    static let cardRadius: CGFloat = 12
    /// 卡片拖小时的下限。
    static let minPane: CGFloat = 160
    /// 卡片标题栏的高度，Mac 上按住它拖动卡片。
    static let cardHeader: CGFloat = 40
    /// action 区：一排按钮、账号那一行，和两行之间的距离。
    static let actionButton: CGFloat = 36
    static let accountRow: CGFloat = 36
    static let actionSpacing: CGFloat = 10
    static var actionArea: CGFloat { actionButton + actionSpacing + accountRow }
    /// iPhone 上拉出侧边栏、action 栏的手势区：左边缘多宽、底边多高。
    static let edgeZone: CGFloat = 24
}
