import SwiftUI

/// 点放大镜展开成搜索框的一块玻璃。没在搜时放大镜和 buttons 同在一组；展开后 buttons 换成输入框和 accessory，整组伸满，
/// 关闭按钮从组里分出来，停稳后是两块玻璃（GlassSplit）。玻璃容器由用的地方给（GlassEffectContainer，间距同按钮间距），旁边别的按钮组也能和它一起变形。
/// 面板始终是同一个视图，只随状态伸缩；拆进两个分支会变成移除再插入，iOS 上只剩模糊淡入。侧栏标志栏和文件窗口的控制区用它。
struct ExpandingSearch<Buttons: View, Accessory: View>: View {
    @Binding var presented: Bool
    @Binding var text: String
    /// 在输入框里按回车。
    var submit: () -> Void = {}
    @ViewBuilder var buttons: Buttons
    /// 展开后跟在输入框后面，例如匹配个数和上一个、下一个。
    @ViewBuilder var accessory: Accessory
    @FocusState private var focused: Bool
    @Namespace private var glass

    var body: some View {
        GlassSplit(open: presented) {
            PaneHeaderButtonGroup(expands: presented) { controls }
                .glassEffectID("search-panel", in: glass)
                .glassEffectTransition(.matchedGeometry)
        } close: {
            Button(action: close) {
                PaneHeaderButtonLabel("关闭搜索", systemImage: "xmark")
            }
            .help("关闭搜索")
        }
    }

    @ViewBuilder private var controls: some View {
        Button {
            // 面板展开停稳后再把焦点交给输入框。
            withAnimation {
                presented = true
            } completion: {
                if presented { focused = true }
            }
        } label: {
            PaneHeaderButtonLabel("搜索", systemImage: "magnifyingglass")
        }
        .help("搜索")
        if presented {
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.paneHeaderButton)
                .focused($focused)
                .onSubmit(submit)
                .keyboardDismissToolbar()
                #if os(macOS)
                .onExitCommand(perform: close)
                #endif
            accessory
        } else {
            buttons
        }
    }

    private func close() {
        focused = false
        text = ""
        withAnimation { presented = false }
    }
}

extension ExpandingSearch where Accessory == EmptyView {
    init(presented: Binding<Bool>, text: Binding<String>, @ViewBuilder buttons: () -> Buttons) {
        self.init(presented: presented, text: text, buttons: buttons, accessory: { EmptyView() })
    }
}

/// 一块玻璃伸开时从里面分出关闭按钮：关闭按钮那块收着时并在 panel 的尾端，伸开时 panel 让出位置、两块拉开，见 GlassRow。玻璃容器由用的地方给。
struct GlassSplit<Panel: View, Close: View>: View {
    let open: Bool
    @ViewBuilder var panel: Panel
    @ViewBuilder var close: Close

    var body: some View {
        GlassRow(spacing: Metrics.paneButtonGap) {
            panel.glassRowFills()
            PaneHeaderButtonGroup { close }.glassMerge(open ? .open : .merged(.leading))
        }
    }
}

/// 一行玻璃里的一块开着，还是并进挨着的那块（见 GlassRow）。
nonisolated enum GlassMerge: Equatable {
    case open
    /// 并进这一边挨着的那块开着的：.trailing 是右边那块，叠在它的左端；这一边没有就并进另一边的。
    case merged(HorizontalEdge)

    /// 并着的内容怎么淡：分出来时等离开邻居再显出来，并回去时先藏起来。跟着挪动一起淡的话，图标一路压在邻居的图标上
    /// （2026-10-27 iPhone 录屏：侧栏开关伸成搜索框时，关闭按钮的叉压着放大镜）。
    static func fade(merged: Bool) -> Animation {
        merged ? .easeOut(duration: 0.1) : .easeIn(duration: 0.15).delay(0.15)
    }
}

extension View {
    /// GlassRow 里的一块开着还是并着。并着时里面的按钮组缩成一个按钮大的圆、内容藏起来（见 PaneHeaderButtonGroup），点不到、读屏跳过。
    func glassMerge(_ merge: GlassMerge) -> some View {
        modifier(GlassMergePiece(merge: merge))
    }

