import SwiftUI

/// 代理头像：角色签名里的头像算式，画在 9×9 格的圆形小画布上（x、y 为 −4～4），圆外的格不画。
/// 同一角色的代理按实例 ID 取动画里不同的时刻；运行中才动。每帧按最大值放大，淡的图案在小尺寸下也看得清。
/// Mac 上动着的头像不经 SwiftUI 逐帧更新（见 AvatarFrames）：停靠栏的托管视图每帧整轮更新、再提交一次 Metal，比画头像本身贵得多。
struct AgentAvatar: View {
    let design: EmblemDesign?
    let instance: String
    var animating = false
    /// 需要处理时代替本色（正值的颜色）。
    var tint: Color?
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.avatarsPaused) private var avatarsPaused

    private static let half = 4

    var body: some View {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        let pattern = (design?.avatarPattern(accent: accent) ?? EmblemDesign.fallback.avatarPattern(accent: accent)).map(tinted)
        let rest = DotColor(Theme.dotRest.resolve(in: environment))
        let seed = Self.seed(instance)
        Group {
            #if os(macOS)
            if animating, !reduceMotion, let pattern {
                AvatarFrames(pattern: pattern, rest: rest, seed: seed)
                    .allowsHitTesting(false)
            } else {
                frames(pattern: pattern, rest: rest, seed: seed)
            }
            #else
            frames(pattern: pattern, rest: rest, seed: seed)
            #endif
        }
        .accessibilityHidden(true)
    }

    private func frames(pattern: DotPattern?, rest: DotColor, seed: Double) -> some View {
        TimelineView(.animation(minimumInterval: Self.interval, paused: !animating || reduceMotion || avatarsPaused)) { context in
            let t = animating && !reduceMotion ? Self.time(seed: seed, at: context.date) : seed
            Canvas { canvas, size in
                guard let pattern else { return }
                for cell in Self.cells(pattern, rest: rest, at: t, size: size) {
                    canvas.fill(cell.path, with: .color(cell.color.color))
                }
            }
        }
    }

    /// 动画最多每秒 24 帧。
    static let interval: TimeInterval = 1.0 / 24

    /// 动画里的时刻：实例的起始时刻加上现在（按一小时取余，免得数太大丢精度）。
    nonisolated static func time(seed: Double, at date: Date) -> Double {
        seed + date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }

    /// t 时刻各格画什么：轮廓（画布坐标，左上为原点）和填色。SwiftUI 的 Canvas 和 Mac 的 AvatarFrames 都按它画。
    static func cells(_ pattern: DotPattern, rest: DotColor, at t: Double, size: CGSize) -> [(path: Path, color: DotColor)] {
        let half = Self.half, n = 2 * half + 1
        let pitch = min(size.width, size.height) / CGFloat(n)
        var scope = DotExpression.Scope()
        scope[.t] = t
        scope[.w] = Double(n)
        scope[.h] = Double(n)
        scope[.px] = 999
        scope[.py] = 999
        scope[.d] = hypot(999, 999)
        var values: [(center: CGPoint, value: Double)] = []
        for row in 0..<n {
            for column in 0..<n {
                let x = Double(column - half), y = Double(row - half)
                guard hypot(x, y) <= Double(half) + 0.6 else { continue }
                scope[.x] = x
                scope[.y] = y
                scope[.i] = Double(row * n + column)
                scope[.r] = hypot(x, y)
                scope[.a] = atan2(y, x)
                values.append((CGPoint(x: (CGFloat(column) + 0.5) * pitch, y: (CGFloat(row) + 0.5) * pitch),
                               pattern.expression.evaluate(scope)))
            }
        }
        let largest = values.reduce(0) { max($0, abs($1.value)) }
        let gain = largest > 0.05 ? min(4, 0.95 / largest) : 1
        return values.map { center, value in
            let shape = min(1, abs(value) * gain)
            if shape < 0.04 {
                let radius = pitch * 0.1
                return (Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)), rest)
            }
            // 与签名一样从静息点长出来，颜色随大小从静息色混到本色
            let color = rest.mixed(with: value > 0 ? pattern.positive : pattern.negative, by: min(1, shape * 1.6))
            return (pattern.form.path(center: center, radius: pitch / 2 * (0.2 + 0.8 * shape)), color)
        }
    }

    private func tinted(_ pattern: DotPattern) -> DotPattern {
        guard let tint else { return pattern }
        var pattern = pattern
        pattern.positive = DotColor(tint.resolve(in: environment))
        return pattern
    }

    /// 实例 ID 换成动画里的起始时刻，同一角色的代理姿态各不相同。
    static func seed(_ id: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Double(hash % 10_000) / 10_000 * 20
    }
}

