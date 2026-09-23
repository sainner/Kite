import SwiftUI

/// 侧边栏，没有自己的底色。现在只有占位色块。
struct Sidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Theme.placeholder).frame(height: 28)
            }
            Spacer()
        }
    }
}
