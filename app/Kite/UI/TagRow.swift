import SwiftUI

/// 一行只读的小标签，写一样东西能用来做什么这类属性，不能点。描边胶囊、字淡一些，保持安静；
/// 自己不收窄，放不下时让旁边的文字先截断。
struct TagRow: View {
    let titles: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(Theme.rule) }
            }
        }
        .fixedSize()
    }
}
