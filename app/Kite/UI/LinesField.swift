import SwiftUI

/// 每行一项的输入框：编辑时保留敲下的换行和空行，写回 values 时去掉空行与首尾空白。外观由放它的地方加。
struct LinesField: View {
    let placeholder: String
    @Binding var values: [String]
    /// 正在编辑的原文；values 被别处改掉时丢掉，改回按 values 显示。
    @State private var text: String?

    var body: some View {
        TextField(placeholder, text: Binding(get: { text ?? values.joined(separator: "\n") }, set: { value in
            text = value
            let next = Self.lines(value)
            if next != values { values = next }
        }), axis: .vertical)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .onChange(of: values) { _, value in
            if let text, Self.lines(text) != value { self.text = nil }
        }
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
