import AppKit
import SwiftUI

// 让 app/Kite 里的真实源文件（Markdown.swift、ReferenceViews.swift 等）能单独用 swiftc 编进实验：
// 这里只补它们引用到、但与散文排版无关的类型。代码块、表格、提示条在本实验里不出现，桩只要能编过。

// MARK: Markdown.swift 的依赖（代码块、表格、复制提示）

@Observable final class ToastCenter {
    func show(_ text: String, systemImage: String? = nil) {}
}

extension EnvironmentValues {
    @Entry var toast: ToastCenter?
}

func copyToPasteboard(_ text: String, toast: ToastCenter?) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func splitLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return (text.hasSuffix("\n") ? String(text.dropLast()) : text).components(separatedBy: "\n")
}

typealias BlockCardPress = (_ pressed: Bool, _ at: CGPoint) -> Void

struct BlockCard<Label: View, Actions: View, Content: View>: View {
    let content: Content

    init(label: String, copyLabel: String, background: Color = Theme.codeBackground, radius: CGFloat = Metrics.contentRadius,
         copy: @escaping () -> Void, @ViewBuilder actions: @escaping (_ press: @escaping BlockCardPress) -> Actions,
         @ViewBuilder content: () -> Content) where Label == Text {
        self.content = content()
    }

    var body: some View { content }
}

struct BlockCardIcon: View {
    init(_ asset: String) {}
    var body: some View { EmptyView() }
}

struct HighlightedCode: View {
    let text: String
    let language: String?
    var body: some View { Text(text) }
}

extension View {
    func hintsScrollOverflow(_ axis: Axis = .vertical) -> some View { self }
}

struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    var body: some View { EmptyView() }
}

// MARK: ReferenceViews.swift 的依赖（ReferenceNavigation 用到宿主模型，本实验不走它）

@Observable final class AppModel {
    func openFileReference(_ file: FileReference, in area: WorkArea) async throws {}
}

@Observable final class WorkArea {
    struct Machine { let id: String }
    struct Remote { let machine: Machine }
    let id = "spike"
    var remote: Remote?
}
