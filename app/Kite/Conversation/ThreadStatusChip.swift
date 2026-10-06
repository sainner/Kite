import SwiftUI

/// 圆环只表达主状态与上下文占比；文字显示状态或结果，执行内容留在消息流。
struct ThreadStatusChip: View {
    var ringOnRight = false
    @Environment(WorkThread.self) private var thread

    var body: some View {
        HStack(spacing: 6) {
            if !ringOnRight { ring }
            Text(thread.statusLabel)
                .font(Theme.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if ringOnRight { ring }
        }
        .frame(height: 20)
        .padding(.leading, ringOnRight ? 8 : 6)
        .padding(.trailing, ringOnRight ? 6 : 8)
        .background(Theme.codeBackground, in: Capsule())
        .help(thread.statusLabel + "\n" + contextDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thread.statusLabel + "，" + contextDescription)
    }

    private var ring: some View {
        ContextRing(phase: thread.statusPhase, fraction: thread.state?.context?.fraction)
    }

    private var contextDescription: String {
        guard let usage = thread.state?.context else { return "上下文用量未知" }
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
            // 明暗渐变让满环和未知用量的底轨也能看出旋转，不改变占比弧长。
            let stroke = phase == "running" && !reduceMotion
                ? AnyShapeStyle(AngularGradient(colors: [color, color.opacity(0.35), color], center: .center))
                : AnyShapeStyle(color)
            ZStack {
                Circle().stroke(stroke, lineWidth: 2).opacity(0.25)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .rotationEffect(.degrees(phase == "running" ? progress * 360 : 0))
            .opacity(pulse)
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}
