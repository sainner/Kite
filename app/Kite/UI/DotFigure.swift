import SwiftUI

/// 点阵在背景上拼出的图形，逐行用字符画写；字符在 colors 里对应一格的颜色，其余字符是静息的点。
/// 图形尺寸不限，摆放时按内容居中；换图形时按窗口格位逐格形变，新旧图形大小不必一致。
nonisolated struct DotFigure: Hashable, Sendable {
    /// 图形共用的字母表：B 主题色，M Morning Breeze，L Dewy Blue，Y Sunwashed，D Sunwashed 深一档，
    /// 习惯用 . 写静息的点。颜色可以任意给，新图形优先沿用这张表。
    static func letters(accent: DotColor) -> [Character: DotColor] {
        ["B": accent, "M": .morningBreeze, "L": .dewyBlue, "Y": .sunwashed, "D": .sunwashedDeep]
    }

    /// 换图形时逐格形变：沿对角线从左上到右下依次出发，每格形变一次，整段多长。
    static let stagger: TimeInterval = 0.3
    static let transition = stagger + DotMetrics.morphDuration

    /// 图形里一起动的一组格子。
    struct Layer: Hashable, Sendable {
        var motion: FigureMotion
    }

    struct Cell: Hashable, Sendable {
        var color: DotColor
        /// 格子长多大，1 是满格。
        var shape = 1.0
        var layer: Int
        /// 叠上来之前这里原有的格子：这一层闪烁熄掉时露出它，而不是露出静息的点。
        var under: Look?
        /// 帧序列的层里这一格每帧的样子，nil 是静息的点；color 与 shape 取首帧。其他层为空。
        var frames: [Look?] = []

        var look: Look { Look(color: color, shape: shape) }
    }

    struct Look: Hashable, Sendable {
        var color: DotColor
        var shape: Double

        /// 从 a 过渡到 b 走到 t；空白帧同时回到静息点的形状与颜色。
        static func blend(_ a: Look?, _ b: Look?, by t: Double, rest: DotColor) -> Look? {
            guard a != nil || b != nil else { return nil }
            let from = a ?? Look(color: rest, shape: 0)
            let to = b ?? Look(color: rest, shape: 0)
            return Look(color: from.color.mixed(with: to.color, by: t), shape: from.shape + (to.shape - from.shape) * t)
        }
    }

    /// 有内容的一格和它所在的层。
    struct Occupied: Hashable, Sendable {
        var column: Int
        var row: Int
        var layer: Int
    }

    private(set) var columns: Int
    private(set) var rows: Int
    /// 按行排列，nil 是静息的点。
    private var cells: [Cell?]
    private(set) var layers: [Layer]
    /// 有内容的格子：摆到点阵上时只算它们附近，不必把整块画幅逐格算一遍（风筝场景 32 × 24 格里只有一百多格有内容）。
    /// 改了 cells 之后由 indexOccupied 重算。
    private(set) var occupied: [Occupied] = []

    private mutating func indexOccupied() {
        occupied = []
        for index in cells.indices {
            if let cell = cells[index] { occupied.append(Occupied(column: index % columns, row: index / columns, layer: cell.layer)) }
        }
    }

    /// 一层的图形；shapes 给不满格的字符定大小，motion 是这一层的小动画。
    init(_ lines: [String], colors: [Character: DotColor], shapes: [Character: Double] = [:], motion: FigureMotion = .still) {
        let width = lines.map(\.count).max() ?? 0
        columns = width
        rows = lines.count
        cells = lines.flatMap { line in
            let characters = Array(line)
            return (0..<width).map { column -> Cell? in
                guard column < characters.count, let color = colors[characters[column]] else { return nil }
                return Cell(color: color, shape: shapes[characters[column]] ?? 1, layer: 0)
            }
        }
        layers = [Layer(motion: motion)]
        indexOccupied()
    }

    /// 帧序列的图形：frames 是逐帧的字符画，第 i 帧停 holds[i] 秒，再用 transition 秒逐格过渡到下一帧，末帧接回首帧。
    /// stagger 是过渡里沿对角线从左上到右下错开的总时长，不超过 transition。各帧大小可以不同，左上角对齐。
    /// 减少动态效果或换图形时停在首帧。
    init(frames: [[String]], colors: [Character: DotColor], shapes: [Character: Double] = [:], holds: [TimeInterval],
         transition: TimeInterval = DotMetrics.morphDuration, stagger: TimeInterval = 0, phase: Double = 0) {
        precondition(!frames.isEmpty && frames.count == holds.count, "每帧要有一个停留时长")
        let width = frames.flatMap { $0.map(\.count) }.max() ?? 0
        let height = frames.map(\.count).max() ?? 0
        let grids = frames.map { $0.map(Array.init) }
        columns = width
        rows = height
        cells = (0..<height).flatMap { row in
            (0..<width).map { column -> Cell? in
                let looks = grids.map { grid -> Look? in
                    guard row < grid.count, column < grid[row].count, let color = colors[grid[row][column]] else { return nil }
                    return Look(color: color, shape: shapes[grid[row][column]] ?? 1)
                }
                guard let shown = looks.first(where: { $0 != nil }) ?? nil else { return nil }
                return Cell(color: shown.color, shape: looks[0]?.shape ?? 0, layer: 0, frames: looks)
            }
        }
        layers = [Layer(motion: .frames(holds: holds, transition: transition, stagger: min(stagger, transition), phase: phase))]
        indexOccupied()
    }

    /// 每帧停留同样久的帧序列。
    init(frames: [[String]], colors: [Character: DotColor], shapes: [Character: Double] = [:], hold: TimeInterval,
         transition: TimeInterval = DotMetrics.morphDuration, stagger: TimeInterval = 0, phase: Double = 0) {
        self.init(frames: frames, colors: colors, shapes: shapes, holds: Array(repeating: hold, count: frames.count),
                  transition: transition, stagger: stagger, phase: phase)
    }

    /// 空白的画布，用 adding 往上叠。
    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        cells = Array(repeating: nil, count: columns * rows)
        layers = []
    }

    /// 把 other 叠到 (column, row) 处，作为各自独立运动的层；画布按需要扩大。盖住的格子记在 under 里。
    func adding(_ other: DotFigure, column: Int, row: Int) -> DotFigure {
        var result = DotFigure(columns: max(columns, column + other.columns), rows: max(rows, row + other.rows))
        for r in 0..<rows {
            for c in 0..<columns { result.cells[r * result.columns + c] = cells[r * columns + c] }
        }
        for r in 0..<other.rows {
            for c in 0..<other.columns {
                guard var cell = other.cells[r * other.columns + c] else { continue }
                let index = (row + r) * result.columns + column + c
                cell.layer += layers.count
                cell.under = result.cells[index]?.look
                result.cells[index] = cell
            }
        }
        result.layers = layers + other.layers
        result.indexOccupied()
        return result
    }

    /// 去掉四周全空的行和列，摆放时按实际内容居中。
    func trimmed() -> DotFigure {
        var bounds = (minX: columns, minY: rows, maxX: -1, maxY: -1)
        for row in 0..<rows {
            for column in 0..<columns where cells[row * columns + column] != nil {
                bounds = (min(bounds.minX, column), min(bounds.minY, row), max(bounds.maxX, column), max(bounds.maxY, row))
            }
        }
        guard bounds.maxX >= 0 else { return self }
        var result = DotFigure(columns: bounds.maxX - bounds.minX + 1, rows: bounds.maxY - bounds.minY + 1)
        for row in 0..<result.rows {
            for column in 0..<result.columns {
                result.cells[row * result.columns + column] = cells[(row + bounds.minY) * columns + column + bounds.minX]
            }
        }
        result.layers = layers
        result.indexOccupied()
        return result
    }

    /// 有一层在动。
    var moves: Bool { layers.contains { !$0.motion.isStill } }

    subscript(column: Int, row: Int) -> Cell? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return cells[row * columns + column]
    }
}

