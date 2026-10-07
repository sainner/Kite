import SwiftUI

/// 点阵视觉语言的几何：格 + 缝 = 步距，一格缩到点径时就是静息的那颗点。
/// 布局模数等于点阵步距，每个模块中心一颗点，布局边界就是点的格线。
nonisolated enum DotMetrics {
    /// 布局的模数：边距、缝、侧栏与卡片尺寸都取它的整数倍，边界落在模块线上。
    static let module: CGFloat = 12
    static let pitch: CGFloat = module
    static let cell: CGFloat = 10
    static let gap = pitch - cell
    static let dot: CGFloat = 2
    /// shape 为 0 那端相对满格的比例。
    static let restScale = Double(dot / cell)
    /// 一次形变的时长与曲线。
    static let morphDuration: TimeInterval = 0.5
    static let morph = Animation.easeOut(duration: morphDuration)

    static func snap(_ length: CGFloat) -> CGFloat { (length / module).rounded() * module }
    static func snapUp(_ length: CGFloat) -> CGFloat { (length / module).rounded(.up) * module }
    static func snapDown(_ length: CGFloat) -> CGFloat { (length / module).rounded(.down) * module }

    /// 第 (column, row) 格在窗口坐标中占的步距方块，点画在它的中心。
    static func square(column: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: pitch, height: pitch)
    }

    /// 一格与一块区域之间的距离（点）；重叠即 0。
    static func distance(between square: CGRect, and rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - square.maxX, square.minX - rect.maxX, 0)
        let dy = max(rect.minY - square.maxY, square.minY - rect.maxY, 0)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 一格的状态。形状与颜色是两条独立通道：shape 只管轮廓与大小，颜色按给定的 RGBA 画。
/// shape 为 0 时任何终态都是同一颗点，所以点阵是格子的静息态，而不是另一层纹理。
nonisolated struct Dot: Hashable, Sendable {
    var form: DotForm
    /// 0 是一颗点，1 是满格的终态；范围外按边界截断。
    var shape: Double
    var color: DotColor

    init(_ form: DotForm = .square, shape: Double = 0, color: DotColor) {
        self.form = form
        self.shape = shape
        self.color = color
    }

    var profile: DotProfile { form.profile(at: shape) }

    /// rect 是这一格的范围，终态按短边居中。几乎静息的格子直接画圆，铺满整片点阵时省去逐点轮廓。
    func path(in rect: CGRect) -> Path {
        guard shape > 1.0 / 512 else {
            let diameter = min(rect.width, rect.height) * DotMetrics.restScale
            return Path(ellipseIn: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                          width: diameter, height: diameter))
        }
        return profile.path(in: rect)
    }
}

