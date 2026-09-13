import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ItemListUI
import TelegramCore

struct FluxgramShortVideoRow {
    let title: String
    let subtitle: String
    /// A nil symbol identifies a source row with a circular fallback avatar.
    let symbol: String?
    let tint: UIColor
    let action: () -> Void
    let avatar: Signal<UIImage?, NoError>?

    init(title: String, subtitle: String, symbol: String?, tint: UIColor, action: @escaping () -> Void, avatar: Signal<UIImage?, NoError>? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.action = action
        self.avatar = avatar
    }
}

enum FluxgramShortVideoBlock {
    case intro(String)
    case rows(header: String?, count: Int?, rows: [FluxgramShortVideoRow])
    case information(String)
}

/// UIKit rendering only: one surface contains all rows of an action/source group.
/// The list remains the sole scroll container, and actions are forwarded unchanged.
final class FluxgramShortVideoBlockView: UIView {
    private typealias Design = FluxgramDesign
    private let surface = UIView()
    private let heading = UILabel()
    private let countLabel = UILabel()
    private let message = UILabel()
    private let infoIcon = UIImageView()
    private var rowViews: [FluxgramShortVideoRowView] = []
    private var content: FluxgramShortVideoBlock = .intro("")
    private var category: UIContentSizeCategory = .large

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Design.Surface.page
        surface.layer.cornerRadius = Design.Size.cardCornerRadius
        surface.layer.cornerCurve = .continuous
        surface.clipsToBounds = true
        heading.textColor = .label
        heading.accessibilityTraits = .header
        countLabel.textColor = Design.Surface.secondaryText
        countLabel.textAlignment = .right
        message.textColor = Design.Surface.secondaryText
        message.numberOfLines = 0
        infoIcon.image = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: Design.Size.iconSize, weight: .medium))
        infoIcon.contentMode = .scaleAspectFit
        infoIcon.tintColor = Design.Surface.secondaryText
        for child in [surface, heading, countLabel, message, infoIcon] { addSubview(child) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: FluxgramShortVideoBlock, category: UIContentSizeCategory) {
        self.content = content
        self.category = category
        heading.font = Design.scaledFont(Design.Font.sectionTitle, category: category)
        countLabel.font = Design.scaledFont(Design.secondaryTextStyle, category: category)
        message.font = Design.scaledFont(Design.secondaryTextStyle, category: category)
        surface.backgroundColor = Design.Surface.card
        heading.isHidden = true
        countLabel.isHidden = true
        infoIcon.isHidden = true
        message.isHidden = true
        surface.isHidden = false
        var rows: [FluxgramShortVideoRow] = []
        switch content {
        case let .intro(text):
            surface.isHidden = true
            message.isHidden = false
            message.text = text
            message.textAlignment = .center
        case let .rows(header, count, values):
            rows = values
            heading.text = header
            heading.isHidden = header == nil
            countLabel.text = count.map { "共 \($0) 个" }
            countLabel.isHidden = count == nil
            if values.isEmpty {
                message.isHidden = false
                message.text = "尚未添加来源"
                message.textAlignment = .center
            }
        case let .information(text):
            surface.backgroundColor = Design.Surface.auxiliary
            message.isHidden = false
            message.text = text
            message.textAlignment = .left
            infoIcon.isHidden = false
        }
        while rowViews.count > rows.count { rowViews.removeLast().removeFromSuperview() }
        while rowViews.count < rows.count {
            let row = FluxgramShortVideoRowView()
            surface.addSubview(row)
            rowViews.append(row)
        }
        for (index, row) in rows.enumerated() {
            rowViews[index].update(row: row, category: category, showsSeparator: index < rows.count - 1)
        }
        setNeedsLayout()
    }

    static func rowHeight(category: UIContentSizeCategory) -> CGFloat {
        let title = Design.scaledFont(Design.primaryTextStyle, category: category)
        let subtitle = Design.scaledFont(Design.secondaryTextStyle, category: category)
        let textHeight = ceil(title.lineHeight) + Design.Spacing.titleToSubtitle + ceil(subtitle.lineHeight)
        return max(Design.Size.iconContainerSize, textHeight) + Design.Spacing.rowVerticalPadding * 2
    }

    private func headerHeight() -> CGFloat {
        return ceil(heading.font.lineHeight) + Design.Spacing.metricSpacing
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // The item node already applies the list's left/right insets. Keep the
        // block at that full width so its card margin matches the NAS cards.
        let width = max(0, size.width)
        let contentWidth = max(0, width - Design.Spacing.pageHorizontalPadding * 2)
        let padding = Design.Spacing.cardPadding
        let height: CGFloat
        switch content {
        case .intro:
            height = message.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height + Design.Spacing.sectionSpacing
        case let .rows(header, _, rows):
            height = (header == nil ? 0 : headerHeight()) + CGFloat(max(1, rows.count)) * Self.rowHeight(category: category) + Design.Spacing.sectionSpacing
        case .information:
            let textWidth = max(0, contentWidth - padding * 2 - Design.Size.iconSize - Design.Spacing.iconToText)
            let textHeight = message.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            height = max(Design.Size.iconSize, ceil(textHeight)) + padding * 2 + Design.Spacing.sectionSpacing
        }
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = Design.Spacing.cardPadding
        let cardX = Design.Spacing.pageHorizontalPadding
        let width = max(0, bounds.width - cardX * 2)
        let contentHeight = sizeThatFits(bounds.size).height - Design.Spacing.sectionSpacing
        switch content {
        case .intro:
            message.frame = CGRect(x: cardX, y: 0, width: width, height: contentHeight)
        case let .rows(header, _, rows):
            let headerHeight = header == nil ? 0 : self.headerHeight()
            if header != nil {
                let countWidth = min(ceil(countLabel.intrinsicContentSize.width), width / 2)
                let titleHeight = ceil(heading.font.lineHeight)
                let countHeight = ceil(countLabel.font.lineHeight)
                heading.frame = CGRect(x: cardX + padding, y: 0, width: max(0, width - padding * 2 - countWidth - Design.Spacing.iconToText), height: titleHeight)
                // Align typographic baselines while allowing Dynamic Type to grow the header.
                countLabel.frame = CGRect(x: cardX + width - padding - countWidth, y: heading.font.ascender - countLabel.font.ascender, width: countWidth, height: countHeight)
            }
            let rowHeight = Self.rowHeight(category: category)
            surface.frame = CGRect(x: cardX, y: headerHeight, width: width, height: rowHeight * CGFloat(max(1, rows.count)))
            for (index, rowView) in rowViews.enumerated() {
                rowView.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
            }
            if rows.isEmpty {
                message.frame = surface.frame.insetBy(dx: padding, dy: padding)
            }
        case .information:
            surface.frame = CGRect(x: cardX, y: 0, width: width, height: contentHeight)
            infoIcon.frame = CGRect(x: cardX + padding, y: (contentHeight - Design.Size.iconSize) / 2, width: Design.Size.iconSize, height: Design.Size.iconSize)
            let textX = infoIcon.frame.maxX + Design.Spacing.iconToText
            message.frame = CGRect(x: textX, y: padding, width: max(0, cardX + width - padding - textX), height: contentHeight - padding * 2)
        }
    }
}

