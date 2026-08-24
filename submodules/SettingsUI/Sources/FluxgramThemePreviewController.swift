import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext

private struct FluxgramThemePreviewChat {
    let title: String
    let subtitle: String
    let suggestion: String
    let accentIndex: Int
}

private let fluxgramThemePreviewSuggestions = [
    "工作资料",
    "稍后看",
    "视频素材",
    "项目灵感",
    "生活/旅行"
]

private let fluxgramThemePreviewFallbackChats: [FluxgramThemePreviewChat] = [
    FluxgramThemePreviewChat(title: "产品灵感群", subtitle: "Radius 的空间层次、Arc 的侧边栏质感，可以沉淀成 Fluxgram 的聊天入口。", suggestion: "项目灵感", accentIndex: 0),
    FluxgramThemePreviewChat(title: "设计素材频道", subtitle: "3 个视频、2 个链接待整理，适合先收藏，晚上统一看。", suggestion: "视频素材", accentIndex: 1),
    FluxgramThemePreviewChat(title: "NAS 下载通知", subtitle: "下载完成后自动回流到收藏箱，文件和来源聊天保持关联。", suggestion: "工作资料", accentIndex: 2)
]

private func fluxgramPreviewColor(_ hex: UInt32, alpha: CGFloat = 1.0) -> UIColor {
    return UIColor(
        red: CGFloat((hex >> 16) & 0xff) / 255.0,
        green: CGFloat((hex >> 8) & 0xff) / 255.0,
        blue: CGFloat(hex & 0xff) / 255.0,
        alpha: alpha
    )
}

private func fluxgramPreviewAccentColor(_ index: Int, alpha: CGFloat = 1.0) -> UIColor {
    let colors: [UInt32] = [
        0x8E7BFF,
        0x34D6FF,
        0xFF8A5B,
        0x7CFFB2,
        0xFF6FD8
    ]
    return fluxgramPreviewColor(colors[index % colors.count], alpha: alpha)
}

private func fluxgramPreviewCleanText(_ text: String, fallback: String) -> String {
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let value = collapsed.isEmpty ? fallback : collapsed
    if value.count <= 62 {
        return value
    }
    let index = value.index(value.startIndex, offsetBy: 62)
    return "\(value[..<index])…"
}

private func fluxgramThemePreviewChats(context: AccountContext) -> Signal<[FluxgramThemePreviewChat], NoError> {
    return context.sharedContext.subscribeChatListData(context: context, location: .chatList(groupId: .root))
    |> map { chatList -> [FluxgramThemePreviewChat] in
        let mapped = chatList.items.prefix(6).enumerated().compactMap { index, item -> FluxgramThemePreviewChat? in
            let title = fluxgramPreviewCleanText(item.renderedPeer.chatMainPeer?.debugDisplayTitle ?? "", fallback: "聊天")
            let draftText = item.draft?.text ?? ""
            let messageText = item.messages.first?.text ?? ""
            let mediaFallback = item.messages.first?.media.isEmpty == false
                ? "最近有媒体、链接或文件，适合收藏后统一整理。"
                : "媒体、链接与文件会在这里聚合预览。"
            let subtitleSource = draftText.isEmpty ? messageText : "草稿：\(draftText)"
            let subtitle = fluxgramPreviewCleanText(subtitleSource, fallback: mediaFallback)
            let suggestion = fluxgramThemePreviewSuggestions[index % fluxgramThemePreviewSuggestions.count]
            return FluxgramThemePreviewChat(title: title, subtitle: subtitle, suggestion: suggestion, accentIndex: index)
        }
        return mapped.isEmpty ? fluxgramThemePreviewFallbackChats : mapped
    }
}

