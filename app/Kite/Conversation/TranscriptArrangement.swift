import QuartzCore
import SwiftUI

/// 平台每次排版时交进来的几何。
struct TranscriptViewport {
    /// 滚动区露出来的整个范围，文档坐标：Mac 是 clip view 的 bounds。标题栏、控制区底下也画字。
    var bounds: CGRect
    /// 标题栏、控制区让出的距离；iOS 还有键盘和左右安全区。
    var insets: EdgeInsets
    /// 拖缝或吸附中：只量、只放可见区附近的行。由平台传进来（Mac 读 WindowLayout.anyResizing），共用层不读外壳。
    var resizing: Bool

    /// 可见区：滚动区去掉上下让出的那两截，文档坐标。
    var visible: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY + insets.top,
               width: bounds.width, height: max(bounds.height - insets.top - insets.bottom, 0))
    }

    /// 内容列：最宽 transcriptWidth，两边至少留 padding × 2，在让出左右安全区以后的宽里居中。
    var column: (x: CGFloat, width: CGFloat) {
        let width = bounds.width - insets.leading - insets.trailing
        let columnWidth = max(min(width - Metrics.padding * 4, Metrics.transcriptWidth), 0)
        return (insets.leading + ((width - columnWidth) / 2).rounded(), columnWidth)
    }
}

/// 一次排列的结果，平台按它改文档高、定滚动位置。
struct TranscriptLayout: Equatable {
    enum Scroll: Equatable {
        /// 程序在滚：交给那一下，不动滚动位置。
        case none
        /// 可见区顶边对到文档里的这个位置，夹在能滚到的范围里。
        case top(CGFloat)
        /// 文档改了高以后按眼下的位置重新夹一下。
        case current
    }

    var documentHeight: CGFloat
    /// 最后一行的底边，留白露没露出来按它看。
    var lastBottom: CGFloat
    var scroll: Scroll
    /// 还有没量准的行，空闲时要补量。
    var waiting: Bool
}

/// 一行这次放在哪。
enum TranscriptPlacement: Equatable {
    /// 放进列表，视图摆在这里（文档坐标，刚发出去还在下面藏着的已经加上了偏移）。
    case place(CGRect)
    /// 已经放着的先藏起来：离可见区不远，拖缝时不跟着改宽。
    case hide
    /// 已经放着的拿出来。
    case remove
}

/// 原生对话列表两端共用的部分：行的仓库（按 id 复用行对象，看签名、外观决定换不换内容）、排列循环、
/// 放进列表的范围、行高动画、空闲补量。滚动视图、行视图、操作栏宿主各端自己写，按这里的结果执行。
/// 规则见 TranscriptListView 开头（iOS 的 PhoneTranscriptView 同）；跟不跟着最底下、留白、发送后的滑动见 TranscriptFollow。
@MainActor final class TranscriptArrangement {
    private(set) var slots: [TranscriptRowSlot] = []
    private(set) var byID: [RowID: TranscriptRowSlot] = [:]
    /// 各行上次更新时的形状签名，签名变了才换内容，见 update。
    private var shapes: [RowID: Int] = [:]
    /// 环境里会让行重画的几项：外观变了所有行都换一遍。
    private var appearanceKey: AppearanceKey?
    /// 刚发出去的消息建成行（先在下面藏着）的次数，发送时用它看新消息排进来没有。
    private(set) var arrivals = 0
    /// 正在展开、收起的行：从哪个高起、弹簧走到哪了。
    private(set) var heightAnimations: [RowID: HeightAnimation] = [:]
    /// 生成中的话上次按哪个宽量出多高，变了就缓过去，见 arrange。
    private var growth: [RowID: (width: CGFloat, height: CGFloat)] = [:]
    /// 生成中的话变高（多了一行）时怎么走。
    static let growthMotion = RowMotion.curve(.easeOut, duration: 0.2)
    /// 空闲时补量屏幕外的行。
    private var measuring: Task<Void, Never>?