private final class FluxgramShortVideoRowView: UIView {
    private typealias Design = FluxgramDesign
    private let iconContainer = UIView()
    private let icon = UIImageView()
    private let initials = UILabel()
    private let avatarImage = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView()
    private let separator = UIView()
    private var action: (() -> Void)?
    private var avatarDisposable: Disposable?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        iconContainer.clipsToBounds = true
        icon.contentMode = .scaleAspectFit
        initials.textAlignment = .center
        initials.textColor = Design.Surface.secondaryText
        avatarImage.contentMode = .scaleAspectFill
        avatarImage.clipsToBounds = true
        titleLabel.textColor = .label
        subtitleLabel.textColor = Design.Surface.secondaryText
        for label in [titleLabel, subtitleLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: Design.Size.chevronSize, weight: .medium))
        chevron.tintColor = Design.Surface.secondaryText.withAlphaComponent(0.6)
        chevron.contentMode = .scaleAspectFit
        separator.backgroundColor = Design.Surface.separator
        for child in [iconContainer, icon, initials, avatarImage, titleLabel, subtitleLabel, chevron, separator] {
            child.isUserInteractionEnabled = false
            addSubview(child)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { avatarDisposable?.dispose() }

    func update(row: FluxgramShortVideoRow, category: UIContentSizeCategory, showsSeparator: Bool) {
        avatarDisposable?.dispose()
        avatarDisposable = nil
        action = row.action
        titleLabel.font = Design.scaledFont(Design.primaryTextStyle, category: category)
        subtitleLabel.font = Design.scaledFont(Design.secondaryTextStyle, category: category)
        initials.font = Design.primaryTextStyle
        titleLabel.text = row.title
        subtitleLabel.text = row.subtitle
        accessibilityLabel = "\(row.title)，\(row.subtitle)"
        icon.isHidden = row.symbol == nil
        initials.isHidden = row.symbol != nil
        avatarImage.isHidden = row.symbol != nil
        if let symbol = row.symbol {
            icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: Design.Size.iconSize, weight: .medium))
            icon.tintColor = row.tint
            iconContainer.backgroundColor = row.tint.withAlphaComponent(0.10)
            iconContainer.layer.cornerRadius = Design.Size.iconCornerRadius
        } else {
            // The stored source has no avatar resource. Use a consistent initial,
            // skipping brackets/punctuation rather than inventing a channel image.
            initials.text = row.title.first(where: { $0.isLetter || $0.isNumber }).map(String.init) ?? "•"
            iconContainer.backgroundColor = Design.Surface.auxiliary
            iconContainer.layer.cornerRadius = Design.Size.iconContainerSize / 2
            if let avatar = row.avatar {
                avatarDisposable = (avatar |> deliverOnMainQueue).start(next: { [weak self] image in
                    self?.avatarImage.image = image
                    self?.avatarImage.isHidden = image == nil
                    self?.initials.isHidden = image != nil
                })
            }
        }
        separator.isHidden = !showsSeparator
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = Design.Spacing.cardPadding
        let containerSize = Design.Size.iconContainerSize
        iconContainer.frame = CGRect(x: padding, y: (bounds.height - containerSize) / 2, width: containerSize, height: containerSize)
        icon.frame = iconContainer.frame.insetBy(dx: (containerSize - Design.Size.iconSize) / 2, dy: (containerSize - Design.Size.iconSize) / 2)
        initials.frame = iconContainer.frame
        avatarImage.frame = iconContainer.frame
        let textX = Design.Spacing.separatorInset
        let chevronSize = Design.Size.chevronSize
        chevron.frame = CGRect(x: bounds.width - padding - chevronSize, y: (bounds.height - chevronSize) / 2, width: chevronSize, height: chevronSize)
        let textWidth = max(0, chevron.frame.minX - Design.Spacing.iconToText - textX)
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let subtitleHeight = ceil(subtitleLabel.font.lineHeight)
        let textY = (bounds.height - titleHeight - subtitleHeight - Design.Spacing.titleToSubtitle) / 2
        titleLabel.frame = CGRect(x: textX, y: textY, width: textWidth, height: titleHeight)
        subtitleLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + Design.Spacing.titleToSubtitle, width: textWidth, height: subtitleHeight)
        let pixel = 1 / max(1, traitCollection.displayScale)
        separator.frame = CGRect(x: textX, y: bounds.height - pixel, width: max(0, bounds.width - padding - textX), height: pixel)
    }

    @objc private func pressed() { action?() }
    override func accessibilityActivate() -> Bool {
        action?()
        return action != nil
    }
}

