import SwiftUI

enum Theme {
    /// 整个 App 的底色，侧边栏直接铺在它上面，没有自己的底色。
    // 颜色资源带浅色、深色两套值，由当前窗口的外观解析。
    static let background = Color("WorkspaceBackground")
    static let card = Color("CardBackground")
    /// 还没有内容时的占位色块。
    static let placeholder = Color("Placeholder")
    /// 占位里要显眼一点的，比如标题。
    static let strongPlaceholder = Color("StrongPlaceholder")
    /// 侧边栏里选中的一行。
    static let selection = Color("Selection")
    /// 会话窗口里人发的消息的气泡：agent 收到了是主题色配白字，排队中只描边。
    static let bubble = Color.accentColor
    static let bubbleStroke = Color.accentColor.opacity(0.4)
    static let bubbleShape = UnevenRoundedRectangle(
        topLeadingRadius: Metrics.contentRadius, bottomLeadingRadius: Metrics.contentRadius,
        bottomTrailingRadius: Metrics.bubbleTail, topTrailingRadius: Metrics.contentRadius,
        style: .continuous)
    /// 代码、命令输出的底。
    static let codeBackground = Color("CodeBackground")
    /// 主题色用户气泡内的不透明蓝色代码底，随深浅外观调整。
    static let userCodeBackground = Color("UserCodeBackground")
    /// 引用、子 agent 过程左边的竖线。
    static let rule = Color("Rule")
    /// 工具列表的描边与分割线更浅一些。
    static let toolRule = rule.opacity(0.65)
    /// 点阵静息那颗点的颜色：墨蓝（深色雾白）叠透明度，与格子颜色在预乘透明度的 oklab 中混合。
    static let dotRest = Color("DotRest")
    /// 参考色只有黄蓝两个色相：新增用天空蓝，删除用错误色。
    static let added = Palette.breeze.opacity(0.22)
    static let removed = danger.opacity(0.14)
    /// 错误、删除与危险操作，参考色以外唯一的例外。
    static let danger = Color("Danger")
    /// 停止中、警示，取 Sunwashed 的深一档。
    static let warning = Color("Warning")
    /// 浅色填充（停靠图标、最小化窗口）上的图标色。
    static let ink = Color(red: 0.173, green: 0.271, blue: 0.4)

    // 字号：两端共用 token，常规文字采用系统文本样式，侧栏层级使用指定字号。
    // 视图里不写点数，都从这里取
    /// 标题栏的标题。
    static let title = Font.headline
    /// 对话正文、控制区的输入框。
    static let body = Font.body
    /// 次要的字：标题旁边的信息、折起来的一行、会话里的事件、展开后的详情。
    static let secondary = Font.subheadline
    /// 比次要的字再小一号：iPhone 上标题下面的次要信息。
    static let caption = Font.footnote
    /// 最小的字：状态 chip、工具信息与预览标注。
    static let status = Font.caption
    /// 侧栏项目与菜单标题。
    static let sidebarHeading = Font.system(size: 13, weight: .bold)
    /// 侧栏工作区名称。
    static let sidebarWorkspace = Font.system(size: 12)
    /// 账号额度圆环悬停时浮出的外圈剩余百分比。
    static let ringValue = Font.system(size: 11, weight: .bold).monospacedDigit()
    /// 侧栏检出所属的工作机名称。
    static let sidebarCheckout = Font.system(size: 10)
    /// 命令、输出、代码、改动。
    static let code = Font.system(.subheadline, design: .monospaced)
    /// 初始配置这类整页的大标题，直接压在背景上。
    static let display = Font.largeTitle.weight(.bold)
    /// agent 回复里的各级标题。
    static let heading1 = Font.title2.weight(.semibold)
    static let heading2 = Font.title3.weight(.semibold)
    static let heading3 = Font.headline
    /// 侧栏的「Kite」字标：思源宋体半粗，大小与 title3 相同并随系统字号缩放。
    /// 字体只含英文字符，按 OFL 改名为 Kite Wordmark，许可见 Resources/Fonts。
    #if os(macOS)
    static let wordmark = Font.custom("KiteWordmark-SemiBold", size: 15, relativeTo: .title3)
    #else
    static let wordmark = Font.custom("KiteWordmark-SemiBold", size: 20, relativeTo: .title3)
    #endif
}

/// 视觉参考色（规范见 docs/视觉风格.md）。界面里的彩色都从这里或由它派生的颜色资源取，不直接用系统色。
enum Palette {
    static let buttercup = Color(hex: 0xFFF2B2)
    static let dewy = Color(hex: 0xA8C6E7)
    static let sunwashed = Color(hex: 0xFFE08A)
    static let cloud = Color(hex: 0xFFF7D6)
    static let breeze = Color(hex: 0x7FA8D6)
    /// 中性的窗口类别色，终端等没有专属色的窗口用。
    static let stone = Color(hex: 0xDAD5C8)
}

