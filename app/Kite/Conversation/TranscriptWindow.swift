import SwiftUI

/// Mac 主对话的按需排版：只排可见区附近的几组，其余的组按量过的高占位，总高始终是真实的。
/// LazyVStack 也只排可见区附近，但没排过的组按已排过的平均估高，滚到新地方估计一修正总高就变，滚动条跟着跳
/// （2026-10-12 离屏实测：200 条回复打开时估 1.2 万 pt，实际 3.8 万）；整个排又太慢（打开 0.8 秒、改宽度每帧 365 ms）。
/// 所以每组的高都量出来：打开以后、改了宽度、屏幕外的组内容变了，空闲时把这些组在原地藏着排一遍量高（不画，不占排版），
/// 量好再换上；换的组在可见区上面时，同一次更新把滚动位置补上同样的距离，看着的内容不动（TranscriptScroll.contentAboveChanged）。
/// 都量过以后滚动时总高不再变。滚远了的组拆掉只留占位，和 LazyVStack 一样，组里展开收起这些状态不留（实测 LazyVStack 也不留）。
///
/// 改宽度时（拖缝的每一帧、旁边窗口缩小恢复时这个窗口让位的那一下）只重排看得见的组：可见区上下各一屏的组也排着真内容，
/// 除了紧挨着可见区的一小段，它们一直按停下时的宽排（Slot.frozenWidth），宽度变了不跟，等宽度停下、没有窗口在过渡时再分几次跟上新宽（thaw）。
/// 可见区上面的组跟上新宽会把看着的内容顶走：跟着最底下时底部对齐兜住；不跟着时先换成占位，藏着按新宽量好高再换回来，
/// 同一次补滚动位置，这几组里展开收起的状态不留。
/// 藏着量高、跟上新宽都要在主线程上排版，一次十几毫秒，都避开所有窗口的过渡（WindowLayout.anyTransitioning）。
@MainActor
final class TranscriptWindow {
    /// 一组的状态，TranscriptView 的每组只读自己这一份。
    @Observable
    final class Slot {
        let id: RowID
        /// 排真内容：可见区附近的、最后一组、开着操作栏的。
        fileprivate(set) var live = false
        /// 占位时在原地藏着排一遍量高。
        fileprivate(set) var measuring = false
        /// 占位多高：排真内容时报来的、藏着量出来的，都没有就是估的。
        fileprivate(set) var height: CGFloat
        /// 排真内容、离可见区远一点时按这个宽排，改宽度时不跟着重排；在可见区和紧挨着的一段里为 nil，跟着对话的宽。
        fileprivate(set) var frozenWidth: CGFloat?
        /// 一直排真内容。
        @ObservationIgnored fileprivate var pinned = false
        /// 内容的签名，变了要重量。
        @ObservationIgnored fileprivate var signature = 0
        /// 量出 height 时的宽和签名。
        @ObservationIgnored fileprivate var measured: (width: CGFloat, signature: Int)?
        /// 藏着排出来的高和报来的时刻，收批时换上。
        @ObservationIgnored fileprivate var pending: (height: CGFloat, at: ContinuousClock.Instant)?
        /// 上边在对话里的位置，排列时算出来。
        @ObservationIgnored fileprivate var top: CGFloat = 0

        fileprivate init(id: RowID, height: CGFloat) {
            self.id = id
            self.height = height
        }
    }

    /// 补位置、看忙不忙。
    weak var scroll: TranscriptScroll?
    private var slots: [RowID: Slot] = [:]
    private var order: [RowID] = []
    /// 组的宽，排真内容的组报来。
    private var width: CGFloat = 0
    private var widthChanged = ContinuousClock.now
    /// 可见区，对话内容里的坐标。
    private var visible: CGRect?
    private var measuring: Task<Void, Never>?
    private var thawing: Task<Void, Never>?

    /// 改宽度停下多久以后才重量屏幕外的组。
    private static let settle = Duration.milliseconds(300)

    /// 这会儿不做往后放的排版：宽度还在变（量了也作废）、有窗口在过渡、程序在滚。
    private var busy: Bool {
        ContinuousClock.now - widthChanged < Self.settle || WindowLayout.anyTransitioning || scroll?.gliding == true
    }

    func slot(_ id: RowID) -> Slot {
        if let slot = slots[id] { return slot }
        let slot = Slot(id: id, height: estimate)
        slots[id] = slot
        return slot
    }

