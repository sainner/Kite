import SwiftUI

/// 等待时主体呼吸，执行时像素扫掠；原视图继续负责布局和链接。
struct ToolRowActivity: ViewModifier {
    let state: Call.State?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if state == .queued {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                let breath = (sin(phase * .pi * 2) + 1) / 2
                content.opacity(0.45 + 0.55 * breath)
            }
        } else if state == .running {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                // 先在 Double 中收敛到一周期，再传入 Metal，避免大时间戳损失逐帧精度。
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                let travel = UnitCurve.easeInOut.value(at: min(phase / 0.88, 1))
                content.layerEffect(ShaderLibrary.kitePixels(.boundingRect, .float(travel)),
                                    maxSampleOffset: CGSize(width: 4, height: 4))
            }
        } else {
            content
        }
    }
}
