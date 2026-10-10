import SwiftUI

/// 按钮在卡片里的位置按这个坐标空间量，按压从按钮中心发起。
nonisolated private let blockCardSpace = "BlockCard"

/// 标题栏按钮按下（true）与松开（false）时通知卡片，并给出按钮在卡片里的中心。
typealias BlockCardPress = (_ pressed: Bool, _ at: CGPoint) -> Void

/// 代码块、表格与上下文编辑器的块共用的卡片：标题栏左边是类别或块名，右边是操作按钮，有复制时复制始终在最右。
/// 按住标题栏按钮时卡片朝按钮的位置倾斜下沉，松手回弹；Mac 的 Force Touch 触控板按得越重压得越深，
/// 鼠标和 iPhone 没有压力数据，用固定深度。其他操作由使用方给出，排在复制左边，用 BlockCardButton 或 BlockCardPressable 接上 `press`。
struct BlockCard<Label: View, Actions: View, Content: View>: View {
    let label: Label
    var background: Color = Theme.codeBackground
    var radius: CGFloat = Metrics.contentRadius
    /// 复制按钮的说明与动作；没有时标题栏不放复制。
    let copy: (label: String, action: () -> Void)?
    let actions: (_ press: @escaping BlockCardPress) -> Actions
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var cardSize: CGSize = .zero
    @State private var pressLocation = UnitPoint.center
    /// 0 是静止；无压力数据时按住为 1，Force Touch 在 0.7～1.4 之间随力度变化。
    @State private var pressDepth: CGFloat = 0
    #if os(macOS)
    @State private var pressureMonitor: Any?
    #endif

    init(label: String, copyLabel: String, background: Color = Theme.codeBackground, radius: CGFloat = Metrics.contentRadius,
         copy: @escaping () -> Void, @ViewBuilder actions: @escaping (_ press: @escaping BlockCardPress) -> Actions,
         @ViewBuilder content: () -> Content) where Label == Text {
        self.label = Text(label)
        self.background = background
        self.radius = radius
        self.copy = (copyLabel, copy)
        self.actions = actions
        self.content = content()
    }

    /// 标题栏左边放自己的视图（如可改的名称），不带复制。
    init(background: Color = Theme.codeBackground, radius: CGFloat = Metrics.contentRadius,
         @ViewBuilder label: () -> Label, @ViewBuilder actions: @escaping (_ press: @escaping BlockCardPress) -> Actions,
         @ViewBuilder content: () -> Content) {
        self.label = label()
        self.background = background
        self.radius = radius
        copy = nil
        self.actions = actions
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let iconSize = Theme.body.resolve(in: fontContext).pointSize
        let tiltX = Double((0.5 - pressLocation.y) * 5 * pressDepth)
        let tiltY = Double((pressLocation.x - 0.5) * 5 * pressDepth)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.paneButtonGap) {
                label
                    .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 12)
                HStack(spacing: 0) {
                    actions(press)
                    if let copy { BlockCardButton("CodeCopy", label: copy.label, press: press, action: copy.action) }
                }
                .buttonStyle(PaneButtonStyle())
            }
            .foregroundStyle(.secondary)
            .padding(.leading, (Metrics.paneButton - iconSize) / 2 + Metrics.codeHeaderInset)
            .padding(.trailing, Metrics.paneToolbarInset)
            .padding(.vertical, Metrics.codeHeaderInset)
            .overlay(alignment: .bottom) { Divider() }
            content
                #if os(iOS)
                .modifier(BlockCardLongPress())
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: shape)
        .clipShape(shape)
        .buttonStyle(.pointingPlain)
        .coordinateSpace(name: blockCardSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
        .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .scaleEffect(1 - pressDepth * 0.012, anchor: pressLocation)
        #if os(macOS)
        .onDisappear(perform: stopPressureTracking)
        #endif
    }

    private func press(_ pressed: Bool, at point: CGPoint) {
        guard pressed else {
            #if os(macOS)
            stopPressureTracking()
            #endif
            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { pressDepth = 0 }
            return
        }
        guard !reduceMotion, cardSize.width > 0, cardSize.height > 0 else { return }
        pressLocation = UnitPoint(x: min(1, max(0, point.x / cardSize.width)),
                                  y: min(1, max(0, point.y / cardSize.height)))
        withAnimation(.snappy(duration: 0.12)) { pressDepth = 1 }
        #if os(macOS)
        startPressureTracking()
        #endif
    }

    #if os(macOS)
    /// 只在按住期间监听压力事件；第一阶段按压力 0～1 线性加深，到达用力点按（第二阶段）时最深。
    private func startPressureTracking() {
        stopPressureTracking()
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { event in
            let force = event.stage >= 2 ? 1 : CGFloat(min(max(event.pressure, 0), 1))
            MainActor.assumeIsolated {
                withAnimation(.interactiveSpring(duration: 0.15)) { pressDepth = 0.7 + 0.7 * force }
            }
            return event
        }
    }

    private func stopPressureTracking() {
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        pressureMonitor = nil
    }
    #endif
}

#if os(iOS)
extension EnvironmentValues {
    /// iPhone 上长按卡片内容弹出所在消息的操作栏。标题栏不接长按：高优先级的长按会压住按钮的按下状态，按压动效就出不来。
    @Entry var blockCardLongPress: (@MainActor () -> Void)?
}

private struct BlockCardLongPress: ViewModifier {
    @Environment(\.blockCardLongPress) private var action

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.4, maximumDistance: 8).onEnded { _ in action() })
        } else {
            content
        }
    }
}
#endif

/// 卡片标题栏上的操作按钮。
struct BlockCardButton: View {
    let asset: String
    let label: String
    let press: BlockCardPress
    let action: () -> Void

    init(_ asset: String, label: String, press: @escaping BlockCardPress, action: @escaping () -> Void) {
        self.asset = asset
        self.label = label
        self.press = press
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            BlockCardIcon(asset)
        }
        .help(label)
        .accessibilityLabel(label)
        .modifier(BlockCardPressable(press: press))
    }
}

/// 让标题栏上的按钮（含 ShareLink）按下、松开时驱动卡片按压。按压点取按钮中心：按钮相对卡片很小，和实际触点差别不大。
struct BlockCardPressable: ViewModifier {
    let press: BlockCardPress
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .buttonStyle(PressReportingStyle { pressed in press(pressed, CGPoint(x: frame.midX, y: frame.midY)) })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(blockCardSpace)) } action: { frame = $0 }
    }
}

/// 外观与 PaneButtonStyle 一致，额外报告按下状态。
private struct PressReportingStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        PaneButtonStyle().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// 卡片标题栏图标跟随正文字号，点击范围由统一按钮样式提供。
struct BlockCardIcon: View {
    let asset: String
    @Environment(\.fontResolutionContext) private var fontContext

    init(_ asset: String) {
        self.asset = asset
    }

    var body: some View {
        let size = Theme.body.resolve(in: fontContext).pointSize
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