    /// 没量过的组按量过的平均估，一组都没量过时估 200 pt。
    private var estimate: CGFloat {
        let known = slots.values.filter { $0.measured != nil }
        guard !known.isEmpty else { return 200 }
        return known.reduce(0) { $0 + $1.height } / CGFloat(known.count)
    }

    /// 组的先后。
    func reorder(_ ids: [RowID]) {
        order = ids
        let kept = Set(ids)
        slots = slots.filter { kept.contains($0.key) }
        arrange()
    }

    func contentChanged(_ slot: Slot, signature: Int) {
        slot.signature = signature
        if slot.live { slot.measured = (slot.frozenWidth ?? width, signature) }
        arrange()
    }

    func pin(_ slot: Slot, _ pinned: Bool) {
        slot.pinned = pinned
        arrange()
    }

    /// 排真内容的组排出来多大。按原宽排着的组不改对话的宽。
    func laidOut(_ slot: Slot, size: CGSize) {
        guard slot.live else { return }
        if slot.frozenWidth == nil, size.width != width {
            let first = width == 0
            width = size.width
            widthChanged = .now
            scheduleThaw()
            // 知道了宽才能把屏幕外的组按它定住
            if first { arrange() }
        }
        slot.measured = (size.width, slot.signature)
        if slot.height != size.height { slot.height = size.height }
    }

    /// 藏着排的组排出来多高。
    func measured(_ slot: Slot, height: CGFloat) {
        guard slot.measuring else { return }
        slot.pending = (height, .now)
    }

    func visibleChanged(_ rect: CGRect) {
        guard rect != visible else { return }
        visible = rect
        arrange()
    }

    private func certain(_ slot: Slot) -> Bool {
        slot.measured.map { $0.width == width && $0.signature == slot.signature } ?? false
    }

    /// 按可见区重新决定哪些组排真内容。可见区里的一定排；上下各一屏以内的量准了才排，没量准的先藏着量；更远的占位。
    private func arrange() {
        guard let visible else {
            for slot in slots.values {
                if slot.live != slot.pinned { slot.live = slot.pinned }
                if slot.frozenWidth != nil { slot.frozenWidth = nil }
            }
            return
        }
        let margin = visible.height
        var top: CGFloat = 0
        var waiting = false
        for id in order {
            guard let slot = slots[id] else { continue }
            slot.top = top
            let bottom = top + slot.height
            let shown = bottom > visible.minY && top < visible.maxY
            let near = bottom > visible.minY - margin && top < visible.maxY + margin
            // 可见区上下各四分之一屏也跟着对话的宽排：改宽度时可见的组变高变矮，旁边的组会被带进可见区，按原宽排着就露出一帧
            let follows = bottom > visible.minY - margin / 4 && top < visible.maxY + margin / 4
            // 排着真内容的组按自己报来的高算，一直是准的；改宽度时先报的组不会把还没报的挤成占位。
            // 刚换成真内容、还没报来眼下的宽下多高的组也先留着：它的高还是估的或旧宽下的，按它算位置会把它挤回占位，
            // 换回占位对话一变矮又把它拉进来，一次排版里来回换（2026-10-12 离屏实测：四屏长的对话改宽度时每帧换几百次，
            // 一帧两百多毫秒，总高也停在估的高上）
            let reporting = slot.live && slot.frozenWidth == nil && !certain(slot)
            let live = slot.pinned || shown || reporting || near && (slot.live || certain(slot))
            if slot.live != live {
                slot.live = live
                if live { slot.measuring = false }
            }
            // 屏幕外排真内容的按眼下的宽定住；已经定住的不跟着改，等 thaw
            let frozen = live && !follows && width > 0 ? slot.frozenWidth ?? width : nil
            if slot.frozenWidth != frozen { slot.frozenWidth = frozen }
            if !live && !certain(slot) { waiting = true }
            top = bottom
        }
        if waiting && measuring == nil {
            measuring = Task { [weak self] in
                await self?.measureAll()
                self?.measuring = nil
            }
        }
    }

