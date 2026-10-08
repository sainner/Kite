import SwiftUI

extension EnvironmentValues {
    /// 容器给出窗口焦点；单独显示的空状态和单页默认获得焦点。
    @Entry var windowDotsFocused = true
}

/// 从当前视图树汇总，窗口失焦、收起或移除后自动归还 App 点阵。
struct WindowDotsActive: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let next = nextValue()
        value = value || next
    }
}

extension View {
    /// 窗口选择使用点阵；图案与事件通过内部的 dotStage 环境发出，也可传入已有舞台。
    func windowDots(_ enabled: Bool = true, stage: DotStage? = nil) -> some View {
        modifier(WindowDotBackground(enabled: enabled, suppliedStage: stage))
    }

    /// 每个 App 窗口各自持有背景舞台，并响应其中聚焦窗口的点阵占用。
    func appDotBackground() -> some View {
        modifier(AppDotBackground())
    }
}

private struct WindowDotBackground: ViewModifier {
    let enabled: Bool
    let suppliedStage: DotStage?
    @State private var stage = DotStage()
    @Environment(\.dotStage) private var inheritedStage
    @Environment(\.windowDotsFocused) private var focused

    func body(content: Content) -> some View {
        content
            .background {
                if enabled && focused { DotCanvas() }
            }
            .environment(\.dotStage, enabled ? suppliedStage ?? stage : inheritedStage)
            .preference(key: WindowDotsActive.self, value: enabled && focused)
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
                    if !occupied { DotCanvas() }
                }
                .ignoresSafeArea()
            }
            .environment(\.dotStage, stage)
            .onPreferenceChange(WindowDotsActive.self) { occupied = $0 }
    }
}
