import SwiftUI

enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    #if os(macOS)
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #else
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
    #endif
}

/// 设置页和 Mac 菜单共用同一份偏好，各个窗口也读取它。
struct AppearancePicker: View {
    @AppStorage("KiteAppearance") private var appearance: Appearance = .system

    var body: some View {
        Picker("颜色模式", selection: $appearance) {
            ForEach(Appearance.allCases, id: \.self) { value in
                Text(value.title).tag(value)
            }
        }
        .clickPointer()
    }
}

#if os(iOS)
/// 使用 Kite 时屏幕不自动锁定，默认开启；仅对本台设备生效。
struct KeepAwakeToggle: View {
    @AppStorage("KiteKeepAwake") private var keepAwake = true

    var body: some View {
        Toggle("使用时不自动锁屏", isOn: $keepAwake)
    }
}
#endif

/// 颜色偏好不用 preferredColorScheme：从浅色改回跟随系统（nil）时它不撤掉之前设下的，系统变深色 App 仍停在浅色。
/// Mac 设在 NSApp.appearance 上，各个窗口、弹出的页面和菜单都从它继承。
private struct AppAppearance: ViewModifier {
    @AppStorage("KiteAppearance") private var appearance: Appearance = .system
    #if os(iOS)
    @AppStorage("KiteKeepAwake") private var keepAwake = true
    #endif

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background(WindowInterfaceStyle(style: appearance.interfaceStyle))
            #else
            .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.appKitAppearance }
            #endif
            .buttonStyle(.pointingAutomatic)
            #if os(iOS)
            .onChange(of: keepAwake, initial: true) { UIApplication.shared.isIdleTimerDisabled = keepAwake }
            #endif
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
}

#if os(iOS)
/// iOS 上颜色偏好设在所在窗口的 overrideUserInterfaceStyle 上，UIKit 往下传给窗口里的原生视图、各个托管视图和弹出的页面。
/// 窗口的根视图同时固定不随弹出层调暗，见 didMoveToWindow。
private struct WindowInterfaceStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> Applier { Applier() }

    func updateUIView(_ view: Applier, context: Context) { view.style = style }

    final class Applier: UIView {
        var style = UIUserInterfaceStyle.unspecified {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // 弹出提醒、气泡时 UIKit 把根视图的 tint 调成 0.8 透明度的灰，SwiftUI 的主题色跟着变灰；台面、紧凑外壳抄给原生层和各岛的环境
            // 停在那时的灰色，弹出层关了也不回来（2026-10-24 iPhone 的用户气泡、用户头像发灰）。显式设成 normal，UIKit 就不再调暗它
            // （Catalyst 小程序验证过：不设时弹出提醒后根视图变成 dimmed，设了以后主题色一直不变）。
            window?.rootViewController?.view.tintAdjustmentMode = .normal
            apply()
        }

        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
#endif
