import SwiftUI

/// 新代理另存角色的弹窗里的点阵签名：动画预览，右下角是头像，下面一行签名各项。手改后随角色一起保存，之后不再被自动生成替换。
struct TemplateEmblemField: View {
    @Binding var design: EmblemDesign
    @Environment(\.self) private var environment
    @State private var check = EmblemCheck()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel("点阵签名")
            EmblemPreview(pattern: check.pattern)
                .overlay(alignment: .bottomTrailing) { EmblemAvatar(design: check.avatar).padding(10) }
            EmblemCards(design: $design, check: check)
                .padding(.top, 2)
            CardNote("保存后由模型按提示词生成；手改后保留手改的版本。")
        }
        .onChange(of: design, initial: true) { check.update(design, in: environment) }
        .onChange(of: environment.colorScheme) { check.update(design, in: environment) }
    }
}

/// 资源库角色的签名窗口：签名铺满整个窗口，连同标题栏和控制区后面，同新代理的空白页；指针划过时跟着起反应。
/// 头像在控制区上方点阵的正中，签名各项在控制区里，算式输入框的位置同空白页的输入区。
/// 生成进度写在副标题，失败在信息区；「重新生成」交给模型按提示词重画，连手改过的一起替换。
struct RoleEmblemPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.dotStage) private var stage
    @Environment(\.self) private var environment
    @State private var check = EmblemCheck()
    @State private var slot = "emblem.\(UUID().uuidString)"

    private var saved: AgentRole? { model.roleCatalog?.roles.first { $0.id == id } }
    private var edited: EmblemDesign? { model.roleDraft(id)?.emblem }
    /// 没手改时跟随工作机上的最新签名，重新生成的结果直接显示。
    private var design: EmblemDesign { edited ?? saved?.emblem?.design ?? .fallback }
    private var generating: Bool { saved?.emblemState == "generating" }
    private var saving: Bool { model.savingRoles.contains(id) }

    private var status: String {
        if generating { return "正在按提示词生成" }
        if edited != nil { return "已手改，保存后不再自动替换" }
        guard let saved else { return "保存后按提示词生成" }
        switch saved.emblemState {
        case "failed": return "生成失败"
        case "stale": return "提示词已修改，会重新生成"
        default:
            if saved.emblem == nil { return "还没有签名" }
            return saved.emblem?.source == "manual" ? "手改过，不会被自动替换" : "按提示词生成"
        }
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: "签名", subtitle: status), usesDots: true,
                   notice: saved?.emblemState == "failed" ? .failure("签名生成失败：\(saved?.emblemError ?? "未知原因")") : nil) {
            EmblemStage(check: check, slot: slot)
        } controls: { typing in
            EmblemControls(design: Binding(get: { design }, set: { value in model.editRole(id) { $0.emblem = value } }),
                           check: check, typing: typing)
                .disabled(saving)
                .frame(maxWidth: Metrics.transcriptWidth)
        } headerActions: {
            if let saved {
                PaneHeaderButtonGroup {
                    Button { regenerate(saved) } label: {
                        PaneHeaderButtonLabel("重新生成", systemImage: "sparkles")
                            .opacity(generating ? 0 : 1)
                            .overlay { if generating { CardSpinner().scaleEffect(0.6) } }
                    }
                    .help(generating ? "正在生成" : "按提示词重新生成签名")
                    .disabled(generating || saving || !model.connected)
                }
            }
        }
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { stage?.patternPointer(point, slot: slot) }
            else { stage?.patternPointer(nil, slot: slot) }
        }
        #endif
        .onChange(of: design, initial: true) { check.update(design, in: environment) }
        .onChange(of: environment.colorScheme) { check.update(design, in: environment) }
    }

    /// 手改的签名随之作废。
    private func regenerate(_ role: AgentRole) {
        model.editRole(id) { $0.emblem = nil }
        Task { try? await model.generateRoleEmblem(role, force: true, connection: model.connectionRevision) }
    }
}

