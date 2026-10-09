import SwiftUI

/// 点阵舞台：一个 App 窗口只有一套点阵，像一块显示屏，每个模块是一个像素。组件只占位，把图案（mask）交给所在窗口的舞台；
/// App 背景和窗口卡片上的 DotCanvas 都只是这块屏的取景框，画的是同一份状态里落在自己范围内的那部分。
/// 坐标统一用窗口坐标（SwiftUI 的 .global）：原点是窗口左上角，每个模块（步距 p）的中心一颗点，布局边界都落在模块线上。
///
/// 静息网点是屏的底色，画在焦点所在的一边：焦点在窗口区时由开了点阵的窗口画，App 背景让出；焦点在侧栏（移动端是侧栏或底栏）时由背景画。
/// 各取景框格位一致，卡片移动时格位不跟着挪。
/// 图案按摆上去的先后叠加，后摆上的按覆盖度盖在上面；波和轨迹最后按取大叠上去。
/// 事件（如发送消息的波）只在一段时间里抬高经过的格子，结束后格子退回静息的点。
/// 每个图形占一个位置（slot），格子一直长着，换图形时逐格形变过去；组件消失时用 remove 直接撤掉。
/// 图案落在两格之间（随滚动或卡片位移）时不取整，由相邻格按位置插值显示。
/// 图形的各层可以有自己的小动画（浮动、闪烁、脉冲、帧序列）：格子始终在格位上，浮动时动的是各格从图形内容里分到的形变量
/// （亚格重采样，同 Pigeon 的格阵）。换图形时先停下，形变完再动起来。
@MainActor @Observable
final class DotStage {
    private var waves: [DotWave] = []
    private var slots: [String: FigureSlot] = [:]
    /// 新 slot 的叠放次序，越大越靠上。
    @ObservationIgnored private var nextOrder = 0
    /// 图形摆在会移动的卡片上时，那张卡片这一帧实际挪到哪，见 DotCarrier。
    private var carriers: [String: DotCarrier] = [:]
    /// 指针或手指在空白画板上划过时点亮的格子，键是格位，值是点亮的时刻。
    @ObservationIgnored private var sparks: [DotCell: Date] = [:]
    /// 有波或形变在走时为 true。
    private var ticking = false
    /// 铺满一块区域的图案（点阵签名），见 DotPattern。
    private var patterns: [String: PatternSlot] = [:]
    @ObservationIgnored private var patternRequests: [String: PatternRequest] = [:]
    @ObservationIgnored private var patternInputs: [String: PatternInput] = [:]
    /// 各图案上一帧用的 PatternGrid，位置、大小和压字范围不变就接着用。
    @ObservationIgnored private var patternGrids: [String: PatternGrid] = [:]
    /// 取景框（rect，窗口坐标）是否要逐帧刷新，静息时不耗电：有事件走或有卡片在走时都刷新；
    /// 呼吸、在动的图形和图案只带动与它相交的取景框；不画图案的取景框不受图案带动。
    func animating(in rect: CGRect, patterns drawsPatterns: Bool = true) -> Bool {
        if ticking || carriers.values.contains(where: \.moving) { return true }
        // 浮动和随卡片挪动至多偏出一格
        let near = rect.insetBy(dx: -DotMetrics.pitch, dy: -DotMetrics.pitch)
        return slots.contains { key, slot in
            (slot.breathing || slot.figure?.figure.moves == true) && figureFrame(key)?.intersects(near) == true
        } || drawsPatterns && patterns.values.contains { ($0.carrier?.final.apply($0.area) ?? $0.area).intersects(near) }
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
    /// 各 slot 最近一次要摆的图形；被所在内容的离场收起时留着，回到场上再摆回去。
    @ObservationIgnored private var requests: [String: Request] = [:]
    /// 收起了各 slot 的离场层，见 DotsPresence。
    @ObservationIgnored private var hiders: [String: Set<String>] = [:]

    private struct PatternRequest {
        var pattern: DotPattern
        var area: CGRect
        var quiet: [PatternQuiet]
        var carrier: DotCarrier?
    }

    /// 在 slot 上把 pattern 铺满 area（窗口坐标；给出 carrier 时是卡片坐标），nil 让图案收回。
    /// 从无到有时由中心向外长出来，换图案时沿对角线逐格形变；quiet 是文字压在上面的范围，图案在那里收弱。
    func showPattern(_ pattern: DotPattern?, in area: CGRect, quiet: [PatternQuiet] = [], slot: String, carrier: DotCarrier? = nil) {
        patternRequests[slot] = pattern.map { PatternRequest(pattern: $0, area: area, quiet: quiet, carrier: carrier) }
        placePattern(slot)
    }

    /// 指针在图案上的位置（窗口坐标），离开时给 nil。
    func patternPointer(_ point: CGPoint?, slot: String) {
        patternInputs[slot, default: PatternInput()].pointer = point
    }

    /// 打了一下字：图案的活跃度加一截，随后慢慢落回去。
    func patternKeystroke(slot: String) {
        var input = patternInputs[slot] ?? PatternInput()
        input.activity = min(1, input.level(at: .now) + PatternMotion.activityStep)
        input.activityAt = .now
        patternInputs[slot] = input
    }

    private func placePattern(_ slot: String) {
        let request = hiders[slot] == nil ? patternRequests[slot] : nil
        let now = Date.now
        guard var current = patterns[slot] else {
            guard let request else { return }
            patterns[slot] = PatternSlot(pattern: request.pattern, changed: now, start: now,
                                         area: request.area, quiet: request.quiet, carrier: request.carrier)
            return
        }
        if let request {
            var changed = current.area != request.area || current.quiet != request.quiet || current.carrier !== request.carrier
            if current.leaving != nil {
                // 收回途中又摆回来：重新长出来
                current.previous = nil
                current.changed = now
                current.leaving = nil
                changed = true
            } else if current.pattern != request.pattern {
                current.previous = current.pattern
                current.changed = now
                changed = true
            }
            guard changed else { return }
            current.pattern = request.pattern
            current.area = request.area
            current.quiet = request.quiet
            current.carrier = request.carrier
            patterns[slot] = current
        } else if current.leaving == nil {
            current.leaving = now
            patterns[slot] = current
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(PatternMotion.leaveDuration + 0.05))
                guard let self, self.patterns[slot]?.leaving == now else { return }
                self.patterns[slot] = nil
                self.patternGrids[slot] = nil
            }
        }
    }

    private func resolvedPatterns(at date: Date, live: Bool) -> [ResolvedPattern] {
        patterns.compactMap { key, slot in
            let mapping = slot.carrier.map { live && $0.moving ? $0.current : $0.final }
            let area = mapping?.apply(slot.area) ?? slot.area
            let pitch = DotMetrics.pitch
            let cells = DotMetrics.cells(within: area)
            guard !cells.columns.isEmpty, !cells.rows.isEmpty else { return nil }
            let columns = cells.columns.lowerBound, lastColumn = cells.columns.upperBound - 1
            let rows = cells.rows.lowerBound, lastRow = cells.rows.upperBound - 1
            let input = patternInputs[key] ?? PatternInput()
            let center = (x: Double(columns) + Double((lastColumn - columns + 1) / 2),
                          y: Double(rows) + Double((lastRow - rows + 1) / 2))
            let pointer = input.pointer.map { (x: Double($0.x / pitch) - 0.5 - center.x, y: Double($0.y / pitch) - 0.5 - center.y) }
            // 形变走完就不再算旧图案
            let previous = live && date.timeIntervalSince(slot.changed) < PatternMotion.settled ? slot.previous : nil
            let quiet = slot.quiet.map { $0.mapped(by: mapping) }
            return ResolvedPattern(pattern: slot.pattern, previous: previous, changed: slot.changed, leaving: slot.leaving,
                                   start: slot.start, columns: columns...lastColumn, rows: rows...lastRow,
                                   quiet: quiet, pointer: pointer,
                                   activity: live ? input.level(at: date) : 0, sound: live ? input.sound : 0,
                                   grid: grid(key, columns: columns...lastColumn, rows: rows...lastRow, quiet: quiet))
        }
    }

    private func grid(_ slot: String, columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet]) -> PatternGrid {
        if let grid = patternGrids[slot], grid.matches(columns: columns, rows: rows, quiet: quiet) { return grid }
        let grid = PatternGrid(columns: columns, rows: rows, quiet: quiet)
        patternGrids[slot] = grid
        return grid
    }

    private struct Request {
        var figure: DotFigure
        var area: CGRect
        var placement: PlacedFigure.Placement
        var clip: CGRect?
        var breathing: Bool
        var carrier: DotCarrier?
    }

    /// 从 origin（窗口坐标）向四周推开一道波；不给 form 时取方格终态。pace 小于 1 时整道波放慢，用于不赶时间的场景。
    func emitWave(from origin: CGRect, form: DotForm? = nil, pace: Double = 1) {
        let wave = DotWave(origin: origin, start: .now, form: form ?? .square, pace: pace)
        waves.append(wave)
        keepAnimating(for: wave.duration(DotWave.Parameters()))
    }

    /// 在 slot 上按 placement 把 figure 摆进 area（窗口坐标），nil 让图形退回静息的点。换成另一个图形时逐格形变过去；
    /// 只是区域变了（窗口改大小、内容滚动）就直接挪过去。breathing 时图形按等待呼吸起伏。
    /// clip 是图案可见的范围（同 area 的坐标），出了范围的格子不显示，像窗口裁掉滚出去的内容。
    /// 摆在会移动的卡片上时给出 carrier，area 与 clip 用卡片坐标（DotCarrier.space）：卡片走着的时候图形随它在点阵上滑过去。
    func show(_ figure: DotFigure?, in area: CGRect, placement: PlacedFigure.Placement = .center,
              clip: CGRect? = nil, breathing: Bool = false, slot: String = FigureSlot.main, carrier: DotCarrier? = nil) {
        requests[slot] = figure.map {
            Request(figure: $0, area: area, placement: placement, clip: clip, breathing: breathing, carrier: carrier)
        }
        place(slot)
    }

    /// owner 所在的内容离场（hidden）或回到场上时，收起或摆回 slots 上的图形。见 DotsPresence。
    func setHidden(_ slots: Set<String>, by owner: String, _ hidden: Bool) {
        for slot in slots {
            let was = hiders[slot] != nil
            if hidden {
                hiders[slot, default: []].insert(owner)
            } else {
                hiders[slot]?.remove(owner)
                if hiders[slot]?.isEmpty == true { hiders[slot] = nil }
            }
            if was != (hiders[slot] != nil) {
                place(slot)
                placePattern(slot)
            }
        }
    }

    /// owner 随所在内容一起移除：只去掉它的登记，不把收起的图形摆回去，图形由各自的组件消失时撤掉。
    func release(_ slots: Set<String>, by owner: String) {
        for slot in slots {
            hiders[slot]?.remove(owner)
            if hiders[slot]?.isEmpty == true { hiders[slot] = nil }
        }
    }

    private func place(_ slot: String) {
        let request = hiders[slot] == nil ? requests[slot] : nil
        let figure = request?.figure, area = request?.area ?? .zero, placement = request?.placement ?? .center
        let clip = request?.clip, breathing = request?.breathing ?? false
        // 收回时不再跟着卡片
        let carrier = request?.carrier
        guard figure != nil || slots[slot] != nil else { return }
        if carriers[slot] !== carrier { carriers[slot] = carrier }
        var current = slots[slot] ?? FigureSlot(order: nextOrder)
        if slots[slot] == nil { nextOrder += 1 }
        let placed = figure.map { figure in
            carrier.map { PlacedFigure(figure, in: $0.final.apply(area), placement: placement, area: area,
                                       clip: clip.map($0.final.apply), localClip: clip) }
                ?? PlacedFigure(figure, in: area, placement: placement, clip: clip)
        }
        current.breathing = breathing && placed != nil
        if placed == current.figure {
            if slots[slot]?.breathing != current.breathing { slots[slot] = current }
            return
        }
        if let placed, placed.figure == current.figure?.figure {
            // 换摆放方式（滚动开始或停下）时整格与亚格位置差不到一格，从原来的位置滑过去，不跳。
            if let old = current.figure, old.placement != placed.placement {
                let residual = current.settleResidual(at: .now)
                let x = Double(old.column) + old.shiftX + residual.x - Double(placed.column) - placed.shiftX
                let y = Double(old.row) + old.shiftY + residual.y - Double(placed.row) - placed.shiftY
                if abs(x) > 0.001 || abs(y) > 0.001 {
                    current.settle = (x, y)
                    current.settleStart = .now
                    keepAnimating(for: FigureSlot.settleDuration)
                }
            }
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

    /// 在 point（窗口坐标）附近留下轨迹，越远越淡，随后慢慢退回静息的点。
    func trace(at point: CGPoint) {
        let column = Int((point.x / DotMetrics.pitch).rounded(.down)), row = Int((point.y / DotMetrics.pitch).rounded(.down))
        let now = Date.now
        sparks = sparks.filter { now.timeIntervalSince($0.value) < DotSpark.duration }
        sparks[DotCell(column: column, row: row)] = now
        for dr in -DotSpark.radius...DotSpark.radius {
            for dc in -DotSpark.radius...DotSpark.radius {
                let distance = hypot(Double(dc), Double(dr))
                guard distance > 0, distance <= Double(DotSpark.radius) else { continue }
                let age = DotSpark.halo * distance
                let cell = DotCell(column: column + dc, row: row + dr)
                if sparks[cell].map({ now.timeIntervalSince($0) > age }) ?? true {
                    sparks[cell] = now - age
                }
            }
        }
        keepAnimating(for: DotSpark.duration)
    }

    /// date 时刻的取值快照，供一帧绘制使用。live 为 false（静息或减少动态效果）时不呼吸；
    /// patterns 为 false 时不含图案，逐格求值的图案只由画它的取景框算。
    func field(at date: Date, rest: DotColor, live: Bool, patterns drawsPatterns: Bool = true) -> DotField {
        let wave = DotWave.Parameters()
        return DotField(waves: waves.filter { $0.isActive(at: date, wave) }, wave: wave,
                        palette: DotColor.palette, rest: rest,
                        slots: slots.map { key, slot in (carriers[key]?.carry(slot, moving: live) ?? slot).settled(at: date, live: live) }
                            .sorted { $0.order < $1.order },
                        breath: live ? WaitingBreath.opacity(at: date) : 1, moving: live,
                        sparks: live ? sparks : [:], patterns: drawsPatterns ? resolvedPatterns(at: date, live: live) : [])
    }

    private func keepAnimating(for duration: TimeInterval) {
        activeUntil = max(activeUntil, .now + duration)
        ticking = true
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, (self?.activeUntil.timeIntervalSinceNow ?? 0)) + 0.05))
            guard let self, !Task.isCancelled else { return }
            let wave = DotWave.Parameters()
            waves.removeAll { !$0.isActive(at: .now, wave) }
            sparks = sparks.filter { Date.now.timeIntervalSince($0.value) < DotSpark.duration }
            for key in slots.keys { slots[key]?.previous = nil }
            slots = slots.filter { $0.value.figure != nil }
            requests = requests.filter { slots[$0.key] != nil || hiders[$0.key] != nil }
            carriers = carriers.filter { slots[$0.key] != nil }
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
    nonisolated static let space = "dot.carrier"

    /// 摆到点阵上的坐标：在会移动的卡片里（carrier 不为 nil）用卡片坐标，否则用窗口坐标。
    nonisolated static func coordinateSpace(_ carrier: DotCarrier?) -> CoordinateSpace { carrier == nil ? .global : .named(space) }

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

    /// slot 上的图形（area 是卡片坐标）按卡片停下时的位置摆到点阵上；moving 时再加上这一帧还差的亚格偏移。图形本身不缩放。
    func carry(_ slot: FigureSlot, moving: Bool) -> FigureSlot {
        func carried(_ placed: PlacedFigure) -> PlacedFigure {
            guard let area = placed.area else { return placed }
            let mapping = moving ? current : final
            var result = PlacedFigure(placed.figure, in: final.apply(area), placement: placed.placement, area: area,
                                      clip: placed.localClip.map(mapping.apply), localClip: placed.localClip)
            if moving {
                let center = CGPoint(x: area.midX, y: area.midY)
                let now = current.apply(center), then = final.apply(center)
                result.shiftX += Double((now.x - then.x) / DotMetrics.pitch)
                result.shiftY += Double((now.y - then.y) / DotMetrics.pitch)
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
    static let radius = 2
    /// 每离中心一格，多衰减这么久，边缘的格子就更小。
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
    /// 图形左上角偏出 (column, row) 多少（格）：exact 摆放落在两格之间，或随所在卡片挪动；对齐格位时为 0。
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

    /// 窗口点阵上 (column, row) 这一格从图形内容里分到多少形变、什么颜色、覆盖了几成；一点都没分到是 nil。
    /// 浮动的层和落在两格之间、随卡片挪动的图形按此刻的位移把这一格的中心反算回图形坐标，由相邻格按双线性权重分配形变量；
    /// 颜色按相同的空间权重在 oklab 中混合，未覆盖的部分留给 DotBlend 与下层合成；闪烁的层连续交接给底层或静息点。
    /// 幅度为 0、没有挪动时正好取回原来那一格。
    func sample(column: Int, row: Int, at date: Date, amplitude: Double, rest: DotColor) -> DotSample? {
        if let clip {
            let center = CGPoint(x: (CGFloat(column) + 0.5) * DotMetrics.pitch, y: (CGFloat(row) + 0.5) * DotMetrics.pitch)
            guard clip.contains(center) else { return nil }
        }
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
        return DotSample(shape: min(shape, 1), color: DotColor(color.scaled(by: 1 / coverage)), coverage: min(coverage, 1))
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
    /// 换摆放方式时原位置相对新位置的偏移（格），从 settleStart 起在 settleDuration 内减到零。
    var settle = (x: 0.0, y: 0.0)
    var settleStart = Date.distantPast

    static let settleDuration: TimeInterval = 0.2

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
    let patterns: [ResolvedPattern]

    func dot(column: Int, row: Int, at date: Date) -> Dot {
        // 先按叠放次序把各图案合成到静息的点上，再叠波和轨迹
        var dot = Dot(.square, shape: 0, color: rest)
        // 图案铺在最底下，图形叠在它上面
        for pattern in patterns {
            if let value = pattern.dot(column: column, row: row, at: date, live: moving, rest: rest) { dot = value }
        }
        for slot in slots {
            if let cell = figureCell(in: slot, column: column, row: row, at: date) {
                dot = DotBlend.normal.composite(cell, over: dot)
            }
        }
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
        // 波只占图案之外剩余的幅度，交接处不因大小刚好反超而跳色；满格图案保留原色。
        let lit = DotBlend.lighten.composite(DotSample(shape: shape, color: target, coverage: 1), over: dot)
        return shape > dot.shape ? Dot(form, shape: lit.shape, color: lit.color) : dot
    }

    /// 图形在这一格的取值；形变中从旧图形（或静息的点）缓出到新图形（或静息的点）。
    /// 旧图形一开始形变就在 0.3 秒内停下回正，新图形形变完后 0.8 秒内动起来。
    private func figureCell(in slot: FigureSlot, column: Int, row: Int, at date: Date) -> DotSample? {
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
            eased = easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
        } else if previousFigure != nil || figure != nil {
            // 从无到有或整体收回：所有格子一起形变。
            eased = easeOutCubic(elapsed / DotMetrics.morphDuration)
        }
        var target = to?.color ?? rest
        if to != nil, slot.breathing { target.alpha *= breath }
        // 旧图案按 1 − eased、新图案按 eased 计入覆盖度，颜色按各自覆盖的份量混合
        let fromWeight = (from?.coverage ?? 0) * (1 - eased), toWeight = (to?.coverage ?? 0) * eased
        let coverage = fromWeight + toWeight
        guard coverage > 0 else { return nil }
        let shape = (from?.shape ?? 0) * (1 - eased) + (to?.shape ?? 0) * eased
        let color = (from?.color ?? rest).mixed(with: target, by: toWeight / coverage)
        return DotSample(shape: shape, color: color, coverage: coverage)
    }

    /// 这一帧交给着色器（DotField.metal）的样子。图形与轨迹覆盖到的格子在这里按 dot 算好，放进按格位散列的表；
    /// 图案（点阵签名）铺满整块区域，格子多，可见的部分整批求值后按行列直接排给着色器；其余格子只有经过的波和静息的点，由着色器逐像素算。
    /// origin 是画布左上角的窗口坐标，scale 是画布坐标到窗口坐标的缩放，pixel 是一像素合多少窗口点，bounds 是画布在窗口里的范围。
    /// drawsRest 为 false 时不画静息的点，只留图形、图案、波和轨迹。hidden 是画布被遮掉的范围（窗口坐标），那里不用算。
    func shader(origin: CGPoint, scale: CGFloat, pixel: CGFloat, bounds: CGRect, at date: Date, drawsRest: Bool = true,
                hidden: [CGRect] = []) -> Shader {
        var waveFloats = waves.flatMap { wave -> [Float] in
            let front = date.timeIntervalSince(wave.start) * self.wave.speed * wave.pace
            return [wave.origin.minX, wave.origin.minY, wave.origin.width, wave.origin.height, front, wave.form.index]
                .map { Float($0) }
        }
        if waveFloats.isEmpty { waveFloats = [0] }
        let colors = palette.isEmpty ? DotColor.palette : palette
        let visible = Self.visibleCells(in: bounds)
        let hiddenCells = hidden.map(DotMetrics.cells(within:))
        var patternFloats: [Float] = [], patternValues: [Float] = []
        for pattern in patterns {
            pattern.appendShaderData(to: &patternFloats, values: &patternValues, columns: visible.columns, rows: visible.rows,
                                     hidden: hiddenCells, at: date, live: moving)
        }
        // 着色器的数组参数不能为空，空的给一个占位；占位比一条记录短，着色器按长度跳过。
        let hiddenFloats = hidden.flatMap { [Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)] }
        return ShaderLibrary.dotField(
            .float4(origin.x, origin.y, scale, pixel), rest.shaderValue, .float(drawsRest ? 1 : 0),
            .floatArray(cellTable(at: date, in: visible, hidden: hiddenCells)), .floatArray(waveFloats),
            .float4(wave.width, wave.reach, wave.fadeStart, wave.peak), .float(wave.opacity),
            .floatArray(colors.flatMap { [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)] }),
            .floatArray(DotForm.shaderProfiles),
            .floatArray(patternFloats.isEmpty ? [0] : patternFloats), .floatArray(patternValues.isEmpty ? [0] : patternValues),
            .floatArray(hiddenFloats.isEmpty ? [0] : hiddenFloats))
    }

    /// 画布范围（窗口坐标）覆盖到的格子。
    private static func visibleCells(in bounds: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        let pitch = DotMetrics.pitch
        return (Int((bounds.minX / pitch).rounded(.down))...Int((bounds.maxX / pitch).rounded(.up)),
                Int((bounds.minY / pitch).rounded(.down))...Int((bounds.maxY / pitch).rounded(.up)))
    }

    /// 格表每格的数：列、行、终态序号（-1 是空位）、shape、不预乘的 sRGB 与透明度。
    static let cellStride = 8

    /// 开放寻址的格表，容量是 2 的幂且至少空一半，着色器按 slot 取位、顺次往后找。
    /// 只收落在画布范围（visible）里、图形可能占到的格子（浮动、随卡片挪动至多偏出一格）和轨迹，算出来是静息的点就不收。
    /// 这些格子按 dot 连同底下的图案一起算好，着色器查到就不再算图案；图案的其余格子由着色器算。
    /// 着色器每个像素只查自己那一格，范围外的格子不用算；整格落在 hidden 里的像素全被遮掉，也不用算。
    private func cellTable(at date: Date, in visible: (columns: ClosedRange<Int>, rows: ClosedRange<Int>),
                           hidden hiddenCells: [(columns: Range<Int>, rows: Range<Int>)]) -> [Float] {
        let visibleColumns = visible.columns, visibleRows = visible.rows
        var cells = Set(sparks.keys.filter { visibleColumns.contains($0.column) && visibleRows.contains($0.row) })
        for slot in slots {
            for placed in [slot.figure, slot.previous].compactMap(\.self) {
                let dx = Int(placed.shiftX.rounded(.down)), dy = Int(placed.shiftY.rounded(.down))
                let rows = (placed.row + dy - 1)...(placed.row + dy + placed.figure.rows + 1)
                let columns = (placed.column + dx - 1)...(placed.column + dx + placed.figure.columns + 1)
                guard rows.overlaps(visibleRows), columns.overlaps(visibleColumns) else { continue }
                for row in rows.clamped(to: visibleRows) {
                    for column in columns.clamped(to: visibleColumns) { cells.insert(DotCell(column: column, row: row)) }
                }
            }
        }
        var dots: [(DotCell, Dot)] = []
        func add(_ cell: DotCell) {
            if hiddenCells.contains(where: { $0.columns.contains(cell.column) && $0.rows.contains(cell.row) }) { return }
            let dot = dot(column: cell.column, row: cell.row, at: date)
            if dot.shape > 1.0 / 512 || dot.color != rest { dots.append((cell, dot)) }
        }
        for cell in cells { add(cell) }
        var capacity = 2
        while capacity < dots.count * 2 { capacity *= 2 }
        let stride = Self.cellStride
        var table = [Float](repeating: 0, count: capacity * stride)
        for slot in 0..<capacity { table[slot * stride + 2] = -1 }
        let mask = UInt32(capacity - 1)
        for (cell, dot) in dots {
            var slot = Int(Self.slot(column: cell.column, row: cell.row) & mask)
            while table[slot * stride + 2] >= 0 { slot = (slot + 1) & Int(mask) }
            let base = slot * stride
            table[base] = Float(cell.column)
            table[base + 1] = Float(cell.row)
            table[base + 2] = Float(dot.form.index)
            table[base + 3] = Float(dot.shape)
            table[base + 4] = Float(dot.color.red)
            table[base + 5] = Float(dot.color.green)
            table[base + 6] = Float(dot.color.blue)
            table[base + 7] = Float(dot.color.alpha)
        }
        return table
    }

    /// 格位的散列，与 DotField.metal 的 cellHash 一致。
    static func slot(column: Int, row: Int) -> UInt32 {
        let h = (UInt32(truncatingIfNeeded: column) &* 73_856_093) ^ (UInt32(truncatingIfNeeded: row) &* 19_349_663)
        return h ^ (h >> 16)
    }
}

