import SwiftUI

/// 一个 App 窗口里的点阵舞台：管点阵上的事件，图像由窗口背景里唯一那张点阵画布（DotCanvas）来画。
/// 坐标统一用窗口坐标（SwiftUI 的 .global）：原点是窗口左上角，每个模块（步距 p）的中心一颗点，布局边界都落在模块线上。
///
/// 点阵只在 App 背景上，卡片是不透明的面，盖住它；窗口内部不显示点阵。整片点阵只有一套相位，卡片移动时点不跟着挪。
/// 事件（如发送消息的波）只在一段时间里抬高经过的格子，结束后格子退回静息的点。
/// 背景上还可以拼出图形（如初始配置每一步的标志和步骤点），每个图形占一个位置（slot），格子一直长着，换图形时逐格形变过去；
/// 图形的各层可以有自己的小动画（浮动、闪烁、脉冲、帧序列）：格子始终在格位上，浮动时动的是各格从图形内容里分到的形变量
/// （亚格重采样，同 Pigeon 的格阵）。换图形时先停下，形变完再动起来。
@MainActor @Observable
final class DotStage {
    private var waves: [DotWave] = []
    private var slots: [String: FigureSlot] = [:]
    /// 图形摆在会移动的卡片上时，那张卡片这一帧实际挪到哪，见 DotCarrier。
    private var carriers: [String: DotCarrier] = [:]
    /// 指针或手指在空白画板上划过时点亮的格子，键是格位，值是点亮的时刻。
    @ObservationIgnored private var sparks: [DotCell: Date] = [:]
    /// 画布在窗口里的范围，调试面板从它的底部中间发测试波。
    @ObservationIgnored var bounds: CGRect = .zero
    /// 有波或形变在走时为 true。
    private var ticking = false
    /// 画布只在有事件走、图形呼吸、图形在动或所在卡片在走时逐帧刷新，静息时不耗电。
    var animating: Bool {
        ticking || slots.values.contains { $0.breathing || $0.figure?.figure.moves == true }
            || carriers.values.contains { $0.moving }
    }
    /// slot 上正拼着的图形。
    func shownFigure(_ slot: String = FigureSlot.main) -> DotFigure? { slots[slot]?.figure?.figure }
    /// slot 上的图形在窗口坐标中占的范围。
    func figureFrame(_ slot: String = FigureSlot.main) -> CGRect? {
        guard let shown = slots[slot] else { return nil }
        return (carriers[slot]?.carry(shown, moving: false) ?? shown).figure?.frame
    }
    @ObservationIgnored private var activeUntil = Date.distantPast
    @ObservationIgnored private var settle: Task<Void, Never>?

    init() {
        DotTuning.shared.attach(self)
    }

    /// 从 origin（窗口坐标）向四周推开一道波；不给 form 时取调过的终态。pace 小于 1 时整道波放慢，用于不赶时间的场景。
    func emitWave(from origin: CGRect, form: DotForm? = nil, pace: Double = 1) {
        let wave = DotWave(origin: origin, start: .now, form: form ?? DotTuning.shared.values.form, pace: pace)
        waves.append(wave)
        keepAnimating(for: wave.duration(DotTuning.shared.values.wave))
    }

    /// 在 slot 上按 placement 把 figure 摆进 area（窗口坐标），nil 让图形退回静息的点。换成另一个图形时逐格形变过去；
    /// 只是区域变了（窗口改大小）就直接挪过去。breathing 时图形按等待呼吸起伏。
    /// 摆在会移动的卡片上时给出 carrier，area 用卡片坐标（DotCarrier.space）：卡片走着的时候图形随它在点阵上滑过去。
    func show(_ figure: DotFigure?, in area: CGRect, placement: PlacedFigure.Placement = .center,
              breathing: Bool = false, slot: String = FigureSlot.main, carrier: DotCarrier? = nil) {
        let carrier = figure == nil ? nil : carrier
        if carriers[slot] !== carrier { carriers[slot] = carrier }
        var current = slots[slot] ?? FigureSlot()
        let placed = figure.map { figure in
            carrier.map { PlacedFigure(figure, in: $0.final.apply(area), placement: placement, area: area) }
                ?? PlacedFigure(figure, in: area, placement: placement)
        }
        current.breathing = breathing && placed != nil
        if placed == current.figure {
            if slots[slot]?.breathing != current.breathing { slots[slot] = current }
            return
        }
        if let placed, placed.figure == current.figure?.figure {
            current.figure = placed
            current.previous = nil
            slots[slot] = current
            return
        }
        current.previous = current.figure
        current.figure = placed
        current.start = .now
        slots[slot] = current
        keepAnimating(for: DotFigure.transition)
    }

