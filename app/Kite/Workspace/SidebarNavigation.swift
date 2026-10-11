import SwiftUI

/// 一级导航的各栏。
enum SidebarSection: CaseIterable, Identifiable {
    case workspaces, drive, extensions, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .workspaces: "空间"
        case .drive: "设备"
        case .extensions: "资源库"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "cube"
        case .drive: "externaldrive"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }

    /// 设置不在一级导航里，从用户栏末尾的设置按钮进入。
    var navigable: Bool { self != .settings }

    /// 导航行尾的数字：工作区数量，设备一栏是在线的机器数。
    @MainActor func count(in model: AppModel) -> Int? {
        switch self {
        case .workspaces: model.workspaces.count
        case .drive: model.availableWorkers.count
        case .extensions, .settings: nil
        }
    }
}

/// 一级栏里的一页：侧栏里一行，内容区一张卡片。
protocol SidebarPage: Hashable, Identifiable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    var icon: TablerSymbol { get }
    var available: Bool { get }
}

/// 一级菜单使用主题色背景，列表行使用 SidebarListRow。
private struct SidebarNavigationStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.sidebarMetrics) private var metrics
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hovering = hovered && isEnabled
        let highlight = Color.gray.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.2 : hovering ? 0.1 : 0)
        configuration.label
            .environment(\.sidebarButtonHovered, !InputMode.current.isTouch && hovered && isEnabled && !selected)
            .padding(.leading, metrics.itemInset)
            // 行尾数字自己占一个与行同高的方格，见 SidebarNavigationLabel。
            .frame(height: metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(metrics.rowShape)
            .background {
                metrics.rowShape.fill(selected ? Color.accentColor : highlight)
                    .overlay {
                        metrics.rowShape.fill(Color.black.opacity(!selected ? 0 : configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .clickPointer()
    }
}

/// 一级菜单的图标、标题与数量。
private struct SidebarNavigationLabel: View {
    let title: String
    let systemImage: String
    var note: String?
    /// 选中时图标换实心，白字配合主题色背景。
    var selected = false
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.labelExtent - 4, weight: .bold))
                .symbolVariant(selected ? .fill : .none)
                .opacity(0.65)
                .frame(width: metrics.labelExtent)
            Text(title).font(Theme.sidebarHeading).lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .frame(minWidth: metrics.rowHeight)
            }
        }
        .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
    }
}

/// 一级导航：标志栏下面一列全宽按钮，选中项用主题色背景配白字。两端相同，iPhone 放在侧栏抽屉顶部。
/// 设置不在这里，入口是用户栏末尾的设置按钮。
/// 收起的侧栏里只留图标竖着排。
struct SidebarNavigation: View {
    /// 收起的图标栏里只要图标。
    var iconsOnly = false
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        VStack(spacing: iconsOnly ? 12 : 4) {
            ForEach(SidebarSection.allCases.filter(\.navigable)) { section in
                let selected = model.sidebarSection == section
                let button = Button {
                    withAnimation(.snappy) { model.sidebarSection = section }
                } label: {
                    if iconsOnly {
                        Image(systemName: section.symbol)
                            .font(.system(size: metrics.labelExtent - 4, weight: .bold))
                            .symbolVariant(selected ? .fill : .none)
                            .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
                            .opacity(0.65)
                            .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                            .background(selected ? Color.accentColor : .clear, in: sidebarRowShape)
                            .contentShape(sidebarRowShape)
                    } else {
                        SidebarNavigationLabel(title: section.title, systemImage: section.symbol,
                                               note: section.count(in: model).map(String.init), selected: selected)
                    }
                }
                .help(section.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if iconsOnly { button.buttonStyle(SidebarButtonStyle()) }
                else { button.buttonStyle(SidebarNavigationStyle(selected: selected)) }
            }
        }
    }
}

/// 侧栏底部的用户栏：左边账号信息，末尾的按钮进入设置。
struct SidebarUserBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.workspacePresentation) private var presentation

    private var user: AccountUser? { model.account.user }

    var body: some View {
        let quotas = model.subscriptionQuotas
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.email ?? "未登录")
                    .font(Theme.body).lineLimit(1).truncationMode(.middle)
                    // 宽屏侧栏里邮箱比额度再往里缩一点
                    .padding(.leading, presentation == .tiled ? 2 : 0)
                HStack(spacing: 4) {
                    // 账号层的错误比额度更上游，出现时替换额度，点开看 Kite 账号页。
                    if let error = model.account.error {
                        Button { withAnimation(.snappy) { model.openSettings(.account) } } label: {
                            chip {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text(error)
                            }
                        }
                        .buttonStyle(.plain)
                        .clickPointer()
                        .help(error)
                        .accessibilityLabel(error)
                        .accessibilityHint("打开 Kite 账号设置")
                    } else if quotas.isEmpty {
                        chip { Text("额度未获取") }
                            .help("在设备的账号页查看登录和查询状态")
                    } else {
                        ForEach(quotas) { quota($0) }
                    }
                }
            }
            .padding(.leading, presentation == .tiled ? 3 : 6)
            Spacer(minLength: 0)
            SidebarSettingsButton()
        }
        // 设置按钮贴着侧栏右边缘，底边与旁边窗口的底边对齐
        .padding(.top, 10)
    }

    /// 圆环显示这家厂商各账号合计的剩余额度，不到两成时换成警示色；悬停列出各账号。
    private func quota(_ quota: SubscriptionQuota) -> some View {
        let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(0))) }
        let total = quota.accounts.count > 1 ? "\(quota.accounts.count) 个账号合计剩余" : "剩余"
        let detail = (["\(quota.provider) · \(total) \(percent(quota.remaining))"]
            + quota.accounts.map { "\($0.name) · \($0.quota) · 剩余 \(percent($0.remaining))" }).joined(separator: "\n")
        let tint = quota.remaining < 0.2 ? Theme.warning : Color.accentColor
        return chip {
            ZStack {
                Circle().stroke(Theme.rule, lineWidth: 1.5)
                Circle().trim(from: 0, to: quota.remaining)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 8, height: 8)
            Text(quota.provider)
        }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        // iPhone 的 caption2 比 Mac 大一号，胶囊跟着放大
        #if os(iOS)
        let (inset, height): (CGFloat, CGFloat) = (6, 16)
        #else
        let (inset, height): (CGFloat, CGFloat) = (5, 14)
        #endif
        return HStack(spacing: 3) { content() }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, inset)
            .frame(height: height)
            .background(Theme.selection, in: Capsule())
    }
}

