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

private struct AppAppearance: ViewModifier {
    @AppStorage("KiteAppearance") private var appearance: Appearance = .system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
            .buttonStyle(.pointingAutomatic)
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
}
