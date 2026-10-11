import SwiftUI

extension EnvironmentValues {
    /// 所在 App 窗口的点阵舞台，一个窗口只有一个。
    @Entry var dotStage: DotStage?
    /// 所在卡片会移动时（窄屏的窗口），卡片停着时在哪；不动的地方为 nil。卡片里的图形摆在它上面，由卡片的点阵层画。
    @Entry var dotCarrier: DotCarrier?
    /// 图案可见的范围（窗口坐标；在会移动的卡片里是卡片坐标），见 dotClip()。
    @Entry var dotClip: CGRect?
    /// 所在滚动区正在滚动（拖动、惯性或程序滚动），见 dotClip()。
    @Entry var dotScrolling = false
}

extension View {
    /// 放在滚动区上：里面摆到点阵上的图案只在滚动区范围内显示，滚出卡片就不画；
    /// 和文字一样从标题栏、控制区后面滚过去，不在那里截掉。滚动时图案连续跟随，停下后吸附到最近的格位。
    func dotClip() -> some View { modifier(DotClip()) }
}

private struct DotClip: ViewModifier {
    @Environment(\.dotCarrier) private var carrier
    @State private var frame: CGRect?
    @State private var scrolling = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: { frame = $0 }
            .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
            .environment(\.dotClip, frame)
            .environment(\.dotScrolling, scrolling)
    }
}

/// 里面摆在点阵上的图形的 slot，由 DotMask 和 EmptyStage 报上来。
struct DotSlots: PreferenceKey {
    static let defaultValue: Set<String> = []

    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// 内容是否还在场：离场（淡出、滑走、收成停靠）一开始就设为 false，里面摆在点阵上的图形随之逐格收回，回到场上再摆回去。
/// 点阵是窗口共用的，不随视图的转场淡出或移走，也不能等转场结束、视图移除时才撤掉。
/// 由这一层直接告诉舞台：离场中的视图不再刷新（实测里面的 onChange 不触发），只有转场这一层还收得到变化。
struct DotsPresence: ViewModifier {
    let presented: Bool
    @Environment(\.dotStage) private var stage
    @State private var owner = "presence.\(UUID().uuidString)"
    @State private var slots: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(DotSlots.self) { new in
                stage?.setHidden(slots.subtracting(new), by: owner, false)
                stage?.setHidden(new, by: owner, !presented)
                slots = new
            }
            .onChange(of: presented, initial: true) { stage?.setHidden(slots, by: owner, !presented) }
            .onDisappear { stage?.release(slots, by: owner) }
    }
}

extension AnyTransition {
    /// 与别的转场组合：视图离场一开始，摆在点阵上的图案就收回。
    static var dotsPresence: AnyTransition { AnyTransition(DotsPresenceTransition()) }
}

private struct DotsPresenceTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(DotsPresence(presented: phase != .didDisappear))
    }
}

/// 点阵上的一块图案：自己只占位，图案交给所在窗口的舞台，按占位的实际位置摆上去。
/// 占位默认正好是 figure 的列数 × 行数个模块；给出 alignment 时铺满外面给的大小，图形按它对齐摆在里面，收回时的底色铺满整个占位。
/// 跟着内容滚动或随卡片移动时连续跟随，落在两格之间由点阵插值显示；停着时吸附到离占位最近的格位，不让插值把图案拆虚。
/// 所在内容离场（见 DotsPresence）或视图消失时逐格收回。
struct DotMask: View {
    let figure: DotFigure
    var alignment: Alignment?
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.dotClip) private var clip
    @Environment(\.dotScrolling) private var scrolling
    @State private var slot = "mask.\(UUID().uuidString)"
    @State private var area: CGRect?

    var body: some View {
        Color.clear
            .frame(width: CGFloat(figure.columns) * DotMetrics.pitch, height: CGFloat(figure.rows) * DotMetrics.pitch)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: {
                area = $0
                refresh()
            }
            .onChange(of: figure) { refresh() }
            .onChange(of: clip) { refresh() }
            .onChange(of: scrolling) { refresh() }
            .onDisappear { stage?.show(nil, in: .zero, slot: slot) }
            .frame(maxWidth: alignment == nil ? nil : .infinity, maxHeight: alignment == nil ? nil : .infinity,
                   alignment: alignment ?? .center)
            .preference(key: DotSlots.self, value: [slot])
            .allowsHitTesting(false)
    }

    private func refresh() {
        guard let area else { return }
        stage?.show(figure, in: area, placement: scrolling ? .exact : .nearest, clip: clip, slot: slot, carrier: carrier)
    }
}