/// 停靠栏里一个实例的样子：代理是签名头像，其他实例是窗口类别图标。没有窗口的缩成小头像，样子不另外区分。
/// 代理头像描一圈本色：方形点阵裁成圆后边界不清；需要处理时本色换成状态色，点和描边一起换，大小头像一样。
/// 工具的圆角和图标随格子大小缩放。
struct DockFace: View {
    enum Look {
        case agent(instance: String, design: EmblemDesign?)
        case tool(WindowAppearance)
    }

    let look: Look
    var running = false
    /// 需要处理的状态色，代替代理头像的本色。
    var tint: Color?
    /// 窗口正看得到时指向它的箭头（SF Symbol 名）：头像或图标模糊，上面画箭头，不显示状态。
    var arrow: String?
    /// 代理头像的描边由自己画。为 false 时交给外面的容器，颜色经 DockRingColor 报上去：最小化的窗口卡片把它画在外框上，见 CardView。
    var ring = true
    @Environment(\.self) private var environment
    @Environment(\.dockFaceScale) private var faceScale

    static let ringWidth: CGFloat = 1

    var body: some View {
        switch look {
        case .agent(let instance, let design):
            let base = (design ?? .fallback).baseColor(in: environment)
            let ringColor = arrow == nil ? tint ?? base : base
            // 描边、留边、模糊按画出来的大小，在停靠栏的面板里随头像缩放时不跟着变细，见 dockFaceScale
            Circle().fill(Theme.card)
                .overlay {
                    if let arrow {
                        AgentAvatar(design: design, instance: instance)
                            .blur(radius: 3 / faceScale).opacity(0.55).clipShape(Circle())
                        DockArrow(symbol: arrow, faceScale: faceScale).foregroundStyle(base)
                    } else {
                        AgentAvatar(design: design, instance: instance, animating: running, tint: tint)
                            .padding(1 / faceScale)
                            .clipShape(Circle())
                    }
                }
                .overlay { if ring { Circle().strokeBorder(ringColor, lineWidth: Self.ringWidth / faceScale) } }
                .preference(key: DockRingColor.self, value: ring ? nil : ringColor)
        case .tool(let appearance):
            // 底色定大小，图标叠在上面：图标按原字号排版，放进小头像会比格子宽，不能让它撑开底色
            // 圆角和图标按格子大小等比缩放，停靠格大小时圆角正好是 dockRadius
            GeometryReader { proxy in
                let scale = min(proxy.size.width, proxy.size.height) / Metrics.dragBubble
                RoundedRectangle(cornerRadius: Metrics.dockRadius * scale, style: .continuous).fill(appearance.tint)
                    .overlay {
                        ZStack {
                            Image(systemName: appearance.icon)
                                .blur(radius: arrow == nil ? 0 : 3 / faceScale).opacity(arrow == nil ? 1 : 0.55)
                            if let arrow { Image(systemName: arrow).scaleEffect(1 / faceScale) }
                        }
                        .font(Theme.title)
                        .foregroundStyle(Theme.ink)
                        .scaleEffect(scale)
                    }
            }
        }
    }
}

/// 代理头像上的箭头：照家族格里头像的字号，画出来比它小的（小头像）按比例缩小；faceScale 见 dockFaceScale。
private struct DockArrow: View {
    let symbol: String
    let faceScale: CGFloat

    var body: some View {
        let reference = Metrics.dragBubble - 2 * DockGroup.inset(Metrics.dragBubble), scale = faceScale
        Image(systemName: symbol).font(Theme.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .visualEffect { content, proxy in
                content.scaleEffect(min(1, proxy.size.width * scale / reference) / scale)
            }
    }
}

/// 交给外面容器画的头像描边颜色，见 DockFace.ring。
struct DockRingColor: PreferenceKey {
    static let defaultValue: Color? = nil

    static func reduce(value: inout Color?, nextValue: () -> Color?) {
        value = value ?? nextValue()
    }
}

extension EmblemDesign {
    /// 头像的本色，最小化的头像用它描边；主题色按所在环境解析。
    func baseColor(in environment: EnvironmentValues) -> Color {
        positiveColor(accent: DotColor(Color.accentColor.resolve(in: environment))).color
    }
}

extension AgentAvatar {
    /// 不动的一帧头像（实例的起始时刻），对话里代理来信、子代理回报那一行用，原生视图直接放进图层：
    /// 卡片底色的圆、点阵、一圈本色描边，同停靠栏的 DockFace。design 为 nil 时用默认图案；diameter 是点，scale 是屏幕倍数。
    /// 画过的一样的（图案、姿态、大小、颜色都一样）不重画：工具步骤流式输出时每来一段都重新 show，各步的头像跟着重取。
    static func still(design: EmblemDesign?, instance: String, diameter: CGFloat, scale: CGFloat, environment: EnvironmentValues) -> CGImage? {
        let key = StillKey(design: design, instance: instance, diameter: diameter, scale: scale, accent: Color.accentColor.resolve(in: environment),
                           card: Theme.card.resolve(in: environment), rest: Theme.dotRest.resolve(in: environment))
        if let image = stills[key] { return image }
        guard let image = drawStill(key, environment: environment) else { return nil }
        if stills.count >= 256 { stills.removeAll() }
        stills[key] = image
        return image
    }

