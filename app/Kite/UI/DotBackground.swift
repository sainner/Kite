import SwiftUI

/// 静息点阵的归属：宽屏按窗口是否启用自动选择；窄屏由侧栏的展开状态决定。
enum DotBackgroundPlacement { case automatic, app, windows }

extension EnvironmentValues {
    @Entry var dotBackgroundPlacement: DotBackgroundPlacement = .automatic
    /// 所在窗口选择了点阵，由 windowDots 给出。
    @Entry var windowUsesDots = false
    /// 所在的窗口，由 windowDots 给出；窗口没选点阵时也有，限定在这个窗口里的波就哪儿都不画。
    @Entry var dotScope: DotScope?
}

/// 一个窗口在点阵上的范围：限定在窗口里的波（见 DotStage.emitWave）只由窗口里的取景框画，App 背景和别的窗口不画。
/// frame 是窗口在窗口坐标中的范围，随布局更新，不引起视图更新。
@MainActor final class DotScope {
    fileprivate(set) var frame: CGRect = .zero
}

/// 标题栏底下另画点阵的范围（窗口坐标），窗口的取景框在这里挖空，同一格不画两遍。
struct ScrollEdgeDotsArea: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// 页面中是否有开启点阵的窗口；从视图树汇总，供自动模式决定 App 背景是否画静息点阵。
struct WindowDotsActive: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// 窗口选择使用点阵：卡片上开一个取景框，画出所在 App 窗口那一套点阵落在卡片里的部分。
    func windowDots(_ enabled: Bool = true) -> some View {
        modifier(WindowDotBackground(enabled: enabled))
    }

    /// 每个 App 窗口持有唯一的点阵舞台，背景是它的取景框。自动模式下，有窗口开启点阵时背景让出静息的点，否则接回来。
    /// 波和轨迹照常画；图案和限定在窗口里的波总由所在窗口画，背景不画。
    func appDotBackground() -> some View {
        modifier(AppDotBackground())
    }
}

private struct WindowDotBackground: ViewModifier {
    let enabled: Bool
    @Environment(\.dotBackgroundPlacement) private var placement
    @State private var edges: [CGRect] = []
    @State private var scope = DotScope()

    func body(content: Content) -> some View {
        content
            .background {
                if enabled { DotCanvas(drawsRest: placement != .app, excluding: edges) }
            }
            .onPreferenceChange(ScrollEdgeDotsArea.self) { edges = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scope.frame = $0 }
            .environment(\.windowUsesDots, enabled)
            .environment(\.dotScope, scope)
            .preference(key: WindowDotsActive.self, value: enabled)
    }
}

/// 宽屏标题栏底下再开一个取景框。窗口里有滚动区时，滚动软边压在窗口点阵上面把点阵一起糊掉；
/// 这里画在软边之上、标题栏控件之下，标题栏和窗口的点阵连成一片，窗口的取景框在这块挖空。
/// 窄屏的软边只糊标题栏下面那一截，不补画。窗口没选点阵时什么也不画。
struct ScrollEdgeDots: View {
    @Environment(\.windowUsesDots) private var usesDots
    @Environment(\.dotBackgroundPlacement) private var placement
    @Environment(\.workspacePresentation) private var presentation

    var body: some View {
        if usesDots && presentation != .compact {
            DotCanvas(drawsRest: placement != .app)
                .background {
                    GeometryReader { Color.clear.preference(key: ScrollEdgeDotsArea.self, value: [$0.frame(in: .global)]) }
                }
        }
    }
}

private struct AppDotBackground: ViewModifier {
    @Environment(\.dotBackgroundPlacement) private var placement
    @State private var stage = DotStage()
    @State private var occupied = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Theme.background
                    DotCanvas(drawsRest: placement == .app || (placement == .automatic && !occupied), drawsPatterns: false)
                }
                .ignoresSafeArea()
            }
            .environment(\.dotStage, stage)
            .onPreferenceChange(WindowDotsActive.self) { occupied = $0 }
    }
}
