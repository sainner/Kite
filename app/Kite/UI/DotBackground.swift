import SwiftUI

extension EnvironmentValues {
    /// 焦点在窗口区：宽屏点按窗口区以外的侧栏时为 false；移动端拉开侧边栏或底栏时为 false。
    @Entry var windowDotsFocused = true
    /// 所在窗口选择了点阵，由 windowDots 给出。
    @Entry var windowUsesDots = false
}

/// 标题栏底下另画点阵的范围（窗口坐标），窗口的取景框在这里挖空，同一格不画两遍。
struct ScrollEdgeDotsArea: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// 有开了点阵的窗口在焦点区里画着静息的点；从视图树汇总，窗口失焦、移除后自动归还给 App 背景。
struct WindowDotsActive: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// 窗口选择使用点阵：卡片上开一个取景框，画出所在 App 窗口那一套点阵落在卡片里的部分。
    /// 焦点不在窗口区时不画静息的点，图案照常显示。
    func windowDots(_ enabled: Bool = true) -> some View {
        modifier(WindowDotBackground(enabled: enabled))
    }

    /// 每个 App 窗口持有唯一的点阵舞台，背景是它的取景框。焦点在窗口区、有窗口画着静息的点时，背景让出静息的点，
    /// 波和轨迹照常画；焦点回到侧栏时背景接回来。图案总由所在窗口画，背景不画。
    func appDotBackground() -> some View {
        modifier(AppDotBackground())
    }
}

private struct WindowDotBackground: ViewModifier {
    let enabled: Bool
    @Environment(\.windowDotsFocused) private var focused
    @State private var edges: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .background {
                if enabled { DotCanvas(drawsRest: focused, excluding: edges) }
            }
            .onPreferenceChange(ScrollEdgeDotsArea.self) { edges = $0 }
            .environment(\.windowUsesDots, enabled)
            .preference(key: WindowDotsActive.self, value: enabled && focused)
    }
}

/// 宽屏标题栏底下再开一个取景框。窗口里有滚动区时，滚动软边压在窗口点阵上面把点阵一起糊掉；
/// 这里画在软边之上、标题栏控件之下，标题栏和窗口的点阵连成一片，窗口的取景框在这块挖空。
/// 窄屏的软边只糊标题栏下面那一截，不补画。窗口没选点阵时什么也不画。
struct ScrollEdgeDots: View {
    @Environment(\.windowUsesDots) private var usesDots
    @Environment(\.windowDotsFocused) private var focused
    @Environment(\.workspacePresentation) private var presentation

    var body: some View {
        if usesDots && presentation != .compact {
            DotCanvas(drawsRest: focused)
                .background {
                    GeometryReader { Color.clear.preference(key: ScrollEdgeDotsArea.self, value: [$0.frame(in: .global)]) }
                }
        }
    }
}

private struct AppDotBackground: ViewModifier {
    @State private var stage = DotStage()
    @State private var occupied = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Theme.background
                    DotCanvas(drawsRest: !occupied, drawsPatterns: false)
                }
                .ignoresSafeArea()
            }
            .environment(\.dotStage, stage)
            .onPreferenceChange(WindowDotsActive.self) { occupied = $0 }
    }
}
