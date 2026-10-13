import Foundation
import Observation

/// 原生视图跟着 Observable 模型变。用法：在排版（或专门的刷新）里 `tracking.track({ 读模型 }) { 标记重排 }`，读过的属性变了调 changed。
///
/// - 同一时刻只有一条登记：上一条还没触发时 track 只读值、不再登记，触发过以后的下一次 track 才重新登记。
///   withObservationTracking 的登记要等读过的某个属性变了才撤掉，每次排版都登记的话，没变的那些属性上登记越积越多（拖缝时每步一条）。
///   所以两次触发之间读到的属性要在上一条登记里：读的范围变了，得是因为某个读过的属性变了（比如多了一张卡片是因为排布变了）。
/// - 通知在属性改之前发出（willSet），changed 里只做标记（如 needsLayout），到排版时再读新值；同一轮的多次变化合成一次。
///   要在通知里读新值的，自己隔一拍（Task）再读。
/// - 自己要在读之前改模型（比如报视口），包在 quietly 里：改动照样撤掉那条登记，但不回头通知自己。
/// - 视图拆掉时 cancel：还挂着的那条登记以后触发时什么也不做。
@MainActor final class ModelTracking {
    /// 有一条登记还没触发。
    private var live = false
    private var muted = false
    /// 登记的第几代：cancel 以后，之前那条触发时作废。
    private var generation = 0

    @discardableResult
    func track<T>(_ read: () -> T, changed: @escaping @MainActor () -> Void) -> T {
        guard !live else { return read() }
        live = true
        let current = generation
        return withObservationTracking(read) { [weak self] in
            // 模型都在主线程上改，通知当场在主线程上；万一不在，下一拍再标
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.fire(current, changed) }
            } else {
                Task { @MainActor in self?.fire(current, changed) }
            }
        }
    }

    /// 在这里面改模型不回头通知自己（读过的属性变了，登记照样撤掉，下一次 track 重新登记）。
    func quietly(_ body: () -> Void) {
        muted = true
        body()
        muted = false
    }

    /// 不再跟：还挂着的那条登记以后触发时什么也不做。
    func cancel() {
        generation += 1
        live = false
    }

    private func fire(_ current: Int, _ changed: @MainActor () -> Void) {
        guard generation == current else { return }
        live = false
        if !muted { changed() }
    }
}
