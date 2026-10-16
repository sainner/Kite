import SwiftUI

/// 点放大镜展开成搜索框的一块玻璃。没在搜时放大镜和 buttons 同在一组；展开后 buttons 换成输入框和 accessory，整组伸满，
/// 关闭按钮从组里分出来，停稳后是两块玻璃。玻璃容器由用的地方给（GlassEffectContainer，间距同按钮间距），旁边别的按钮组也能和它一起变形。
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
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderButtonGroup(expands: presented) { controls }
                .glassEffectID("search-panel", in: glass)
                .glassEffectTransition(.matchedGeometry)
            if presented {
                PaneHeaderButtonGroup {
                    Button(action: close) {
                        PaneHeaderButtonLabel("关闭搜索", systemImage: "xmark")
                    }
                    .help("关闭搜索")
                }
                .glassEffectID("search-close", in: glass)
                .glassEffectTransition(.matchedGeometry)
            }
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
