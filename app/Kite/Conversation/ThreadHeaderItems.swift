import SwiftUI

/// 模型菜单的内容，两端原生菜单共用：按厂商分节列出模型，后端随所选模型确定，不单独出现。
struct ThreadModelMenu {
    struct Vendor: Identifiable {
        let id: String
        /// 只有一个厂商时不加节标题。
        let title: String?
        let models: [Model]
    }
    struct Model: Identifiable {
        let id: String
        let name: String
        let selected: Bool
        let enabled: Bool
    }
    let vendors: [Vendor]
    /// 读取、切换中或没有模型时代替列表的说明。
    let status: String?
    /// 不能换到其他厂商的原因。
    let note: String?
    let select: (String) -> Void
}

/// 模型菜单的条目，SwiftUI 原生菜单共用：每个厂商一节，当前模型打勾。
struct ThreadModelMenuItems: View {
    let models: ThreadModelMenu

    var body: some View {
        if let status = models.status {
            Text(status)
        }
        ForEach(models.vendors) { vendor in
            if let title = vendor.title {
                Section(title) { items(vendor) }
            } else {
                Section { items(vendor) }
            }
        }
        if let note = models.note {
            Section { Text(note) }
        }
    }

    private func items(_ vendor: ThreadModelMenu.Vendor) -> some View {
        ForEach(vendor.models) { model in
            Toggle(model.name, isOn: Binding(get: { model.selected }, set: { _ in models.select(model.id) }))
                .disabled(!model.enabled)
        }
    }
}

struct ThreadHeaderCommand: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var enabled = true
    let action: @MainActor () -> Void
}
