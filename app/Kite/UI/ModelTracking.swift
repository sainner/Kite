import Foundation
import Observation

/// 原生视图跟着 Observable 模型变：在 track 里读模型，读过的属性变了就调 changed。通知在属性改之前发出（willSet），
/// changed 里只做标记（如 needsLayout），到排版时再读新值；同一轮的多次变化合成一次。
/// 每次 track 重新登记，之前登记的作废，不叠着通知；begin 只作废、不登记，读之前先改模型时用，自己的改动不回头通知自己。
@MainActor final class ModelTracking {
    private var generation = 0

    func begin() { generation += 1 }

    @discardableResult
    func track<T>(_ read: () -> T, changed: @escaping @MainActor () -> Void) -> T {
        generation += 1
        let current = generation
        return withObservationTracking(read) { [weak self] in
            // 模型都在主线程上改，通知当场在主线程上；万一不在，下一拍再标
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard self?.generation == current else { return }
                    changed()
                }
            } else {
                Task { @MainActor in
                    guard self?.generation == current else { return }
                    changed()
                }
            }
        }
    }
}
