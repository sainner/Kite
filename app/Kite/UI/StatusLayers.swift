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

/// 会话状态圆环的图层版：外观照 ContextRingFrame 逐项复刻，转动和明暗起伏交给 Core Animation，跟屏幕刷新率走，主线程不逐帧重画
/// （SwiftUI 版每秒 30 帧重算 body）。节奏按绝对时间对齐（同 SwiftUI 版按 timeIntervalSinceReferenceDate 取进度），几个圆环同阶段时同步。
struct ContextRingLayers {
    let phase: String
    let fraction: Double?
    let lineWidth: CGFloat
    let still: Bool
    #if DEBUG
    /// 对照用：停在一个周期里的这一处，见 StagePreview 的圆环对照。
    var frozen: Double?
    #endif

    fileprivate func update(_ view: ContextRingLayerView, environment: EnvironmentValues) {
        let color = ContextRing.color(phase)
        view.configure(.init(phase: phase, fraction: fraction, lineWidth: lineWidth, still: still, period: ContextRing.period(phase)),
                       color: color, environment: environment)
        #if DEBUG
        view.frozen = frozen
        #endif
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

    /// 整圈：转动、明暗都在这一层上。
    private let ring = CALayer()
    /// 底轨：运行中是明暗渐变（锥形渐变按描边遮住），否则是纯色描边；整体 0.25 透明。
    private let track = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    /// 上下文用量的弧，从 12 点顺时针。
    private let arc = CAShapeLayer()
    private var look: Look?
    private var color: Color = .secondary
    private var environment = EnvironmentValues()
    #if DEBUG
    var frozen: Double? {
        didSet { if frozen != oldValue { restartAnimations() } }
    }
    #endif

    override init() {
        super.init()
        backing.addSublayer(ring)
        track.fillColor = nil
        gradient.type = .conic
        gradient.mask = gradientMask
        gradientMask.fillColor = nil
        gradientMask.strokeColor = CGColor(gray: 0, alpha: 1)
        arc.fillColor = nil
        arc.lineCap = .round
        ring.addSublayer(track)
        ring.addSublayer(gradient)
        ring.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ look: Look, color: Color, environment: EnvironmentValues) {
        self.color = color
        self.environment = environment
        let changed = look != self.look
        self.look = look
        updateColors()
        if changed {
            markNeedsLayout()
            restartAnimations()
        }
    }

    override func appearanceChanged() { updateColors() }

    // 离开窗口时图层动画会被拿掉，回来接着按绝对时间转
    override func enteredWindow() { restartAnimations() }

    /// 颜色按这个视图的外观解析成 SwiftUI 里同样的值。
    private func updateColors() {
        let resolved = resolve(color, in: environment)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = resolved.cgColor
        arc.strokeColor = resolved.cgColor
        var faint = resolved
        faint.opacity *= 0.35
        gradient.colors = [resolved.cgColor, faint.cgColor, resolved.cgColor]
        CATransaction.commit()
    }

    override func layoutLayers() {
        guard let look else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        let circle = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let path = CGPath(ellipseIn: circle, transform: nil)
        let gradientShown = look.phase == "running" && !look.still
        for shape in [track, arc] { shape.frame = bounds }
        for shape in [track, gradientMask, arc] { shape.lineWidth = look.lineWidth }
        track.path = path
        track.isHidden = gradientShown
        gradient.isHidden = !gradientShown
        // 描边一半在边界外面：渐变层按边界裁，四周多留一截线宽
        let overhang = look.lineWidth
        gradient.frame = bounds.insetBy(dx: -overhang, dy: -overhang)
        gradientMask.frame = gradient.bounds
        gradientMask.path = CGPath(ellipseIn: circle.offsetBy(dx: overhang, dy: overhang), transform: nil)
        track.opacity = 0.25
        gradient.opacity = 0.25
        // 锥形渐变从 3 点钟方向起，同 AngularGradient 的起始角 0
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        if let fraction = look.fraction {
            arc.isHidden = false
            arc.path = arcPath(in: circle)
            arc.strokeEnd = min(max(fraction, 0), 1)
        } else {
            arc.isHidden = true
        }
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

    /// 运行中整圈顺时针转一圈一个周期；停止、收尾时整圈按余弦明暗起伏。节奏按绝对时间对齐。
    /// 明暗分别乘在底轨（0.25）和弧上，同 SwiftUI 的 opacity 加在 ZStack 上时各个子视图各自变淡：弧压着底轨的地方底轨照样透上来。
    private func restartAnimations() {
        for layer in [ring, track, gradient, arc] { layer.removeAnimation(forKey: "status") }
        guard let look, look.period > 0, !look.still else { return }
        let period = look.period
        var progress = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        #if DEBUG
        if let frozen { progress = frozen }
        #endif
        func start(_ animation: CAAnimation, on layer: CALayer) {
            animation.duration = period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - progress * period
            #if DEBUG
            if frozen != nil {
                animation.speed = 0
                animation.timeOffset = progress * period
                animation.beginTime = 0
            }
            #endif
            layer.add(animation, forKey: "status")
        }
        if look.phase == "running" {
            let flipped = flippedLayers
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (flipped ? 2 : -2) * CGFloat.pi
            start(spin, on: ring)
        } else {
            let steps = 60
            let pulse = (0...steps).map { 0.65 + 0.35 * cos(Double($0) / Double(steps) * 2 * .pi) }
            for (layer, base) in [(track, 0.25), (gradient, 0.25), (arc, 1.0)] as [(CALayer, Double)] {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = pulse.map { Float(base * $0) }
                animation.calculationMode = .linear
                start(animation, on: layer)
            }
        }
    }
}

/// 停靠栏头像的脉冲的图层版：外观照 DockPulseFrame 逐项复刻（实心的一圈从头像外缘往外扩、边扩边淡），交给 Core Animation，
/// 跟屏幕刷新率走。节奏按绝对时间对齐，同阶段的几个头像同步；减少动态效果时停在半路。
struct DockPulseLayers {
    let color: Color
    let period: Double
    /// 四周伸出头像的那一截。
    let margin: CGFloat
    let still: Bool
    #if DEBUG
    var frozen: Double?
    #endif

    fileprivate func update(_ view: DockPulseLayerView, environment: EnvironmentValues) {
        view.configure(.init(period: period, margin: margin, still: still), color: color, environment: environment)
        #if DEBUG
        view.frozen = frozen
        #endif
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
    #if DEBUG
    var frozen: Double? {
        didSet { if frozen != oldValue { restart() } }
    }
    #endif

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
        var progress = look.still ? 0.5 : Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: look.period) / look.period
        #if DEBUG
        if let frozen { progress = frozen }
        #endif
        let now = shape(progress, color: resolved)
        disc.path = now.path
        disc.fillColor = now.color
        CATransaction.commit()
        guard !look.still else { return }
        #if DEBUG
        if frozen != nil { return }
        #endif
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