/// 图形一层的小动画，按 period 循环；phase（0–1）错开同一图形里的几层。
nonisolated struct FigureMotion: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case still
        /// 上下浮动，幅度是点。
        case float(Double)
        /// 闪烁：每周期亮 duty 那一段，熄掉时露出底下的格子或静息的点。
        case blink(duty: Double)
        /// 每周期在 duration 内从点长成满格再收回，形变量线性变化。
        case pulse(duration: TimeInterval)
        /// 帧序列：第 i 帧停 holds[i]，再用 transition 逐格过渡到下一帧，末帧接回首帧；stagger 让过渡沿对角线错开。
        case frames(holds: [TimeInterval], transition: TimeInterval, stagger: TimeInterval)
    }

    var kind = Kind.still
    var period: TimeInterval = 1
    var phase = 0.0

    static let still = FigureMotion()
    static func float(_ points: Double, period: TimeInterval, phase: Double = 0) -> FigureMotion {
        FigureMotion(kind: .float(points), period: period, phase: phase)
    }
    static func blink(period: TimeInterval, duty: Double = 0.5, phase: Double = 0) -> FigureMotion {
        FigureMotion(kind: .blink(duty: duty), period: period, phase: phase)
    }
    static func pulse(period: TimeInterval, duration: TimeInterval, phase: Double = 0) -> FigureMotion {
        FigureMotion(kind: .pulse(duration: duration), period: period, phase: phase)
    }
    static func frames(holds: [TimeInterval], transition: TimeInterval, stagger: TimeInterval = 0, phase: Double = 0) -> FigureMotion {
        FigureMotion(kind: .frames(holds: holds, transition: transition, stagger: stagger),
                     period: max(holds.reduce(0, +) + Double(holds.count) * transition, 0.01), phase: phase)
    }

    var isStill: Bool { kind == .still }

    /// 这一周期走到哪（0–1）；先收敛到一周期，避免大时间戳损失精度。
    private func cycle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period + phase
        return t - t.rounded(.down)
    }

    /// 上下位移（格）；amplitude 是 0–1 的幅度系数。
    func offset(at date: Date, amplitude: Double) -> Double {
        guard case .float(let points) = kind, amplitude > 0 else { return 0 }
        return sin(cycle(at: date) * 2 * .pi) * points * amplitude / Double(DotMetrics.pitch)
    }

    /// 展开程度（0–1）：无底层时控制点与满格的形变，有底层时与它交接；amplitude 为 0 时完全展开。
    func visibility(at date: Date, amplitude: Double) -> Double {
        guard amplitude > 0 else { return 1 }
        let elapsed = cycle(at: date) * period
        let lit: Double
        switch kind {
        case .blink(let duty):
            let edge = 0.08
            lit = smoothstep(elapsed / edge) * (1 - smoothstep((elapsed - duty * period) / edge))
        case .pulse(let duration):
            lit = max(0, 1 - abs(elapsed - duration / 2) / (duration / 2))
        case .still, .float, .frames:
            return 1
        }
        return 1 - amplitude * (1 - lit)
    }

    /// 帧序列此刻这一格的样子；delay（0–1）是这一格在过渡里按对角线位置晚出发多少。
    /// amplitude 从 0 到 1 时由首帧过渡到当前帧，为 0 时停在首帧。不是帧序列的层原样返回首帧。
    func look(of cell: DotFigure.Cell, at date: Date, delay: Double, amplitude: Double, rest: DotColor) -> DotFigure.Look? {
        guard case .frames(let holds, let transition, let stagger) = kind, !cell.frames.isEmpty, amplitude > 0 else {
            return cell.frames.isEmpty ? cell.look : cell.frames[0]
        }
        var elapsed = cycle(at: date) * period
        var current = cell.frames[0]
        for (index, hold) in holds.enumerated() {
            current = cell.frames[index]
            guard elapsed >= hold else { break }
            elapsed -= hold
            if elapsed < transition {
                // 和换图形一样缓出；最晚出发的那一格正好在 transition 结束时到位
                let t = (elapsed - delay * stagger) / max(transition - stagger, 0.01)
                current = DotFigure.Look.blend(current, cell.frames[(index + 1) % holds.count], by: easeOutCubic(t), rest: rest)
                break
            }
            elapsed -= transition
        }
        return amplitude < 1 ? DotFigure.Look.blend(cell.frames[0], current, by: amplitude, rest: rest) : current
    }
}

