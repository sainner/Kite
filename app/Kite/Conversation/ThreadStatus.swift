import SwiftUI

/// 标题栏圆环表达主状态与上下文占比，悬停提示和辅助功能保留状态与结果说明。
struct ThreadStatusRing: View {
    @Environment(WorkThread.self) private var thread
    @Environment(\.paneHeaderStatusGrouped) private var grouped
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = Metrics.paneHeaderButton
    private var diameter: CGFloat { InputMode.current.isTouch ? scaledDiameter : Metrics.paneHeaderButton }
    private let lineWidth: CGFloat = 3

    var body: some View {
        // 和侧栏入口同在一块玻璃里时缩小，给玻璃边缘留出余量
        let ring = diameter * (grouped ? 0.6 : Metrics.statusRingScale)
        ContextRing(phase: thread.statusPhase, fraction: thread.state?.context?.fraction, lineWidth: lineWidth)
            .padding(lineWidth / 2)
            .frame(width: ring, height: ring)
            // 合进按钮组时排在组尾：前面同按钮一样带半个间距，后面让圆环与胶囊端头同心
            .padding(.leading, grouped ? Metrics.paneButtonGap / 2 : 0)
            .padding(.trailing, grouped ? (diameter - ring) / 2 - Metrics.paneHeaderGroupInset : 0)
            .frame(width: grouped ? nil : diameter, height: diameter)
            .help(thread.statusLabel + "\n" + thread.contextDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(thread.statusLabel + "，" + thread.contextDescription)
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

private struct ContextRing: View {
    let phase: String
    let fraction: Double?
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch phase {
        case "running": .accentColor
        case "stopping": Theme.warning
        case "finishing": Palette.dewy
        default: .secondary
        }
    }

    private var period: Double {
        switch phase {
        case "running": 2.4
        case "stopping": 1
        case "finishing": 1.6
        default: 0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: period == 0 || reduceMotion)) { timeline in
            let progress = period == 0 || reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let pulse = period == 0 || reduceMotion || phase == "running" ? 1 : 0.65 + 0.35 * cos(progress * 2 * .pi)
            // 底轨保留明暗渐变，未知用量时也能看出旋转。
            let stroke = phase == "running" && !reduceMotion
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
}
