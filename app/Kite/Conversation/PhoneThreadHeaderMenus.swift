#if os(iOS)
import SwiftUI
import UIKit

struct PhoneThreadMenuGlass: ViewModifier {
    @Environment(\.compactSharedGlass) private var shared

    @ViewBuilder func body(content: Content) -> some View {
        if shared { content.glassEffect(.regular.interactive(), in: .capsule) }
        else { content }
    }
}

/// 模型与更多入口共用一个原生菜单控件和标题栏玻璃，按点在哪一侧决定弹出哪份菜单。
struct PhoneThreadHeaderMenus: UIViewRepresentable {
    let modelTitle: String
    let modelLogo: ImageResource?
    let modelName: String?
    let modelEnabled: Bool
    let models: ThreadModelMenu
    let commands: [[ThreadHeaderCommand]]
    @Environment(\.compactSharedGlass) private var sharedGlass
    @ScaledMetric(relativeTo: .body) private var controlHeight = Metrics.paneHeaderButton

    func makeUIView(context: Context) -> PhoneThreadMenuButton { PhoneThreadMenuButton() }
    func updateUIView(_ button: PhoneThreadMenuButton, context: Context) {
        button.update(self, sharedGlass: sharedGlass)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneThreadMenuButton, context: Context) -> CGSize? {
        CGSize(width: uiView.intrinsicContentSize.width, height: controlHeight)
    }
}

final class PhoneThreadMenuButton: UIButton {
    private enum MenuKind { case model, more }
    private var content: PhoneThreadHeaderMenus?
    private var activeMenu: MenuKind = .model
    private var accessibilityMenu: MenuKind?
    private var sharedGlass = false
    private struct TitleKey: Equatable {
        let text: String
        let logo: ImageResource?
        let size: UIContentSizeCategory
    }
    /// 已显示的模型名、标志和字号，变了才重排标题。
    private var shownTitle: TitleKey?
    private lazy var modelElement = PhoneMenuAccessibilityElement(accessibilityContainer: self)
    private lazy var moreElement = PhoneMenuAccessibilityElement(accessibilityContainer: self)

    init() {
        super.init(frame: .zero)
        configuration = Self.appearance(sharedGlass: false)
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

    private static func appearance(sharedGlass: Bool) -> UIButton.Configuration {
        var appearance = sharedGlass ? UIButton.Configuration.plain() : UIButton.Configuration.glass()
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
        return appearance
    }

    /// 厂商标志作为文字附件排在模型名前，随文字颜色着色，竖直居中于大写字母；命中分界仍按标题末尾算。
    /// 和模型名的间隔画成附件图右侧的留白：附件字符上加 kern 在按钮标题里拉不开间距。
    private static func title(_ text: String, logo: ImageResource?, size: UIContentSizeCategory) -> AttributedString {
        guard let logo else { return AttributedString(text) }
        let traits = UITraitCollection(preferredContentSizeCategory: size)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let extent = UIFontMetrics(forTextStyle: .body).scaledValue(for: Metrics.paneHeaderLogo, compatibleWith: traits)
        let width = extent + Metrics.paneHeaderLogoGap
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: extent)).image { _ in
            UIImage(resource: logo).draw(in: CGRect(x: 0, y: 0, width: extent, height: extent))
        }
        let attachment = NSTextAttachment(image: image.withRenderingMode(.alwaysTemplate))
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - extent) / 2, width: width, height: extent)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: text))
        return (try? AttributedString(title, including: \.uiKit)) ?? AttributedString(text)
    }

    func update(_ next: PhoneThreadHeaderMenus, sharedGlass: Bool) {
        if self.sharedGlass != sharedGlass {
            self.sharedGlass = sharedGlass
            // 保留菜单的配置和命中分区，只把玻璃交回共享容器。
            configuration = Self.appearance(sharedGlass: sharedGlass)
            shownTitle = nil
        }
        content = next
        let key = TitleKey(text: next.modelTitle, logo: next.modelLogo, size: traitCollection.preferredContentSizeCategory)
        if shownTitle != key {
            shownTitle = key
            configuration?.attributedTitle = Self.title(key.text, logo: key.logo, size: key.size)
        }
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
        guard kind != .model || content?.modelEnabled == true else { return nil }
        activeMenu = kind
        return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    private func openAccessibleMenu(_ kind: MenuKind) -> Bool {
        guard window != nil, !isHeld, kind != .model || content?.modelEnabled == true else { return false }
        accessibilityMenu = kind
        performPrimaryAction()
        return true
    }

    private func menuElements() -> [UIMenuElement] {
        guard let content else { return [] }
        switch activeMenu {
        case .model:
            let models = content.models
            var elements: [UIMenuElement] = []
            if let status = models.status {
                elements.append(UIAction(title: status, attributes: .disabled) { _ in })
            }
            elements += models.vendors.map { vendor in
                UIMenu(title: vendor.title ?? "", options: .displayInline, children: vendor.models.map { model in
                    UIAction(title: model.name, attributes: model.enabled ? [] : .disabled,
                        state: model.selected ? .on : .off) { _ in models.select(model.id) }
                })
            }
            if let note = models.note {
                elements.append(UIMenu(options: .displayInline, children: [UIAction(title: note, attributes: .disabled) { _ in }]))
            }
            return elements
        case .more:
            return content.commands.map { section in
                UIMenu(options: .displayInline, children: section.map { command in
                    var attributes: UIMenuElement.Attributes = command.enabled ? [] : .disabled
                    if command.destructive { attributes.insert(.destructive) }
                    return UIAction(title: command.title, image: UIImage(systemName: command.symbol), attributes: attributes) { _ in command.action() }
                })
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

private final class PhoneMenuAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}
#endif
