import SwiftUI

/// 窗口的一帧。轮廓、正文和头像共用这份状态，不能各自从目标值启动动画。
nonisolated struct WindowPose: Equatable {
    var frame: CGRect
    var scale: CGFloat = 1
    var radius: CGFloat = 16
    var contentOpacity: Double = 1
    var iconOpacity: Double = 0

    func interpolated(to other: Self, progress: Double) -> Self {
        let p = CGFloat(progress)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return Self(frame: CGRect(x: mix(frame.minX, other.frame.minX), y: mix(frame.minY, other.frame.minY),
                                  width: mix(frame.width, other.frame.width), height: mix(frame.height, other.frame.height)),
                    scale: mix(scale, other.scale), radius: mix(radius, other.radius),
                    contentOpacity: contentOpacity + (other.contentOpacity - contentOpacity) * progress,
                    iconOpacity: iconOpacity + (other.iconOpacity - iconOpacity) * progress)
    }

    /// 正文横向居中、底边固定，尺寸只在目标改变时重排一次。
    func contentOrigin(size: CGSize) -> CGPoint {
        CGPoint(x: frame.midX - size.width * scale / 2, y: frame.maxY - size.height * scale)
    }

    /// 标题两侧贴着这一帧的外框：相对正文排版位置，左侧右移、右侧左移 dx，两侧都下移 dy。
    func headerShift(contentSize: CGSize) -> CGVector {
        CGVector(dx: (contentSize.width - frame.width / scale) / 2, dy: contentSize.height - frame.height / scale)
    }
}

nonisolated enum WindowMotionKind {
    case immediate, settle, preview, tracking

    /// 逐帧取样与 SwiftUI 排布动画共用曲线和时长，窗口与停靠栏保持同步。
    static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0),
                                       endControlPoint: UnitPoint(x: 0, y: 1))

    var duration: TimeInterval {
        switch self {
        case .immediate: 0
        case .settle: 0.3
        case .preview, .tracking: 0.2
        }
    }

    /// SwiftUI 排布动画，与逐帧取样同曲线同时长。
    var animation: Animation { .timingCurve(Self.curve, duration: duration) }
}

/// 只在目标改变时更新。TimelineView 负责取帧，窗口内容不订阅逐帧状态。
/// 中途反向从当时的呈现状态继续；拖动中的指针移动平移整条轨迹，不反复重启缩小动画。
@MainActor @Observable
final class WindowMotion {
    private(set) var target: WindowPose
    private(set) var moving = false
    var interacting = false
    @ObservationIgnored private var source: WindowPose
    /// 从这次改变排好、交上去之后起算；之前取样都停在起点，见 move。
    @ObservationIgnored private var started: Date?
    @ObservationIgnored private var duration: TimeInterval = 0
    private var kind = WindowMotionKind.immediate
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// 这一段开始计时的那一刻（见 move），Mac 原生台面在这时把整段交给 Core Animation。
    @ObservationIgnored var onStart: ((WindowMotion) -> Void)?

    init(_ pose: WindowPose) { target = pose; source = pose }

    /// 排布动画进行中（缩小、恢复、让位、放下后归位），不含跟手拖动。
    var settling: Bool { moving && kind != .tracking }

    /// 跟手拖动：指针一动整条轨迹跟着平移，不能整段预先交出去。
    var tracking: Bool { kind == .tracking }

    /// 正在走的这一段从哪一刻起、走多久；还没开始计时或停着时为 nil。
    var flight: (start: Date, duration: TimeInterval)? {
        guard moving, duration > 0, let started else { return nil }
        return (started, duration)
    }

    /// 排布动画在停靠形状和台面形状之间变：缩小进停靠栏、从停靠栏恢复、拖动松手后展开。收进家族格的子代理没有头像，看正文。
    var changingForm: Bool { settling && (source.iconOpacity != target.iconOpacity || source.contentOpacity != target.contentOpacity) }