    /// 屏幕外的行排在可见区上下各多远以内就建视图、跟着宽度量。
    static let margin: CGFloat = 0.5
    /// 可见区上下各十分之一屏：这以内的行每次排列都当场量准；拖缝时只量、只放这以内的，其余按原来的高占位，停下再补。
    /// 看着的内容按顶上那一行按住，外面的行只在每步挪动的几点里滑进来，留一点余量够了；多留的每步都要跟着重排。
    static let closeMargin: CGFloat = 0.1
    /// 一次排列里量不急的行最多花多久，超了留给空闲时补。
    static let layoutBudget: CFTimeInterval = 0.006

    // MARK: - 内容

    /// 换上新的行和环境。make 建这一行的实现，fits 看已有的还能不能接着用（种类变了换新的），都由平台给。
    /// 返回被换掉、删掉的行，平台把它们的视图拿出列表。
    func update(_ rows: [TranscriptRow], context: TranscriptRowContext,
                make: (TranscriptRow) -> TranscriptRowSlot,
                fits: (TranscriptRowSlot, TranscriptRow) -> Bool) -> [TranscriptRowSlot] {
        let appearance = AppearanceKey(context.environment)
        let appearanceChanged = appearance != appearanceKey
        appearanceKey = appearance
        var removed: [TranscriptRowSlot] = []
        var next: [TranscriptRowSlot] = []
        var nextByID: [RowID: TranscriptRowSlot] = [:]
        for row in rows {
            var hasher = Hasher()
            row.shape(into: &hasher)
            let shape = hasher.finalize()
            let slot: TranscriptRowSlot
            if let existing = byID[row.id], fits(existing, row) {
                slot = existing
                // 签名（记录只追加，字数就能看出变没变）或外观变了才换内容、作废量过的高
                if shapes[row.id] != shape || appearanceChanged { slot.update(row, context: context) }
            } else {
                slot = make(row)
                slot.update(row, context: context)
                // 刚发出去的消息先在下面藏着，跟着滑到底的那一下浮上来，见各端列表的 startGlideIfReady
                if case .message(let message, _, _) = row.content, context.environment.arrivingMessages.contains(message.id) {
                    slot.rise = 1
                    arrivals += 1
                }
            }
            shapes[row.id] = shape
            next.append(slot)
            nextByID[row.id] = slot
        }
        for (id, slot) in byID where nextByID[id] !== slot {
            removed.append(slot)
            shapes[id] = nil
            growth[id] = nil
        }
        slots = next
        byID = nextByID
        return removed
    }

    // MARK: - 排列