/// 用户头像，显示邮箱首字母。
struct SidebarAvatar: View {
    @Environment(AppModel.self) private var model

    private var user: AccountUser? { model.account.user }

    var body: some View {
        Text(user?.email.first.map { String($0).uppercased() } ?? "?")
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Metrics.paneHeaderButton, height: Metrics.paneHeaderButton)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel("用户头像")
    }
}

/// 用户栏与收起的侧栏共用设置入口；在设置一栏里时变成返回，回到进入设置前的一栏。
struct SidebarSettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.sidebarSection == .settings
        let title = selected ? "返回" : "设置"
        PaneHeaderButtonGroup(selected: selected) {
            Button { withAnimation(.snappy) { selected ? model.closeSettings() : model.openSettings() } } label: {
                PaneHeaderButtonLabel(title, systemImage: selected ? "chevron.backward" : "gearshape")
            }
            .help(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct SidebarListHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        if model.sidebarSection != .drive {
            Text(model.sidebarSection == .workspaces ? "项目" : model.sidebarSection.title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.itemInset)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// 标志栏：Kite 字标，右端一组标题栏玻璃按钮，搜索在前，宽屏后面跟侧边栏按钮。字标与侧栏行的文字左对齐，宽屏时与按钮底对齐；底下一道分割线。
/// 两端都有，窄布局放在侧栏抽屉顶部。搜索展开时用输入框替换侧栏按钮。
struct SidebarLogoBar<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons
    @Environment(\.workspacePresentation) private var presentation
    @Environment(\.sidebarMetrics) private var metrics
    @State private var searchPresented = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var glass

    var body: some View {
        // 宽屏侧栏里字标与按钮底部对齐，窄布局的抽屉里垂直居中
        let tiled = presentation == .tiled
        return VStack(spacing: Metrics.sidebarRuleGap) {
            HStack(alignment: tiled ? .bottom : .center, spacing: Metrics.paneButtonGap) {
                Text("Kite").font(Theme.wordmark)
                controlPanel
                    .padding(.leading, tiled && searchPresented ? Metrics.padding : 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.leading, metrics.itemInset - 2)
            .frame(height: Metrics.paneHeaderButton)
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    private var controlPanel: some View {
        // 玻璃间距与控件间距一致，让关闭按钮从面板分裂出来，停稳后仍是两块玻璃。
        // 面板始终是同一个视图，只随状态伸缩；拆进两个分支会变成移除再插入，iOS 上只剩模糊淡入。
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                searchPanel
                if searchPresented {
                    PaneHeaderButtonGroup {
                        closeSearchButton
                    }
                    .glassEffectID("search-close", in: glass)
                    .glassEffectTransition(.matchedGeometry)
                }
            }
        }
    }

    private var searchPanel: some View {
        searchPanelContent
            .glassEffectID("search-panel", in: glass)
            .glassEffectTransition(.matchedGeometry)
    }

    private var searchPanelContent: some View {
        PaneHeaderButtonGroup(expands: searchPresented) {
            searchControls
        }
    }

    @ViewBuilder private var searchControls: some View {
        Button {
            // 面板展开停稳后再把焦点交给输入框。
            withAnimation {
                searchPresented = true
            } completion: {
                if searchPresented { searchFocused = true }
            }
        } label: {
            PaneHeaderButtonLabel("搜索", systemImage: "magnifyingglass")
        }
        .help("搜索")
        if searchPresented {
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.paneHeaderButton)
                .focused($searchFocused)
                .keyboardDismissToolbar()
                #if os(macOS)
                .onExitCommand(perform: closeSearch)
                #endif
        } else {
            buttons
        }
    }

    private var closeSearchButton: some View {
        Button(action: closeSearch) {
            PaneHeaderButtonLabel("关闭搜索", systemImage: "xmark")
        }
        .help("关闭搜索")
    }

    private func closeSearch() {
        searchFocused = false
        searchText = ""
        withAnimation { searchPresented = false }
    }
}