/// 摆到窗口点阵上的图形，column 与 row 是左上角那一格。
nonisolated struct PlacedFigure: Hashable, Sendable {
    let figure: DotFigure
    let column: Int
    let row: Int
    let placement: Placement
    /// 摆在会移动的卡片上时，卡片坐标里的范围，见 DotCarrier。
    let area: CGRect?
    /// 可见范围（窗口坐标），格心在范围外的格子不显示；nil 不裁。
    let clip: CGRect?
    /// 摆在会移动的卡片上时，卡片坐标里的可见范围。
    let localClip: CGRect?
    /// 图形左上角偏出 (column, row) 多少（格）：exact 摆放落在两格之间；对齐格位时为 0。
    var shiftX = 0.0
    var shiftY = 0.0

    /// center 让图形中心落在离 area 中心最近的格位；leading 让左边贴着 area 左边、上下居中，也取整到格位；
    /// exact 让左上角正好落在 area 左上角，落在两格之间时由相邻格插值显示，用于正在滚动、移动的图案；
    /// nearest 让左上角落在离 area 左上角最近的格位，图案比占位至多偏出半格，用于停着的图案，免得插值让图案发虚。
    enum Placement: Sendable { case center, leading, exact, nearest }

    /// 按 placement 摆进 area（窗口坐标），格子对齐窗口的点阵。
    init(_ figure: DotFigure, in area: CGRect, placement: Placement = .center, area local: CGRect? = nil,
         clip: CGRect? = nil, localClip: CGRect? = nil) {
        self.figure = figure
        self.placement = placement
        self.area = local
        self.clip = clip
        self.localClip = localClip
        let pitch = Double(DotMetrics.pitch)
        let x: Double = switch placement {
        case .center: (Double(area.midX) / pitch - Double(figure.columns) / 2).rounded()
        case .leading: (Double(area.minX) / pitch).rounded()
        case .exact: Double(area.minX) / pitch
        case .nearest: (Double(area.minX) / pitch).rounded()
        }
        let y: Double = switch placement {
        case .exact: Double(area.minY) / pitch
        case .nearest: (Double(area.minY) / pitch).rounded()
        case .center, .leading: (Double(area.midY) / pitch - Double(figure.rows) / 2).rounded()
        }
        // 离格位不到千分之一格的当作对齐，免得浮点误差让停着的图案一直插值
        func split(_ value: Double) -> (Int, Double) {
            let near = value.rounded()
            if abs(value - near) < 0.001 { return (Int(near), 0) }
            let whole = value.rounded(.down)
            return (Int(whole), value - whole)
        }
        (column, shiftX) = split(x)
        (row, shiftY) = split(y)
    }

    var frame: CGRect {
        CGRect(x: CGFloat(column) * DotMetrics.pitch, y: CGFloat(row) * DotMetrics.pitch,
               width: CGFloat(figure.columns) * DotMetrics.pitch, height: CGFloat(figure.rows) * DotMetrics.pitch)
    }

    /// 这一帧可能占到的格子：浮动、落在两格之间至多偏出一格。
    var reach: (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        let dx = Int(shiftX.rounded(.down)), dy = Int(shiftY.rounded(.down))
        return ((column + dx - 1)...(column + dx + figure.columns + 1), (row + dy - 1)...(row + dy + figure.rows + 1))
    }

    /// date 时刻、按 amplitude（0–1 的幅度系数）动着的样子，取样用。
    func posed(at date: Date, amplitude: Double) -> PosedFigure {
        let offsets = figure.layers.map { $0.motion.offset(at: date, amplitude: amplitude) }
        var distinct: [Double] = []
        for offset in offsets where !distinct.contains(offset) { distinct.append(offset) }
        return PosedFigure(placed: self, date: date, amplitude: amplitude, offsets: offsets,
                           lit: figure.layers.map { $0.motion.visibility(at: date, amplitude: amplitude) }, distinctOffsets: distinct)
    }
}

