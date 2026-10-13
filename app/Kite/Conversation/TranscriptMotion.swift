import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 原生对话列表两端共用的动画：行高的走法、逐帧时钟、发送后的滑动。

extension Spring {
    /// 发送后对话往上滑，气泡同时浮进来；控制区推开的波也按它走（见 ThreadControls.sendWave）。
    static let glide = Spring.smooth(duration: 0.5)
}

/// 一行展开收起怎么动，和 SwiftUI 版的那一下对上：气泡折叠是弹簧，工具行是普通缓出。
enum RowMotion {
    case spring(Spring)
    case curve(UnitCurve, duration: TimeInterval)

    var duration: TimeInterval {
        switch self {
        case .spring(let spring): spring.settlingDuration
        case .curve(_, let duration): duration
        }
    }

    /// 走了 time 秒时到哪了：0 起，1 到。
    func progress(at time: TimeInterval) -> Double {
        switch self {
        case .spring(let spring): spring.value(target: 1.0, time: time)
        case .curve(let curve, let duration): curve.value(at: min(time / duration, 1))
        }
    }
}

/// 一行展开收起的动画：从哪个高起，走到哪了。
struct HeightAnimation {
    let from: CGFloat
    let motion: RowMotion
    var started: CFTimeInterval?
    var progress: Double = 0
}

/// 按显示刷新逐帧调 step（传这一帧的时刻），step 返回 false 时停。
/// Mac 用视图的 displayLink（跟着视图所在的屏幕）；iOS 用 CADisplayLink，要显式要 120 Hz，不然 ProMotion 上按 60 Hz 走。
@MainActor final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var step: ((CFTimeInterval) -> Bool)?

    func start(in view: PlatformView, step: @escaping (CFTimeInterval) -> Bool) {
        self.step = step
        let link = Self.link(in: view, target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if step?(link.targetTimestamp) != true {
            link.invalidate()
            self.link = nil
            step = nil
        }
    }

    fileprivate static func link(in view: PlatformView, target: Any, selector: Selector) -> CADisplayLink {
        #if canImport(UIKit)
        let link = CADisplayLink(target: target, selector: selector)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return link
        #else
        return view.displayLink(target: target, selector: selector)
        #endif
    }
}

/// 发送后滑到最底下：Spring.glide（smooth 0.5 秒），按显示刷新逐帧走。
@MainActor final class Glide: NSObject {
    let from: CGFloat
    /// 跟着这一下浮上来的消息。
    var rising: [RowID] = []
    private var started: CFTimeInterval?
    private var link: CADisplayLink?
    private var step: ((Double?) -> Bool)?

    init(from: CGFloat) { self.from = from }

    func start(in view: PlatformView, step: @escaping (Double?) -> Bool) {
        self.step = step
        let link = FrameTicker.link(in: view, target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let started = started ?? now
        self.started = started
        let spring = Spring.glide
        let time = now - started
        let done = time >= spring.settlingDuration
        if step?(done ? nil : spring.value(target: 1.0, time: time)) != true {
            link.invalidate()
            self.link = nil
            step = nil
        }
    }
}
