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
        content.preferredColorScheme(appearance.colorScheme)
            .buttonStyle(.pointingAutomatic)
            #if os(iOS)
            .onChange(of: keepAwake, initial: true) { UIApplication.shared.isIdleTimerDisabled = keepAwake }
            #endif
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
}