    func presentation(at date: Date) -> WindowPose {
        guard duration > 0 else { return target }
        guard let started else { return source }
        let fraction = min(max(date.timeIntervalSince(started) / duration, 0), 1)
        let progress = WindowMotionKind.curve.value(at: fraction)
        return source.interpolated(to: target, progress: progress)
    }

    /// 从 start 起 duration 秒里每 1/120 秒取一帧（含两端），整段交给 Core Animation 用（见 StageKeyframes）。
    func presentations(from start: Date, duration: TimeInterval) -> [WindowPose] {
        let steps = max(Int((duration * 120).rounded(.up)), 1)
        return (0...steps).map { presentation(at: start.addingTimeInterval(duration * Double($0) / Double(steps))) }
    }

    func move(to next: WindowPose, kind: WindowMotionKind, at date: Date = .now) {
        guard next != target || (kind == .immediate && moving) else { return }
        if kind == .tracking, self.kind == .tracking,
           next.frame.size == target.frame.size, next.scale == target.scale {
            let dx = next.frame.minX - target.frame.minX, dy = next.frame.minY - target.frame.minY
            source.frame = source.frame.offsetBy(dx: dx, dy: dy)
            if !moving { source = next }
            target = next
            return
        }
        source = presentation(at: date)
        target = next
        duration = kind.duration
        if self.kind != kind { self.kind = kind }
        completion?.cancel()
        generation += 1
        let current = generation
        // 没变不写：拖缝时每步都交新终点，读 moving 的几层不跟着每步更新
        if moving != (duration > 0) { moving = duration > 0 }
        guard moving else { source = next; started = date; return }
        // 改变排布的那次更新要重排几个窗口，几十毫秒后才画出第一帧（2026-10-11 Mac 三窗口实测 60～70 毫秒）。
        // 从动作时刻起算的话，第一帧已走过曲线的一半，窗口一出来就跳一大截；所以第一帧停在起点，等这次更新交上去再计时
        started = nil
        completion = Task { [weak self] in
            await Task.yield()
            guard let self, generation == current else { return }
            let start = Date.now
            started = start
            onStart?(self)
            do { try await Task.sleep(until: .now + .seconds(duration)) } catch { return }
            guard generation == current else { return }
            source = target
            self.duration = 0
            moving = false
            completion = nil
        }
    }
}

extension EnvironmentValues {
    @Entry var windowMotion: WindowMotion?
}

/// 按 motion 逐帧取样，只在动画进行中走。动画开始、结束只更新这一层，外面的窗口不跟着重算。
struct WindowClock<Content: View>: View {
    let motion: WindowMotion
    var paused = false
    @ViewBuilder let content: (WindowPose) -> Content

    var body: some View {
        TimelineView(.animation(paused: paused || !motion.moving)) { clock in
            content(motion.presentation(at: clock.date))
        }
    }
}