/// 点阵的取景框，格子按窗口坐标对齐，不参与点击和读屏。画的是所在窗口舞台里落在自己范围内的那部分：静息网点、图案、波和轨迹。
/// 像素由 Metal 着色器（DotField.metal）画，CPU 每帧只算图形和轨迹那几格。
/// 所在环境给出卡片（dotCarrier）时是那张卡片的点阵层，只画摆在它上面的图形和图案；否则只画不在卡片上的。
struct DotCanvas: View {
    /// 画静息的点；为 false 时只画图案、波和轨迹。
    var drawsRest = true
    /// 画图案（点阵签名）。图案每帧逐格求值，只由所在窗口的取景框画；App 背景被不透明的窗口盖住，不再重算一遍。
    var drawsPatterns = true
    /// 另有取景框负责的范围（窗口坐标），这里不画也不求值。
    var excluding: [CGRect] = []
    /// 卡片正在走：屏幕上的一点对应卡片停着时的哪里，卡片上的图形按它跟着走，见 DotCarrier。
    var follow: DotCarrier.Mapping?
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.dotScope) private var scope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            // 放在缩放的窗口里时，按屏幕上的实际大小画，格子仍与 App 网格对齐。
            let scale = proxy.size.width > 0 ? global.width / proxy.size.width : 1
            if let stage {
                let live = stage.animating(in: global, carrier: carrier, patterns: drawsPatterns) && !reduceMotion
                TimelineView(.animation(paused: !live)) { timeline in
                    // 静息或减少动态效果时取波都已结束的时刻，直接画出静息的点。
                    let date = live ? timeline.date : .distantFuture
                    let field = stage.field(at: date, rest: .rest(in: environment), live: live, patterns: drawsPatterns, scope: scope,
                                            carrier: carrier, follow: follow)
                    Rectangle().fill(field.shader(origin: global.origin, scale: scale, pixel: 1 / max(displayScale, 1),
                                                  bounds: global, at: date, drawsRest: drawsRest, hidden: excluding))
                }
                // 逐帧刷新不带动画：否则所在视图离场时，每帧的更新都继承转场的动画，转场一直结束不了，视图移除不掉
                .transaction { $0.animation = nil }
            }
        }
        .mask {
            if excluding.isEmpty {
                Rectangle()
            } else {
                GeometryReader { proxy in
                    let global = proxy.frame(in: .global)
                    let scale = proxy.size.width > 0 ? global.width / proxy.size.width : 1
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        for rect in excluding {
                            path.addRect(CGRect(x: (rect.minX - global.minX) / scale, y: (rect.minY - global.minY) / scale,
                                                width: rect.width / scale, height: rect.height / scale))
                        }
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
import AppKit

extension View {
    /// 让所在 App 窗口按模块调整大小。
    func resizesByModule() -> some View {
        background(ModuleResizing())
    }
}

private struct ModuleResizing: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // 增量只管每次变多少，起点不齐会一直带着余数，所以起点也要落在模块上：
            // 窗口出现时（恢复的尺寸、最小尺寸都可能不齐）和每次拖完各对齐一次。
            // 全屏、分屏等系统给的尺寸不动，余下的不足一格留在右边和下边。
            window.contentResizeIncrements = NSSize(width: DotMetrics.pitch, height: DotMetrics.pitch)
            DispatchQueue.main.async { [weak window] in window.map(Self.alignToModule) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated { window.map(Self.alignToModule) }
            }
        }

        /// 内容区宽高向下取到模块的整数倍，但不小于最小尺寸；左上角不动。
        private static func alignToModule(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            let frame = window.frame
            var content = window.contentRect(forFrameRect: frame)
            let minimum = window.contentMinSize
            let size = NSSize(width: max(DotMetrics.snapDown(content.width), DotMetrics.snapUp(minimum.width)),
                              height: max(DotMetrics.snapDown(content.height), DotMetrics.snapUp(minimum.height)))
            guard size != content.size else { return }
            content.origin.y += content.height - size.height
            content.size = size
            window.setFrame(window.frameRect(forContentRect: content), display: true)
        }
    }
}
#endif
