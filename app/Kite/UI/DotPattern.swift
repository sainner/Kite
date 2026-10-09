import SwiftUI

/// 铺满一块区域、按表达式逐格求值的图案，即模板的点阵签名。值的绝对值是点的大小，正负选两种颜色。
nonisolated struct DotPattern: Equatable, Sendable {
    let expression: DotExpression
    var positive: DotColor
    var negative: DotColor
    var form: DotForm

    static func == (a: Self, b: Self) -> Bool {
        a.expression.source == b.expression.source && a.positive == b.positive && a.negative == b.negative && a.form == b.form
    }
}

/// 图案收弱的一块范围：文字压在上面时图案在这里只留 floor 那么多，离开范围 quietReach 格回到原样。
nonisolated struct PatternQuiet: Equatable, Sendable {
    var rect: CGRect
    var floor = PatternMotion.quietFloor

    func mapped(by mapping: DotCarrier.Mapping?) -> PatternQuiet {
        PatternQuiet(rect: mapping?.apply(rect) ?? rect, floor: floor)
    }
}

/// 舞台上一块图案的状态。区域在会移动的卡片里时用卡片坐标，见 DotCarrier。
struct PatternSlot {
    var pattern: DotPattern?
    /// 换图案时的旧图案，形变完就不再用。
    var previous: DotPattern?
    /// 当前图案摆上来的时刻：从无到有时由中心向外长出来，换图案时沿对角线逐格形变。
    var changed: Date
    /// 整块收回的时刻。
    var leaving: Date?
    /// 表达式里 t 的起点。
    var start: Date
    var area: CGRect
    /// 文字压在上面的范围，图案在这里收弱。
    var quiet: [PatternQuiet]
    var carrier: DotCarrier?
}

/// 图案的交互输入：指针所在（窗口坐标）与打字的活跃度。逐帧读取，不引起视图更新。
struct PatternInput {
    var pointer: CGPoint?
    var activity = 0.0
    var activityAt = Date.distantPast

    /// 每敲一下加一截，随后按秒衰减。
    func level(at date: Date) -> Double {
        max(0, activity - date.timeIntervalSince(activityAt) * PatternMotion.activityDecay)
    }
}

nonisolated enum PatternMotion {
    /// 从无到有时由中心向外长出来，最外一圈晚这么久出发。
    static let growSpread: TimeInterval = 0.7
    /// 换图案时沿对角线错开的时长。
    static let morphSpread: TimeInterval = 0.6
    static let leaveDuration: TimeInterval = 0.45
    /// 长出来或形变完所需的最长时间，过后不再算旧图案。
    static let settled: TimeInterval = 1.3
    static let activityStep = 0.22
    static let activityDecay = 0.5
    /// 压字的范围里留多少，离开范围多远（格）回到原样。
    static let quietFloor = 0.12
    static let quietReach = 3.0
}

/// 一帧里的一块图案，坐标都已换算到窗口格位。
nonisolated struct ResolvedPattern: Sendable {
    let pattern: DotPattern?
    let previous: DotPattern?
    let changed: Date
    let leaving: Date?
    let start: Date
    let columns: ClosedRange<Int>
    let rows: ClosedRange<Int>
    let quiet: [PatternQuiet]
    /// 指针所在格，相对图案中心。
    let pointer: (x: Double, y: Double)?
    let activity: Double

    func dot(column: Int, row: Int, at date: Date, live: Bool, rest: DotColor) -> Dot? {
        guard columns.contains(column), rows.contains(row) else { return nil }
        let w = Double(columns.count), h = Double(rows.count)
        let x = Double(column - columns.lowerBound) - (w / 2).rounded(.down)
        let y = Double(row - rows.lowerBound) - (h / 2).rounded(.down)
        var scope = DotExpression.Scope()
        scope[.t] = live ? date.timeIntervalSince(start) : 0
        scope[.x] = x
        scope[.y] = y
        scope[.w] = w
        scope[.h] = h
        scope[.i] = Double(row - rows.lowerBound) * w + Double(column - columns.lowerBound)
        scope[.r] = hypot(x, y)
        scope[.a] = atan2(y, x)
        scope[.px] = pointer.map { x - $0.x } ?? 999
        scope[.py] = pointer.map { y - $0.y } ?? 999
        scope[.d] = hypot(scope[.px], scope[.py])
        scope[.k] = activity

        let elapsed = live ? date.timeIntervalSince(changed) : .infinity
        var value = 0.0
        var colors = pattern
        if let pattern {
            value = pattern.expression.evaluate(scope)
            if let previous {
                // 沿对角线从左上到右下逐格换过去
                let span = Double(columns.count + rows.count - 2)
                let delay = span > 0 ? Double(column - columns.lowerBound + row - rows.lowerBound) / span * PatternMotion.morphSpread : 0
                let eased = easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
                value = previous.expression.evaluate(scope) * (1 - eased) + value * eased
                if eased < 0.5 { colors = previous }
            } else {
                // 由中心向外长出来
                let reach = hypot(w / 2, h / 2)
                let delay = reach > 0 ? scope[.r] / reach * PatternMotion.growSpread : 0
                value *= easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
            }
        }
        if let leaving, live {
            value *= 1 - easeOutCubic(date.timeIntervalSince(leaving) / PatternMotion.leaveDuration)
        }
        if !quiet.isEmpty {
            let square = DotMetrics.square(column: column, row: row)
            var factor = 1.0
            for quiet in quiet {
                let distance = Double(DotMetrics.distance(between: square, and: quiet.rect) / DotMetrics.pitch)
                factor = min(factor, quiet.floor + (1 - quiet.floor) * smoothstep(distance / PatternMotion.quietReach))
            }
            value *= factor
        }
        let shape = abs(value)
        guard shape > 1.0 / 512, let colors else { return nil }
        let color = rest.mixed(with: value >= 0 ? colors.positive : colors.negative, by: min(1, shape * 1.6))
        return Dot(colors.form, shape: shape, color: color)
    }
}

/// 在一块区域上铺点阵签名：自己只占位，图案交给所在窗口的舞台。指针划过和打字由使用方报给舞台。
/// 给出 area 时铺在那里（如整个窗口，连同标题栏和控制区后面），否则铺满自己占的位置。
struct DotPatternArea: View {
    let pattern: DotPattern?
    /// 收弱的范围；坐标与 area 相同：窗口坐标，在会移动的卡片里是卡片坐标。
    var quiet: [PatternQuiet] = []
    var area: CGRect?
    let slot: String
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @State private var frame: CGRect?

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: {
                frame = $0
                refresh()
            }
            .onChange(of: pattern) { refresh() }
            .onChange(of: quiet) { refresh() }
            .onChange(of: area) { refresh() }
            .onDisappear { stage?.showPattern(nil, in: .zero, slot: slot) }
            .preference(key: DotSlots.self, value: [slot])
            .allowsHitTesting(false)
    }

    private func refresh() {
        guard let area = area ?? frame else { return }
        stage?.showPattern(pattern, in: area, quiet: quiet, slot: slot, carrier: carrier)
    }
}