/// 点阵共用的缓动，输入先截到 0...1。
nonisolated func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// 形变、长出与收回用的缓出。
nonisolated func easeOutCubic(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return 1 - pow(1 - t, 3)
}

extension EnvironmentValues {
    /// 所在 App 窗口的点阵舞台，一个窗口只有一个。
    @Entry var dotStage: DotStage?
    /// 所在卡片会移动时（iPhone 的窗口），报告卡片这一帧实际在哪；不动的地方为 nil。
    @Entry var dotCarrier: DotCarrier?
    /// 图案可见的范围（窗口坐标；在会移动的卡片里是卡片坐标），见 dotClip()。
    @Entry var dotClip: CGRect?
    /// 所在滚动区正在滚动（拖动、惯性或程序滚动），见 dotClip()。
    @Entry var dotScrolling = false
}

extension View {
    /// 放在滚动区上：里面摆到点阵上的图案只在滚动区范围内显示，滚出卡片就不画；
    /// 和文字一样从标题栏、控制区后面滚过去，不在那里截掉。滚动时图案连续跟随，停下后吸附到最近的格位。
    func dotClip() -> some View { modifier(DotClip()) }
}

private struct DotClip: ViewModifier {
    @Environment(\.dotCarrier) private var carrier
    @State private var frame: CGRect?
    @State private var scrolling = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: { frame = $0 }
            .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
            .environment(\.dotClip, frame)
            .environment(\.dotScrolling, scrolling)
    }
}