#if os(macOS)
/// 窗口的点阵层（CardView 的 backdrop）：托管在自己的视图里，窗口移动时只改外面的遮罩，里面整窗大小的点阵着色器不跟着卡片逐帧重画
/// （2026-10-11 Mac 实测，三个窗口并排缩小、恢复时，每帧多画三遍整窗点阵，掉到约 30 帧；挪进单独的视图后这部分开销消失）。
/// 只负责显示，点击和读屏都穿过去。
final class BackdropHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Mac 台面上卡片的正文（CardView）托管在这里，按停着的样子排一次；缩小、恢复途中只改外层图层的 sublayerTransform。
/// 正文若由 SwiftUI 几何效果缩放，SwiftUI 会把变换落到里面每个 AppKit 视图上（setFrameTransform、滚动区的 setBoundsOrigin），
/// 对话的滚动区和每个文本视图逐帧重排可见范围、按新比例重画字形（2026-10-12 Mac 实测：缩小、恢复后 0.5 秒里主线程忙 360～410 毫秒，
/// 一半以上花在这上面；离屏对照每帧 8～12 毫秒，只改外层图层后 1～4 毫秒）。
/// 外层图层的变换 AppKit 和 SwiftUI 都不知道：飞行中按停着时的位置命中，所以只在停着、看得见时接点击；
/// 收成停靠形状停着时整块隐藏，原尺寸摆着的文本视图不接光标和点击。
/// 外框裁切和淡出是这一层图层上的遮罩：SwiftUI 的 mask 加在 AppKit 视图上时，每帧按整个窗口区域的大小重画遮罩
/// （2026-10-12 Mac 实测，缩小、恢复各多 30～50 毫秒主线程）。缩放、平移放在里面一层：sublayerTransform 连遮罩一起变换。
/// 托管视图从窗口原点铺到这一层的右下角，里面的坐标就是窗口坐标：嵌套的托管视图按自己的原点报标题栏给滚动软边，
/// 软边却按窗口坐标比对，原点不在窗口左上角时对不上，软边当作上面没有浮着的元素，不再模糊（2026-10-12 Mac 实测，
/// 一列两个窗口时下面那个没有软边）；正文里按 .global 取位置的也一起对上。
final class HostedContentContainer: NSView, HostedContentSurface {
    let host: HostedContentView
    weak var motion: WindowMotion?
    var origin = CGPoint.zero {
        didSet { if origin != oldValue { needsLayout = true } }
    }
    /// 原生的正文（Mac 原生台面上的会话窗口外框，见 ThreadWindowView）：有它时托管视图只留一点、不跟着改尺寸，
    /// 正文按 nativeFrame（这一层的坐标）摆，缩放、裁切照样在外面这一层。
    var native: NSView? {
        didSet {
            guard native !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let native { mover.addSubview(native) }
            needsLayout = true
        }
    }
    var nativeFrame = CGRect.zero {
        didSet { if nativeFrame != oldValue { needsLayout = true } }
    }
    private let mover = FlippedView()
    private let clip = CAShapeLayer()
    private var frameState = HostedContentFrame()

    init(rootView: AnyView) {
        host = HostedContentView(rootView: rootView)
        // 尺寸由外面给，正文只按停着的大小排；不另算安全区，和放在卡片里时一样
        host.sizingOptions = []
        host.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        mover.addSubview(host)
        addSubview(mover)
        layer?.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mover.frame = bounds
        if let native {
            if host.frame != .zero { host.frame = .zero }
            if native.frame != nativeFrame { native.frame = nativeFrame }
        } else {
            host.frame = CGRect(x: -origin.x, y: -origin.y,
                                width: max(origin.x + bounds.width, 0), height: max(origin.y + bounds.height, 0))
        }
        // 排版只补摆模型值，不收进行中交给 Core Animation 的那一段
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(frameState)
        CATransaction.commit()
    }

