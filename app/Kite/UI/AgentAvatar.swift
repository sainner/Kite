import SwiftUI

/// 代理头像：角色签名里的头像算式，画在 9×9 格的圆形小画布上（x、y 为 −4～4），圆外的格不画。
/// 同一角色的代理按实例 ID 取动画里不同的时刻；运行中才动。每帧按最大值放大，淡的图案在小尺寸下也看得清。
struct AgentAvatar: View {
    let design: EmblemDesign?
    let instance: String
    var animating = false
    /// 没有窗口：点色淡一些、偏灰。
    var washed = false
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let half = 4

    var body: some View {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        let pattern = design?.avatarPattern(accent: accent) ?? EmblemDesign.fallback.avatarPattern(accent: accent)
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
        let gray = DotColor(red: 0.6, green: 0.6, blue: 0.6)
        for (center, value) in cells {
            let shape = min(1, abs(value) * gain)
            if shape < 0.04 {
                let radius = pitch * 0.1
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                            with: .color(rest.color))
                continue
            }
            // 与签名一样从静息点长出来，颜色随大小从静息色混到本色
            var color = rest.mixed(with: value > 0 ? pattern.positive : pattern.negative, by: min(1, shape * 1.6))
            if washed { color = color.mixed(with: gray, by: 0.45); color.alpha *= 0.7 }
            canvas.fill(pattern.form.path(center: center, radius: pitch / 2 * (0.2 + 0.8 * shape)), with: .color(color.color))
        }
    }

    /// 实例 ID 换成动画里的起始时刻，同一角色的代理姿态各不相同。
    static func seed(_ id: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Double(hash % 10_000) / 10_000 * 20
    }
}

/// 停靠栏里一个实例的样子：代理是签名头像，其他实例是窗口类别图标。
/// 最小化的窗口实心；没有窗口的用同色相更灰更淡的底，加本色描边。
struct DockFace: View {
    enum Look {
        case agent(instance: String, design: EmblemDesign?)
        case tool(WindowAppearance)
    }

    let look: Look
    var windowless = false
    var running = false
    @Environment(\.self) private var environment

    var body: some View {
        switch look {
        case .agent(let instance, let design):
            ZStack {
                if !windowless { Circle().fill(Theme.card) }
                AgentAvatar(design: design, instance: instance, animating: running, washed: windowless)
                    .padding(1)
                    .clipShape(Circle())
            }
            .windowlessPlate(Circle(), tint: windowless ? baseColor(design) : nil)
        case .tool(let appearance):
            let shape = RoundedRectangle(cornerRadius: Metrics.dockRadius, style: .continuous)
            ZStack {
                if !windowless { shape.fill(appearance.tint) }
                Image(systemName: appearance.icon)
                    .font(Theme.title)
                    .foregroundStyle(windowless ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.ink))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowlessPlate(shape, tint: windowless ? appearance.tint : nil, opacity: 0.35)
        }
    }

    private func baseColor(_ design: EmblemDesign?) -> Color {
        (design ?? .fallback).positiveColor(accent: DotColor(Color.accentColor.resolve(in: environment))).color
    }
}

extension View {
    /// 没有窗口的样子：同色相更灰更淡的底，加本色描边；tint 为 nil 时不加。
    @ViewBuilder
    func windowlessPlate(_ shape: some InsettableShape, tint: Color?, opacity: Double = 0.18) -> some View {
        if let tint {
            background {
                shape.fill(Theme.background)
                shape.fill(tint.mix(with: .gray, by: 0.3).opacity(opacity))
            }
            .overlay { shape.strokeBorder(tint, lineWidth: 1.5) }
        } else {
            self
        }
    }
}