private final class FluxgramThemePreviewBackgroundView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradientLayer = self.layer as! CAGradientLayer
        gradientLayer.colors = [
            fluxgramPreviewColor(0x090A12).cgColor,
            fluxgramPreviewColor(0x171429).cgColor,
            fluxgramPreviewColor(0x0C1725).cgColor
        ]
        gradientLayer.locations = [0.0, 0.48, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FluxgramThemePreviewGlowView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    init(colors: [UIColor]) {
        super.init(frame: CGRect())
        let gradientLayer = self.layer as! CAGradientLayer
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.layer.cornerRadius = 120.0
        self.layer.masksToBounds = true
        self.alpha = 0.42
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FluxgramThemePreviewGlassCardView: UIView {
    private let blurView: UIVisualEffectView
    private let strokeView: UIView

    init(cornerRadius: CGFloat = 28.0) {
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        self.strokeView = UIView()
        super.init(frame: CGRect())

        self.layer.cornerRadius = cornerRadius
        self.layer.cornerCurve = .continuous
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.26
        self.layer.shadowRadius = 24.0
        self.layer.shadowOffset = CGSize(width: 0.0, height: 14.0)
        self.clipsToBounds = false

        self.blurView.translatesAutoresizingMaskIntoConstraints = false
        self.blurView.layer.cornerRadius = cornerRadius
        self.blurView.layer.cornerCurve = .continuous
        self.blurView.clipsToBounds = true
        self.addSubview(self.blurView)

        self.strokeView.translatesAutoresizingMaskIntoConstraints = false
        self.strokeView.layer.cornerRadius = cornerRadius
        self.strokeView.layer.cornerCurve = .continuous
        self.strokeView.layer.borderWidth = 1.0
        self.strokeView.layer.borderColor = UIColor.white.withAlphaComponent(0.13).cgColor
        self.strokeView.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        self.strokeView.isUserInteractionEnabled = false
        self.addSubview(self.strokeView)

        NSLayoutConstraint.activate([
            self.blurView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.blurView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.blurView.topAnchor.constraint(equalTo: self.topAnchor),
            self.blurView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.strokeView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.strokeView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.strokeView.topAnchor.constraint(equalTo: self.topAnchor),
            self.strokeView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private func fluxgramPreviewLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = UIFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = lines
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

private func fluxgramPreviewPill(_ text: String, color: UIColor, textColor: UIColor = .white) -> UILabel {
    let label = fluxgramPreviewLabel(text, size: 12.0, weight: .semibold, color: textColor, lines: 1)
    label.textAlignment = .center
    label.backgroundColor = color
    label.layer.cornerRadius = 13.0
    label.layer.cornerCurve = .continuous
    label.clipsToBounds = true
    label.heightAnchor.constraint(equalToConstant: 26.0).isActive = true
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
}

private func fluxgramPreviewCardStack(in card: UIView, insets: UIEdgeInsets = UIEdgeInsets(top: 18.0, left: 18.0, bottom: 18.0, right: 18.0), spacing: CGFloat = 12.0) -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
        stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -insets.right),
        stack.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
        stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -insets.bottom)
    ])
    return stack
}

private func fluxgramPreviewSectionTitle(_ title: String, subtitle: String) -> UIView {
    let container = UIView()
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4.0
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    stack.addArrangedSubview(fluxgramPreviewLabel(title, size: 19.0, weight: .bold, color: .white, lines: 1))
    stack.addArrangedSubview(fluxgramPreviewLabel(subtitle, size: 13.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.58), lines: 0))
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4.0),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4.0),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    return container
}

private func fluxgramThemePreviewHeroCard() -> UIView {
    let card = FluxgramThemePreviewGlassCardView(cornerRadius: 34.0)
    let stack = fluxgramPreviewCardStack(in: card, insets: UIEdgeInsets(top: 22.0, left: 20.0, bottom: 20.0, right: 20.0), spacing: 16.0)

    let topRow = UIStackView()
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 8.0
    topRow.addArrangedSubview(fluxgramPreviewPill("Preview Only", color: fluxgramPreviewColor(0xFFFFFF, alpha: 0.13)))
    topRow.addArrangedSubview(fluxgramPreviewPill("Arc / Radius Mood", color: fluxgramPreviewColor(0x8E7BFF, alpha: 0.24), textColor: fluxgramPreviewColor(0xDED8FF)))
    let topSpacer = UIView()
    topRow.addArrangedSubview(topSpacer)
    stack.addArrangedSubview(topRow)

    stack.addArrangedSubview(fluxgramPreviewLabel("Fluxgram 高级主题预览", size: 31.0, weight: .bold, color: .white, lines: 0))
    stack.addArrangedSubview(fluxgramPreviewLabel("只看氛围，不改真实聊天。重点预览：圆角玻璃、空间分层、聊天快速收藏、AI 分类建议。", size: 15.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.72), lines: 0))

    let navRow = UIStackView()
    navRow.axis = .horizontal
    navRow.spacing = 8.0
    navRow.distribution = .fillEqually
    ["聊天", "收藏箱", "项目", "NAS"].enumerated().forEach { index, title in
        let pill = fluxgramPreviewPill(title, color: index == 0 ? fluxgramPreviewColor(0xFFFFFF, alpha: 0.18) : fluxgramPreviewColor(0xFFFFFF, alpha: 0.075), textColor: index == 0 ? .white : UIColor.white.withAlphaComponent(0.58))
        navRow.addArrangedSubview(pill)
    }
    stack.addArrangedSubview(navRow)

    return card
}