/// 一格最终长成的样子。新增终态只需给出一条以格心为中心、落在 [-1, 1] 内的闭合轮廓。
nonisolated enum DotForm: String, CaseIterable, Hashable, Codable, Sendable {
    case square, circle, diamond, kite, star, heart, plus

    var title: String {
        switch self {
        case .square: "圆角方块"
        case .circle: "圆"
        case .diamond: "菱形"
        case .kite: "风筝"
        case .star: "星"
        case .heart: "心"
        case .plus: "十字"
        }
    }

    /// 先在点圆与终态轮廓之间混合，再按 Pigeon 的比例从点径长到满格；
    /// 因为所有终态共用同一组采样角，换终态时两条轮廓也能直接插值。
    func profile(at shape: Double) -> DotProfile {
        // 先判 > 0：NaN 落到静息那端。
        let s = shape > 0 ? min(shape, 1) : 0
        let scale = DotMetrics.restScale + (1 - DotMetrics.restScale) * s
        let unit = Self.unitProfiles[self] ?? []
        return DotProfile(radii: unit.map { scale * (1 + ($0 - 1) * s) })
    }

    /// 在 allCases 里的序号，着色器按它取轮廓。
    var index: Double { Double(Self.allCases.firstIndex(of: self) ?? 0) }

    /// 各终态满格时的轮廓按 allCases 顺序首尾相接，交给着色器。
    static let shaderProfiles: [Float] = allCases.flatMap { form in
        (unitProfiles[form] ?? []).map { Float($0) }
    }

    private static let unitProfiles: [DotForm: [Double]] = Dictionary(uniqueKeysWithValues: allCases.map { form in
        (form, form.outline.map(radii) ?? Array(repeating: 1, count: DotProfile.count))
    })

    /// 满格时的轮廓，坐标以半格为单位；nil 表示圆。
    private var outline: [CGPoint]? {
        switch self {
        case .circle:
            return nil
        case .square:
            // 圆角占边长 17%，与 Pigeon 格子的方块端一致。
            let radius = 0.34, inner = 1 - radius
            let corners = [(inner, -inner, -90.0), (inner, inner, 0.0), (-inner, inner, 90.0), (-inner, -inner, 180.0)]
            return corners.flatMap { x, y, start in
                (0...12).map { step in
                    let angle = (start + Double(step) * 90 / 12) * .pi / 180
                    return CGPoint(x: x + radius * cos(angle), y: y + radius * sin(angle))
                }
            }
        case .diamond:
            return [.init(x: 0, y: -1), .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: -1, y: 0)]
        case .kite:
            return [.init(x: 0, y: -1), .init(x: 0.72, y: -0.28), .init(x: 0, y: 1), .init(x: -0.72, y: -0.28)]
        case .star:
            return (0..<10).map { index in
                let angle = -Double.pi / 2 + Double(index) * .pi / 5
                let radius = index.isMultiple(of: 2) ? 1 : 0.48
                return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            }
        case .heart:
            let points = (0..<240).map { index in
                let t = Double(index) / 240 * 2 * .pi
                return CGPoint(x: 16 * pow(sin(t), 3),
                               y: -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)))
            }
            return Self.fitted(points)
        case .plus:
            let arm = 0.34
            return [(-arm, -1), (arm, -1), (arm, -arm), (1, -arm), (1, arm), (arm, arm),
                    (arm, 1), (-arm, 1), (-arm, arm), (-1, arm), (-1, -arm), (-arm, -arm)]
                .map { CGPoint(x: $0.0, y: $0.1) }
        }
    }

    /// 按包围盒居中并缩放到 [-1, 1]。
    private static func fitted(_ points: [CGPoint]) -> [CGPoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let half = max(maxX - minX, maxY - minY) / 2
        guard half > 0 else { return points }
        return points.map { CGPoint(x: ($0.x - (minX + maxX) / 2) / half, y: ($0.y - (minY + maxY) / 2) / half) }
    }

    /// 从格心沿每个采样角发射线，取与轮廓最近的交点；轮廓须从格心可见全部边界。
    private static func radii(_ polygon: [CGPoint]) -> [Double] {
        DotProfile.directions.map { direction in
            var nearest = Double.infinity
            for index in polygon.indices {
                let p = polygon[index], q = polygon[(index + 1) % polygon.count]
                let ex = q.x - p.x, ey = q.y - p.y
                let denominator = direction.dx * ey - direction.dy * ex
                guard abs(denominator) > 1e-12 else { continue }
                let t = (p.x * ey - p.y * ex) / denominator
                let u = (p.x * direction.dy - p.y * direction.dx) / denominator
                if t > 0, u >= -1e-9, u <= 1 + 1e-9 { nearest = min(nearest, t) }
            }
            return nearest.isFinite ? nearest : 1
        }
    }
}

