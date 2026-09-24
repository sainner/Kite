import SwiftUI

enum Theme {
    /// 整个 App 的底色，侧边栏直接铺在它上面，没有自己的底色。
    static let background = Color(red: 0.93, green: 0.92, blue: 0.90)
    static let card = Color.white
    /// 还没有内容时的占位色块。
    static let placeholder = Color.black.opacity(0.06)
    /// 占位里要显眼一点的，比如标题。
    static let strongPlaceholder = Color.black.opacity(0.16)
    /// 侧边栏里选中的一行。
    static let selection = Color.black.opacity(0.07)
    /// 会话窗口里人发的消息的气泡：agent 收到了是这个底色，排队中只描边。
    static let bubble = Color(red: 0.95, green: 0.94, blue: 0.92)
    static let bubbleStroke = Color.black.opacity(0.2)
    /// 代码、命令输出、表格的底。
    static let codeBackground = Color.black.opacity(0.04)
    /// 引用、子 agent 过程左边的竖线。
    static let rule = Color.black.opacity(0.12)
    static let added = Color.green.opacity(0.14)
    static let removed = Color.red.opacity(0.12)

    // 字号：两端用同一套 token，每个 token 是一种系统文本样式，多大由系统按平台定，iPhone 上还跟着系统的字号设置。
    // 视图里不写点数，都从这里取
    /// 标题栏的标题。
    static let title = Font.headline
    /// 对话正文、控制区的输入框。
    static let body = Font.body
    /// 次要的字：标题旁边的信息、折起来的一行、会话里的事件、展开后的详情。
    static let secondary = Font.subheadline
    /// 比次要的字再小一号：iPhone 上标题下面的次要信息。
    static let caption = Font.footnote
    /// 最小的字：控制区底下的状态信息。
    static let status = Font.caption
    /// 命令、输出、代码、改动。
    static let code = Font.system(.subheadline, design: .monospaced)
    /// agent 回复里的各级标题。
    static let heading1 = Font.title2.weight(.semibold)
    static let heading2 = Font.title3.weight(.semibold)
    static let heading3 = Font.headline
}

enum Metrics {
    /// 窗口内边距。
    static let padding: CGFloat = 10
    /// 卡片之间的缝，也是拖动调整大小的把手。
    static let gap: CGFloat = 10
    static let sidebarWidth: CGFloat = 240
    /// 侧边栏拖动调宽度的范围；拖到比 sidebarCollapse 还窄就收起。
    static let sidebarMin: CGFloat = 200
    static let sidebarMax: CGFloat = 400
    static let sidebarCollapse: CGFloat = 120
    /// 侧边栏自己的左边距，加上窗口内边距，和红绿灯按钮对齐。
    static let sidebarLeading: CGFloat = 10
    static let cardRadius: CGFloat = 12
    /// 卡片拖小时的下限。
    static let minPane: CGFloat = 160
    /// 按下后挪动多少才算拖动，免得单击也算。
    static let dragThreshold: CGFloat = 4
    /// Mac 上窗口标题栏的高度，标题在里面垂直居中；也是卡片拖动把手的高度。
    static let header: CGFloat = 40
    /// iPhone 上窗口标题栏底下的留白。状态栏的安全区底下本来空着一截（iPhone 17 上约 20pt），
    /// 所以标题栏上边不留、只在下边留一点，标题看着才在状态栏和栏底之间居中。
    static let phoneHeaderBottom: CGFloat = 8
    /// iPhone 上标题栏后面的渐变遮罩往下伸过标题栏底边多少。
    static let topFadeOverhang: CGFloat = 20
    /// iPhone 上标题栏里按钮（拉开侧边栏）的直径，和系统导航栏里的按钮一样大。
    static let headerButton: CGFloat = 44
    /// 拖出布局的卡片变成的圆。
    static let dragBubble: CGFloat = 40
    /// action 区：一排按钮、账号那一行，和两行之间的距离。
    static let actionButton: CGFloat = 36
    static let accountRow: CGFloat = 36
    static let actionSpacing: CGFloat = 10
    /// iPhone 上拉出侧边栏后窗口最少留多宽，要大于圆角的直径，圆角才不会变形。
    static let phoneMinWindow: CGFloat = 120
    /// iPhone 上页签那一行的高度，拉出 action 栏时出现在它上面。
    static let tabBar: CGFloat = 36
    /// iPhone 上拉出侧边栏的手势区，左边缘多宽。
    static let edgeZone: CGFloat = 24
    /// 控制区一行的高度，和输入框只有一行字时一样高；还没做的窗口按它画占位。
    static let controlHeight: CGFloat = 40
    /// 控制区那张玻璃卡片的最小圆角（离窗口的角近的角和窗口圆角同心，可能更大），和它离窗口左右边的距离；
    /// 底下没有安全区时离底边、打字时离键盘也是这么远。
    static let controlRadius: CGFloat = 22
    static let controlMargin: CGFloat = 12
    /// 控制区底下的安全区至少多高才放状态信息，放得下一行小字。
    static let statusMinHeight: CGFloat = 20
    /// 选 effort 的主刻度线的间距，一档占这么宽，拖过这么宽换一档。
    static let effortTick: CGFloat = 24
    /// 会话窗口里对话那一栏最宽多少，卡片再宽也不让一行字太长。
    static let transcriptWidth: CGFloat = 720
    /// 对话上下的留白，和相邻两行之间的间距。
    static let transcriptPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 14
    /// 气泡里文字离边的距离，左右和上下。
    static let bubblePadding = CGSize(width: 16, height: 12)
    /// 气泡里文字和代码块之间空多少，代码块里的字离框多远。
    static let messageSegmentGap: CGFloat = 8
    static let codePadding: CGFloat = 8
    /// agent 的话里块和块之间空多少；嵌套的列表每深一层往里缩多少；列表的编号占多宽（编号靠右对齐在里面）。
    static let markdownBlockGap: CGFloat = 10
    static let listIndent: CGFloat = 18
    static let listMarker: CGFloat = 14
    /// 对话里人发的消息和前后的内容之间、别的新一轮（Kite 发来的、后台任务通知）和上一轮之间，在平常的间距之外多空多少。
    static let messageGap: CGFloat = 12
    static let turnGap: CGFloat = 12
    /// 气泡的圆角，右下角小一点。形状在主线程之外也会取，所以标 nonisolated。
    nonisolated static let bubbleRadius: CGFloat = 18
    nonisolated static let bubbleTail: CGFloat = 6
    /// 发送时气泡从多低的地方往上浮进来。
    static let bubbleRise: CGFloat = 32
    /// 人发的消息折起来时显示多高，大约十行；比它高出不少才折（见 MessageBubble）。
    static let messageFold: CGFloat = 220
    /// 消息上面附件缩略图的高度。
    static let attachmentHeight: CGFloat = 96
    /// 对话里点一项弹出的操作栏：一个按钮多大，离这一项多远。Mac 上用鼠标点，小一号。
    #if os(macOS)
    static let actionBarButton: CGFloat = 28
    #else
    static let actionBarButton: CGFloat = 40
    #endif
    static let actionBarGap: CGFloat = 6
}