private func fluxgramThemePreviewChatRow(_ chat: FluxgramThemePreviewChat) -> UIView {
    let card = FluxgramThemePreviewGlassCardView(cornerRadius: 24.0)
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .top
    stack.spacing = 12.0
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    let accentColor = fluxgramPreviewAccentColor(chat.accentIndex)
    let avatar = UILabel()
    avatar.text = String(chat.title.prefix(1)).uppercased()
    avatar.textAlignment = .center
    avatar.font = UIFont.systemFont(ofSize: 18.0, weight: .bold)
    avatar.textColor = .white
    avatar.backgroundColor = accentColor.withAlphaComponent(0.76)
    avatar.layer.cornerRadius = 24.0
    avatar.layer.cornerCurve = .continuous
    avatar.clipsToBounds = true
    avatar.translatesAutoresizingMaskIntoConstraints = false
    avatar.widthAnchor.constraint(equalToConstant: 48.0).isActive = true
    avatar.heightAnchor.constraint(equalToConstant: 48.0).isActive = true
    stack.addArrangedSubview(avatar)

    let textStack = UIStackView()
    textStack.axis = .vertical
    textStack.spacing = 7.0
    textStack.addArrangedSubview(fluxgramPreviewLabel(chat.title, size: 16.0, weight: .semibold, color: .white, lines: 1))
    textStack.addArrangedSubview(fluxgramPreviewLabel(chat.subtitle, size: 13.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.62), lines: 2))

    let chipRow = UIStackView()
    chipRow.axis = .horizontal
    chipRow.spacing = 7.0
    chipRow.addArrangedSubview(fluxgramPreviewPill("AI 建议：\(chat.suggestion)", color: accentColor.withAlphaComponent(0.20), textColor: accentColor))
    chipRow.addArrangedSubview(fluxgramPreviewPill("确认收藏", color: UIColor.white.withAlphaComponent(0.11)))
    let chipSpacer = UIView()
    chipRow.addArrangedSubview(chipSpacer)
    textStack.addArrangedSubview(chipRow)
    stack.addArrangedSubview(textStack)

    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14.0),
        stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14.0),
        stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14.0),
        stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14.0)
    ])

    return card
}

private func fluxgramThemePreviewInboxCard(chats: [FluxgramThemePreviewChat]) -> UIView {
    let container = UIStackView()
    container.axis = .vertical
    container.spacing = 10.0
    for chat in chats.prefix(4) {
        container.addArrangedSubview(fluxgramThemePreviewChatRow(chat))
    }
    return container
}

private func fluxgramThemePreviewSaveCard(chats: [FluxgramThemePreviewChat]) -> UIView {
    let card = FluxgramThemePreviewGlassCardView(cornerRadius: 30.0)
    let stack = fluxgramPreviewCardStack(in: card, spacing: 14.0)

    stack.addArrangedSubview(fluxgramPreviewLabel("聊天内快速收藏", size: 20.0, weight: .bold, color: .white, lines: 1))
    stack.addArrangedSubview(fluxgramPreviewLabel("选中链接、图片或文件时，底部操作区出现更清晰的收藏入口。收藏时弹出 AI 建议分类，你确认或修改即可。", size: 14.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.66), lines: 0))

    let sampleChat = chats.first ?? fluxgramThemePreviewFallbackChats[0]
    let saveBubble = UIView()
    saveBubble.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    saveBubble.layer.cornerRadius = 22.0
    saveBubble.layer.cornerCurve = .continuous
    let saveStack = UIStackView()
    saveStack.axis = .vertical
    saveStack.spacing = 10.0
    saveStack.translatesAutoresizingMaskIntoConstraints = false
    saveBubble.addSubview(saveStack)
    saveStack.addArrangedSubview(fluxgramPreviewLabel("“\(sampleChat.subtitle)”", size: 13.5, weight: .regular, color: UIColor.white.withAlphaComponent(0.72), lines: 0))

    let actionRow = UIStackView()
    actionRow.axis = .horizontal
    actionRow.spacing = 8.0
    actionRow.addArrangedSubview(fluxgramPreviewPill("收藏到 \(sampleChat.suggestion)", color: fluxgramPreviewAccentColor(sampleChat.accentIndex, alpha: 0.22), textColor: fluxgramPreviewAccentColor(sampleChat.accentIndex)))
    actionRow.addArrangedSubview(fluxgramPreviewPill("改分类", color: UIColor.white.withAlphaComponent(0.10)))
    let actionSpacer = UIView()
    actionRow.addArrangedSubview(actionSpacer)
    saveStack.addArrangedSubview(actionRow)

    NSLayoutConstraint.activate([
        saveStack.leadingAnchor.constraint(equalTo: saveBubble.leadingAnchor, constant: 14.0),
        saveStack.trailingAnchor.constraint(equalTo: saveBubble.trailingAnchor, constant: -14.0),
        saveStack.topAnchor.constraint(equalTo: saveBubble.topAnchor, constant: 14.0),
        saveStack.bottomAnchor.constraint(equalTo: saveBubble.bottomAnchor, constant: -14.0)
    ])
    stack.addArrangedSubview(saveBubble)

    return card
}