    /// 在 point（窗口坐标）所在的格子留下一点轨迹，随后慢慢退回静息的点；周围一圈跟着亮一点。
    func trace(at point: CGPoint) {
        let column = Int((point.x / DotMetrics.pitch).rounded(.down)), row = Int((point.y / DotMetrics.pitch).rounded(.down))
        let now = Date.now
        sparks = sparks.filter { now.timeIntervalSince($0.value) < DotSpark.duration }
        sparks[DotCell(column: column, row: row)] = now
        // 周围一圈晚一点出发，看起来是笔尖晕开
        for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let cell = DotCell(column: column + dc, row: row + dr)
            if sparks[cell].map({ now.timeIntervalSince($0) > DotSpark.halo }) ?? true {
                sparks[cell] = now - DotSpark.halo
            }
        }
        keepAnimating(for: DotSpark.duration)
    }

    /// date 时刻的取值快照，供一帧绘制使用。live 为 false（静息或减少动态效果）时不呼吸。
    func field(at date: Date, rest: DotColor, live: Bool) -> DotField {
        let values = DotTuning.shared.values
        return DotField(waves: waves.filter { $0.isActive(at: date, values.wave) }, wave: values.wave,
                        palette: values.waveColor.map { [$0] } ?? values.palette, rest: rest,
                        slots: slots.map { key, slot in carriers[key]?.carry(slot, moving: live) ?? slot },
                        breath: live ? WaitingBreath.opacity(at: date) : 1, moving: live,
                        sparks: live ? sparks : [:])
    }

    private func keepAnimating(for duration: TimeInterval) {
        activeUntil = max(activeUntil, .now + duration)
        ticking = true
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, (self?.activeUntil.timeIntervalSinceNow ?? 0)) + 0.05))
            guard let self, !Task.isCancelled else { return }
            let wave = DotTuning.shared.values.wave
            waves.removeAll { !$0.isActive(at: .now, wave) }
            sparks = sparks.filter { Date.now.timeIntervalSince($0.value) < DotSpark.duration }
            for key in slots.keys { slots[key]?.previous = nil }
            ticking = false
        }
    }
}

/// 窗口点阵上的一格。
nonisolated struct DotCell: Hashable, Sendable {
    let column: Int
    let row: Int
}

/// 一张会移动的卡片（iPhone 的窗口）。卡片里的内容按卡片自己的坐标（space）排，
/// 卡片的动画逐帧报来这一帧实际在哪（current）和要去哪（final），两者都是卡片坐标到窗口坐标的换算。
/// 摆在卡片上的图形按 final 落到整格，再按 current 与 final 之差把亚格偏移分给相邻的格子（同浮动），
/// 不跟着卡片整块平移；格位和偏移取自同一帧的换算，不等卡片里的布局回报。
@MainActor @Observable
final class DotCarrier {
    /// 卡片内容的坐标空间。
    static let space = "dot.carrier"

    /// 卡片坐标到窗口坐标：p × scale + origin。
    nonisolated struct Mapping: Equatable, Sendable {
        var origin = CGPoint.zero
        var scale: CGFloat = 1

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
        }

