import SwiftUI

/// 菜单里的一项。结束性的（role 为 destructive）用危险色：iOS 的菜单按 role 自己画红；
/// Mac 的菜单不按 role 上色，NSMenuItem 私有的 setDestructive: 也画不出颜色，只认标题文字自带的颜色，所以标题自己上色。
/// 同一套样子的 AppKit 菜单项见 MenuAction.item。
struct MenuButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            if let systemImage {
                Label { text } icon: { Image(systemName: systemImage) }
            } else {
                text
            }
        }
    }

    // 颜色只能加在 Text 上：加在 Label 或 Button 外面，Mac 的菜单不认
    @ViewBuilder private var text: some View {
        #if os(macOS)
        if role == .destructive {
            Text(title).foregroundStyle(Theme.danger)
        } else {
            Text(title)
        }
        #else
        Text(title)
        #endif
    }
}