/// 签名窗口的正文，不滚动：头像居中在控制区上面这一块里，窗口变高变矮只伸缩这一块。
/// 图案铺满整个窗口，标题栏一带稍收弱，头像四周渐弱，不在边上切断大点；控制区是玻璃，后面不收。iPhone 上手指划过图案时跟着起反应。
private struct EmblemStage: View {
    let check: EmblemCheck
    let slot: String
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.paneWindowFrame) private var windowFrame
    private var window: CGRect? { windowFrame?.rect }
    @State private var content: CGRect?
    @State private var avatarFrame: CGRect?

    /// 标题栏一带留多少，同新代理的空白页。
    private static var headerFloor: Double { 0.45 }

    var body: some View {
        ZStack {
            DotPatternArea(pattern: check.pattern, quiet: quiet, area: window, slot: slot)
            EmblemAvatar(design: check.avatar)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: DotCarrier.coordinateSpace(carrier))
                } action: { avatarFrame = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        #if os(iOS)
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { stage?.patternPointer($0.location, slot: slot) }
            .onEnded { _ in stage?.patternPointer(nil, slot: slot) })
        #endif
        // 窗口太矮时截掉头像，不压到标题栏和控制区上。
        .frame(minHeight: 0, maxHeight: .infinity).clipped()
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: DotCarrier.coordinateSpace(carrier))
        } action: { content = $0 }
    }

    private var quiet: [PatternQuiet] {
        var result = [avatarFrame].compactMap { $0.map { PatternQuiet(rect: $0) } }
        if let window, let content, content.minY > window.minY {
            result.append(PatternQuiet(rect: CGRect(x: window.minX, y: window.minY, width: window.width, height: content.minY - window.minY),
                                       floor: Self.headerFloor))
        }
        return result
    }
}

/// 表达式改到一半无效时，预览停在上一个有效的样子，错误另外显示；头像算式同样。
private struct EmblemCheck {
    var pattern: DotPattern?
    var error: String?
    var avatar: EmblemDesign?
    var avatarError: String?

    mutating func update(_ design: EmblemDesign, in environment: EnvironmentValues) {
        do {
            _ = try DotExpression(design.expression)
            error = nil
            pattern = design.pattern(accent: DotColor(Color.accentColor.resolve(in: environment)))
        } catch {
            self.error = error.localizedDescription
        }
        do {
            _ = try DotExpression(design.avatar)
            avatarError = nil
            avatar = design
        } catch {
            avatarError = error.localizedDescription
        }
    }
}

/// 签名的头像，样子与停靠栏里运行中的代理一致，比停靠栏里大一些。
private struct EmblemAvatar: View {
    let design: EmblemDesign?

    var body: some View {
        let size = (Metrics.dragBubble * 1.4).rounded()
        DockFace(look: .agent(instance: "preview", design: design), running: true)
            .frame(width: size, height: size)
    }
}

/// 签名各项，一行三张卡片：图案与头像的算式，正负两种颜色，点的形状。
/// 算式是单独底色的输入框，行数固定，参数说明在标签右边的图标上；这一行的高度由算式卡片定。
/// 颜色与形状竖排成一列，点一下选中，放不下时在卡片里滚动。
private struct EmblemCards: View {
    @Binding var design: EmblemDesign
    let check: EmblemCheck
    @Environment(\.self) private var environment
    @FocusState private var focus: Formula?
    @State private var height: CGFloat?

    private enum Formula { case pattern, avatar }

