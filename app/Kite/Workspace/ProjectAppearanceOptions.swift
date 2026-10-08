import SwiftUI

/// 图标属于账号下的项目，同一项目在各台机器上使用相同选择。
struct ProjectAppearanceOptions: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var error: String?

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
                                    TablerIcon(.tablerCheck).font(Theme.caption).foregroundStyle(Theme.background)
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
                ForEach(ProjectIcon.all) { icon in
                    Button { save(["icon": icon.id]) } label: {
                        TablerIcon(icon.symbol, selected: appearance.icon == icon.id)
                    }
                    .buttonStyle(PaneButtonStyle(foreground: appearance.icon == icon.id ? tint : .primary))
                    .background(tint.opacity(appearance.icon == icon.id ? 0.12 : 0), in: Capsule())
                    .help(icon.title)
                    .accessibilityLabel(icon.title)
                    .accessibilityAddTraits(appearance.icon == icon.id ? .isSelected : [])
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

/// 账号保存图标标识，列表和选择器使用同一份资源映射。
struct ProjectIcon: Identifiable {
    let id: String
    let title: String
    let symbol: TablerSymbol

    static let all: [ProjectIcon] = [
        .init(id: "folder", title: "文件夹", symbol: .folder),
        .init(id: "paperplane", title: "纸飞机", symbol: .send),
        .init(id: "diamond", title: "菱形", symbol: .diamond),
        .init(id: "cursorarrow", title: "光标", symbol: .pointer),
        .init(id: "terminal", title: "终端", symbol: .terminal),
        .init(id: "curlybraces", title: "代码", symbol: .fileCode),
        .init(id: "chevron.left.forwardslash.chevron.right", title: "开发", symbol: .code),
        .init(id: "app", title: "应用", symbol: .appWindow),
        .init(id: "globe", title: "网站", symbol: .world),
        .init(id: "book", title: "书籍", symbol: .book),
        .init(id: "doc.text", title: "文档", symbol: .fileText),
        .init(id: "pencil", title: "写作", symbol: .pencil),
        .init(id: "paintbrush", title: "画笔", symbol: .palette),
        .init(id: "photo", title: "图片", symbol: .photo),
        .init(id: "camera", title: "相机", symbol: .camera),
        .init(id: "music.note", title: "音乐", symbol: .music),
        .init(id: "film", title: "影片", symbol: .video),
        .init(id: "gamecontroller", title: "游戏", symbol: .gamepad),
        .init(id: "sparkles", title: "灵感", symbol: .sparkles),
        .init(id: "lightbulb", title: "想法", symbol: .bulb),
        .init(id: "leaf", title: "树叶", symbol: .leaf),
        .init(id: "bolt", title: "闪电", symbol: .bolt),
        .init(id: "star", title: "星星", symbol: .star),
        .init(id: "heart", title: "爱心", symbol: .heart),
    ]

    static func symbol(for id: String?) -> TablerSymbol {
        all.first { $0.id == id }?.symbol ?? .folder
    }
}