/// 一格的轮廓：从正上方顺时针等角采样的半径，单位是半格。
/// 120 个采样能被 4、8、10 整除，方块的角、菱形与星的尖都落在采样角上。
/// 作为向量参与 SwiftUI 动画，形变与换终态都是逐角插值。
nonisolated struct DotProfile: VectorArithmetic, Sendable {
    static let count = 120
    static let directions: [CGVector] = (0..<count).map { index in
        let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(count)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    /// 空数组表示零向量，只在动画插值中出现。
    var radii: [Double]

    static var zero: DotProfile { .init(radii: []) }

    static func + (lhs: DotProfile, rhs: DotProfile) -> DotProfile { combine(lhs, rhs, +) }
    static func - (lhs: DotProfile, rhs: DotProfile) -> DotProfile { combine(lhs, rhs, -) }

    private static func combine(_ lhs: DotProfile, _ rhs: DotProfile,
                                _ operation: (Double, Double) -> Double) -> DotProfile {
        if lhs.radii.isEmpty { return .init(radii: rhs.radii.map { operation(0, $0) }) }
        if rhs.radii.isEmpty { return lhs }
        return .init(radii: zip(lhs.radii, rhs.radii).map(operation))
    }

    static func == (lhs: DotProfile, rhs: DotProfile) -> Bool {
        if lhs.radii.isEmpty { return rhs.radii.allSatisfy { $0 == 0 } }
        if rhs.radii.isEmpty { return lhs.radii.allSatisfy { $0 == 0 } }
        return lhs.radii == rhs.radii
    }

    mutating func scale(by rhs: Double) {
        radii = radii.map { $0 * rhs }
    }

    var magnitudeSquared: Double { radii.reduce(0) { $0 + $1 * $1 } }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard radii.count == Self.count else { return path }
        let half = min(rect.width, rect.height) / 2
        for (index, direction) in Self.directions.enumerated() {
            let radius = radii[index] * half
            let point = CGPoint(x: rect.midX + direction.dx * radius, y: rect.midY + direction.dy * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 一格的颜色：sRGB 分量与不预乘的透明度，均为 0...1。
/// 插值在预乘透明度的 oklab 中进行，两种颜色之间不经灰，淡入淡出也不会带出透明端的杂色。
nonisolated struct DotColor: Hashable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    init(_ resolved: Color.Resolved) {
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue),
                  alpha: Double(resolved.opacity))
    }

    /// 静息点色随深浅外观变化，按当前环境解析颜色资源。
    @MainActor static func rest(in environment: EnvironmentValues) -> DotColor {
        DotColor(Theme.dotRest.resolve(in: environment))
    }

    /// 效果色，与执行扫掠同一组：参考色中在浅底上看得清的三色，加上 Sunwashed 深一档和主题色。
    /// Buttercup Sky 与 Cloud Puff 太浅，只用作面。
    static let palette: [DotColor] = [morningBreeze, dewyBlue, sunwashed, sunwashedDeep, accent]
    static let morningBreeze = DotColor(hex: 0x7FA8D6)
    static let dewyBlue = DotColor(hex: 0xA8C6E7)
    static let sunwashed = DotColor(hex: 0xFFE08A)
    /// Sunwashed 深一档。
    static let sunwashedDeep = DotColor(hex: 0xF5C95C)
    /// 主题色的默认取值；随外观变化的地方用解析后的 accentColor。
    static let accent = DotColor(hex: 0x5B88C2)

    /// 某一格固定取五色中的哪一色，同一格始终同色，避免逐帧闪色。
    /// 取法与 DotField.metal 一致，CPU 算的格子与着色器算的格子取到同一色。
    static func palette(column: Int, row: Int, in colors: [DotColor] = palette) -> DotColor {
        guard !colors.isEmpty else { return palette[0] }
        let h = (UInt32(truncatingIfNeeded: column) &* 73_856_093) ^ (UInt32(truncatingIfNeeded: row) &* 19_349_663)
        return colors[Int(h % UInt32(colors.count))]
    }

    /// 交给着色器的值：不预乘的 sRGB 与透明度。
    var shaderValue: Shader.Argument {
        .float4(red, green, blue, alpha)
    }

    /// 十六进制写法，不含透明度。
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// 在 oklab 中混合，t=0 取自身、t=1 取 other。需要颜色随 shape 从点色长出来的调用方用 shape 作 t。
    func mixed(with other: DotColor, by t: Double) -> DotColor {
        let t = t > 0 ? min(t, 1) : 0
        return DotColor(oklab + (other.oklab - oklab).scaled(by: t))
    }

    var oklab: Oklab {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Oklab(lightness: (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s) * alpha,
                     a: (1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s) * alpha,
                     b: (0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s) * alpha,
                     alpha: alpha)
    }

    init(_ lab: Oklab) {
        let alpha = lab.alpha > 0 ? min(lab.alpha, 1) : 0
        guard alpha > 0 else {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        let lightness = lab.lightness / lab.alpha, a = lab.a / lab.alpha, b = lab.b / lab.alpha
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.291485548 * b, 3)
        func gamma(_ value: Double) -> Double {
            let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
            return min(max(encoded, 0), 1)
        }
        self.init(red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
                  alpha: alpha)
    }

    /// 预乘透明度的 oklab，作为动画向量。
    nonisolated struct Oklab: VectorArithmetic, Sendable {
        var lightness: Double
        var a: Double
        var b: Double
        var alpha: Double

        static var zero: Oklab { .init(lightness: 0, a: 0, b: 0, alpha: 0) }

        static func + (lhs: Oklab, rhs: Oklab) -> Oklab {
            .init(lightness: lhs.lightness + rhs.lightness, a: lhs.a + rhs.a, b: lhs.b + rhs.b, alpha: lhs.alpha + rhs.alpha)
        }

        static func - (lhs: Oklab, rhs: Oklab) -> Oklab {
            .init(lightness: lhs.lightness - rhs.lightness, a: lhs.a - rhs.a, b: lhs.b - rhs.b, alpha: lhs.alpha - rhs.alpha)
        }

        mutating func scale(by rhs: Double) {
            lightness *= rhs
            a *= rhs
            b *= rhs
            alpha *= rhs
        }

        var magnitudeSquared: Double { lightness * lightness + a * a + b * b + alpha * alpha }
    }
}

/// 一格轮廓本身，可描边或另行填充；随 profile 动画。
nonisolated struct DotShape: Shape {
    var profile: DotProfile

    var animatableData: DotProfile {
        get { profile }
        set { profile = newValue }
    }

    func path(in rect: CGRect) -> Path { profile.path(in: rect) }
}

/// 单独一格。shape、终态和颜色的变化都随外层动画连续过渡；终态按视图短边居中。
struct DotView: View, Animatable {
    private var profile: DotProfile
    private var color: DotColor.Oklab

    init(_ dot: Dot) {
        profile = dot.profile
        color = dot.color.oklab
    }

    var animatableData: AnimatablePair<DotProfile, DotColor.Oklab> {
        get { .init(profile, color) }
        set {
            profile = newValue.first
            color = newValue.second
        }
    }

    var body: some View {
        DotShape(profile: profile).fill(DotColor(color).color)
    }
}

/// 一片点阵，逐格由调用方给出状态；需要随时间变化时放进 TimelineView。
struct DotMatrix: View {
    let columns: Int
    let rows: Int
    let dot: (_ column: Int, _ row: Int) -> Dot

    /// 给定宽度最多放下几列（末列右侧不带缝）。
    static func columns(fitting width: CGFloat) -> Int {
        max(0, Int((width + DotMetrics.gap) / DotMetrics.pitch))
    }

    var body: some View {
        Canvas { context, _ in
            for row in 0..<rows {
                for column in 0..<columns {
                    let cell = dot(column, row)
                    let rect = CGRect(x: CGFloat(column) * DotMetrics.pitch, y: CGFloat(row) * DotMetrics.pitch,
                                      width: DotMetrics.cell, height: DotMetrics.cell)
                    context.fill(cell.path(in: rect), with: .color(cell.color.color))
                }
            }
        }
        .frame(width: max(0, CGFloat(columns) * DotMetrics.pitch - DotMetrics.gap),
               height: max(0, CGFloat(rows) * DotMetrics.pitch - DotMetrics.gap))
    }
}