    /// 卡片上下留白。
    private static let inset: CGFloat = 10
    private static let fieldShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        let palette = DotFigure.letters(accent: DotColor(Color.accentColor.resolve(in: environment)))
        let color = { (letter: String) in letter.first.flatMap { palette[$0] }?.color ?? .accentColor }
        let colorTitle = { (letter: String) in EmblemDesign.letterTitles[letter] ?? letter }
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                label("图案算式", error: check.error) { EmblemFormulaInfo.pattern }
                field("图案算式", text: $design.expression, formula: .pattern, lines: 3, invalid: check.error != nil)
                label("头像算式", error: check.avatarError) { EmblemFormulaInfo.avatar }
                .padding(.top, 6)
                field("头像算式", text: $design.avatar, formula: .avatar, lines: 2, invalid: check.avatarError != nil)
            }
            .padding(.horizontal, Self.inset)
            .emblemCard(inset: Self.inset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            HStack(alignment: .top, spacing: 0) {
                EmblemChoiceColumn(label: "正值", options: EmblemDesign.letters, selection: $design.positive,
                                   title: colorTitle, tint: color) { letter, _ in
                    EmblemSwatch(color: color(letter))
                }
                EmblemChoiceColumn(label: "负值", options: EmblemDesign.letters, selection: $design.negative,
                                   title: colorTitle, tint: color) { letter, _ in
                    EmblemSwatch(color: color(letter))
                }
            }
            .padding(.horizontal, 4)
            .emblemCard(inset: Self.inset, height: height)
            EmblemChoiceColumn(label: "形状", options: DotForm.allCases.map(\.rawValue), selection: $design.form,
                               title: { DotForm(rawValue: $0)?.title ?? $0 }, tint: { _ in color(design.positive) }) { form, selected in
                EmblemFormGlyph(form: DotForm(rawValue: form) ?? .circle, color: selected ? color(design.positive) : EmblemFormGlyph.idle)
            }
            .padding(.horizontal, 4)
            .emblemCard(inset: Self.inset, height: height)
        }
    }

    /// 输入框上面的标签，右边是参数说明的图标；算式出错时原因排在最右，放不下的悬停看全。
    private func label(_ title: String, error: String?, info: () -> Text) -> some View {
        HStack(spacing: 4) {
            Text(title).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            CardInfo(title: title, text: info())
            if let error {
                Spacer(minLength: 8)
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    .lineLimit(1).truncationMode(.tail)
                    .help(error)
            }
        }
        .frame(height: InputMode.current.labelExtent)
    }

    /// 算式的输入框：比卡片亮一档的底色，固定行数，写长了在框里滚动；整块都能点进去，聚焦时描主题色，出错时描错误色。
    private func field(_ title: String, text: Binding<String>, formula: Formula, lines: Int, invalid: Bool) -> some View {
        let focused = focus == formula
        return TextField(title, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.code)
            .lineLimit(lines, reservesSpace: true)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($focus, equals: formula)
            .scrollsOnlyWhileTyping(focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.card, in: Self.fieldShape)
            .overlay {
                Self.fieldShape.strokeBorder(invalid ? Theme.danger.opacity(0.8) : focused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08),
                                             lineWidth: invalid || focused ? 1.5 : 1)
            }
            .clipShape(Self.fieldShape)
            .contentShape(Self.fieldShape)
            .onTapGesture { focus = formula }
            .typingTarget()
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// 两条算式的参数说明，弹窗卡片与窗口控制区共用。
private enum EmblemFormulaInfo {
    static var pattern: Text {
        Text("\(code("t")) 秒，\(code("x y")) 格坐标，\(code("r a")) 极坐标，\(code("d")) 到指针的距离，\(code("k")) 打字活跃度")
    }

    static var avatar: Text {
        Text("停靠栏头像：9×9 格的圆，\(code("x y")) 为 −4～4，没有指针与打字，代理工作时才动")
    }

    /// 说明里的参数名：等宽、正文色。
    private static func code(_ name: String) -> Text {
        Text(name).font(Theme.caption.monospaced().weight(.semibold)).foregroundStyle(.primary)
    }
}

/// 签名窗口控制区里的签名各项。上面一行靠右，是颜色与形状：正负两色一组、形状一组，只显示当前的小样；
/// 点一个，它所在的胶囊横向展开成这一项的全部小样，另一组让出位置，选中后收回。
/// 下面是算式输入框，同会话的输入区：文字直接写在玻璃上，写长了往上长；左下角是参数说明，右下角两个图标在图案与头像两条算式之间切换，
/// 出错原因排在说明后面，正在看的这条没错、另一条有错时也提示。输入框接窗口的打字焦点。
private struct EmblemControls: View {
    @Binding var design: EmblemDesign
    let check: EmblemCheck
    var typing: FocusState<Bool>.Binding
    @Environment(\.self) private var environment
    @State private var formula = Formula.pattern
    @State private var expanded: Pick?
    @State private var showsInfo = false

