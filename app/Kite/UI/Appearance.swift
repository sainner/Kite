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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    #if os(iOS)
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
            .preferredColorScheme(appearance.colorScheme)
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
/// 不用 preferredColorScheme：从浅色改回跟随系统（nil）时它不撤掉之前设下的，系统变深色 App 仍停在浅色。
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
            apply()
        }

        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
#endif