/// 里面摆在点阵上的图形的 slot，由 DotMask 和 EmptyStage 报上来。
struct DotSlots: PreferenceKey {
    static let defaultValue: Set<String> = []

    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// 内容是否还在场：离场（淡出、滑走、收成停靠）一开始就设为 false，里面摆在点阵上的图形随之逐格收回，回到场上再摆回去。
/// 点阵是窗口共用的，不随视图的转场淡出或移走，也不能等转场结束、视图移除时才撤掉。
/// 由这一层直接告诉舞台：离场中的视图不再刷新（实测里面的 onChange 不触发），只有转场这一层还收得到变化。
struct DotsPresence: ViewModifier {
    let presented: Bool
    @Environment(\.dotStage) private var stage
    @State private var owner = "presence.\(UUID().uuidString)"
    @State private var slots: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(DotSlots.self) { new in
                stage?.setHidden(slots.subtracting(new), by: owner, false)
                stage?.setHidden(new, by: owner, !presented)
                slots = new
            }
            .onChange(of: presented, initial: true) { stage?.setHidden(slots, by: owner, !presented) }
            .onDisappear { stage?.release(slots, by: owner) }
    }
}

extension AnyTransition {
    /// 与别的转场组合：视图离场一开始，摆在点阵上的图案就收回。
    static var dotsPresence: AnyTransition { AnyTransition(DotsPresenceTransition()) }
}

