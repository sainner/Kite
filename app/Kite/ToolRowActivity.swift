import SwiftUI

/// 等待中的淡蓝呼吸仍铺在标题行背景；执行动效由摘要文字单独处理。
struct ToolRowActivity: View {
    let state: Call.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if state == .queued {
            if reduceMotion {
                Color.accentColor.opacity(0.05)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let breath = (sin(time * .pi * 2 / 2.8) + 1) / 2
                    Color.accentColor.opacity(0.025 + 0.075 * breath)
                }
            }
        }
    }
}

/// 阵风从左向右经过工具摘要或折叠组文字，短暂模糊并向右偏移；布局和链接由原视图负责。
struct ToolSummaryActivity: ViewModifier {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if running && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                // 先在 Double 中收敛到一周期，再传入 Metal，避免大时间戳损失逐帧精度。
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                // 直接使用系统 easeInOut：平滑加速后减速；末段留给风完全离开文字。
                let travel = UnitCurve.easeInOut.value(at: min(phase / 0.88, 1))
                content.layerEffect(
                    ShaderLibrary.kiteWind(.boundingRect, .float(travel)),
                    maxSampleOffset: CGSize(width: 5, height: 3))
            }
        } else {
            content
        }
    }
}