/// 摆好的图形在某一时刻的样子。各层的位移和展开程度只和时刻有关，一帧算一次，各格取样共用。
nonisolated struct PosedFigure: Sendable {
    let placed: PlacedFigure
    let date: Date
    let amplitude: Double
    /// 各层浮动的位移（格）与展开程度，见 FigureMotion。
    let offsets: [Double]
    let lit: [Double]
    /// offsets 里不同的值：位移相同的层落在同样的格位上，一起取样。
    let distinctOffsets: [Double]

    /// center（窗口点阵上一格的格心；跟着卡片走时已换算回卡片停着的位置）从图形内容里分到多少形变、什么颜色、覆盖了几成；
    /// 一点都没分到是 nil。浮动的层和落在两格之间的图形按此刻的位移把 center 反算回图形坐标，由相邻格按双线性权重分配形变量；
    /// 颜色按相同的空间权重在 oklab 中混合，未覆盖的部分留给 DotBlend 与下层合成；闪烁的层连续交接给底层或静息点。
    /// 幅度为 0、没有挪动时正好取回原来那一格。
    func sample(at center: CGPoint, rest: DotColor) -> DotSample? {
        if let clip = placed.clip, !clip.contains(center) { return nil }
        let figure = placed.figure
        // 格的中心，以格为单位、相对图形左上角；浮动至多偏出一格
        let x = Double(center.x / DotMetrics.pitch) - Double(placed.column) - placed.shiftX
        let y = Double(center.y / DotMetrics.pitch) - Double(placed.row) - placed.shiftY
        guard x > -1, x < Double(figure.columns) + 1, y > -1, y < Double(figure.rows) + 1 else { return nil }
        let u = x - 0.5, u0 = u.rounded(.down), fu = u - u0
        var shape = 0.0, coverage = 0.0
        // 分到的都是同一种颜色时（大多数格子）结果就是它，不必在 oklab 里加权再换回来；出现第二种颜色才开始累加
        var single: DotColor?
        var color = DotColor.Oklab.zero
        func contribute(_ look: DotFigure.Look, weight: Double) {
            guard weight > 0 else { return }
            if coverage == 0 {
                single = look.color
            } else if let first = single, first != look.color {
                color = first.oklab.scaled(by: coverage)
                single = nil
            }
            if single == nil { color += look.color.oklab.scaled(by: weight) }
            shape += look.shape * weight
            coverage += weight
        }
        for offset in distinctOffsets {
            let v = y - offset - 0.5
            let v0 = v.rounded(.down), fv = v - v0
            func tap(_ du: Int, _ dv: Int, _ w: Double) {
                let c = Int(u0) + du, r = Int(v0) + dv
                guard w > 0, let cell = figure[c, r], offsets[cell.layer] == offset else { return }
                let lit = lit[cell.layer]
                let delay = Double(c + r) / Double(max(figure.columns + figure.rows - 2, 1))
                let look = figure.layers[cell.layer].motion.look(of: cell, at: date, delay: delay, amplitude: amplitude, rest: rest)
                // 熄掉的那部分换成底下的格子
                if let look { contribute(look, weight: w * lit) }
                if let under = cell.under { contribute(under, weight: w * (1 - lit)) }
            }
            tap(0, 0, (1 - fu) * (1 - fv))
            tap(1, 0, fu * (1 - fv))
            tap(0, 1, (1 - fu) * fv)
            tap(1, 1, fu * fv)
        }
        guard coverage > 0 else { return nil }
        // shape 是图案作者给定的大小，不当作颜色权重，避免小格子本来饱满的颜色被冲淡。
        let mixed = single?.normalized ?? DotColor(color.scaled(by: 1 / coverage))
        return DotSample(shape: min(shape, 1), color: mixed, coverage: min(coverage, 1))
    }

    /// 取样分得到内容的格子（窗口点阵的列、行），同一格可能给出多次；不含 clip 的裁切。follow 同 DotField.follow。
    /// 内容格只分给格心离它左右、上下都不到一格的格子，对齐格位、不浮动、不跟着卡片走时正好是内容格自己。
    func forEachReachedCell(through follow: DotCarrier.Mapping?, _ body: (_ column: Int, _ row: Int) -> Void) {
        let back = follow?.inverted ?? DotCarrier.Mapping()
        let pitch = Double(DotMetrics.pitch), scale = Double(back.scale)
        // 内容格左上角落在 base 格处：格心（卡片停着时的坐标）在 base − 0.5 到 base + 1.5 格之间的分得到它，换算回屏幕上看是哪几格
        func reached(_ base: Double, origin: CGFloat) -> ClosedRange<Int> {
            let low = (Double(origin) + (base - 0.5) * pitch * scale) / pitch - 0.5
            let high = (Double(origin) + (base + 1.5) * pitch * scale) / pitch - 0.5
            return Int(low.rounded(.down)) + 1...Int(high.rounded(.up)) - 1
        }
        for cell in placed.figure.occupied {
            let columns = reached(Double(placed.column + cell.column) + placed.shiftX, origin: back.origin.x)
            for row in reached(Double(placed.row + cell.row) + placed.shiftY + offsets[cell.layer], origin: back.origin.y) {
                for column in columns { body(column, row) }
            }
        }
    }
}