private func fluxgramThemePreviewFoldersCard() -> UIView {
    let card = FluxgramThemePreviewGlassCardView(cornerRadius: 30.0)
    let stack = fluxgramPreviewCardStack(in: card, spacing: 14.0)

    stack.addArrangedSubview(fluxgramPreviewLabel("底部入口：收藏箱管理", size: 20.0, weight: .bold, color: .white, lines: 1))
    stack.addArrangedSubview(fluxgramPreviewLabel("收藏内容按项目 / 主题 / 文件夹整理。AI 优先推荐已有文件夹，必要时建议新建。", size: 14.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.66), lines: 0))

    let folderRows: [[(String, String, UInt32)]] = [
        [("工作资料", "18 条", 0x8E7BFF), ("稍后看", "11 条", 0x34D6FF)],
        [("视频素材", "7 条", 0xFF8A5B), ("建议新建", "AI 产品化", 0x7CFFB2)]
    ]

    for row in folderRows {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 10.0
        rowStack.distribution = .fillEqually
        for item in row {
            let folder = UIView()
            folder.backgroundColor = fluxgramPreviewColor(item.2, alpha: 0.14)
            folder.layer.cornerRadius = 20.0
            folder.layer.cornerCurve = .continuous
            folder.layer.borderColor = fluxgramPreviewColor(item.2, alpha: 0.24).cgColor
            folder.layer.borderWidth = 1.0

            let folderStack = UIStackView()
            folderStack.axis = .vertical
            folderStack.spacing = 5.0
            folderStack.translatesAutoresizingMaskIntoConstraints = false
            folder.addSubview(folderStack)
            folderStack.addArrangedSubview(fluxgramPreviewLabel(item.0, size: 15.0, weight: .semibold, color: .white, lines: 1))
            folderStack.addArrangedSubview(fluxgramPreviewLabel(item.1, size: 12.0, weight: .regular, color: UIColor.white.withAlphaComponent(0.58), lines: 1))
            NSLayoutConstraint.activate([
                folderStack.leadingAnchor.constraint(equalTo: folder.leadingAnchor, constant: 12.0),
                folderStack.trailingAnchor.constraint(equalTo: folder.trailingAnchor, constant: -12.0),
                folderStack.topAnchor.constraint(equalTo: folder.topAnchor, constant: 12.0),
                folderStack.bottomAnchor.constraint(equalTo: folder.bottomAnchor, constant: -12.0)
            ])
            rowStack.addArrangedSubview(folder)
        }
        stack.addArrangedSubview(rowStack)
    }

    return card
}

private func fluxgramThemePreviewPrivacyCard() -> UIView {
    let card = FluxgramThemePreviewGlassCardView(cornerRadius: 26.0)
    let stack = fluxgramPreviewCardStack(in: card, spacing: 10.0)
    stack.addArrangedSubview(fluxgramPreviewLabel("隐私边界", size: 17.0, weight: .bold, color: .white, lines: 1))
    stack.addArrangedSubview(fluxgramPreviewLabel("预览页仅读取本机聊天标题 / 摘要作为展示素材；后续 AI 分类也只处理标题、摘要、来源和轻文本，不上传原文件。", size: 13.5, weight: .regular, color: UIColor.white.withAlphaComponent(0.64), lines: 0))
    return card
}

private final class FluxgramThemePreviewControllerNode: ASDisplayNode {
    private var presentationData: PresentationData
    private var chats: [FluxgramThemePreviewChat]
    private weak var scrollView: UIScrollView?
    private var validLayout: (ContainerViewLayout, CGFloat)?