/// 项目默认跟随系统文字色。自选主题色用来区分项目，是参考色板之外的例外：色相尽量拉开，
/// 避开错误色；明度取中等，在浅色和深色背景上都约有 3:1 的对比度，两种外观用同一个颜色，色板所见即所得。
enum ProjectTheme: String, CaseIterable, Identifiable {
    case primary, accent, green, purple, orange, pink
    var id: Self { self }

    var title: String {
        switch self {
        case .primary: "文字色"
        case .accent: "主题蓝"
        case .green: "草绿"
        case .purple: "紫"
        case .orange: "橙"
        case .pink: "粉"
        }
    }

    var color: Color {
        switch self {
        case .primary: .primary
        case .accent: .accentColor
        case .green: Color(hex: 0x4E9A5C)
        case .purple: Color(hex: 0x9670C8)
        case .orange: Color(hex: 0xC98420)
        case .pink: Color(hex: 0xCC6A9A)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Metrics {
    // 主要布局尺寸以 DotMetrics.module（12）为模数；侧栏水平留白单独设置。
    /// 窗口内边距，一个模块。
    static let padding: CGFloat = 12
    /// 卡片之间的缝，也是拖动调整大小的把手，一个模块。
    static let gap: CGFloat = 12
    /// 侧栏左右的外侧留白。
    static let sidebarInset: CGFloat = 12
    /// 菜单项与项目列表内容共用的左内边距。
    static let sidebarItemInset: CGFloat = 10
    static let sidebarWidth: CGFloat = 240
    /// 侧边栏拖动调宽度的范围；拖到比 sidebarCollapse 还窄就收起。松手后宽度吸附到模块。
    static let sidebarMin: CGFloat = 204
    static let sidebarMax: CGFloat = 396
    static let sidebarCollapse: CGFloat = 120
    /// 最小化插件窗口的圆角；agent 仍使用圆形。
    static let dockRadius: CGFloat = 12
    /// 卡片拖小时的下限。
    static var minPane: CGFloat { InputMode.current.isTouch ? 360 : 168 }
    /// 按下后挪动多少才算拖动，免得单击也算。
    static let dragThreshold: CGFloat = 4
    /// Mac 内容区外缘的拖放范围，在这里沿整个窗口组分栏。
    static let windowEdgeDrop: CGFloat = 32
    /// 输入区内部和工具条的点击区：Mac 使用紧凑尺寸，iPhone 保留触控尺寸。
    /// 独立玻璃入口通过系统 controlSize 决定。
    static var paneButton: CGFloat { InputMode.current.button }
    static var paneHeaderButton: CGFloat { InputMode.current.headerButton }
    /// 标题栏按钮组两端的留白：图标在按钮高度里的空白，减去按钮自带的半个间距。
    static var paneHeaderGroupInset: CGFloat { (paneHeaderButton - InputMode.current.labelExtent - paneHeaderButtonGap) / 2 }
    /// 触屏组内每个图标入口至少留出完整按钮宽度，避免只增加高度后仍挤在一起。
    static var paneHeaderButtonGap: CGFloat {
        InputMode.current.isTouch ? max(paneButtonGap, paneButton - InputMode.current.labelExtent) : paneButtonGap
    }
    static let paneButtonGap: CGFloat = 10
    /// 按钮到所属工具条容器的四边留白。
    static let paneToolbarInset: CGFloat = 8
    static let paneToolbarHeight: CGFloat = paneButton + 2 * paneToolbarInset
    /// 窗口四边的固定最小留白；已让出的安全区只补到这个值，不重复叠加。
    static var paneMargin: CGFloat { InputMode.current.paneMargin }
    /// 标题栏状态圆环占按钮方框的比例；方框每侧留下的空白计入圆环与标题之间的按钮间距。
    static let statusRingScale: CGFloat = 0.75
    static var statusRingMargin: CGFloat { paneHeaderButton * (1 - statusRingScale) / 2 }
    /// 主标题与尾部刷新图标之间的间距。
    static let titleRefreshGap: CGFloat = 3
    /// 刷新图标的命中与悬停范围向外扩出的距离，不影响排版；iPhone 保留触控尺寸。
    static var titleRefreshOutset: CGFloat { InputMode.current.titleOutset }
    /// 卡片和内部输入框保持同心。
    static var cardRadius: CGFloat { controlRadius + paneMargin }
    /// iPhone 上标题栏后面的渐变遮罩往下伸过标题栏底边多少。
    static let topFadeOverhang: CGFloat = 20
    /// 拖出布局或最小化后的窗口图标尺寸：Mac 三个模块，iPhone 四个模块，保留触控尺寸。
    static var dragBubble: CGFloat { InputMode.current.dockItem }
    /// Mac 右侧停靠栏与窗口图标同宽。
    static let dockWidth: CGFloat = dragBubble
    /// iPhone 上拉出侧边栏后窗口收成胶囊，宽度是圆角的直径；直径小于这个值时点不着，改留 phoneMinWindow 宽。
    static let phoneMinCapsule: CGFloat = 44
    /// 没有屏幕圆角可用时，拉出侧边栏后窗口留多宽。
    static let phoneMinWindow: CGFloat = 120
    /// iPhone 上页签那一行的高度，拉出 action 栏时出现在它上面。
    static let tabBar: CGFloat = dragBubble
    /// iPhone 上拉出侧边栏的手势区，左边缘多宽。
    static let edgeZone: CGFloat = 24
    /// 会话输入栏的顶部留白，文字左右在此基础上增加留白。
    static let controlInset: CGFloat = 8
    /// 按钮行左右和底部的留白，让末端按钮与玻璃面板的圆角同心。
    static var controlButtonInset: CGFloat { controlRadius - paneButton / 2 }
    /// 玻璃、交互范围与悬停轮廓共用。
    static var controlRadius: CGFloat { InputMode.current.controlRadius }
    /// 选 effort 的主刻度线的间距，一档占这么宽，拖过这么宽换一档。
    static let effortTick: CGFloat = 24
    /// 会话窗口里对话那一栏最宽多少，卡片再宽也不让一行字太长。
    static let transcriptWidth: CGFloat = 720
    /// 对话上下的留白，和相邻两行之间的间距。
    static let transcriptPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 14
    /// 工具列表的行内边距。
    static let toolRowInset: CGFloat = 10
    /// 工具标题行高度，视图中随系统字号缩放。
    static var toolRowHeight: CGFloat { InputMode.current.isTouch ? 36 : 32 }
    static let toolIcon: CGFloat = 16
    /// 工具组和工具详情卡片的圆角，比会话内容块小，不随 contentRadius 变化。
    static let toolGroupRadius: CGFloat = 8
    /// 图标、名字、摘要之间使用相同的间距。
    static let toolLabelGap: CGFloat = 6
    /// 气泡里文字离边的距离，左右和上下。
    static let bubblePadding = CGSize(width: 16, height: 12)
    /// 气泡里文字和代码块之间的间距。
    static let messageSegmentGap: CGFloat = 8
    /// 行内代码背景的内边距、与正文的外间距，以及统一字号比例。
    nonisolated static let inlineCodePadding: CGFloat = 4
    nonisolated static let inlineCodeGap: CGFloat = 2
    nonisolated static let inlineCodeRadius: CGFloat = 4
    static let inlineCodeFontScale: CGFloat = 0.9
    /// agent 的话里行距与块距随正文字号缩放：中文行高约为字号的 1.85 倍，块和块之间约空一个字，标题上方再多空半个块距。
    static func markdownLineSpacing(_ fontSize: CGFloat) -> CGFloat { (fontSize * 0.45).rounded() }
    static func markdownBlockGap(_ fontSize: CGFloat) -> CGFloat { (fontSize * 0.9).rounded() }
    /// 嵌套的列表每深一层往里缩多少；列表的编号占多宽（编号靠右对齐在里面）。
    /// 代码块标题栏的上下留白，以及左侧额外留白。
    static let codeHeaderInset: CGFloat = 4
    static let listIndent: CGFloat = 18
    static let listMarker: CGFloat = 14
    /// 文件图标与 favicon 到链接文字的统一间距。
    static let referenceIconGap: CGFloat = 2
    static let referenceIconScale: CGFloat = 0.85
    /// 两端文本渲染不同：Mac 沿用基线，iPhone 向下微调。
    #if os(iOS)
    static let referenceIconBaselineOffset: CGFloat = -1
    #else
    static let referenceIconBaselineOffset: CGFloat = 0
    #endif
    /// 对话里人发的消息和前后的内容之间、别的新一轮（Kite 发来的、后台任务通知）和上一轮之间，在平常的间距之外多空多少。
    static let messageGap: CGFloat = 12
    static let turnGap: CGFloat = 12
    /// 会话里的内容块（消息气泡、代码块、表格、附件、Kite 发的消息）共用的圆角；气泡右下角小一点。
    nonisolated static let contentRadius: CGFloat = 18
    nonisolated static let bubbleTail: CGFloat = 6
    /// 嵌在内容块里的块与外框同心：圆角是外框圆角减去两者间距，最小与气泡右下角一样。
    static func nestedRadius(inset: CGFloat) -> CGFloat { max(contentRadius - inset, bubbleTail) }
    /// 发送时气泡从多低的地方往上浮进来。
    static let bubbleRise: CGFloat = 32
    /// 人发的消息折起来时显示多高，大约十行；比它高出不少才折（见 MessageBubble）。
    static let messageFold: CGFloat = 220
    /// 折叠内容仅在末端短渐隐，展开按钮位于渐隐外。
    static let messageFoldFade: CGFloat = 20
    /// 消息上面附件缩略图的高度。
    static let attachmentHeight: CGFloat = 96
    /// 对话浮动操作栏离消息的距离。
    static let actionBarGap: CGFloat = 6
}

extension UnitCurve {
    /// 先快后慢，不过冲：1 − (1 − x)³。随时间走的展开、收起都用它：effort 的刻度线、iPhone 的抽屉。
    static let easeOutCubic = UnitCurve.bezier(startControlPoint: UnitPoint(x: 1.0 / 3, y: 1),
                                               endControlPoint: UnitPoint(x: 2.0 / 3, y: 1))
}
