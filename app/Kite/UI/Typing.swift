import SwiftUI

extension View {
    /// 打字时点这块区域收起键盘，只在 iPhone 上。和区域里原有的点按（展开折起来的一行等）同时生效，不抢它们；
    /// 点到区域里标了 typingTarget 的输入框不算。
    func endsTyping(_ typing: Bool, end: @escaping () -> Void) -> some View {
        modifier(EndsTyping(typing: typing, end: end))
    }

    /// iPhone 键盘上方的「完成」，给没有换行键可收键盘的输入框；Mac 上什么都不加。
    @ViewBuilder
    func keyboardDoneButton(_ end: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成", action: end) } }
        #else
        self
        #endif
    }

    /// 标出一块输入框：点它是要打字，所在区域的 endsTyping 不收键盘。
    func typingTarget() -> some View { modifier(TypingTarget()) }
}

extension EnvironmentValues {
    /// 所在区域正在打字，里面的输入框要报上自己的位置。
    @Entry var collectsTypingTargets = false
}

/// 只在所在区域打字时量位置：窗口移动、缩放时位置每帧都变，平时不往上报。
private struct TypingTarget: ViewModifier {
    @Environment(\.collectsTypingTargets) private var collecting

    func body(content: Content) -> some View {
        content.background {
            if collecting {
                GeometryReader { geo in
                    Color.clear.preference(key: TypingTargets.self, value: [geo.frame(in: .global)])
                }
            }
        }
    }
}

/// 输入框的位置只在点按时拿来比对，存在这里，变了不引起视图更新。
private final class TypingTargetFrames {
    var frames: [CGRect] = []
}

private struct TypingTargets: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct EndsTyping: ViewModifier {
    let typing: Bool
    let end: () -> Void
    @State private var targets = TypingTargetFrames()

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.collectsTypingTargets, typing)
            .onPreferenceChange(TypingTargets.self) { [targets] frames in Task { @MainActor in targets.frames = frames } }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                if !targets.frames.contains(where: { $0.contains(tap.location) }) { end() }
            }, isEnabled: typing)
        #else
        content
        #endif
    }
}
