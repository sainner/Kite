import SwiftUI

/// 输入框上面的 skill 候选：打了「/」开头的名字时，这个工作区能加载的 skill 里名字匹配的一个挨一个横排，放不下横着滑；
/// 点一个就把「/名字 」换进输入框。圆角和玻璃同心（ComposerLayout.fieldFillRadius）。
/// 两端原生输入区（MacControlsBar、PhoneControlsBar）经 ComposerStripHost 托管它，Mac 窄窗口的 ThreadControls 直接放。
struct SkillCandidateStrip: View {
    let controls: ThreadControlsModel

    /// 一行的高，固定；输入区按它排版，不用量。
    static let height: CGFloat = 32

    var body: some View {
        let candidates = controls.skillCandidates
        let current = controls.selectedSkill(in: candidates)?.name
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(candidates) { skill in
                        let selected = current == skill.name
                        Button { controls.pickSkill(skill) } label: {
                            HStack(spacing: 6) {
                                Text("/\(skill.name)").font(Theme.code)
                                if !skill.description.isEmpty {
                                    Text(skill.description).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: Self.height)
                            .frame(maxWidth: 320)
                            .background(selected ? Color.accentColor.opacity(0.18) : ComposerLayout.fieldFill,
                                        in: RoundedRectangle(cornerRadius: ComposerLayout.fieldFillRadius, style: .continuous))
                        }
                        .buttonStyle(.pointingPlain)
                        .help(skill.description)
                        .accessibilityLabel("用 skill \(skill.name)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(skill.name)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: current, initial: true) {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .frame(height: Self.height)
    }
}