    /// 宽度停下、没有窗口在过渡、人和程序都没在滚的时候，屏幕外按原宽排着的组分几次跟上新宽。
    private func scheduleThaw() {
        guard thawing == nil else { return }
        thawing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if busy || scroll?.userScrolling == true { continue }
                guard thaw() else {
                    thawing = nil
                    return
                }
            }
        }
    }

    /// 离可见区最近的、按原宽排着的组凑够半屏，换成眼下的宽；还有没换的返回 true。
    /// 可见区下面的直接换：内容按顶部对齐或钉着坐标，看着的不动。上面的在跟着最底下时也直接换，底部对齐兜住；
    /// 不然先换成占位，藏着按新宽量好高再换回来，同一次补滚动位置（见 commit）。
    private func thaw() -> Bool {
        guard let visible else { return false }
        let stale = order.compactMap { slots[$0] }
            .filter(isStale)
            .sorted { distance($0, from: visible) < distance($1, from: visible) }
        let keepsBottom = scroll?.keepsBottom ?? true
        var height: CGFloat = 0
        for slot in stale {
            if slot.top < visible.minY, !keepsBottom, !slot.pinned {
                slot.live = false
                slot.frozenWidth = nil
            } else {
                slot.frozenWidth = width
            }
            height += slot.height
            if height >= visible.height / 2 { break }
        }
        arrange()
        return stale.contains(where: isStale)
    }

    /// 排着真内容、按的不是眼下的宽。
    private func isStale(_ slot: Slot) -> Bool {
        guard slot.live, let frozen = slot.frozenWidth else { return false }
        return frozen != width
    }

    /// 一批一批藏着量，直到屏幕外的组都量准。人在滚时只量快进可见区的；宽度还在变（量了也作废）、有窗口在过渡、程序在滚时不量。
    private func measureAll() async {
        while !Task.isCancelled {
            let batch = busy ? [] : nextBatch(nearOnly: scroll?.userScrolling == true)
            guard !batch.isEmpty else {
                guard slots.values.contains(where: { !$0.live && !certain($0) }) else { return }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let width = width
            for slot in batch {
                slot.pending = nil
                slot.measuring = true
            }
            // 都报了高、而且一拍里没再变才收：附件、表格、折叠的气泡排完会再报一次
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .milliseconds(500) {
                try? await Task.sleep(for: .milliseconds(8))
                let settled = batch.allSatisfy { slot in
                    !slot.measuring || slot.pending.map { ContinuousClock.now - $0.at > .milliseconds(20) } ?? false
                }
                if settled { break }
            }
            commit(batch, width: width)
        }
    }

    /// 离可见区最近的几组没量准的，凑够半屏高为一批：实测一屏的回复藏着排一遍约 15 ms，超过一帧，人在滚时会顿一下。
    /// 都在可见区上面或都在下面：上面的换高要补滚动位置，一批只补一个方向。
    private func nextBatch(nearOnly: Bool) -> [Slot] {
        guard let visible else { return [] }
        func distance(_ slot: Slot) -> CGFloat { self.distance(slot, from: visible) }
        let candidates = order.compactMap { slots[$0] }
            .filter { !$0.live && !certain($0) && (!nearOnly || distance($0) < visible.height) }
            .sorted { distance($0) < distance($1) }
        guard let first = candidates.first else { return [] }
        let above = first.top < visible.minY
        var batch: [Slot] = []
        var height: CGFloat = 0
        for slot in candidates where (slot.top < visible.minY) == above {
            batch.append(slot)
            height += slot.height
            if height >= visible.height / 2 { break }
        }
        return batch
    }

    /// 组离可见区多远，在里面为 0。
    private func distance(_ slot: Slot, from visible: CGRect) -> CGFloat {
        max(visible.minY - (slot.top + slot.height), slot.top - visible.maxY, 0)
    }

    /// 量出来的高换上去。可见区上面的组变高变矮多少，滚动位置就补多少。
    private func commit(_ batch: [Slot], width: CGFloat) {
        var above: CGFloat = 0
        for slot in batch {
            let pending = slot.pending
            slot.pending = nil
            guard slot.measuring else { continue }
            slot.measuring = false
            guard width == self.width, slots[slot.id] === slot else { continue }
            slot.measured = (width, slot.signature)
            // 半秒都没报高的不再重试，按原来的高算
            guard let height = pending?.height else { continue }
            guard height != slot.height else { continue }
            if let visible, slot.top < visible.minY { above += height - slot.height }
            slot.height = height
        }
        if above != 0 { scroll?.contentAboveChanged(by: above) }
        arrange()
    }
}
