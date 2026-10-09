#if os(iOS)
import SwiftUI
import UIKit

/// 模型打开 SwiftUI 分段选择弹窗，更多操作保留原生菜单；两个入口共用标题栏玻璃。
struct PhoneThreadHeaderMenus: UIViewRepresentable {
    let modelTitle: String
    let modelName: String?
    let modelEnabled: Bool
    let commands: [[ThreadHeaderCommand]]
    let onOpenModel: () -> Void
    @ScaledMetric(relativeTo: .body) private var controlHeight = Metrics.paneHeaderButton

    func makeUIView(context: Context) -> PhoneThreadMenuButton { PhoneThreadMenuButton() }
    func updateUIView(_ button: PhoneThreadMenuButton, context: Context) {
        button.update(self)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneThreadMenuButton, context: Context) -> CGSize? {
        CGSize(width: uiView.intrinsicContentSize.width, height: controlHeight)
    }
}

final class PhoneThreadMenuButton: UIButton {
    private enum MenuKind { case model, more }
    private var content: PhoneThreadHeaderMenus?
    private var accessibilityMenu: MenuKind?
    private lazy var modelElement = PhoneMenuAccessibilityElement(accessibilityContainer: self)
    private lazy var moreElement = PhoneMenuAccessibilityElement(accessibilityContainer: self)

    init() {
        super.init(frame: .zero)
        var appearance = UIButton.Configuration.glass()
        appearance.cornerStyle = .capsule
        appearance.buttonSize = .large
        appearance.baseForegroundColor = .label
        appearance.image = UIImage(systemName: "ellipsis")
        appearance.imagePlacement = .trailing
        appearance.imagePadding = Metrics.paneHeaderButtonGap
        appearance.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15)
        appearance.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        appearance.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .body)
            return attributes
        }
        // 内容与玻璃都由 UIButton 自己生成，沿用系统默认的菜单转场来源。
        appearance.titleLineBreakMode = .byClipping
        configuration = appearance
        titleLabel?.numberOfLines = 1
        showsMenuAsPrimaryAction = true
        isAccessibilityElement = false
        modelElement.accessibilityLabel = "模型"
        moreElement.accessibilityLabel = "更多操作"
        moreElement.accessibilityTraits = .button
        modelElement.activate = { [weak self] in self?.openAccessibleMenu(.model) ?? false }
        moreElement.activate = { [weak self] in self?.openAccessibleMenu(.more) ?? false }
        accessibilityElements = [modelElement, moreElement]
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in
            complete(self?.menuElements() ?? [])
        }])
    }

    func update(_ next: PhoneThreadHeaderMenus) {
        content = next
        if configuration?.title != next.modelTitle { configuration?.title = next.modelTitle }
        modelElement.accessibilityValue = next.modelName ?? next.modelTitle
        modelElement.accessibilityTraits = next.modelEnabled ? .button : [.button, .notEnabled]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let modelWidth = menuBoundary
        modelElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: modelWidth, height: bounds.height)
        moreElement.accessibilityFrameInContainerSpace = CGRect(x: modelWidth, y: 0, width: bounds.width - modelWidth, height: bounds.height)
    }

    /// 两个入口按标签间距的中点分界，收紧间距后不让“更多”的点击区覆盖模型文字。
    private var menuBoundary: CGFloat {
        guard let titleLabel, let imageView else { return max(0, bounds.width - bounds.height) }
        let titleFrame = titleLabel.convert(titleLabel.bounds, to: self)
        let imageFrame = imageView.convert(imageView.bounds, to: self)
        return (titleFrame.maxX + imageFrame.minX) / 2
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let kind = accessibilityMenu ?? (location.x < menuBoundary ? .model : .more)
        accessibilityMenu = nil
        if kind == .model {
            if content?.modelEnabled == true { content?.onOpenModel() }
            return nil
        }
        return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    private func openAccessibleMenu(_ kind: MenuKind) -> Bool {
        guard window != nil, !isHeld, kind != .model || content?.modelEnabled == true else { return false }
        if kind == .model {
            content?.onOpenModel()
            return true
        }
        accessibilityMenu = kind
        performPrimaryAction()
        return true
    }

    private func menuElements() -> [UIMenuElement] {
        guard let content else { return [] }
        return content.commands.map { section in
            UIMenu(options: .displayInline, children: section.map { command in
                UIAction(title: command.title, image: UIImage(systemName: command.symbol),
                    attributes: command.enabled ? [] : .disabled) { _ in command.action() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

private final class PhoneMenuAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}
#endif
