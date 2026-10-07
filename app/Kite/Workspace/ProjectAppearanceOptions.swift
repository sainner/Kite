import SwiftUI

/// 图标属于账号下的项目，同一项目在各台机器上使用相同选择。
struct ProjectAppearanceOptions: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var error: String?

    private static let symbols: [(name: String, title: String)] = [
        ("folder", "文件夹"), ("paperplane", "纸飞机"), ("diamond", "菱形"),
        ("cursorarrow", "光标"), ("terminal", "终端"), ("curlybraces", "代码"),
        ("chevron.left.forwardslash.chevron.right", "开发"), ("app", "应用"), ("globe", "网站"),
        ("book", "书籍"), ("doc.text", "文档"), ("pencil", "写作"),
        ("paintbrush", "画笔"), ("photo", "图片"), ("camera", "相机"),
        ("music.note", "音乐"), ("film", "影片"), ("gamecontroller", "游戏"),
        ("sparkles", "灵感"), ("lightbulb", "想法"), ("leaf", "树叶"),
        ("bolt", "闪电"), ("star", "星星"), ("heart", "爱心"),
    ]

    private var appearance: ProjectAppearance { model.account.projectAppearances[projectID] ?? ProjectAppearance() }
    private var tint: Color { ProjectTheme(rawValue: appearance.color)?.color ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("颜色").font(Theme.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(ProjectTheme.allCases) { theme in
                    if theme != ProjectTheme.allCases.first { Spacer(minLength: 0) }
                    Button { save(["color": theme.rawValue]) } label: {
                        Circle().fill(theme.color)
                            .overlay {
                                if appearance.color == theme.rawValue {
                                    Image(systemName: "checkmark").font(Theme.caption.weight(.bold)).foregroundStyle(Theme.background)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .frame(width: Metrics.paneButton, height: Metrics.paneButton)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointingPlain)
                    .help(theme.title)
                    .accessibilityLabel(theme.title)
                    .accessibilityAddTraits(appearance.color == theme.rawValue ? .isSelected : [])
                }
            }
            .disabled(saving)
            Text("图标").font(Theme.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.paneButton), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.symbols, id: \.name) { symbol in
                    Button { save(["icon": symbol.name]) } label: {
                        Image(systemName: symbol.name)
                    }
                    .buttonStyle(PaneButtonStyle(foreground: appearance.icon == symbol.name ? tint : .primary))
                    .background(tint.opacity(appearance.icon == symbol.name ? 0.12 : 0), in: Capsule())
                    .help(symbol.title)
                    .accessibilityLabel(symbol.title)
                    .accessibilityAddTraits(appearance.icon == symbol.name ? .isSelected : [])
                }
            }
            .disabled(saving)
            if saving { ProgressView().controlSize(.small) }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save(_ values: [String: String]) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.account.setProjectAppearance(values, projectID: projectID)
            } catch { self.error = error.localizedDescription }
        }
    }
}