    /// 排一遍：量该量的行、定每行在文档里的位置（slot.frame），给出文档多高和滚动位置该怎么定。
    /// 对齐：程序在滚时交给那一下；跟着最底下、没露留白时贴底；不然保持可见区顶上那一行不动。
    func arrange(_ viewport: TranscriptViewport, follow: TranscriptFollow) -> TranscriptLayout {
        let visible = viewport.visible
        let (x, columnWidth) = viewport.column
        let resizing = viewport.resizing
        let keepsBottom = follow.keepsBottom
        let anchor = keepsBottom || follow.glide != nil ? nil : currentAnchor(in: visible)
        // 顶上那一行是长正文时按住看着的那截：拖缝时它上面没排的是估的高，停下整段排准时还会变，量完按它在行里挪了多少挪回去
        if let anchor { byID[anchor.id]?.pin(at: -anchor.offset) }
        let near = visible.insetBy(dx: 0, dy: -visible.height * (resizing ? Self.closeMargin : Self.margin))
        // 可见区和紧挨着的必须当场量准；再远些的在这一帧还有空时量，不然先用着旧的高，空闲时补（松手后上下半屏一起重量要卡一下）
        let urgent = visible.insetBy(dx: 0, dy: -visible.height * Self.closeMargin)
        let started = CACurrentMediaTime()
        // 拖缝时长正文只排这一截：滚动区露出来的整个范围（标题栏、控制区底下也画字）上下各加十分之一屏。
        // 文本视图自己的视口越过排好的上沿时，补排的段落会和排好的叠在一起（见 TextKitMeasuring.measure(lineWidth:from:through:)）
        let reach = viewport.bounds.insetBy(dx: 0, dy: -visible.height * Self.closeMargin)
        let estimate = estimatedHeight(columnWidth)
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
            let old = slot.frame
            // 量：可见区附近的按眼下的宽量；远的有量过的高就先用着（宽可能是旧的），没有就估，空闲时再补
            func overlaps(_ area: CGRect) -> Bool {
                old.maxY > area.minY && old.minY < area.maxY || old == .zero && y < area.maxY && y + estimate > area.minY
            }
            // 刚发出去的消息离多远都当场量：人翻在上面时它不在附近，按估的高（量过各行的平均）占位，
            // 滑到底的那一下每帧只摆不排，气泡就按估的高撑开，滑完重排才缩回去
            let close = slot.rise > 0 || overlaps(near) && (overlaps(urgent) || CACurrentMediaTime() - started < Self.layoutBudget)
            var height: CGFloat
            // 拖缝中按近似量的，停下后当作没量准
            let exact = !slot.provisional || resizing
            if let measured = slot.measured, measured.width == columnWidth && exact || !close {
                height = measured.height
                if measured.width != columnWidth || !exact { waiting = true }
            } else if close {
                if !exact { slot.measured = nil }
                slot.resizing = resizing
                let lower = max(reach.minY - old.minY, 0), upper = min(reach.maxY, old.maxY) - old.minY
                if resizing, old != .zero, upper > lower {
                    height = slot.height(width: columnWidth, band: lower...upper)
                } else {
                    height = slot.height(width: columnWidth)
                }
            } else {
                height = estimate
                waiting = true
            }
            // 生成中的话量出来的高变了（多了一行）：从眼下的高缓过去，跟着最底下时整列滑上去，不一下跳一行。拖缝、换了宽不算
            if slot.growsSmoothly, close, !resizing {
                if let last = growth[slot.id], last.width == columnWidth, abs(last.height - height) > 0.5, old.height > 0 {
                    heightAnimations[slot.id] = HeightAnimation(from: old.height, motion: Self.growthMotion)
                }
                growth[slot.id] = (columnWidth, height)
            } else {
                growth[slot.id] = nil
            }
            // 展开收起的动画中：从原来的高按弹簧走向新量的高
            if let animation = heightAnimations[slot.id] {
                height = animation.from + (height - animation.from) * animation.progress
            }
            // 拖缝中按近似量的，等停下由空闲补量按精确的重量
            if slot.provisional { waiting = true }
            slot.frame = CGRect(x: x, y: y, width: columnWidth, height: height)
            y += height
        }
        let lastBottom = y
        // 留白：最后一轮（从开启它的那条消息的上一行底边算起）至少多高
        if let trim = follow.trim, lastTurnStartsHuman, !slots.isEmpty {
            let only = lastTurnTop == Metrics.transcriptPadding
            let tail = max(visible.height, follow.heldVisible) - Metrics.transcriptPadding + DotMetrics.module - trim
            let minimum = only ? tail - Metrics.transcriptPadding - DotMetrics.module : tail
            y = max(y, lastTurnTop + max(minimum, 0))
        }
        let height = max(y + Metrics.transcriptPadding, visible.height)
        let scroll: TranscriptLayout.Scroll
        if follow.glide != nil || follow.pendingGlide != nil {
            scroll = .none
        } else if keepsBottom {
            scroll = .top(height - visible.height)
        } else if let anchor, let slot = byID[anchor.id] {
            scroll = .top(slot.frame.minY - anchor.offset + slot.pinShift)
        } else {
            scroll = .current
        }
        return TranscriptLayout(documentHeight: height, lastBottom: lastBottom, scroll: scroll, waiting: waiting)
    }

    /// 可见区附近的行放进列表、摆好位置，远的拿出来。拖缝时只摆量着的那些，其余放着的先藏起来、不跟着改宽：
    /// 文本视图每次改宽，自己排版时都要按新宽估整段多高、排最后一段，白花时间；拿出来又要在松手时一起放回、重画，卡一下。
    /// 没放进列表、也没建过视图的行不报。
    func placements(in viewport: TranscriptViewport, _ body: (TranscriptRowSlot, TranscriptPlacement) -> Void) {
        let visible = viewport.visible
        let near = visible.insetBy(dx: 0, dy: -visible.height * Self.margin)
        let placed = viewport.resizing ? visible.insetBy(dx: 0, dy: -visible.height * Self.closeMargin) : near
        for slot in slots {
            if slot.frame.maxY > placed.minY && slot.frame.minY < placed.maxY {
                // 刚发出去的消息在下面 bubbleRise 处藏着，浮上来的过程见各端列表的 glideStep
                body(slot, .place(slot.viewFrame(in: slot.frame).offsetBy(dx: 0, dy: slot.rise * Metrics.bubbleRise)))
            } else if slot.hasView {
                body(slot, slot.frame.maxY > near.minY && slot.frame.minY < near.maxY ? .hide : .remove)
            }
        }
    }

    /// 要放进列表的行里有还没按眼下的宽量过的：人滚得比空闲补量快时，滑进来的行先要排一遍（arrange 先量再放、按住顶上那一行）。
    func needsMeasure(in viewport: TranscriptViewport) -> Bool {
        let visible = viewport.visible
        let width = viewport.column.width
        let placed = visible.insetBy(dx: 0, dy: -visible.height * (viewport.resizing ? Self.closeMargin : Self.margin))
        return slots.contains { slot in
            slot.frame.maxY > placed.minY && slot.frame.minY < placed.maxY && slot.measured?.width != width
        }
    }

    /// 可见区顶上那一行和它离顶边多远，内容变高变矮后按它把看着的内容放回原处。
    func currentAnchor(in visible: CGRect) -> (id: RowID, offset: CGFloat)? {
        guard let slot = slots.first(where: { $0.frame.maxY > visible.minY }) else { return nil }
        return (slot.id, slot.frame.minY - visible.minY)
    }

    /// 没量过的行先按量过的平均高估，一行都没量过时估 60 pt。
    func estimatedHeight(_ width: CGFloat) -> CGFloat {
        let known = slots.compactMap { $0.measured.map(\.height) }
        guard !known.isEmpty else { return 60 }
        return known.reduce(0, +) / CGFloat(known.count)
    }

    // MARK: - 发送

    /// 发送后那一下滑的一帧，刚发出去的消息浮到 value（1 在下面，0 到位），只往上浮。adopting：这一下还是眼下的滑，
    /// 把还在下面的行都收进来（新消息晚一步才排进来的、上一下被接走没浮完的）；被接走以后只把收过的浮完，不停在半路。
    func rise(_ glide: Glide, to value: CGFloat, adopting: Bool) {
        if adopting {
            for slot in slots where slot.rise > 0 && !glide.rising.contains(slot.id) { glide.rising.append(slot.id) }
        }
        for id in glide.rising {
            if let slot = byID[id], slot.rise > value { slot.rise = value }
        }
    }

    // MARK: - 操作栏

    /// 操作栏平常在这一行底下，底下放不下（会压到控制区）、上面放得下时放到上面；上下都放不下时见 actionBarFrame。
    static func actionBarAbove(anchor: CGRect, visible: CGRect) -> Bool {
        let room = Metrics.actionBarGap + Metrics.paneHeaderButton
        return anchor.maxY + room > visible.maxY && anchor.minY - room >= visible.minY
    }

    /// 操作栏的位置：离这一行 actionBarGap，和这一行给的那一边对齐。上下都放不下（这一行比可见区还高，或顶上那截滚出去了）时
    /// 往上收进可见区，压在这一行的末尾上，不藏到控制区底下。
    static func actionBarFrame(anchor: CGRect, size: CGSize, above: Bool, side: HorizontalEdge, visible: CGRect) -> CGRect {
        let beside = above ? anchor.minY - Metrics.actionBarGap - size.height : anchor.maxY + Metrics.actionBarGap
        let y = min(beside, visible.maxY - Metrics.actionBarGap - size.height)
        let x = side == .leading ? anchor.minX : anchor.maxX - size.width
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - 行高动画

    /// 一行自己展开、收起：从原来的高按这一行给的走法走到新量的高，下面的行跟着挪。
    /// 平台接着重排，逐帧时钟没在走就起一个，每帧调 stepHeights。
    func animateHeight(of slot: TranscriptRowSlot, motion: RowMotion) {
        heightAnimations[slot.id] = HeightAnimation(from: slot.frame.height, motion: motion)
    }

    /// 行高动画的一帧，都走完了返回 false。平台接着重排。
    func stepHeights(_ now: CFTimeInterval) -> Bool {
        for (id, var animation) in heightAnimations {
            let started = animation.started ?? now
            animation.started = started
            let time = now - started
            if time >= animation.motion.duration || byID[id] == nil {
                heightAnimations[id] = nil
            } else {
                animation.progress = animation.motion.progress(at: time)
                heightAnimations[id] = animation
            }
        }
        return !heightAnimations.isEmpty
    }

    // MARK: - 补量

    /// 宽度停下、没有窗口在过渡、人和程序都没在滚（busy 为 false）的时候，屏幕外的行分批按眼下的宽量好，每批不超过 8 ms，
    /// 每批量完调 arrange 重排。viewport 给 nil 时（列表没了）停；paused 为 true 时（窗口不在屏上）也停，平台回到屏上时重排，
    /// 排列发现还有没量准的会再调这里。
    func measureLater(busy: @escaping () -> Bool, paused: @escaping () -> Bool = { false },
                      viewport: @escaping () -> TranscriptViewport?, arrange: @escaping () -> Void) {
        guard measuring == nil else { return }
        measuring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let current = viewport() else { return }
                if paused() {
                    measuring = nil
                    return
                }
                if busy() { continue }
                guard measureBatch(current) else {
                    measuring = nil
                    return
                }
                arrange()
            }
        }
    }

    /// 离可见区最近的没量准的行量一批，还有没量准的返回 true。可见区和紧挨着的留给接着的 arrange 量：它先按住顶上那一行看着的那截再量。
    func measureBatch(_ viewport: TranscriptViewport) -> Bool {
        let columnWidth = viewport.column.width
        let visible = viewport.visible
        let urgent = visible.insetBy(dx: 0, dy: -visible.height * Self.closeMargin)
        let pending = slots.filter { $0.measured?.width != columnWidth || $0.provisional }
        guard !pending.isEmpty else { return false }
        let start = CACurrentMediaTime()
        for slot in pending.sorted(by: { distance($0.frame, from: visible) < distance($1.frame, from: visible) }) {
            if slot.frame.maxY > urgent.minY && slot.frame.minY < urgent.maxY { continue }
            if slot.provisional { slot.measured = nil }
            slot.resizing = false
            _ = slot.height(width: columnWidth)
            if CACurrentMediaTime() - start > 0.008 { break }
        }
        return true
    }

    private func distance(_ frame: CGRect, from visible: CGRect) -> CGFloat {
        max(visible.minY - frame.maxY, frame.minY - visible.maxY, 0)
    }

    // MARK: - 环境

    /// 外观：字色、装饰按它解析成颜色。iOS 的字号还跟着动态字体和粗体文字变。
    private struct AppearanceKey: Equatable {
        let colorScheme: ColorScheme
        let font: Font?
        #if os(iOS)
        let typeSize: DynamicTypeSize
        let weight: LegibilityWeight?
        #endif

        init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            font = environment.font
            #if os(iOS)
            typeSize = environment.dynamicTypeSize
            weight = environment.legibilityWeight
            #endif
        }
    }
}