    init(presentationData: PresentationData, chats: [FluxgramThemePreviewChat]) {
        self.presentationData = presentationData
        self.chats = chats

        super.init()

        self.setViewBlock({
            return UIView()
        })
        self.backgroundColor = .clear
    }

    override func didLoad() {
        super.didLoad()
        self.rebuild()
    }

    func update(presentationData: PresentationData, chats: [FluxgramThemePreviewChat]) {
        self.presentationData = presentationData
        self.chats = chats
        if self.isNodeLoaded {
            self.rebuild()
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        transition.updateFrame(node: self, frame: CGRect(origin: CGPoint(), size: layout.size))
        if let scrollView = self.scrollView {
            let topInset = navigationBarHeight + 12.0
            let bottomInset = layout.intrinsicInsets.bottom + 28.0
            scrollView.contentInset = UIEdgeInsets(top: topInset, left: 0.0, bottom: bottomInset, right: 0.0)
            scrollView.scrollIndicatorInsets = scrollView.contentInset
        }
    }

    private func rebuild() {
        let rootView = self.view
        rootView.subviews.forEach { $0.removeFromSuperview() }

        let backgroundView = FluxgramThemePreviewBackgroundView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(backgroundView)

        let purpleGlow = FluxgramThemePreviewGlowView(colors: [
            fluxgramPreviewColor(0x8E7BFF, alpha: 0.80),
            fluxgramPreviewColor(0xFF6FD8, alpha: 0.16)
        ])
        purpleGlow.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(purpleGlow)

        let blueGlow = FluxgramThemePreviewGlowView(colors: [
            fluxgramPreviewColor(0x34D6FF, alpha: 0.54),
            fluxgramPreviewColor(0x7CFFB2, alpha: 0.14)
        ])
        blueGlow.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(blueGlow)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(scrollView)
        self.scrollView = scrollView

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 18.0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        contentStack.addArrangedSubview(fluxgramThemePreviewHeroCard())
        contentStack.addArrangedSubview(fluxgramPreviewSectionTitle("真实聊天 + 模拟收藏", subtitle: "标题和摘要来自本机聊天列表；收藏夹、分类和确认按钮都是静态预览。"))
        contentStack.addArrangedSubview(fluxgramThemePreviewInboxCard(chats: self.chats))
        contentStack.addArrangedSubview(fluxgramThemePreviewSaveCard(chats: self.chats))
        contentStack.addArrangedSubview(fluxgramThemePreviewFoldersCard())
        contentStack.addArrangedSubview(fluxgramThemePreviewPrivacyCard())

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            purpleGlow.widthAnchor.constraint(equalToConstant: 260.0),
            purpleGlow.heightAnchor.constraint(equalToConstant: 260.0),
            purpleGlow.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: -92.0),
            purpleGlow.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 56.0),

            blueGlow.widthAnchor.constraint(equalToConstant: 240.0),
            blueGlow.heightAnchor.constraint(equalToConstant: 240.0),
            blueGlow.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: 104.0),
            blueGlow.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 270.0),

            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16.0),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16.0),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32.0)
        ])
    }
}

private final class FluxgramThemePreviewController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private var chats: [FluxgramThemePreviewChat] = fluxgramThemePreviewFallbackChats
    private var disposable: Disposable?

    private var controllerNode: FluxgramThemePreviewControllerNode {
        return self.displayNode as! FluxgramThemePreviewControllerNode
    }

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))

        self._hasGlassStyle = true
        self.title = "主题预览"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)

        self.disposable = (combineLatest(context.sharedContext.presentationData, fluxgramThemePreviewChats(context: context))
        |> deliverOnMainQueue).start(next: { [weak self] presentationData, chats in
            guard let strongSelf = self else {
                return
            }
            strongSelf.presentationData = presentationData
            strongSelf.chats = chats
            strongSelf.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
            strongSelf.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData, style: .glass), transition: .immediate)
            strongSelf.navigationItem.backBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
            if strongSelf.isNodeLoaded {
                strongSelf.controllerNode.update(presentationData: presentationData, chats: chats)
            }
        })
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = FluxgramThemePreviewControllerNode(presentationData: self.presentationData, chats: self.chats)
        self.displayNodeDidLoad()
        self.navigationBar?.updateBackgroundAlpha(0.0, transition: .immediate)
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

func fluxgramThemePreviewController(context: AccountContext) -> ViewController {
    return FluxgramThemePreviewController(context: context)
}