private struct DotsPresenceTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(DotsPresence(presented: phase != .didDisappear))
    }
}

/// 点阵上的一块图案：自己只占位（figure 的列数 × 行数个模块），图案交给所在窗口的舞台，按占位的实际位置摆上去。
/// 跟着内容滚动或随卡片移动时连续跟随，落在两格之间由点阵插值显示；停着时吸附到离占位最近的格位，不让插值把图案拆虚。
/// 所在内容离场（见 DotsPresence）或视图消失时逐格收回。
struct DotMask: View {
    let figure: DotFigure
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.dotClip) private var clip
    @Environment(\.dotScrolling) private var scrolling
    @State private var slot = "mask.\(UUID().uuidString)"
    @State private var area: CGRect?

    var body: some View {
        Color.clear
            .frame(width: CGFloat(figure.columns) * DotMetrics.pitch, height: CGFloat(figure.rows) * DotMetrics.pitch)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: {
                area = $0
                refresh()
            }
            .onChange(of: figure) { refresh() }
            .onChange(of: clip) { refresh() }
            .onChange(of: scrolling) { refresh() }
            .onDisappear { stage?.show(nil, in: .zero, slot: slot) }
            .preference(key: DotSlots.self, value: [slot])
            .allowsHitTesting(false)
    }

    private func refresh() {
        guard let area else { return }
        stage?.show(figure, in: area, placement: scrolling ? .exact : .nearest, clip: clip, slot: slot, carrier: carrier)
    }
}

