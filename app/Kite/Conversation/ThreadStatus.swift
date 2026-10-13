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
        case "stopping": Theme.warning
        case "finishing": Palette.dewy
        default: .secondary
        }
    }

    static func period(_ phase: String) -> Double {
        switch phase {
        case "running": 2.4
        case "stopping": 1
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

/// 某一刻的圆环：progress 是一个周期里走到哪（0～1），still 是不动（空闲或减少动态效果）。原来的 SwiftUI 版逐帧画它，
/// 图层版（ContextRingLayers）照它复刻，Mac 的圆环对照（StagePreview）也画它。运行中整圈顺时针转、底轨明暗渐变；停止和收尾时整圈按余弦明暗起伏。
struct ContextRingFrame: View {
    let phase: String
    let fraction: Double?
    let lineWidth: CGFloat
    let progress: Double
    let still: Bool

    var body: some View {
        let color = ContextRing.color(phase)
        let pulse = still || phase == "running" ? 1 : 0.65 + 0.35 * cos(progress * 2 * .pi)
        // 底轨保留明暗渐变，未知用量时也能看出旋转。
        let stroke = phase == "running" && !still
            ? AnyShapeStyle(AngularGradient(colors: [color, color.opacity(0.35), color], center: .center))
            : AnyShapeStyle(color)
        ZStack {
            Circle().stroke(stroke, lineWidth: lineWidth).opacity(0.25)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .rotationEffect(.degrees(phase == "running" ? progress * 360 : 0))
        .opacity(pulse)
    }
}