        func apply(_ rect: CGRect) -> CGRect {
            CGRect(origin: apply(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
        }
    }

    /// 正在走的动画数；有在走的时，点阵逐帧刷新。
    private var runs = 0
    @ObservationIgnored private(set) var current = Mapping()
    @ObservationIgnored private(set) var final = Mapping()

    var moving: Bool { runs > 0 }

    /// 一段动画开始与结束，成对调用。
    func began() { runs += 1 }
    func ended() { runs = max(runs - 1, 0) }

    /// 由卡片的动画逐帧写入，不引起视图更新。
    func update(current: Mapping, final: Mapping) {
        self.current = current
        self.final = final
    }

    /// slot 上的图形（area 是卡片坐标）按卡片停下时的位置落到整格；moving 时再加上这一帧还差的亚格偏移。图形本身不缩放。
    func carry(_ slot: FigureSlot, moving: Bool) -> FigureSlot {
        func carried(_ placed: PlacedFigure) -> PlacedFigure {
            guard let area = placed.area else { return placed }
            var result = PlacedFigure(placed.figure, in: final.apply(area), placement: placed.placement)
            if moving {
                let center = CGPoint(x: area.midX, y: area.midY)
                let now = current.apply(center), then = final.apply(center)
                result.shiftX = Double((now.x - then.x) / DotMetrics.pitch)
                result.shiftY = Double((now.y - then.y) / DotMetrics.pitch)
            }
            return result
        }
        var slot = slot
        slot.figure = slot.figure.map(carried)
        slot.previous = slot.previous.map(carried)
        return slot
    }
}

/// 画板上划过留下的轨迹：一下长到 peak，再缓缓收回静息的点。
nonisolated enum DotSpark {
    static let duration: TimeInterval = 1.4
    /// 周围那一圈从这么晚的地方开始，长得小一些。
    static let halo: TimeInterval = 0.5
    static let peak = 0.7

    static func shape(since start: Date, at date: Date) -> Double {
        let t = date.timeIntervalSince(start) / duration
        guard t >= 0, t < 1 else { return 0 }
        return peak * pow(1 - t, 2)
    }
}

/// 一道波：波前从起点区域的边缘向外推，经过的格子长成 form、从点色混到波的颜色，离开后退回点。
nonisolated struct DotWave: Sendable {
    let origin: CGRect
    let start: Date
    let form: DotForm
    /// 时间倍率，1 是约定的速度。
    var pace = 1.0

    /// 波的参数，默认值即约定（见 docs/视觉风格.md）。
    struct Parameters: Codable, Equatable, Sendable {
        /// 每秒推进多少点。
        var speed = 420.0
        /// 波前的半宽（点），三个模块。
        var width = 36.0
        /// 波前走到这么远（点）时完全消失，十个模块。
        var reach = 120.0
        /// 走到 reach 的几成处开始变弱；0 是一出发就渐弱。
        var fadeStart = 0.0
        /// 波前正中那一格长到多大（shape）。
        var peak = 1.0
        /// 波的颜色在波前正中的不透明度，压低后波不那么抢眼。
        var opacity = 0.4

        var duration: TimeInterval { (reach + width) / max(speed, 1) }
    }

    func duration(_ parameters: Parameters) -> TimeInterval { parameters.duration / max(pace, 0.01) }

    func isActive(at date: Date, _ parameters: Parameters) -> Bool {
        let elapsed = date.timeIntervalSince(start)
        return elapsed >= 0 && elapsed < duration(parameters)
    }

    func shape(at square: CGRect, date: Date, _ parameters: Parameters) -> Double {
        let front = date.timeIntervalSince(start) * parameters.speed * pace
        guard front >= 0, front < parameters.reach + parameters.width, parameters.width > 0 else { return 0 }
        let x = abs(Double(DotMetrics.distance(between: square, and: origin)) - front) / parameters.width
        guard x < 1 else { return 0 }
        let fadeFrom = parameters.reach * parameters.fadeStart
        let fade = 1 - smoothstep((front - fadeFrom) / max(parameters.reach - fadeFrom, 1))
        return (1 - smoothstep(x)) * fade * parameters.peak
    }
}

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

    private(set) var columns: Int
    private(set) var rows: Int
    /// 按行排列，nil 是静息的点。
    private var cells: [Cell?]
    private(set) var layers: [Layer]

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
                let t = min(max((elapsed - delay * stagger) / max(transition - stagger, 0.01), 0), 1)
                current = DotFigure.Look.blend(current, cell.frames[(index + 1) % holds.count], by: 1 - pow(1 - t, 3), rest: rest)
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
    /// 随所在卡片挪动时偏出格位多少（格）；停着时为 0。
    var shiftX = 0.0
    var shiftY = 0.0

    /// center 让图形中心尽量落在 area 中心；leading 让左边贴着 area 左边、上下居中。
    enum Placement: Sendable { case center, leading }