/// 点阵的取景框，格子按窗口坐标对齐，不参与点击和读屏。画的是所在窗口舞台里落在自己范围内的那部分：静息网点、图案、波和轨迹。
/// 像素由 Metal 着色器（DotField.metal）画，CPU 每帧只算图形和轨迹那几格。
struct DotCanvas: View {
    /// 画静息的点；为 false 时只画图案、波和轨迹。
    var drawsRest = true
    /// 画图案（点阵签名）。图案每帧逐格求值，只由所在窗口的取景框画；App 背景被不透明的窗口盖住，不再重算一遍。
    var drawsPatterns = true
    /// 另有取景框负责的范围（窗口坐标），这里不画也不求值。
    var excluding: [CGRect] = []
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            // 放在缩放的窗口里时，按屏幕上的实际大小画，格子仍与 App 网格对齐。
            let scale = proxy.size.width > 0 ? global.width / proxy.size.width : 1
            let local = proxy.frame(in: .named(DotCarrier.space)).origin
            if let stage {
                // 卡片在走时总在刷新，这里按它要去的位置判断范围里有没有在动的内容
                let frame = carrier?.final.apply(CGRect(origin: local, size: proxy.size)) ?? global
                let live = (stage.animating(in: frame, patterns: drawsPatterns) || carrier?.moving == true) && !reduceMotion
                TimelineView(.animation(paused: !live)) { timeline in
                    // 静息或减少动态效果时取波都已结束的时刻，直接画出静息的点。
                    let date = live ? timeline.date : .distantFuture
                    let field = stage.field(at: date, rest: .rest(in: environment), live: live, patterns: drawsPatterns)
                    // 在移动的卡片里时按卡片这一帧的实际位置换算，画出来的格子仍落在窗口的点阵上
                    let mapping = live ? carrier?.current : carrier?.final
                    let origin = mapping?.apply(local) ?? global.origin, canvasScale = mapping?.scale ?? scale
                    // 挖空的范围换到与 bounds 相同的坐标，那里的格子不再求值
                    let hidden = excluding.map { rect in
                        CGRect(x: origin.x + (rect.minX - global.minX) / scale * canvasScale,
                               y: origin.y + (rect.minY - global.minY) / scale * canvasScale,
                               width: rect.width / scale * canvasScale, height: rect.height / scale * canvasScale)
                    }
                    Rectangle().fill(field.shader(origin: origin, scale: canvasScale, pixel: 1 / max(displayScale, 1),
                                                  bounds: CGRect(origin: origin, size: CGSize(width: proxy.size.width * canvasScale,
                                                                                              height: proxy.size.height * canvasScale)),
                                                  at: date, drawsRest: drawsRest, hidden: hidden))
                }
                // 逐帧刷新不带动画：否则所在视图离场时，每帧的更新都继承转场的动画，转场一直结束不了，视图移除不掉
                .transaction { $0.animation = nil }
            }
        }
        .mask {
            if excluding.isEmpty {
                Rectangle()
            } else {
                GeometryReader { proxy in
                    let global = proxy.frame(in: .global)
                    let scale = proxy.size.width > 0 ? global.width / proxy.size.width : 1
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        for rect in excluding {
                            path.addRect(CGRect(x: (rect.minX - global.minX) / scale, y: (rect.minY - global.minY) / scale,
                                                width: rect.width / scale, height: rect.height / scale))
                        }
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
            }
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
