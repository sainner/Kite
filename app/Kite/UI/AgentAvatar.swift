import SwiftUI

/// 代理头像：角色签名里的头像算式，画在 9×9 格的圆形小画布上（x、y 为 −4～4），圆外的格不画。
/// 同一角色的代理按实例 ID 取动画里不同的时刻；运行中才动。每帧按最大值放大，淡的图案在小尺寸下也看得清。
struct AgentAvatar: View {
    let design: EmblemDesign?
    let instance: String
    var animating = false
    /// 需要处理时代替本色（正值的颜色）。
    var tint: Color?
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let half = 4

    var body: some View {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        let pattern = (design?.avatarPattern(accent: accent) ?? EmblemDesign.fallback.avatarPattern(accent: accent)).map(tinted)
        let rest = DotColor(Theme.dotRest.resolve(in: environment))
        let seed = Self.seed(instance)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animating || reduceMotion)) { context in
            let t = animating && !reduceMotion
                ? seed + context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : seed
            Canvas { canvas, size in
                if let pattern { draw(pattern, rest: rest, at: t, in: &canvas, size: size) }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ pattern: DotPattern, rest: DotColor, at t: Double, in canvas: inout GraphicsContext, size: CGSize) {
        let half = Self.half, n = 2 * half + 1
        let pitch = min(size.width, size.height) / CGFloat(n)
        var scope = DotExpression.Scope()
        scope[.t] = t
        scope[.w] = Double(n)
        scope[.h] = Double(n)
        scope[.px] = 999
        scope[.py] = 999
        scope[.d] = hypot(999, 999)
        var cells: [(center: CGPoint, value: Double)] = []
        for row in 0..<n {
            for column in 0..<n {
                let x = Double(column - half), y = Double(row - half)
                guard hypot(x, y) <= Double(half) + 0.6 else { continue }
                scope[.x] = x
                scope[.y] = y
                scope[.i] = Double(row * n + column)
                scope[.r] = hypot(x, y)
                scope[.a] = atan2(y, x)
                cells.append((CGPoint(x: (CGFloat(column) + 0.5) * pitch, y: (CGFloat(row) + 0.5) * pitch),
                              pattern.expression.evaluate(scope)))
            }
        }
        let largest = cells.reduce(0) { max($0, abs($1.value)) }
        let gain = largest > 0.05 ? min(4, 0.95 / largest) : 1
        for (center, value) in cells {
            let shape = min(1, abs(value) * gain)
            if shape < 0.04 {
                let radius = pitch * 0.1
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                            with: .color(rest.color))
                continue
            }
            // 与签名一样从静息点长出来，颜色随大小从静息色混到本色
            let color = rest.mixed(with: value > 0 ? pattern.positive : pattern.negative, by: min(1, shape * 1.6))
            canvas.fill(pattern.form.path(center: center, radius: pitch / 2 * (0.2 + 0.8 * shape)), with: .color(color.color))
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
    @Environment(\.self) private var environment

    var body: some View {
        switch look {
        case .agent(let instance, let design):
            let base = (design ?? .fallback).baseColor(in: environment)
            Circle().fill(Theme.card)
                .overlay {
                    if let arrow {
                        AgentAvatar(design: design, instance: instance)
                            .blur(radius: 3).opacity(0.55).clipShape(Circle())
                        Image(systemName: arrow).font(Theme.title).foregroundStyle(base)
                    } else {
                        AgentAvatar(design: design, instance: instance, animating: running, tint: tint)
                            .padding(1)
                            .clipShape(Circle())
                    }
                }
                .overlay { Circle().strokeBorder(arrow == nil ? tint ?? base : base, lineWidth: 1.5) }
        case .tool(let appearance):
            // 底色定大小，图标叠在上面：图标按原字号排版，放进小头像会比格子宽，不能让它撑开底色
            // 圆角和图标按格子大小等比缩放，停靠格大小时圆角正好是 dockRadius
            GeometryReader { proxy in
                let scale = min(proxy.size.width, proxy.size.height) / Metrics.dragBubble
                RoundedRectangle(cornerRadius: Metrics.dockRadius * scale, style: .continuous).fill(appearance.tint)
                    .overlay {
                        ZStack {
                            Image(systemName: appearance.icon)
                                .blur(radius: arrow == nil ? 0 : 3).opacity(arrow == nil ? 1 : 0.55)
                            if let arrow { Image(systemName: arrow) }
                        }
                        .font(Theme.title)
                        .foregroundStyle(Theme.ink)
                        .scaleEffect(scale)
                    }
            }
        }
    }
}

extension EmblemDesign {
    /// 头像的本色，最小化的头像用它描边；主题色按所在环境解析。
    func baseColor(in environment: EnvironmentValues) -> Color {
        positiveColor(accent: DotColor(Color.accentColor.resolve(in: environment))).color
    }
}
