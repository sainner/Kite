#if DEBUG && os(macOS)
import AppKit
import os

/// 影子对照（临时，零差异后删）：排列循环搬进共用的 TranscriptArrangement 之前的写法原样留在这里，每次排版两份都跑、逐项比对。
/// 新的一份照常排（量高、定 frame）；旧的一份不碰行：读排版前记下的 frame、量过的高和是否近似，要量的按新的一份量出来的结果重放，
/// 预算够不够也按新的一份的判断重放。比对每行的 frame、文档高、最后一行底边、滚动目标、要不要补量，
/// 量了哪些行、按什么宽、整行还是一截，按住哪一行哪里；放进列表的范围另比。不一致记日志（类别 transcript-shadow）并断言。
@MainActor struct TranscriptShadow {
    private static let log = Logger(subsystem: "com.sainner.kite", category: "transcript-shadow")
    /// 比过几次、不一致几次，探针读。
    private(set) static var comparisons = 0
    private(set) static var mismatches = 0

    private let arrangement: TranscriptArrangement
    private let frames: [RowID: CGRect]
    private let measured: [RowID: (width: CGFloat, height: CGFloat)?]
    private let provisional: [RowID: Bool]
    private let trace = TranscriptArrangement.Trace()

    /// 排版前记下各行的状态，让新的一份记下量了什么。
    init(_ arrangement: TranscriptArrangement) {
        self.arrangement = arrangement
        var frames: [RowID: CGRect] = [:], measured: [RowID: (width: CGFloat, height: CGFloat)?] = [:], provisional: [RowID: Bool] = [:]
        for slot in arrangement.slots {
            frames[slot.id] = slot.frame
            measured[slot.id] = slot.measured
            provisional[slot.id] = slot.provisional
        }
        self.frames = frames
        self.measured = measured
        self.provisional = provisional
        arrangement.trace = trace
    }

    /// 新的一份排完以后：按旧写法再排一遍（不碰行），和新的比。
    func compare(_ layout: TranscriptLayout, viewport: TranscriptViewport, follow: TranscriptFollow) {
        arrangement.trace = nil
        var problems: [String] = []
        let legacy = legacyLayoutRows(viewport: viewport, follow: follow, problems: &problems)
        for slot in arrangement.slots {
            guard let old = legacy.frames[slot.id] else { continue }
            if !Self.same(old, slot.frame) { problems.append("\(slot.id) frame 旧 \(old) 新 \(slot.frame)") }
        }
        if !Self.same(legacy.layout.documentHeight, layout.documentHeight) {
            problems.append("文档高 旧 \(legacy.layout.documentHeight) 新 \(layout.documentHeight)")
        }
        if !Self.same(legacy.layout.lastBottom, layout.lastBottom) {
            problems.append("最后一行底边 旧 \(legacy.layout.lastBottom) 新 \(layout.lastBottom)")
        }
        if legacy.layout.waiting != layout.waiting { problems.append("补量 旧 \(legacy.layout.waiting) 新 \(layout.waiting)") }
        switch (legacy.layout.scroll, layout.scroll) {
        case (.none, .none), (.current, .current): break
        case (.top(let old), .top(let new)) where Self.same(old, new): break
        default: problems.append("滚动 旧 \(legacy.layout.scroll) 新 \(layout.scroll)")
        }
        Self.report(problems, "排列")
    }