    /// 按 placement 摆进 area（窗口坐标），格子对齐窗口的点阵。
    init(_ figure: DotFigure, in area: CGRect, placement: Placement = .center, area local: CGRect? = nil) {
        self.figure = figure
        self.placement = placement
        self.area = local
        let pitch = Double(DotMetrics.pitch)
        column = switch placement {
        case .center: Int((Double(area.midX) / pitch - Double(figure.columns) / 2).rounded())
        case .leading: Int((Double(area.minX) / pitch).rounded())
        }
        row = Int((Double(area.midY) / pitch - Double(figure.rows) / 2).rounded())
    }

    var frame: CGRect {
        CGRect(x: CGFloat(column) * DotMetrics.pitch, y: CGFloat(row) * DotMetrics.pitch,
               width: CGFloat(figure.columns) * DotMetrics.pitch, height: CGFloat(figure.rows) * DotMetrics.pitch)
    }

    /// 窗口点阵上 (column, row) 这一格从图形内容里分到多少形变、什么颜色；一点都没分到是 nil。
    /// 浮动的层和随卡片挪动的图形按此刻的位移把这一格的中心反算回图形坐标，由相邻格按双线性权重分配形变量；
    /// 颜色按相同的空间权重在 oklab 中混合，未覆盖的部分取静息点色；闪烁的层连续交接给底层或静息点。
    /// 幅度为 0、没有挪动时正好取回原来那一格。
    func sample(column: Int, row: Int, at date: Date, amplitude: Double, rest: DotColor) -> (shape: Double, color: DotColor)? {
        // 格的中心，以格为单位、相对图形左上角；浮动至多偏出一格
        let x = Double(column - self.column) + 0.5 - shiftX
        let y = Double(row - self.row) + 0.5 - shiftY
        guard x > -1, x < Double(figure.columns) + 1, y > -1, y < Double(figure.rows) + 1 else { return nil }
        let u = x - 0.5, u0 = u.rounded(.down), fu = u - u0
        var shape = 0.0, coverage = 0.0
        var color = DotColor.Oklab.zero
        func contribute(_ look: DotFigure.Look, weight: Double) {
            shape += look.shape * weight
            coverage += weight
            color += look.color.oklab.scaled(by: weight)
        }
        for (index, layer) in figure.layers.enumerated() {
            let v = y - layer.motion.offset(at: date, amplitude: amplitude) - 0.5
            let v0 = v.rounded(.down), fv = v - v0
            let lit = layer.motion.visibility(at: date, amplitude: amplitude)
            func tap(_ du: Int, _ dv: Int, _ w: Double) {
                let c = Int(u0) + du, r = Int(v0) + dv
                guard w > 0, let cell = figure[c, r], cell.layer == index else { return }
                let delay = Double(c + r) / Double(max(figure.columns + figure.rows - 2, 1))
                let look = layer.motion.look(of: cell, at: date, delay: delay, amplitude: amplitude, rest: rest)
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
        color += rest.oklab.scaled(by: max(1 - coverage, 0))
        return (min(shape, 1), DotColor(color.scaled(by: 1 / max(coverage, 1))))
    }
}

/// 背景上一个图形的位置：正拼着的图形、形变起点的旧图形（形变结束后清掉）、开始形变的时刻和是否呼吸。
nonisolated struct FigureSlot: Sendable {
    static let main = "main"
    var figure: PlacedFigure?
    var previous: PlacedFigure?
    var start = Date.distantPast
    var breathing = false
}

/// 一帧的取值：静息的点，加上背景上的图形和经过的波。
nonisolated struct DotField: Sendable {
    let waves: [DotWave]
    let wave: DotWave.Parameters
    let palette: [DotColor]
    let rest: DotColor
    let slots: [FigureSlot]
    /// 呼吸着的图形此刻的不透明度系数。
    let breath: Double

    /// 图形在动（不是静息、没开减少动态效果）。
    let moving: Bool
    let sparks: [DotCell: Date]

    func dot(column: Int, row: Int, at date: Date) -> Dot {
        let square = DotMetrics.square(column: column, row: row)
        var shape = 0.0
        var form = DotForm.square
        for wave in waves {
            let value = wave.shape(at: square, date: date, self.wave)
            if value > shape {
                shape = value
                form = wave.form
            }
        }
        if let start = sparks[DotCell(column: column, row: row)] {
            shape = max(shape, DotSpark.shape(since: start, at: date))
        }
        var target = DotColor.palette(column: column, row: row, in: palette)
        target.alpha *= wave.opacity
        if let cell = slots.lazy.compactMap({ figureCell(in: $0, column: column, row: row, at: date) }).first {
            // 波只占图形之外剩余的幅度，交接处不因大小刚好反超而跳色；满格图形保留原色。
            guard shape > cell.shape else { return Dot(.square, shape: cell.shape, color: cell.color) }
            let amount = (shape - cell.shape) / (1 - cell.shape)
            return Dot(form, shape: shape, color: cell.color.mixed(with: target, by: amount))
        }
        let color = shape > 0 ? rest.mixed(with: target, by: shape) : rest
        return Dot(form, shape: shape, color: color)
    }

    /// 图形在这一格的取值；形变中从旧图形（或静息的点）缓出到新图形（或静息的点）。
    /// 旧图形一开始形变就在 0.3 秒内停下回正，新图形形变完后 0.8 秒内动起来。
    private func figureCell(in slot: FigureSlot, column: Int, row: Int, at date: Date) -> (shape: Double, color: DotColor)? {
        let figure = slot.figure, previousFigure = slot.previous
        let elapsed = date.timeIntervalSince(slot.start)
        let to = figure?.sample(column: column, row: row, at: date,
                                amplitude: moving ? smoothstep((elapsed - DotFigure.transition) / 0.8) : 0, rest: rest)
        let from = previousFigure?.sample(column: column, row: row, at: date,
                                          amplitude: moving ? 1 - smoothstep(elapsed / 0.3) : 0, rest: rest)
        guard to != nil || from != nil else { return nil }
        var eased = 1.0
        if let previousFigure, let figure {
            let first = min(previousFigure.column + previousFigure.row, figure.column + figure.row)
            let last = max(previousFigure.column + previousFigure.figure.columns + previousFigure.row + previousFigure.figure.rows,
                           figure.column + figure.figure.columns + figure.row + figure.figure.rows) - 2
            let delay = last > first ? Double(column + row - first) / Double(last - first) * DotFigure.stagger : 0
            let t = min(max((elapsed - delay) / DotMetrics.morphDuration, 0), 1)
            eased = 1 - pow(1 - t, 3)
        } else if previousFigure != nil || figure != nil {
            // 从无到有或整体收回：所有格子一起形变。
            let t = min(max(elapsed / DotMetrics.morphDuration, 0), 1)
            eased = 1 - pow(1 - t, 3)
        }
        var target = to?.color ?? rest
        if to != nil, slot.breathing { target.alpha *= breath }
        let shape = (from?.shape ?? 0) * (1 - eased) + (to?.shape ?? 0) * eased
        return (shape, (from?.color ?? rest).mixed(with: target, by: eased))
    }

    /// 这一帧交给着色器（DotField.metal）的样子。图形与轨迹覆盖到的格子在这里按 dot 算好，放进按格位散列的表；
    /// 其余格子只有经过的波和静息的点，由着色器逐像素算，静息时 CPU 不碰整片点阵。
    /// origin 是画布左上角的窗口坐标，scale 是画布坐标到窗口坐标的缩放，pixel 是一像素合多少窗口点。
    /// drawsRest 为 false 时不画静息的点，只留图形、波和轨迹。
    func shader(origin: CGPoint, scale: CGFloat, pixel: CGFloat, at date: Date, drawsRest: Bool = true) -> Shader {
        var waveFloats = waves.flatMap { wave -> [Float] in
            let front = date.timeIntervalSince(wave.start) * self.wave.speed * wave.pace
            return [wave.origin.minX, wave.origin.minY, wave.origin.width, wave.origin.height, front, wave.form.index]
                .map { Float($0) }
        }
        if waveFloats.isEmpty { waveFloats = [0] }
        let colors = palette.isEmpty ? DotColor.palette : palette
        return ShaderLibrary.dotField(
            .float4(origin.x, origin.y, scale, pixel), rest.shaderValue, .float(drawsRest ? 1 : 0),
            .floatArray(cellTable(at: date)), .floatArray(waveFloats),
            .float4(wave.width, wave.reach, wave.fadeStart, wave.peak), .float(wave.opacity),
            .floatArray(colors.flatMap { [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)] }),
            .floatArray(DotForm.shaderProfiles))
    }

    /// 格表每格的数：列、行、终态序号（-1 是空位）、shape、不预乘的 sRGB 与透明度。
    static let cellStride = 8

    /// 开放寻址的格表，容量是 2 的幂且至少空一半，着色器按 slot 取位、顺次往后找。
    /// 只收图形可能占到的格子（浮动、随卡片挪动至多偏出一格）和轨迹，算出来是静息的点就不收。
    private func cellTable(at date: Date) -> [Float] {
        var cells = Set(sparks.keys)
        for slot in slots {
            for placed in [slot.figure, slot.previous].compactMap(\.self) {
                let dx = Int(placed.shiftX.rounded(.down)), dy = Int(placed.shiftY.rounded(.down))
                for row in (placed.row + dy - 1)...(placed.row + dy + placed.figure.rows + 1) {
                    for column in (placed.column + dx - 1)...(placed.column + dx + placed.figure.columns + 1) {
                        cells.insert(DotCell(column: column, row: row))
                    }
                }
            }
        }
        let dots = cells.compactMap { cell -> (DotCell, Dot)? in
            let dot = dot(column: cell.column, row: cell.row, at: date)
            return dot.shape <= 1.0 / 512 && dot.color == rest ? nil : (cell, dot)
        }
        var capacity = 2
        while capacity < dots.count * 2 { capacity *= 2 }
        let stride = Self.cellStride
        var table = [Float](repeating: 0, count: capacity * stride)
        for slot in 0..<capacity { table[slot * stride + 2] = -1 }
        let mask = UInt32(capacity - 1)
        for (cell, dot) in dots {
            var slot = Int(Self.slot(column: cell.column, row: cell.row) & mask)
            while table[slot * stride + 2] >= 0 { slot = (slot + 1) & Int(mask) }
            let values = [Double(cell.column), Double(cell.row), dot.form.index, dot.shape,
                          dot.color.red, dot.color.green, dot.color.blue, dot.color.alpha]
            for (offset, value) in values.enumerated() { table[slot * stride + offset] = Float(value) }
        }
        return table
    }

    /// 格位的散列，与 DotField.metal 的 cellHash 一致。
    static func slot(column: Int, row: Int) -> UInt32 {
        let h = (UInt32(truncatingIfNeeded: column) &* 73_856_093) ^ (UInt32(truncatingIfNeeded: row) &* 19_349_663)
        return h ^ (h >> 16)
    }
}

nonisolated private func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

extension EnvironmentValues {
    /// 当前 App 窗口的点阵舞台；预览样本等没有舞台的地方为 nil。
    @Entry var dotStage: DotStage?
    /// 所在卡片会移动时（iPhone 的窗口），报告卡片这一帧实际在哪；不动的地方为 nil。
    @Entry var dotCarrier: DotCarrier?
}

/// 一个 App 窗口里唯一的点阵画布，铺满窗口、放在 App 底色之上，卡片盖在它上面。不参与点击和读屏。
/// 实色卡片会盖住底下的图形，卡片里再垫一层只画图形的（figuresOnly），格子与底下的画布对齐；这一层不改舞台范围。
/// 像素由 Metal 着色器（DotField.metal）画，CPU 每帧只算图形和轨迹那几格。
struct DotCanvas: View {
    var figuresOnly = false
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            // 放在缩放的窗口里时（figuresOnly），按屏幕上的实际大小画，格子和底下的画布对齐
            let scale = figuresOnly && proxy.size.width > 0 ? global.width / proxy.size.width : 1
            let local = proxy.frame(in: .named(DotCarrier.space)).origin
            if let stage {
                let live = (stage.animating || carrier?.moving == true) && !reduceMotion
                TimelineView(.animation(paused: !live)) { timeline in
                    // 静息或减少动态效果时取波都已结束的时刻，直接画出静息的点。
                    let date = live ? timeline.date : .distantFuture
                    let field = stage.field(at: date, rest: .rest(in: environment), live: live)
                    // 在移动的卡片里时按卡片这一帧的实际位置换算，画出来的格子仍落在窗口的点阵上
                    let mapping = live ? carrier?.current : carrier?.final
                    Rectangle().fill(field.shader(origin: mapping?.apply(local) ?? global.origin,
                                                  scale: mapping?.scale ?? scale, pixel: 1 / max(displayScale, 1),
                                                  at: date, drawsRest: !figuresOnly))
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            if !figuresOnly { stage?.bounds = $0 }
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