    private struct StillKey: Hashable {
        var design: EmblemDesign?
        var instance: String
        var diameter: CGFloat
        var scale: CGFloat
        var accent: Color.Resolved
        var card: Color.Resolved
        var rest: Color.Resolved
    }

    private static var stills: [StillKey: CGImage] = [:]

    private static func drawStill(_ key: StillKey, environment: EnvironmentValues) -> CGImage? {
        let (design, instance, diameter, scale) = (key.design, key.instance, key.diameter, key.scale)
        let accent = DotColor(key.accent)
        let pixels = Int((diameter * scale).rounded(.up))
        guard pixels > 0, let pattern = (design ?? .fallback).avatarPattern(accent: accent) ?? EmblemDesign.fallback.avatarPattern(accent: accent),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 格子按左上为原点算，位图原点在左下：上下翻过来
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let ring: CGFloat = 1
        context.addEllipse(in: bounds)
        context.clip()
        context.setFillColor(key.card.cgColor)
        context.fill(bounds)
        // 点阵往里留一个描边宽，同 DockFace 的 padding
        context.saveGState()
        context.translateBy(x: ring, y: ring)
        let rest = DotColor(key.rest)
        let inner = CGSize(width: diameter - ring * 2, height: diameter - ring * 2)
        for cell in cells(pattern, rest: rest, at: seed(instance), size: inner) {
            let color = cell.color
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
            context.addPath(cell.path.cgPath)
            context.fillPath()
        }
        context.restoreGState()
        context.setStrokeColor((design ?? .fallback).baseColor(in: environment).resolve(in: environment).cgColor)
        context.setLineWidth(ring)
        context.strokeEllipse(in: bounds.insetBy(dx: ring / 2, dy: ring / 2))
        return context.makeImage()
    }

    /// 对话里创建 agent 那一步的图标：签名按参数里的角色（没给时是默认角色，同工作机），姿态按建出来的实例，和停靠栏里那个代理一样，
    /// 还没建出来时按调用的 ID 取。角色目录没读到、找不到这个角色时用默认图案。
    static func still(creating call: Call, diameter: CGFloat, scale: CGFloat, environment: EnvironmentValues) -> CGImage? {
        var design: EmblemDesign?
        if let model = environment[AppModel.self], let area = environment[WorkArea.self], let catalog = model.roles(in: area) {
            let role = call.use.input["role"]?.string
            let match = if let role { catalog.roles.first { $0.id == role } } else { catalog.defaultRole }
            design = match?.emblem?.design
        }
        return still(design: design, instance: call.createdInstance ?? call.use.id, diameter: diameter, scale: scale, environment: environment)
    }

    /// 对话里头像的直径：比次要字的字号大一圈，和名字、通知那一句排在一行。
    static func inlineDiameter(font pointSize: CGFloat) -> CGFloat { (pointSize * 1.6).rounded() }

    /// 对话里某个实例的头像用哪个签名：按工作区里的实例找角色，找不到（别的工作区、Line）用默认图案。
    static func design(for instance: String, environment: EnvironmentValues) -> EmblemDesign? {
        guard let model = environment[AppModel.self], let area = environment[WorkArea.self] else { return nil }
        return model.emblem(for: instance, in: area)
    }

    /// 对话里点名的那个代理（告知的对象）：标题和签名。先在这个工作区里找，子工作区里的到别的工作区找；都没有为 nil。
    static func target(_ instance: String, environment: EnvironmentValues) -> (title: String, design: EmblemDesign?)? {
        guard let model = environment[AppModel.self], let area = environment[WorkArea.self] else { return nil }
        for candidate in [area] + model.workspaces {
            if let found = candidate.instances.first(where: { $0.id == instance }) {
                return (found.title, model.emblem(for: instance, in: candidate))
            }
        }
        return nil
    }

