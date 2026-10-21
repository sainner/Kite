import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias StatusHostView = NSView
#else
typealias StatusHostView = UIView
#endif

/// 状态图层（圆环、脉冲）的宿主视图，两端共用：只显示，点按和读屏都穿过去；深浅色、强调色变了、进出窗口时让子类重设颜色和动画。
/// 坐标照 SwiftUI 左上角起往下为正（Mac 上翻转，iOS 的图层本来就是）。
class StatusLayerView: StatusHostView {
    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        // 系统强调色换了当场跟上（SwiftUI 不一定为它调 updateNSView）
        NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        #else
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.appearanceChanged()
        }
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func colorsChanged() { appearanceChanged() }

    /// 深浅色、强调色变了。
    func appearanceChanged() {}
    /// 进了窗口：图层动画离开窗口时会被拿掉，回来接着按绝对时间走。
    func enteredWindow() {}
    /// 尺寸变了、要重排图层。
    func layoutLayers() {}

    var backing: CALayer {
        #if os(macOS)
        layer!
        #else
        layer
        #endif
    }

    /// 图层坐标是不是左上角起往下为正。
    var flippedLayers: Bool {
        #if os(macOS)
        layer?.contentsAreFlipped() ?? true
        #else
        true
        #endif
    }

    /// 颜色按这个视图的深浅色解析成 SwiftUI 里同样的值。
    func resolve(_ color: Color, in environment: EnvironmentValues) -> Color.Resolved {
        var environment = environment
        #if os(macOS)
        environment.colorScheme = effectiveAppearance.isDark ? .dark : .light
        #else
        environment.colorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #endif
        return color.resolve(in: environment)
    }

    func markNeedsLayout() {
        #if os(macOS)
        needsLayout = true
        #else
        setNeedsLayout()
        #endif
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { enteredWindow() }
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { enteredWindow() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }
    #endif
}

/// 会话状态圆环：0.25 透明的底轨（运行中是锥形明暗渐变，否则纯色）上压一段上下文用量的弧（圆头，从 12 点顺时针）。
/// 运行中整圈顺时针转、一圈一个周期；正在压缩（running 的子状态）时不转，弧从 12 点画满一圈再从起点收掉；
/// 停止、收尾和等你回应时整圈按余弦明暗起伏（0.65～1）；空闲或减少动态效果时不动。
/// 转动和明暗起伏交给 Core Animation，跟屏幕刷新率走，主线程不逐帧重画。节奏按绝对时间对齐（timeIntervalSinceReferenceDate 取进度），
/// 几个圆环同阶段时同步。换状态时颜色、底轨、明暗、用量弧都从屏上此刻的样子过渡过去，转动也接着此刻的角度和速度走（见 ContextRingLayerView）。
struct ContextRingLayers {
    let phase: String
    let fraction: Double?
    let lineWidth: CGFloat
    let still: Bool

    fileprivate func update(_ view: ContextRingLayerView, environment: EnvironmentValues) {
        let color = ContextRing.color(phase)
        view.configure(.init(phase: phase, fraction: fraction, lineWidth: lineWidth, still: still, period: ContextRing.period(phase)),
                       color: color, environment: environment)
    }
}

