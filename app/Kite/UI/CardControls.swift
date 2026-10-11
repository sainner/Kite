import SwiftUI

/// 卡片里的控件：初始配置和新建弹窗共用一套输入框、下拉选择、提示与底部按钮。
enum CardMetrics {
    /// 卡片四边的留白。
    static let inset = Metrics.padding * 2
    /// 弹窗正文和底部按钮的左右留白，比卡片窄一些。
    static let sheetInset: CGFloat = 16
    static var fieldHeight: CGFloat { InputMode.current.fieldHeight }
}

/// 填充框的形状。
private let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

/// 填充框上面的标签，和框里的文字左边对齐。
struct CardLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }
}

/// 填充框下面或独立的一段说明。
struct CardNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }
}

/// 上面一行标签，下面是不带边框的填充框，聚焦时描主题色，框下可带一段说明。框里放 cardInput 的输入框或 CardSelectStyle 的菜单。
struct CardField<Content: View>: View {
    let label: String
    var focused = false
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel(label)
            content
                .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
                .background(Theme.codeBackground, in: cardShape)
                .overlay { cardShape.strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.5) }
                .animation(.easeOut(duration: 0.15), value: focused)
            if let note { CardNote(note) }
        }
    }
}

/// 一组设置项：标题、填充框里用分隔线隔开的若干行、框下的说明。没有行时只剩标题和说明。
/// 行里直接写 LabeledContent、Toggle、Button、DisclosureGroup，样式由这里统一换掉；进入子页面的一行用 CardLink。
struct CardSection<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { CardLabel(title) }
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id { Divider() }
                            row.cardRow()
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Theme.codeBackground, in: cardShape)
                }
            }
            if let note { CardNote(note) }
        }
        .font(Theme.body)
        .labeledContentStyle(CardLabeledContentStyle())
        .toggleStyle(CardToggleStyle())
        .disclosureGroupStyle(CardDisclosureStyle())
        .buttonStyle(CardRowButtonStyle())
    }
}

private extension View {
    /// 设置组里的一行：至少一个输入框高，多行文字时上下留白。
    func cardRow() -> some View {
        padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
    }
}

/// 左边名称，右边值或控件。只读的值自己标次要色，以免把右边的选择器也染灰。
private struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}

/// 名称占满左边，开关贴右。
private struct CardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
                .controlSize(InputMode.current.toggleControlSize)
        }
    }
}

/// 点整行展开，右侧箭头转向下；展开的各行缩进一级，同样用分隔线隔开。
private struct CardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .frame(minHeight: CardMetrics.fieldHeight - 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                Group(subviews: configuration.content) { rows in
                    ForEach(rows) { row in
                        Divider().padding(.top, 6)
                        row.padding(.leading, 12).padding(.top, 6)
                            .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight - 6, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// 设置组里的操作：主题色文字，整行可点。
private struct CardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight - 12, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}

/// 设置组里进入子页面的一行：正文色名称，右侧箭头。
struct CardLink: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(Theme.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

extension View {
    /// 填充框里的输入框：无边框、正文字号，整块都能点进去。点它不算点空白处，所在区域的 endsTyping 不收键盘。
    /// 左边已有图标按钮时 leading 收窄。
    func cardInput(leading: CGFloat = 12, focus: @escaping () -> Void) -> some View {
        textFieldStyle(.plain)
            .font(Theme.body)
            .padding(.leading, leading)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(minHeight: CardMetrics.fieldHeight)
            .contentShape(Rectangle())
            .onTapGesture(perform: focus)
            .typingTarget()
    }
}

/// 填充框里的下拉选择：Menu 配 .menuStyle(.button) 用，选中项靠左，右侧上下箭头。
struct CardSelectStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(Theme.caption).foregroundStyle(.secondary)
        }
        .font(Theme.body)
        .padding(.horizontal, 12)
        .frame(minHeight: CardMetrics.fieldHeight)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 卡片里的一条提示，如出错原因。
struct CardCallout: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint = Theme.danger

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).foregroundStyle(tint == .secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