    /// 放进列表的范围：在执行之前，按旧写法（realize）和新的（placements 加上平台的 superview 判断）各算一遍比。
    static func compareRealize(_ arrangement: TranscriptArrangement, viewport: TranscriptViewport) {
        var fresh: [RowID: TranscriptPlacement] = [:]
        arrangement.placements(in: viewport) { slot, placement in
            switch placement {
            case .place: fresh[slot.id] = placement
            case .hide, .remove: if slot.view.superview != nil { fresh[slot.id] = placement }
            }
        }
        // 旧写法，原样
        var legacy: [RowID: TranscriptPlacement] = [:]
        let visible = viewport.visible
        let near = visible.insetBy(dx: 0, dy: -visible.height * 0.5)
        let placed = viewport.resizing ? visible.insetBy(dx: 0, dy: -visible.height * 0.1) : near
        for slot in arrangement.slots {
            if slot.frame.maxY > placed.minY && slot.frame.minY < placed.maxY {
                legacy[slot.id] = .place(slot.viewFrame(in: slot.frame).offsetBy(dx: 0, dy: slot.rise * Metrics.bubbleRise))
            } else if slot.hasView, slot.view.superview != nil {
                legacy[slot.id] = slot.frame.maxY > near.minY && slot.frame.minY < near.maxY ? .hide : .remove
            }
        }
        var problems: [String] = []
        for id in Set(legacy.keys).union(fresh.keys) where legacy[id] != fresh[id] {
            problems.append("\(id) 放置 旧 \(String(describing: legacy[id])) 新 \(String(describing: fresh[id]))")
        }
        report(problems, "放置")
    }

    private static func report(_ problems: [String], _ what: String) {
        comparisons += 1
        guard !problems.isEmpty else { return }
        mismatches += 1
        for problem in problems.prefix(20) { log.error("\(what, privacy: .public)不一致：\(problem, privacy: .public)") }
        assertionFailure("对话列表影子对照\(what)不一致：\(problems.first ?? "")")
    }

