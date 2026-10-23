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

/// 一块玻璃伸开时从里面分出关闭按钮。关闭按钮那块玻璃一直都在：收着时叠在 panel 的尾端，玻璃容器里两块合成一块，图标藏着、点不到；
/// 伸开时 panel 让出位置，关闭按钮停在后面，两块拉开。不靠插入视图：插进来的玻璃没有来处，只会在原地模糊淡入。玻璃容器由用的地方给。
struct GlassSplit<Panel: View, Close: View>: View {
    let open: Bool
    @ViewBuilder var panel: Panel
    @ViewBuilder var close: Close

    var body: some View {
        GlassSplitLayout(open: open, spacing: Metrics.paneButtonGap) {
            panel
            PaneHeaderButtonGroup { close.opacity(open ? 1 : 0) }
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
    }
}

/// GlassSplit 的排布：关闭按钮贴着尾端；伸开时 panel 排在它前面、隔 spacing，收着时 panel 占满、关闭按钮叠在它尾端。
private struct GlassSplitLayout: Layout {
    let open: Bool
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let close = subviews[1].sizeThatFits(.unspecified)
        let panel = subviews[0].sizeThatFits(panelProposal(proposal, close: close))
        let height = max(panel.height, close.height)
        return CGSize(width: open ? panel.width + spacing + close.width : max(panel.width, close.width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let close = subviews[1].sizeThatFits(.unspecified)
        let panel = subviews[0].sizeThatFits(panelProposal(ProposedViewSize(bounds.size), close: close))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(panel))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(close))
    }

    private func panelProposal(_ proposal: ProposedViewSize, close: CGSize) -> ProposedViewSize {
        guard open, let width = proposal.width else { return proposal }
        return ProposedViewSize(width: max(width - spacing - close.width, 0), height: proposal.height)
    }
}