    /// GlassRow 里占满剩下的宽的那块。
    func glassRowFills(_ fills: Bool = true) -> some View {
        layoutValue(key: GlassRowFills.self, value: fills)
    }
}

extension EnvironmentValues {
    /// 所在的这块在 GlassRow 里并着，见 glassMerge。
    @Entry var glassMerged = false
}

private struct GlassMergePiece: ViewModifier {
    let merge: GlassMerge
    @Environment(\.glassMerged) private var outer

    func body(content: Content) -> some View {
        let merged = merge != .open
        content
            .environment(\.glassMerged, outer || merged)
            .allowsHitTesting(!merged)
            .accessibilityHidden(merged)
            .layoutValue(key: GlassMergeKey.self, value: merge)
    }
}

nonisolated private struct GlassMergeKey: LayoutValueKey {
    static let defaultValue = GlassMerge.open
}

nonisolated private struct GlassRowFills: LayoutValueKey {
    static let defaultValue = false
}

/// 一行几块玻璃，开着的从左往右排、隔 spacing，标了 glassRowFills 的那块占满剩下的宽。并着的一块缩成一个按钮大的圆（玻璃的端头也是这么大），
/// 叠在挨着的那块开着的端头上、不占地方，玻璃容器里两块合成一块；开合时它从邻居的端头分出来、并回去。
/// 用不着的一块也一直留在排布里：紧凑布局里控制区换窗口时的玻璃变形要它在，拿掉就只剩硬切（2026-10-27 iPhone 对照）。
/// 旁边那块里有菜单时，iOS 点开菜单会把那块玻璃拿去变形，并着的圆要和它 glassEffectUnion 成一块才不留在原地（见 FilePane 的控制区）；
/// 并着时改用 Glass.identity 不行，开合时一块玻璃消失、一块出现，玻璃容器把变形排成先后两段，侧栏开关要等切换器散完才伸开；
/// 在外面加透明度也藏不住玻璃容器里的玻璃和内容（同日 iPhone）。
/// 不靠插入、移除视图：插进来的玻璃没有来处，只会在原地模糊淡入；移除中的视图不在排布里，按原位淡出（2026-10-24 Mac 小程序逐帧量过）。
/// 新出现的一块先并着画一轮、再改 glassMerge 分出来（见 PaneHeaderActions），不用过渡：iPhone 上过渡修饰里改的环境值传不到内容。
/// 并着的那块旁边要有开着的。玻璃容器由用的地方给，间距同 spacing。
struct GlassRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = arrange(proposal, subviews)
        return CGSize(width: row.width, height: row.pieces.map(\.size.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = arrange(ProposedViewSize(width: bounds.width, height: proposal.height), subviews)
        for (subview, piece) in zip(subviews, row.pieces) {
            subview.place(at: CGPoint(x: bounds.minX + piece.x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(piece.size))
        }
    }

    private func arrange(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (width: CGFloat, pieces: [(x: CGFloat, size: CGSize)]) {
        let merges = subviews.map { $0[GlassMergeKey.self] }
        let open = subviews.indices.filter { merges[$0] == .open }
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = CGFloat(max(open.count - 1, 0)) * spacing
        if let fill = open.first(where: { subviews[$0][GlassRowFills.self] }) {
            let others = open.reduce(0) { $1 == fill ? $0 : $0 + sizes[$1].width }
            sizes[fill] = subviews[fill].sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0 - others - gaps, 0) },
                                                                       height: proposal.height))
        }
        var xs = Array(repeating: CGFloat.zero, count: subviews.count)
        var x: CGFloat = 0
        for index in open {
            xs[index] = x
            x += sizes[index].width + spacing
        }
        for index in subviews.indices {
            guard case .merged(let edge) = merges[index] else { continue }
            let next = open.first { $0 > index }, previous = open.last { $0 < index }
            if let next, edge == .trailing || previous == nil {
                xs[index] = xs[next]
            } else if let previous {
                xs[index] = xs[previous] + sizes[previous].width - sizes[index].width
            }
        }
        return (open.isEmpty ? 0 : x - spacing, zip(xs, sizes).map { ($0, $1) })
    }
}