    private static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.0001 }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        same(a.minX, b.minX) && same(a.minY, b.minY) && same(a.width, b.width) && same(a.height, b.height)
    }

    // MARK: - 旧写法

    /// TranscriptListView.layoutRows 搬家前的排列部分，控制流原样；读行的地方换成排版前的快照，量高、预算换成重放。
    private func legacyLayoutRows(viewport: TranscriptViewport, follow: TranscriptFollow, problems: inout [String])
        -> (frames: [RowID: CGRect], layout: TranscriptLayout) {
        let slots = arrangement.slots
        let width = viewport.bounds.width
        let visible = viewport.visible
        let (x, columnWidth) = Self.column(width: width)
        let resizing = viewport.resizing
        let keepsBottom = follow.following && !follow.blankShown && follow.glide == nil && follow.pendingGlide == nil
        let anchor = keepsBottom || follow.glide != nil ? nil : currentAnchor(in: visible)
        if let anchor {
            if trace.pin?.id != anchor.id || trace.pin.map({ !Self.same($0.y, -anchor.offset) }) ?? true {
                problems.append("按住 旧 \(anchor.id) \(-anchor.offset) 新 \(String(describing: trace.pin))")
            }
        } else if let pin = trace.pin {
            problems.append("按住 旧 无 新 \(pin)")
        }
        let near = visible.insetBy(dx: 0, dy: -visible.height * (resizing ? 0.1 : 0.5))
        let urgent = visible.insetBy(dx: 0, dy: -visible.height * 0.1)
        var askedBudget: Set<RowID> = []
        func budgetLeft(_ id: RowID) -> Bool {
            askedBudget.insert(id)
            guard let left = trace.budget[id] else {
                problems.append("\(id) 旧写法看了预算，新的没看")
                return true
            }
            return left
        }
        var replayed: Set<RowID> = []
        func replayHeight(_ id: RowID, width: CGFloat, band: ClosedRange<CGFloat>?) -> CGFloat {
            replayed.insert(id)
            guard let measure = trace.measures[id] else {
                problems.append("\(id) 旧写法量 \(width) \(String(describing: band))，新的没量")
                return 0
            }
            let sameBand = switch (measure.band, band) {
            case (nil, nil): true
            case (let new?, let old?): Self.same(new.lowerBound, old.lowerBound) && Self.same(new.upperBound, old.upperBound)
            default: false
            }
            if !Self.same(measure.width, width) || !sameBand {
                problems.append("\(id) 量法 旧 \(width) \(String(describing: band)) 新 \(measure.width) \(String(describing: measure.band))")
            }
            return measure.height
        }
        let reach = viewport.bounds.insetBy(dx: 0, dy: -visible.height * 0.1)
        let estimate = estimatedHeight(columnWidth)
        var frames: [RowID: CGRect] = [:]
        var y = Metrics.transcriptPadding
        var lastTurnTop = Metrics.transcriptPadding
        var lastTurnStartsHuman = slots.first?.row.startsHumanTurn ?? false
        var waiting = false
        for (index, slot) in slots.enumerated() {
            if index > 0 {
                if slot.row.startsHumanTurn {
                    lastTurnTop = y
                    lastTurnStartsHuman = true
                }
                y += Metrics.rowSpacing + slot.row.gap
            }
            let old = self.frames[slot.id] ?? .zero
            func overlaps(_ area: CGRect) -> Bool {
                old.maxY > area.minY && old.minY < area.maxY || old == .zero && y < area.maxY && y + estimate > area.minY
            }
            let close = overlaps(near) && (overlaps(urgent) || budgetLeft(slot.id))
            var height: CGFloat
            let exact = !(provisional[slot.id] ?? false) || resizing
            if let measured = measured[slot.id] ?? nil, measured.width == columnWidth && exact || !close {
                height = measured.height
                if measured.width != columnWidth || !exact { waiting = true }
            } else if close {
                let lower = max(reach.minY - old.minY, 0), upper = min(reach.maxY, old.maxY) - old.minY
                if resizing, old != .zero, upper > lower {
                    height = replayHeight(slot.id, width: columnWidth, band: lower...upper)
                } else {
                    height = replayHeight(slot.id, width: columnWidth, band: nil)
                }
            } else {
                height = estimate
                waiting = true
            }
            if let animation = arrangement.heightAnimations[slot.id] {
                height = animation.from + (height - animation.from) * animation.progress
            }
            // 量完以后的是否近似：新的一份量过同样的行，行上的就是旧写法量完会看到的
            if slot.provisional { waiting = true }
            frames[slot.id] = CGRect(x: x, y: y, width: columnWidth, height: height)
            y += height
        }
        for id in Set(trace.measures.keys).subtracting(replayed) { problems.append("\(id) 新的量了，旧写法不量") }
        for id in Set(trace.budget.keys).subtracting(askedBudget) { problems.append("\(id) 新的看了预算，旧写法没看") }
        let lastBottom = y
        if let trim = follow.trim, lastTurnStartsHuman, !slots.isEmpty {
            let only = lastTurnTop == Metrics.transcriptPadding
            let tail = max(visible.height, follow.heldVisible) - Metrics.transcriptPadding + DotMetrics.module - trim
            let minimum = only ? tail - Metrics.transcriptPadding - DotMetrics.module : tail
            y = max(y, lastTurnTop + max(minimum, 0))
        }
        let height = max(y + Metrics.transcriptPadding, visible.height)
        var scroll = TranscriptLayout.Scroll.none
        if follow.glide == nil, follow.pendingGlide == nil {
            if keepsBottom {
                scroll = .top(height - visible.height)
            } else if let anchor, let slot = arrangement.byID[anchor.id], let frame = frames[anchor.id] {
                scroll = .top(frame.minY - anchor.offset + slot.pinShift)
            } else {
                scroll = .current
            }
        }
        return (frames, TranscriptLayout(documentHeight: height, lastBottom: lastBottom, scroll: scroll, waiting: waiting))
    }

    private static func column(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let columnWidth = max(min(width - Metrics.padding * 4, Metrics.transcriptWidth), 0)
        return (((width - columnWidth) / 2).rounded(), columnWidth)
    }

    private func currentAnchor(in visible: CGRect) -> (id: RowID, offset: CGFloat)? {
        guard let slot = arrangement.slots.first(where: { (frames[$0.id] ?? .zero).maxY > visible.minY }) else { return nil }
        return (slot.id, (frames[slot.id] ?? .zero).minY - visible.minY)
    }

    private func estimatedHeight(_ width: CGFloat) -> CGFloat {
        let known = arrangement.slots.compactMap { (measured[$0.id] ?? nil).map(\.height) }
        guard !known.isEmpty else { return 60 }
        return known.reduce(0, +) / CGFloat(known.count)
    }
}
#endif