final class FluxgramShortVideoBlockItem: ListViewItem, ItemListItem {
    let content: FluxgramShortVideoBlock
    let category: UIContentSizeCategory
    let sectionId: ItemListSectionId
    let selectable = false

    init(content: FluxgramShortVideoBlock, category: UIContentSizeCategory, sectionId: ItemListSectionId) {
        self.content = content
        self.category = category
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = FluxgramShortVideoBlockNode()
            let layout = node.prepare(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(params: params) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? FluxgramShortVideoBlockNode else { return }
            let layout = node.prepare(item: self, params: params)
            completion(layout, { _ in node.apply(params: params) })
        }
    }
}

private final class FluxgramShortVideoBlockNode: ListViewItemNode {
    private let block = FluxgramShortVideoBlockView()

    init() {
        super.init(layerBacked: false)
        backgroundColor = FluxgramDesign.Surface.page
    }

    override func didLoad() {
        super.didLoad()
        view.addSubview(block)
    }

    func prepare(item: FluxgramShortVideoBlockItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        block.update(content: item.content, category: item.category)
        let width = max(0, params.width - params.leftInset - params.rightInset)
        let size = block.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: size.height), insets: .zero)
    }

    func apply(params: ListViewItemLayoutParams) {
        let width = max(0, params.width - params.leftInset - params.rightInset)
        let size = block.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        block.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0), size: size)
        block.layoutIfNeeded()
    }
}
