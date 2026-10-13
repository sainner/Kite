import SwiftUI

extension EnvironmentValues {
    /// 原生台面交给卡片正文的：有它时会话窗口的外框是原生的（Mac 的 ThreadWindowView、iPad 的 PhoneThreadWindowView），
    /// 正文里只放 ThreadPaneBridge。
    @Entry var nativeThreadWindow: ThreadWindowSlot?
    /// 卡片交给正文的环境换过几次（外观类的环境变了、窗口组换了一项）：桥按它把整份新环境再交给原生外框。
    @Entry var nativeThreadGeneration = 0
}

/// 卡片和它正文里的 ThreadPaneBridge 之间的联系：桥接上会话和环境时交给卡片，卡片建好原生外框；桥不在了收掉外框。
@MainActor final class ThreadWindowSlot {
    var attach: ((WorkThread, ThreadPaneModel, EnvironmentValues) -> Void)?
    var detach: ((ThreadPaneModel) -> Void)?
}

/// 原生会话窗口外框在 SwiftUI 正文里的那一点：不占地方，接住会话窗口所在的环境（工作区、实例、引用跳转、窗口动画、标题两侧的锚定……）
/// 交给原生外框，挂着不占地方的几样（ThreadPaneSupport：订阅历史、录音、标题和角色的弹窗），报窗口用点阵。
/// 卡片的正文托管视图因此不随拖缝改尺寸：外框里的对话列表是原生的，标题栏、输入区各是原生视图或小的托管视图。
struct ThreadPaneBridge: View {
    let slot: ThreadWindowSlot
    @Environment(WorkThread.self) private var thread
    @Environment(\.self) private var environment
    // 显式读出来：只读 \.self 时这几项变了不重算。卡片换过环境（generation）时整份重交；
    // 卡片环境以外、在正文里才加上的（引用跳转的范围）也在这里看
    @Environment(\.nativeThreadGeneration) private var generation
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var weight
    @Environment(\.referenceScope) private var referenceScope
    @Environment(\.openSidebar) private var openSidebar
    @State private var pane = ThreadPaneModel()

    private struct Key: Equatable {
        let thread: ObjectIdentifier
        let generation: Int
        let colorScheme: ColorScheme
        #if os(macOS)
        let activeState: ControlActiveState
        #endif
        let isEnabled: Bool
        let displayScale: CGFloat
        let reduceMotion: Bool
        let typeSize: DynamicTypeSize
        let weight: LegibilityWeight?
        let referenceScope: ReferenceScope
        let sidebar: Bool
    }

    var body: some View {
        #if os(macOS)
        let key = Key(thread: ObjectIdentifier(thread), generation: generation, colorScheme: colorScheme, activeState: activeState,
                      isEnabled: isEnabled, displayScale: displayScale, reduceMotion: reduceMotion, typeSize: typeSize, weight: weight,
                      referenceScope: referenceScope, sidebar: openSidebar != nil)
        #else
        let key = Key(thread: ObjectIdentifier(thread), generation: generation, colorScheme: colorScheme,
                      isEnabled: isEnabled, displayScale: displayScale, reduceMotion: reduceMotion, typeSize: typeSize, weight: weight,
                      referenceScope: referenceScope, sidebar: openSidebar != nil)
        #endif
        Color.clear
            .frame(width: 0, height: 0)
            .preference(key: WindowDotsActive.self, value: true)
            .modifier(ThreadPaneSupport(pane: pane))
            .onChange(of: key, initial: true) { slot.attach?(thread, pane, environment) }
            .onDisappear { slot.detach?(pane) }
    }
}