    /// 对话里告知 agent 那一步的图标：对方的头像，右下角挖掉一圈、放一个 color 色的纸飞机，在什么底色上都分得开。
    /// 对方找不到时用默认图案、按调用的 ID 取姿态，同创建 agent 那一步。
    static func still(telling call: Call, diameter: CGFloat, scale: CGFloat, color: CGColor, environment: EnvironmentValues) -> CGImage? {
        let instance = call.use.input["instanceId"]?.string
        let design = instance.flatMap { target($0, environment: environment) }?.design
        guard let face = still(design: design, instance: instance ?? call.use.id, diameter: diameter, scale: scale, environment: environment),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: face.width, height: face.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.draw(face, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        // 位图原点在左下，右下角是 x 大、y 小；挖掉的一圈比纸飞机大 1 点
        let badge = (diameter / 2).rounded()
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: diameter - badge, y: 0, width: badge, height: badge).insetBy(dx: -1, dy: -1))
        context.setBlendMode(.normal)
        // 符号按左上为原点画：上下翻过来
        context.translateBy(x: 0, y: diameter)
        context.scaleBy(x: 1, y: -1)
        drawSymbol("paperplane.fill", in: CGRect(x: diameter - badge, y: diameter - badge, width: badge, height: badge), color: color, context: context)
        return context.makeImage()
    }

    /// 在左上为原点、按点算的 context 里画一个符号，按比例放进 rect 正中。
    private static func drawSymbol(_ name: String, in rect: CGRect, color: CGColor, context: CGContext) {
        func fit(_ size: CGSize) -> CGRect {
            guard size.width > 0, size.height > 0 else { return rect }
            let ratio = min(rect.width / size.width, rect.height / size.height)
            let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
            return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        }
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: fit(image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        #else
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold))?
            .withTintColor(UIColor(cgColor: color), renderingMode: .alwaysOriginal) else { return }
        UIGraphicsPushContext(context)
        image.draw(in: fit(image.size))
        UIGraphicsPopContext()
        #endif
    }
}

#if os(macOS)
/// Mac 上动着的代理头像：按 AgentAvatar.cells 用 Core Graphics 画进图层，显示链接按帧换图（同 TimelineView 最多每秒 24 帧），
/// 不经 SwiftUI。在 SwiftUI 里逐帧画时，停靠栏整个托管视图每帧都要更新一轮、再提交一次 Metal（2026-10-14 实测，
/// 头像在跑时托管视图的更新约占主线程 4%，画头像本身约 1.5%）。不接点击、读屏看不见，外观照 Canvas 画的。
private struct AvatarFrames: NSViewRepresentable {
    let pattern: DotPattern
    let rest: DotColor
    let seed: Double

    func makeNSView(context: Context) -> AvatarFramesView { AvatarFramesView() }

    func updateNSView(_ view: AvatarFramesView, context: Context) {
        view.show(pattern: pattern, rest: rest, seed: seed)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AvatarFramesView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class AvatarFramesView: NSView {
    private var content: (pattern: DotPattern, rest: DotColor, seed: Double)?
    private var link: CADisplayLink?
    private var drawnAt: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(pattern: DotPattern, rest: DotColor, seed: Double) {
        if let content, content.pattern == pattern, content.rest == rest, content.seed == seed { return }
        content = (pattern, rest, seed)
        draw(at: .now)
    }

    override func layout() {
        super.layout()
        draw(at: .now)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 24, preferred: 24)
        link.add(to: .main, forMode: .common)
        self.link = link
        draw(at: .now)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw(at: .now)
    }

    @objc private func tick(_ link: CADisplayLink) {
        // 窗口被挡住时不画；同 TimelineView 的最小间隔，换帧按这一帧要显示的时刻
        guard window?.occlusionState.contains(.visible) == true, link.targetTimestamp - drawnAt >= AgentAvatar.interval - 0.004 else { return }
        drawnAt = link.targetTimestamp
        draw(at: Date(timeIntervalSinceNow: link.targetTimestamp - CACurrentMediaTime()))
    }

    private func draw(at date: Date) {
        guard let content, let layer, bounds.width > 0, bounds.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 格子按左上为原点算，位图原点在左下：上下翻过来
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let t = AgentAvatar.time(seed: content.seed, at: date)
        for cell in AgentAvatar.cells(content.pattern, rest: content.rest, at: t, size: bounds.size) {
            let color = cell.color
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
            context.addPath(cell.path.cgPath)
            context.fillPath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.contents = context.makeImage()
        CATransaction.commit()
    }
}
#endif

extension EnvironmentValues {
    /// 头像所在的那一层眼下看不见（紧凑布局收着的底栏只是透明，SwiftUI 不会因此停掉 TimelineView）：动着的头像停在当前帧。
    @Entry var avatarsPaused = false
}
