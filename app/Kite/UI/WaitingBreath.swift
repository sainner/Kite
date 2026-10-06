import SwiftUI

/// 等待呼吸：内容透明度起伏，不加底色（见 docs/视觉风格.md）。工具行、初始配置的文字与点阵图形共用这一条节奏。
nonisolated enum WaitingBreath {
    static let period: TimeInterval = 2.8

    /// date 时刻的不透明度，在 0.45 与 1 之间起伏。
    static func opacity(at date: Date) -> Double {
        // 先收敛到一周期，避免大时间戳损失精度。
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.45 + 0.55 * (sin(phase * .pi * 2) + 1) / 2
    }
}

extension View {
    /// active 时按等待呼吸起伏；开启减少动态效果时不动。
    func waitingBreath(_ active: Bool = true) -> some View {
        modifier(WaitingBreathModifier(active: active))
    }
}

private struct WaitingBreathModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if active, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                content.opacity(WaitingBreath.opacity(at: timeline.date))
            }
        } else {
            content
        }
    }
}
