import SwiftUI

/// 标题栏圆环表达主状态与上下文占比，说明（悬停、长按与读屏）保留状态与结果；信息区有提示时改为提示。
struct ThreadStatusRing: View {
    @Environment(WorkThread.self) private var thread
    private let lineWidth: CGFloat = 3

    var body: some View {
        ContextRing(phase: thread.statusPhase, fraction: thread.state?.context?.fraction, lineWidth: lineWidth)
            .paneHeaderRing(lineWidth: lineWidth, status: thread.statusLabel + "\n" + thread.contextDescription)
    }
}

private extension WorkThread {
    var contextDescription: String {
        guard let usage = state?.context else { return "上下文用量未知" }
        let measured = Date(timeIntervalSince1970: usage.measuredAt / 1000)
            .formatted(date: .omitted, time: .standard)
        let amount = if let fraction = usage.fraction, let window = usage.windowTokens {
            "上下文占用 \(fraction.formatted(.percent.precision(.fractionLength(0))))，\(usage.inputTokens) / \(window) token"
        } else {
            "输入用量 \(usage.inputTokens) token，上下文窗口上限未知"
        }
        return amount + "；最近一次已完成请求，测量于 \(measured)"
    }
}

struct ContextRing: View {
    let phase: String
    let fraction: Double?
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { Self.color(phase) }
    private var period: Double { Self.period(phase) }

    /// 各阶段的颜色与动画周期，停靠栏的脉冲波也用这一套。
    static func color(_ phase: String) -> Color {
        switch phase {
        case "running": .accentColor
        case "stopping", "waiting": Theme.warning
        case "finishing": Palette.dewy
        default: .secondary
        }
    }

    static func period(_ phase: String) -> Double {
        switch phase {
        case "running": 2.4
        case "stopping": 1
        // 等你回应：警示黄，按等待的节奏明暗起伏，不转
        case "waiting": WaitingBreath.period
        case "finishing": 1.6
        default: 0
        }
    }

    var body: some View {
        let still = period == 0 || reduceMotion
        // 旋转、明暗交给图层动画，跟屏幕刷新率走，主线程不逐帧重画
        ContextRingLayers(phase: phase, fraction: fraction, lineWidth: lineWidth, still: still)
    }
}