    private enum Formula: Hashable { case pattern, avatar }
    private enum Pick { case positive, negative, form }

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                if expanded != .form {
                    PaneHeaderButtonGroup {
                        colorSlot("正值", pick: .positive, selection: $design.positive)
                        colorSlot("负值", pick: .negative, selection: $design.negative)
                    }
                }
                if expanded == nil || expanded == .form {
                    PaneHeaderButtonGroup { formSlot }
                }
            }
            formulaPanel
        }
    }

    private var palette: [Character: DotColor] { DotFigure.letters(accent: DotColor(Color.accentColor.resolve(in: environment))) }
    private func color(_ letter: String) -> Color { letter.first.flatMap { palette[$0] }?.color ?? .accentColor }
    private func colorTitle(_ letter: String) -> String { EmblemDesign.letterTitles[letter] ?? letter }

    /// 一种颜色：收起时是当前的色点，展开后是全部颜色。
    @ViewBuilder
    private func colorSlot(_ title: String, pick: Pick, selection: Binding<String>) -> some View {
        if expanded == pick {
            choices(EmblemDesign.letters, selection: selection, title: colorTitle, tint: color) { letter, _ in
                EmblemSwatch(color: color(letter))
            }
        } else {
            trigger(pick, label: "\(title)的颜色", value: colorTitle(selection.wrappedValue)) {
                EmblemSwatch(color: color(selection.wrappedValue))
            }
        }
    }

    /// 点的形状：收起时是当前形状的小样，展开后是全部形状；选中的用正值的颜色，其余的用次要色。
    @ViewBuilder
    private var formSlot: some View {
        let tint = color(design.positive)
        if expanded == .form {
            choices(DotForm.allCases.map(\.rawValue), selection: $design.form, title: { DotForm(rawValue: $0)?.title ?? $0 },
                    tint: { _ in tint }) { option, selected in
                EmblemFormGlyph(form: DotForm(rawValue: option) ?? .circle, color: selected ? tint : EmblemFormGlyph.idle)
            }
        } else {
            let form = DotForm(rawValue: design.form) ?? .circle
            trigger(.form, label: "点的形状", value: form.title) {
                EmblemFormGlyph(form: form, color: tint)
            }
        }
    }

    /// 收起时的一项：只有小样，尺寸同展开后选中的那一项，展开时原地变成一排。
    private func trigger(_ pick: Pick, label: String, value: String, @ViewBuilder glyph: () -> some View) -> some View {
        Button { withAnimation(.snappy) { expanded = pick } } label: {
            glyph()
                .frame(width: EmblemChoice<EmptyView>.glyphSize, height: EmblemChoice<EmptyView>.glyphSize)
                .padding(.horizontal, Metrics.paneHeaderButtonGap / 2)
                .frame(height: Metrics.paneHeaderButton)
                .contentShape(.capsule)
        }
        .help("\(label)：\(value)")
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// 展开后的一排：点一个选中并收回，点当前选中的也收回。
    private func choices(_ options: [String], selection: Binding<String>, title: @escaping (String) -> String,
                         tint: @escaping (String) -> Color,
                         @ViewBuilder glyph: @escaping (_ option: String, _ selected: Bool) -> some View) -> some View {
        ForEach(options, id: \.self) { option in
            EmblemChoice(title: title(option), selected: option == selection.wrappedValue, tint: tint(option)) {
                selection.wrappedValue = option
                withAnimation(.snappy) { expanded = nil }
            } glyph: {
                glyph(option, option == selection.wrappedValue)
            }
            .frame(height: Metrics.paneHeaderButton)
        }
    }

    private var formulaPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        let pattern = formula == .pattern
        let error = pattern ? check.error : check.avatarError
        let otherError = pattern ? check.avatarError.map { "头像算式：\($0)" } : check.error.map { "图案算式：\($0)" }
        let hidden = pattern ? design.avatar : design.expression
        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                // 另一条算式只占高度：输入框取两条里高的那条，切换时面板不变高变矮，下面一行按钮不跟着挪
                Text(hidden.isEmpty ? " " : hidden)
                    .font(Theme.code)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .accessibilityHidden(true)
                TextField(pattern ? "图案算式" : "头像算式", text: pattern ? $design.expression : $design.avatar, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.code)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused(typing)
                    .scrollsOnlyWhileTyping(typing.wrappedValue)
            }
            .padding(.horizontal, Metrics.controlInset + 8)
            .padding(.vertical, 6)
            HStack(spacing: Metrics.paneButtonGap) {
                Button { showsInfo.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(PaneButtonStyle())
                    .help("算式里的参数")
                    .accessibilityLabel(pattern ? "图案算式说明" : "头像算式说明")
                    .popover(isPresented: $showsInfo, arrowEdge: Self.infoEdge) {
                        (pattern ? EmblemFormulaInfo.pattern : EmblemFormulaInfo.avatar)
                            .font(Theme.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 240, alignment: .leading)
                            .padding(12)
                            .presentationCompactAdaptation(.popover)
                    }
                if let message = error ?? otherError {
                    Text(message).font(Theme.caption).foregroundStyle(Theme.danger)
                        .lineLimit(1).truncationMode(.tail)
                        .help(message)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    formulaButton(.pattern, title: "图案算式", icon: "circle.grid.3x3")
                    formulaButton(.avatar, title: "头像算式", icon: "person.crop.circle")
                }
            }
            .padding(.horizontal, Metrics.controlButtonInset)
        }
        .padding(.top, Metrics.controlInset)
        .padding(.bottom, Metrics.controlButtonInset)
        // 面板本身不接交互高光：点里面的图标时整块玻璃不跟着变亮
        .glassEffect(.regular, in: shape)
    }

    /// 参数说明弹在按钮上面，下面只剩控制区的留白。iPhone 上给 .top 时弹出框落在按钮下面、被压成一条（用户实测），所以两端分开给。
    #if os(iOS)
    private static let infoEdge = Edge.bottom
    #else
    private static let infoEdge = Edge.top
    #endif

    /// 切换算式的图标，正在编辑的那条用主题色。
    private func formulaButton(_ value: Formula, title: String, icon: String) -> some View {
        let selected = formula == value
        return Button { formula = value } label: { Image(systemName: icon) }
            .buttonStyle(PaneButtonStyle(foreground: selected ? .accentColor : .secondary))
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    /// 签名的一张卡片：盖住后面的点阵，底色同填充框；给了 height 时取这个高度，同一行与算式卡片一样高。
    func emblemCard(inset: CGFloat, height: CGFloat? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return padding(.vertical, inset)
            .frame(height: height, alignment: .top)
            .background(Theme.codeBackground, in: shape)
            .background(Theme.card, in: shape)
    }
}

