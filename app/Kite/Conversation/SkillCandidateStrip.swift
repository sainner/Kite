import SwiftUI

/// 输入框上面的 skill 候选：打了「/」开头的名字时，这个工作区能加载的 skill 里名字匹配的一个挨一个横排，放不下横着滑；
/// 点一个就把「/名字 」换进输入框。圆角和玻璃同心（ComposerLayout.fieldFillRadius）。
/// 两端原生输入区（MacControlsBar、PhoneControlsBar）经 SkillStripHost 托管它，Mac 窄窗口的 ThreadControls 直接放。
struct SkillCandidateStrip: View {
    let controls: ThreadControlsModel

    /// 一行的高，固定；输入区按它排版，不用量。
    static let height: CGFloat = 32

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(controls.skillCandidates) { skill in
                        let selected = controls.selectedSkill?.name == skill.name
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
            .onChange(of: controls.selectedSkill?.name, initial: true) {
                if let name = controls.selectedSkill?.name { proxy.scrollTo(name, anchor: .center) }
            }
        }
        .frame(height: Self.height)
    }
}

/// 两端原生输入区托管 skill 候选那一行：换了会话、外观或字号重建；候选变了重摆，经 resized 让输入区重排。没有候选时藏着。
/// 每次按模型摆时顺带把这个工作区能加载的 skill 读进来（打了「/」才读）。
@MainActor final class SkillStripHost {
    #if os(macOS)
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    #else
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    #endif
    var resized: () -> Void = {}
    /// 现在放的是哪个会话、什么外观的；换了重建。
    private var owner: (thread: ObjectIdentifier, scheme: ColorScheme?, typeSize: DynamicTypeSize?)?
    /// 现在列着哪几个候选；变了重摆。
    private var key: [String] = []

    var view: PlatformView { host.view }

    init() {
        host.sizingOptions = []
        host.view.isHidden = true
        #if os(iOS)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        #endif
    }

    func show(_ controls: ThreadControlsModel, environment: EnvironmentValues?) {
        controls.loadSkillsIfNeeded()
        let owner = (thread: ObjectIdentifier(controls.thread), scheme: environment?.colorScheme, typeSize: environment?.dynamicTypeSize)
        if self.owner?.thread != owner.thread || self.owner?.scheme != owner.scheme || self.owner?.typeSize != owner.typeSize {
            self.owner = owner
            host.rootView = AnyView(SkillCandidateStrip(controls: controls)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.self, environment ?? EnvironmentValues()))
        }
        let key = controls.skillCandidates.map(\.name)
        if key != self.key {
            self.key = key
            resized()
        }
        if host.view.isHidden != key.isEmpty { host.view.isHidden = key.isEmpty }
    }

    /// 那一行的高，没有候选时 0。
    func height(width: CGFloat) -> CGFloat { key.isEmpty ? 0 : SkillCandidateStrip.height }
}