#if os(macOS)
extension ContextRingLayers: NSViewRepresentable {
    func makeNSView(context: Context) -> ContextRingLayerView { ContextRingLayerView() }
    func updateNSView(_ view: ContextRingLayerView, context: Context) { update(view, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContextRingLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#else
extension ContextRingLayers: UIViewRepresentable {
    func makeUIView(context: Context) -> ContextRingLayerView { ContextRingLayerView() }
    func updateUIView(_ view: ContextRingLayerView, context: Context) { update(view, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContextRingLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif

final class ContextRingLayerView: StatusLayerView {
    struct Look: Equatable {
        var phase: String
        var fraction: Double?
        var lineWidth: CGFloat
        var still: Bool
        var period: Double
    }

    /// 换状态时颜色、底轨、明暗和用量弧过渡多久，曲线同台面的图层动画（不回弹）。
    private static let blendDuration: TimeInterval = 0.35

    /// 整圈：转动在这一层上。
    private let ring = CALayer()
    /// 明暗起伏在这一层上：不按组合成，透明度分别乘到底轨和弧上，弧压着底轨的地方底轨照样透上来。
    private let pulse = CALayer()
    /// 底轨：运行中是明暗渐变（锥形渐变按描边遮住），否则是纯色描边；整体 0.25 透明，两种之间淡入淡出。
    private let track = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    /// 上下文用量的弧，从 12 点顺时针。
    private let arc = CAShapeLayer()
    private var look: Look?
    private var color: Color = .secondary
    private var environment = EnvironmentValues()
    /// 圆环此刻怎么转，换状态时从这里接着走。
    private var spin = RingSpin.still
    /// 正在明暗起伏的周期，不起伏时为空。
    private var pulsing: Double?
    /// 压缩中的弧一来回的周期，不在压缩时为空。
    private var sweeping: Double?

    override init() {
        super.init()
        backing.addSublayer(ring)
        ring.addSublayer(pulse)
        pulse.allowsGroupOpacity = false
        track.fillColor = nil
        gradient.type = .conic
        gradient.mask = gradientMask
        gradientMask.fillColor = nil
        gradientMask.strokeColor = CGColor(gray: 0, alpha: 1)
        arc.fillColor = nil
        arc.lineCap = .round
        pulse.addSublayer(track)
        pulse.addSublayer(gradient)
        pulse.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ look: Look, color: Color, environment: EnvironmentValues) {
        let previous = self.look
        self.color = color
        self.environment = environment
        guard look != previous else { return }
        self.look = look
        if previous?.lineWidth != look.lineWidth { markNeedsLayout() }
        apply(animated: previous != nil)
    }

    override func appearanceChanged() { updateColors(animated: false) }

    // 离开窗口时图层动画会被拿掉，回来直接按现在的状态接着按绝对时间走，不再过渡
    override func enteredWindow() {
        guard look != nil else { return }
        spin = .still
        pulsing = nil
        sweeping = nil
        apply(animated: false)
    }

    /// 按现在的状态摆：animated 时从屏上此刻的样子过渡过去。
    private func apply(animated: Bool) {
        guard let look else { return }
        let now = CACurrentMediaTime()
        let rotating = look.phase == "running" && !look.still
        let sweeping = look.phase == "compacting" && !look.still
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateColors(animated: animated)
        blend(track, "opacity", to: Float(rotating ? 0 : 0.25), animated: animated)
        blend(gradient, "opacity", to: Float(rotating ? 0.25 : 0), animated: animated)
        blend(arc, "opacity", to: Float(sweeping || look.fraction != nil ? 1 : 0), animated: animated)
        updateStroke(sweep: sweeping ? look.period : nil, fraction: look.fraction, animated: animated, now: now)
        updatePulse(look.period > 0 && !rotating && !sweeping && !look.still ? look.period : nil, animated: animated, now: now)
        // 减少动态效果时不转，也不加转起来、停下来的过渡
        updateSpin(rotating ? look.period : nil, animated: animated && !environment.accessibilityReduceMotion, now: now)
        CATransaction.commit()
    }

    /// 颜色按这个视图的外观解析成 SwiftUI 里同样的值。
    private func updateColors(animated: Bool) {
        let resolved = resolve(color, in: environment)
        var faint = resolved
        faint.opacity *= 0.35
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blend(track, "strokeColor", to: resolved.cgColor, animated: animated)
        blend(arc, "strokeColor", to: resolved.cgColor, animated: animated)
        blend(gradient, "colors", to: [resolved.cgColor, faint.cgColor, resolved.cgColor], animated: animated)
        CATransaction.commit()
    }

    /// 把图层的一项改成新值；animated 时从屏上此刻的值过渡过去，否则当场换上并收掉还没走完的过渡。
    private func blend(_ layer: CALayer, _ keyPath: String, to value: Any, animated: Bool) {
        if let current = layer.value(forKeyPath: keyPath) as? NSObject, current.isEqual(value) { return }
        let shown = layer.presentation()?.value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard animated, let shown else {
            layer.removeAnimation(forKey: "blend-" + keyPath)
            return
        }
        layer.add(StageAnimation.basic(keyPath, from: shown, to: value, duration: Self.blendDuration), forKey: "blend-" + keyPath)
    }

    override func layoutLayers() {
        guard let look else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        pulse.frame = bounds
        let side = min(bounds.width, bounds.height)
        let circle = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        for shape in [track, arc] { shape.frame = bounds }
        for shape in [track, gradientMask, arc] { shape.lineWidth = look.lineWidth }
        track.path = CGPath(ellipseIn: circle, transform: nil)
        // 描边一半在边界外面：渐变层按边界裁，四周多留一截线宽
        let overhang = look.lineWidth
        gradient.frame = bounds.insetBy(dx: -overhang, dy: -overhang)
        gradientMask.frame = gradient.bounds
        gradientMask.path = CGPath(ellipseIn: circle.offsetBy(dx: overhang, dy: overhang), transform: nil)
        // 锥形渐变从 3 点钟方向起，同 AngularGradient 的起始角 0
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        arc.path = arcPath(in: circle)
        CATransaction.commit()
    }

    /// 从 12 点起顺时针一整圈：同 SwiftUI 的 Circle().trim 转 -90°。
    private func arcPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2
        // 图层坐标上下没翻转时，顺时针在数学上是角度变小
        let flipped = flippedLayers
        let start = flipped ? -CGFloat.pi / 2 : CGFloat.pi / 2
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: start + (flipped ? 2 : -2) * .pi, clockwise: !flipped)
        return path
    }

    // MARK: - 弧的长度

    /// 平时弧的终点是用量，没有用量时长度停在原处、整段淡出。正在压缩时弧从 12 点顺时针画满一圈、再从起点收掉：
    /// 起点 0→0→1，终点 0→1→1，一来回一个周期，两半各自缓入缓出。进压缩时从屏上此刻的弧接着画（用量弧就是画到半路的样子），
    /// 不过渡时按绝对时间对齐；出压缩时起点、终点从此刻的位置过渡回用量弧。
    private func updateStroke(sweep period: Double?, fraction: Double?, animated: Bool, now: CFTimeInterval) {
        let usage = fraction.map { CGFloat(min(max($0, 0), 1)) }
        guard period != sweeping else {
            if period == nil, let usage { blend(arc, "strokeEnd", to: usage, animated: animated) }
            return
        }
        sweeping = period
        let shown = arc.presentation()
        let start = shown?.strokeStart ?? arc.strokeStart, end = shown?.strokeEnd ?? arc.strokeEnd
        for key in ["sweep", "blend-strokeStart", "blend-strokeEnd"] { arc.removeAnimation(forKey: key) }
        guard let period else {
            let target = usage ?? end
            arc.strokeStart = 0
            arc.strokeEnd = target
            guard animated else { return }
            arc.add(StageAnimation.basic("strokeStart", from: start, to: CGFloat(0), duration: Self.blendDuration), forKey: "blend-strokeStart")
            arc.add(StageAnimation.basic("strokeEnd", from: end, to: target, duration: Self.blendDuration), forKey: "blend-strokeEnd")
            return
        }
        arc.strokeStart = 0
        let visible = (shown?.opacity ?? arc.opacity) > 0.01
        let progress = !animated ? Self.progress(now, period: period)
            : start > 0.001 ? 0.5 + Self.unease(Double(start)) / 2
            : visible ? Self.unease(Double(end)) / 2 : 0
        let steps = 60
        let samples = (0...steps).map { Self.sweep(Double($0) / Double(steps)) }
        let group = CAAnimationGroup()
        group.animations = [("strokeStart", samples.map { $0.start }), ("strokeEnd", samples.map { $0.end })].map { keyPath, values in
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.calculationMode = .linear
            animation.duration = period
            return animation
        }
        group.duration = period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.beginTime = arc.convertTime(now, from: nil) - progress * period
        arc.add(group, forKey: "sweep")
    }

    /// 压缩中的弧走到一个周期的 progress（0～1）时的起点和终点。
    private static func sweep(_ progress: Double) -> (start: Double, end: Double) {
        progress < 0.5 ? (0, ease(progress * 2)) : (ease(progress * 2 - 1), 1)
    }

    /// 缓入缓出（smoothstep）。
    private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// ease 的反函数：走到多远时长度是 y。
    private static func unease(_ y: Double) -> Double {
        0.5 - sin(asin(1 - 2 * min(max(y, 0), 1)) / 3)
    }

    // MARK: - 明暗起伏

    /// 停止、收尾、等你回应时整圈按余弦明暗起伏（0.65～1），节奏按绝对时间对齐。
    /// 换节奏或停下时从屏上此刻的亮度接过去：新节奏照常对齐，差的那一截叠加在上面、随过渡收掉。
    private func updatePulse(_ period: Double?, animated: Bool, now: CFTimeInterval) {
        guard period != pulsing else { return }
        pulsing = period
        let shown = pulse.presentation()?.opacity
        pulse.removeAnimation(forKey: "status")
        pulse.opacity = 1
        var target: Float = 1
        if let period {
            let steps = 60
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0...steps).map { Self.brightness(Double($0) / Double(steps)) }
            animation.calculationMode = .linear
            animation.duration = period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            let progress = Self.progress(now, period: period)
            animation.beginTime = pulse.convertTime(now, from: nil) - progress * period
            pulse.add(animation, forKey: "status")
            target = Self.brightness(progress)
        }
        guard animated, let shown, abs(shown - target) > 0.001 else {
            pulse.removeAnimation(forKey: "status-blend")
            return
        }
        let settle = StageAnimation.basic("opacity", from: shown - target, to: Float(0), duration: Self.blendDuration)
        settle.isAdditive = true
        pulse.add(settle, forKey: "status-blend")
    }

    private static func brightness(_ progress: Double) -> Float {
        Float(0.65 + 0.35 * cos(progress * 2 * .pi))
    }

    /// 媒体时间 time 时，按绝对时间对齐的节奏走到一个周期的哪里（0～1）。
    private static func progress(_ time: CFTimeInterval, period: Double) -> Double {
        let absolute = Date().timeIntervalSinceReferenceDate + (time - CACurrentMediaTime())
        return absolute.truncatingRemainder(dividingBy: period) / period
    }

    // MARK: - 转动

    /// 运行中整圈顺时针转，一圈一个周期，按绝对时间对齐。转起来、停下来都从此刻的角度和速度接着走：
    /// 转起来时加速追上对齐的节奏、速度接上；停下来时顺时针减速停在下一个整圈，弧回到 12 点。
    private func updateSpin(_ period: Double?, animated: Bool, now: CFTimeInterval) {
        guard period != spin.target else { return }
        let (angle, speed) = spin.state(at: now)
        if animated, let segment = Self.settle(from: angle.truncatingRemainder(dividingBy: 2 * .pi), speed: speed, to: period, at: now) {
            spin = .settling(segment, then: period)
        } else {
            spin = period.map { .steady(period: $0) } ?? .still
        }
        ring.removeAnimation(forKey: "spin")
        ring.removeAnimation(forKey: "spin-settle")
        // 角度按顺时针算；图层坐标上下没翻转时，顺时针在数学上是角度变小
        let sign: Double = flippedLayers ? 1 : -1
        switch spin {
        case .still:
            break
        case .steady(let period):
            ring.add(steadySpin(period, from: now, sign: sign), forKey: "spin")
        case .settling(let segment, let then):
            let steps = max(Int(segment.duration * 60), 1)
            let values = (0...steps).map { sign * segment.angle(Double($0) / Double(steps)) }
            let animation = StageKeyframes.make("transform.rotation.z", values, duration: segment.duration)
            animation.beginTime = ring.convertTime(segment.start, from: nil)
            ring.add(animation, forKey: "spin-settle")
            // 过渡走完那一刻接上对齐的转动；在那之前它还没开始，不挡过渡
            if let then { ring.add(steadySpin(then, from: segment.start + segment.duration, sign: sign), forKey: "spin") }
        }
    }

    private func steadySpin(_ period: Double, from start: CFTimeInterval, sign: Double) -> CAAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = sign * 2 * .pi
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = ring.convertTime(start, from: nil)
        animation.timeOffset = Self.progress(start, period: period) * period
        return animation
    }

    /// 从此刻的角度和速度接到目标的一段。要转：时长从短往长试，取第一段不倒转、最快不超过稳定转速 1.5 倍的，
    /// 终点是那一刻对齐的角度（可以多转几圈追上）。要停：按匀减速停在下一个整圈，太远时（超过 1.6 秒）放宽时长，
    /// 同样不倒转、不快过 1.5 倍。已经停着、或刚好停在整圈上时不用过渡。
    private static func settle(from angle: Double, speed: Double, to period: Double?, at now: CFTimeInterval) -> RingSpinSegment? {
        let turn = 2 * Double.pi
        if let period {
            let steady = turn / period
            let limit = 1.5 * max(steady, speed)
            for duration in stride(from: 0.4, through: 4, by: 0.05) {
                let aligned = progress(now + duration, period: period) * turn
                var end = aligned + turn * ((angle - aligned) / turn).rounded(.up)
                for _ in 0..<3 {
                    let segment = RingSpinSegment(start: now, duration: duration, from: angle, fromSpeed: speed, to: end, toSpeed: steady)
                    if segment.smooth(limit: limit) { return segment }
                    end += turn
                }
            }
            return nil
        }
        let end = turn * (angle / turn).rounded(.up)
        guard speed > 0, end > angle else { return nil }
        let stop = { (duration: Double) in RingSpinSegment(start: now, duration: duration, from: angle, fromSpeed: speed, to: end, toSpeed: 0) }
        // 匀减速要的时长，全程只减速
        let natural = 2 * (end - angle) / speed
        guard natural > 1.6 else { return stop(natural) }
        for duration in stride(from: 1.6, to: natural, by: 0.05) where stop(duration).smooth(limit: 1.5 * speed) {
            return stop(duration)
        }
        return stop(natural)
    }
}

/// 圆环的转动：顺时针转过的角度（弧度）随媒体时间走。
private enum RingSpin {
    case still
    /// 按绝对时间对齐地转，period 秒一圈。
    case steady(period: Double)
    /// 过渡段，走完接 then：为空时停在整圈上，否则按它的周期对齐地转。
    case settling(RingSpinSegment, then: Double?)

    /// 最终要转的周期，停着为空。
    var target: Double? {
        switch self {
        case .still: nil
        case .steady(let period): period
        case .settling(_, let then): then
        }
    }

    /// 媒体时间 time 时的角度和角速度。
    func state(at time: CFTimeInterval) -> (angle: Double, speed: Double) {
        switch self {
        case .still:
            return (0, 0)
        case .steady(let period):
            let absolute = Date().timeIntervalSinceReferenceDate + (time - CACurrentMediaTime())
            return (absolute.truncatingRemainder(dividingBy: period) / period * 2 * .pi, 2 * .pi / period)
        case .settling(let segment, let then):
            guard time < segment.start + segment.duration else {
                return then.map { RingSpin.steady(period: $0).state(at: time) } ?? (0, 0)
            }
            let s = max(time - segment.start, 0) / segment.duration
            return (segment.angle(s), segment.speed(s))
        }
    }
}

/// 一段转动的过渡：三次 Hermite，两头的角度和角速度都接上。
private struct RingSpinSegment {
    var start: CFTimeInterval
    var duration: Double
    var from: Double
    var fromSpeed: Double
    var to: Double
    var toSpeed: Double

    /// 走到 s（0～1）时的角度。
    func angle(_ s: Double) -> Double {
        let s2 = s * s, s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * from + (s3 - 2 * s2 + s) * duration * fromSpeed
            + (3 * s2 - 2 * s3) * to + (s3 - s2) * duration * toSpeed
    }

    /// 走到 s 时的角速度（弧度每秒）。
    func speed(_ s: Double) -> Double {
        let s2 = s * s
        return ((6 * s2 - 6 * s) * from + (3 * s2 - 4 * s + 1) * duration * fromSpeed
            + (6 * s - 6 * s2) * to + (3 * s2 - 2 * s) * duration * toSpeed) / duration
    }

    /// 全程不倒转，最快不超过 limit。
    func smooth(limit: Double) -> Bool {
        (0...32).allSatisfy { step in
            let speed = speed(Double(step) / 32)
            return speed >= -1e-9 && speed <= limit + 1e-9
        }
    }
}

/// 停靠栏头像的脉冲：实心的一圈从头像外缘往外扩、边扩边淡，交给 Core Animation，跟屏幕刷新率走。
/// 节奏按绝对时间对齐，同阶段的几个头像同步；减少动态效果时停在半路。
struct DockPulseLayers {
    let color: Color
    let period: Double
    /// 四周伸出头像的那一截。
    let margin: CGFloat
    let still: Bool

    fileprivate func update(_ view: DockPulseLayerView, environment: EnvironmentValues) {
        view.configure(.init(period: period, margin: margin, still: still), color: color, environment: environment)
    }
}

#if os(macOS)
extension DockPulseLayers: NSViewRepresentable {
    func makeNSView(context: Context) -> DockPulseLayerView { DockPulseLayerView() }
    func updateNSView(_ view: DockPulseLayerView, context: Context) { update(view, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockPulseLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#else
extension DockPulseLayers: UIViewRepresentable {
    func makeUIView(context: Context) -> DockPulseLayerView { DockPulseLayerView() }
    func updateUIView(_ view: DockPulseLayerView, context: Context) { update(view, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DockPulseLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif

final class DockPulseLayerView: StatusLayerView {
    struct Look: Equatable {
        var period: Double
        var margin: CGFloat
        var still: Bool
    }

    private let disc = CAShapeLayer()
    private var look: Look?
    private var color: Color = .secondary
    private var environment = EnvironmentValues()
    private var size = CGSize.zero

    override init() {
        super.init()
        disc.fillRule = .evenOdd
        backing.addSublayer(disc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ look: Look, color: Color, environment: EnvironmentValues) {
        let changed = look != self.look || color != self.color
        self.look = look
        self.color = color
        self.environment = environment
        if changed { restart() }
    }

    override func appearanceChanged() { restart() }
    override func enteredWindow() { restart() }

    override func layoutLayers() {
        if bounds.size != size {
            size = bounds.size
            restart()
        }
    }

    /// 走到 progress 时的那一圈：内圈是头像外缘，外圈往外扩 reach 个头像直径，颜色 0.6 × (1 - progress) 透明。
    private func shape(_ progress: Double, color: Color.Resolved) -> (path: CGPath, color: CGColor) {
        let margin = look?.margin ?? 0
        let side = min(bounds.width, bounds.height) - 2 * margin
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        for radius in [side / 2 + side * DockPulse.reach * progress, side / 2] {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        var faded = color
        faded.opacity *= Float(0.6 * (1 - progress))
        return (path, faded.cgColor)
    }

    private func restart() {
        guard let look, bounds.width > 0 else { return }
        let resolved = resolve(color, in: environment)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds
        disc.removeAllAnimations()
        let progress = look.still ? 0.5 : Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: look.period) / look.period
        let now = shape(progress, color: resolved)
        disc.path = now.path
        disc.fillColor = now.color
        CATransaction.commit()
        guard !look.still else { return }
        // 每个波从 0 走到 1（散尽、全透明），下一个波从头发；关键帧之间线性插值，跟屏幕刷新率走
        let steps = max(Int(look.period * 60), 2)
        let frames = (0...steps).map { shape(Double($0) / Double(steps), color: resolved) }
        let group = CAAnimationGroup()
        group.animations = [StageKeyframes.make("path", frames.map(\.path), duration: look.period),
                            StageKeyframes.make("fillColor", frames.map(\.color), duration: look.period)]
        group.duration = look.period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - progress * look.period
        disc.add(group, forKey: "pulse")
    }
}