/// 弹窗卡片里竖排的一列小样，上面是名称。放不下时这一列滚动，不显示滚动条，出现时选中的滚到中间。
/// 颜色与点的形状共用。
private struct EmblemChoiceColumn<Glyph: View>: View {
    let label: String
    let options: [String]
    @Binding var selection: String
    let title: (String) -> String
    let tint: (String) -> Color
    @ViewBuilder let glyph: (_ option: String, _ selected: Bool) -> Glyph

    var body: some View {
        VStack(spacing: 0) {
            Text(label).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(height: InputMode.current.labelExtent)
                .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) { choices }
                }
                .frame(width: InputMode.current.button)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                // 滚动内容默认会画到列外，截在这一列里。
                .clipped()
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private var choices: some View {
        ForEach(options, id: \.self) { option in
            EmblemChoice(title: title(option), selected: option == selection, tint: tint(option)) {
                selection = option
            } glyph: {
                glyph(option, option == selection)
            }
        }
    }
}

/// 一项小样：点一下选中，选中的外面描一圈；名称在悬停提示与读屏里。
private struct EmblemChoice<Glyph: View>: View {
    let title: String
    let selected: Bool
    let tint: Color
    let select: () -> Void
    @ViewBuilder let glyph: Glyph

    static var glyphSize: CGFloat { InputMode.current.isTouch ? 22 : 16 }

    var body: some View {
        Button(action: select) {
            glyph
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .frame(width: Self.glyphSize + 8, height: Self.glyphSize + 8)
                .overlay { Circle().strokeBorder(tint.opacity(selected ? 1 : 0), lineWidth: 1.5) }
                .frame(width: InputMode.current.button, height: InputMode.current.button)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(EmblemChoiceStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一种颜色的小样；描一圈细边，浅黄在浅色底上也看得出边界。
private struct EmblemSwatch: View {
    let color: Color

    var body: some View {
        Circle().fill(color)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
    }
}

/// 点的终态形状的小样；比格子收一点，选中的圈不压到角。
/// 颜色直接给，不取前景色：没选中的形状用次要色前景填充时，在弹出框里看不见。
private struct EmblemFormGlyph: View {
    let form: DotForm
    let color: Color

    /// 没选中的形状的颜色。
    static let idle = Color.primary.opacity(0.45)

    var body: some View {
        Canvas { context, size in
            let path = form.path(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: min(size.width, size.height) / 2 * 0.8)
            context.fill(path, with: .color(color))
        }
    }
}

/// 小样按下时变淡，禁用时整列变灰。
private struct EmblemChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Choice(configuration: configuration)
    }

    private struct Choice: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}

/// 弹窗里没有窗口点阵，预览自带一块舞台和取景框。指针划过时图案跟着起反应。
private struct EmblemPreview: View {
    let pattern: DotPattern?
    @State private var stage = DotStage()
    @State private var slot = "preview.\(UUID().uuidString)"

    var body: some View {
        ZStack {
            DotCanvas()
            DotPatternArea(pattern: pattern, slot: slot)
        }
        .environment(\.dotStage, stage)
        .environment(\.dotCarrier, nil)
        .frame(height: DotMetrics.pitch * 16)
        .frame(maxWidth: .infinity)
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { stage.patternPointer(point, slot: slot) }
            else { stage.patternPointer(nil, slot: slot) }
        }
        #else
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { stage.patternPointer($0.location, slot: slot) }
            .onEnded { _ in stage.patternPointer(nil, slot: slot) })
        #endif
        .accessibilityHidden(true)
    }
}