/// 图案在一格上的取值：shape 已按覆盖度计入，color 是覆盖到的部分的颜色，coverage（0–1）是覆盖了几成。
nonisolated struct DotSample: Sendable {
    var shape: Double
    var color: DotColor
    var coverage: Double
}

/// 一层与下面已叠好的点怎样合成，类似图层的混合模式。
nonisolated enum DotBlend: Hashable, Sendable {
    /// 覆盖：按覆盖度盖住下层，图形多大、什么颜色就是什么样。图形都这样叠。
    case normal
    /// 取大：比下层大的部分才长出来，颜色只在超出的那段混向这一层；比下层小时不改变下层。波和轨迹这样叠。
    case lighten

    func composite(_ top: DotSample, over below: Dot) -> Dot {
        switch self {
        case .normal:
            return Dot(.square, shape: below.shape * (1 - top.coverage) + top.shape,
                       color: below.color.mixed(with: top.color, by: top.coverage))
        case .lighten:
            guard top.shape > below.shape else { return below }
            let amount = (top.shape - below.shape) / max(1 - below.shape, 1e-6)
            return Dot(below.form, shape: top.shape, color: below.color.mixed(with: top.color, by: amount))
        }
    }
}

/// 点阵上一个图形的位置：正拼着的图形、形变起点的旧图形（形变结束后清掉）、开始形变的时刻、是否呼吸和叠放次序。
nonisolated struct FigureSlot: Sendable {
    static let main = "main"
    var figure: PlacedFigure?
    var previous: PlacedFigure?
    var start = Date.distantPast
    var breathing = false
    /// 越大越靠上，同一 slot 换图形时不变。
    var order = 0
    /// 图形摆在会移动的卡片上时，是哪张卡片，见 DotCarrier。
    var carrier: DotCarrier?
    /// 图形摆在自己画点阵的窗口里时，是哪个窗口（DotScope）：只由这个窗口的取景框画，App 背景和别的窗口不画。
    var scope: ObjectIdentifier?
    /// 换摆放方式时原位置相对新位置的偏移（格），从 settleStart 起在 settleDuration 内减到零。
    var settle = (x: 0.0, y: 0.0)
    var settleStart = Date.distantPast

    static let settleDuration: TimeInterval = 0.2

    /// scope 所在的取景框（App 背景是 nil）画不画这个图形。
    func drawn(in scope: ObjectIdentifier?) -> Bool { self.scope == nil || self.scope == scope }

    /// date 时刻还没走完的偏移，缓出。
    func settleResidual(at date: Date) -> (x: Double, y: Double) {
        let t = date.timeIntervalSince(settleStart) / Self.settleDuration
        guard t < 1 else { return (0, 0) }
        let remaining = pow(1 - max(0, t), 3)
        return (settle.x * remaining, settle.y * remaining)
    }

    /// 叠上 date 时刻的偏移；不动（静息或减少动态效果）时直接落到新位置。
    func settled(at date: Date, live: Bool) -> FigureSlot {
        guard live, var placed = figure else { return self }
        let residual = settleResidual(at: date)
        guard residual != (0, 0) else { return self }
        placed.shiftX += residual.x
        placed.shiftY += residual.y
        var slot = self
        slot.figure = placed
        return slot
    }
}