    /// 停着、看得见时才接点击。命中时当场看动画状态：动作那一刻 SwiftUI 就按新排版重算悬停，等逐帧驱动交过来已经晚了，
    /// 会把整段正文的视图树遍历一遍（2026-10-12 Mac 实测，首帧约 3 毫秒）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let motion, !motion.moving, motion.target.contentOpacity > 0 else { return nil }
        return super.hitTest(point)
    }

    /// 交给 Core Animation 的那一段还在走，正文一直显示着（见 animate）。
    private var flying = false

    /// 摆到这一帧：交给 Core Animation 的那一段（有的话）收掉。
    func apply(_ state: HostedContentFrame) {
        flying = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer?.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight-path")
        clip.removeAnimation(forKey: "flight-opacity")
        place(state)
        CATransaction.commit()
    }

    /// 只摆模型值，不碰进行中的动画。
    private func place(_ state: HostedContentFrame) {
        frameState = state
        let shown = state.shown || flying
        if isHidden == shown { isHidden = !shown }
        guard let layer, let moverLayer = mover.layer else { return }
        // 改它时 AppKit 把里面所有图层标成要按新的缩放重画（_NSInvalidateSuggestedContentsScaleBelow），正文里的图片、文字整块重画
        // （2026-10-14 Mac 实测：拖侧栏改宽时停靠栏里收着的窗口每步换缩放，见 StageView.arrange），没变就不设
        let transform = CATransform3DMakeAffineTransform(state.transform)
        if !CATransform3DEqualToTransform(moverLayer.sublayerTransform, transform) { moverLayer.sublayerTransform = transform }
        clip.frame = layer.bounds
        clip.path = clipPath(state, in: layer)
        clip.opacity = Float(state.opacity)
    }

    /// 遮罩的路径按图层自己的坐标：图层没翻转时原点在左下，视图坐标（左上为原点）要上下翻过来。
    private func clipPath(_ state: HostedContentFrame, in layer: CALayer) -> CGPath {
        var rect = state.clip
        if !layer.contentsAreFlipped() { rect.origin.y = layer.bounds.height - rect.maxY }
        return WindowOutline.path(in: rect, radius: state.radius)
    }

    /// 整段交给 Core Animation：变换、遮罩的路径和透明度按 frames 逐帧走，飞行中一直看得见，模型值停在最后一帧。
    func animate(_ frames: [HostedContentFrame], duration: TimeInterval) {
        guard let last = frames.last, let layer, let moverLayer = mover.layer else { return }
        apply(last)
        flying = frames.contains(where: \.shown)
        place(last)
        moverLayer.add(StageKeyframes.make("sublayerTransform", frames.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0.transform)) },
                                           duration: duration), forKey: "flight")
        clip.add(StageKeyframes.make("path", frames.map { clipPath($0, in: layer) }, duration: duration), forKey: "flight-path")
        clip.add(StageKeyframes.make("opacity", frames.map { Float($0.opacity) }, duration: duration), forKey: "flight-opacity")
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 窗口背景照常能拖窗口，正文里按下不拖，和正文放在卡片里时一样。
final class HostedContentView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

#endif

/// 不可插值的排版位置。动画由 WindowMotion 统一采样，SwiftUI 不再额外补一次位移。
struct WindowTranslation: GeometryEffect {
    let point: CGPoint
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: point.x, y: point.y))
    }
}

nonisolated struct WindowOutline: Shape {
    let frame: CGRect
    let radius: CGFloat
    func path(in _: CGRect) -> Path { RoundedRectangle(cornerRadius: radius).path(in: frame) }

    /// 同样的圆角矩形（圆角按 RoundedRectangle 的 .circular，半径不超过短边的一半），给图层用。
    /// 每次都是四段直线加四段三次曲线，半径为零也一样：Core Animation 按控制点逐个插值路径，前后段数不同就不连贯。
    static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        // 四分之一圆的三次曲线近似
        let k = r * 0.552_284_749_8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                      control1: CGPoint(x: rect.maxX - r + k, y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.minY + r - k))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - r + k), control2: CGPoint(x: rect.maxX - r + k, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                      control1: CGPoint(x: rect.minX + r - k, y: rect.maxY), control2: CGPoint(x: rect.minX, y: rect.maxY - r + k))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + r - k), control2: CGPoint(x: rect.minX + r - k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 按时间均匀取的关键帧，线性插值（取得够密，曲线由取样给出）。
enum StageKeyframes {
    static func make(_ keyPath: String, _ values: [Any], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }
}

/// 标题按终点宽度排版，台面上的窗口缩小、恢复途中只露出两侧控件之间的部分：标题在自己这一侧的托管视图里，
/// 遮罩在那一层图层上（见 WindowHeaderAnchored），这里只报标题的左边，截得再多也不截到标题前面的按钮。
/// 不在台面的托管视图里（紧凑布局、单页）时外框和正文一样大，不用遮。
struct WindowHeaderTitleMask: ViewModifier {
    @Environment(\.windowHeaderTitleEdge) private var edge

    func body(content: Content) -> some View {
        if let edge {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("pane-header")).minX } action: { edge.minX = $0 }
        } else {
            content
        }
    }
}
