import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import TinyThumbnail

/// A presentation-only download card. All actions are forwarded to the
/// existing download controller; this item never mutates DownloadManager or
/// the NAS queue.
final class FluxgramDownloadCardItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let job: FluxgramNASDownloadJob
    let thumbnailData: Data?
    let speed: Int64?
    let sectionId: ItemListSectionId
    let cardAction: () -> Void
    let primaryAction: () -> Void
    let moreAction: () -> Void

    init(presentationData: ItemListPresentationData, job: FluxgramNASDownloadJob, thumbnailData: Data?, speed: Int64?, sectionId: ItemListSectionId, cardAction: @escaping () -> Void, primaryAction: @escaping () -> Void, moreAction: @escaping () -> Void) {
        self.presentationData = presentationData
        self.job = job
        self.thumbnailData = thumbnailData
        self.speed = speed
        self.sectionId = sectionId
        self.cardAction = cardAction
        self.primaryAction = primaryAction
        self.moreAction = moreAction
    }

    var selectable: Bool = true

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = FluxgramDownloadCardItemNode()
            let layout = node.layout(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in node.apply(item: self, params: params) }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        // ListView supplies the existing node through a main-queue-only
        // accessor. Resolve it on main before doing any background work.
        Queue.mainQueue().async {
            guard let node = node() as? FluxgramDownloadCardItemNode else { return }
            let layout = node.layout(item: self, params: params)
            completion(layout, { _ in node.apply(item: self, params: params) })
        }
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        cardAction()
    }
}

private final class FluxgramDownloadCardItemNode: ListViewItemNode {
    private let cardView = UIView()
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let statusIcon = UIImageView()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private var primaryAction: (() -> Void)?
    private var moreAction: (() -> Void)?

    init() {
        super.init(layerBacked: false)
        self.backgroundColor = .clear
        self.cardView.backgroundColor = FluxgramDownloadDesign.Surface.card
        self.cardView.layer.cornerRadius = FluxgramDownloadDesign.Size.cardRadius
        self.cardView.layer.masksToBounds = true
        self.thumbnailView.clipsToBounds = true
        self.thumbnailView.layer.cornerRadius = 10.0
        self.titleLabel.font = FluxgramDownloadDesign.Font.fileName
        self.titleLabel.textColor = .label
        self.titleLabel.numberOfLines = 1
        self.metaLabel.font = FluxgramDownloadDesign.Font.metadata
        self.metaLabel.textColor = .secondaryLabel
        self.statusLabel.font = FluxgramDownloadDesign.Font.metadata
        self.statusLabel.textColor = .secondaryLabel
        self.statusLabel.numberOfLines = 1
        self.statusIcon.contentMode = .scaleAspectFit
        self.percentLabel.font = FluxgramDownloadDesign.Font.progress
        self.percentLabel.textColor = .label
        self.percentLabel.adjustsFontSizeToFitWidth = true
        self.percentLabel.minimumScaleFactor = 0.8
        self.percentLabel.textAlignment = .right
        self.progressView.progressTintColor = .systemBlue
        self.progressView.trackTintColor = UIColor.systemGray5
        self.actionButton.tintColor = .secondaryLabel
        self.moreButton.tintColor = .secondaryLabel
        self.actionButton.backgroundColor = FluxgramDownloadDesign.Surface.subtleAction
        self.actionButton.layer.cornerRadius = FluxgramDownloadDesign.Size.cardAction / 2.0
        self.moreButton.backgroundColor = .clear
        self.moreButton.alpha = 0.62
        self.actionButton.addTarget(self, action: #selector(activate), for: .touchUpInside)
        self.moreButton.addTarget(self, action: #selector(activateMore), for: .touchUpInside)
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(cardView)
        cardView.addSubview(thumbnailView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(metaLabel)
        cardView.addSubview(statusIcon)
        cardView.addSubview(statusLabel)
        cardView.addSubview(progressView)
        cardView.addSubview(percentLabel)
        cardView.addSubview(actionButton)
        cardView.addSubview(moreButton)
    }

    @objc private func activate() { primaryAction?() }
    @objc private func activateMore() { moreAction?() }

    func layout(item: FluxgramDownloadCardItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let insets = UIEdgeInsets.zero
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 106.0), insets: insets)
    }

    func apply(item: FluxgramDownloadCardItem, params: ListViewItemLayoutParams) {
        self.primaryAction = item.primaryAction
        self.moreAction = item.moreAction
        let width = params.width
        let status = item.job.status.lowercased()
        let completed = ["done", "completed", "complete", "finished", "success"].contains(status)
        let cardHeight: CGFloat = 98.0
        let thumbnailSize: CGFloat = 82.0
        let leftMargin = max(FluxgramDownloadDesign.Spacing.pageMargin, params.leftInset)
        let rightMargin = max(FluxgramDownloadDesign.Spacing.pageMargin, params.rightInset)
        let cardFrame = CGRect(x: leftMargin, y: FluxgramDownloadDesign.Spacing.xSmall, width: width - leftMargin - rightMargin, height: cardHeight)
        cardView.frame = cardFrame
        thumbnailView.frame = CGRect(x: 8.0, y: 8.0, width: thumbnailSize, height: thumbnailSize)
        let contentX: CGFloat = 100.0
        let trailing: CGFloat = 62.0
        titleLabel.frame = CGRect(x: contentX, y: 7.0, width: cardFrame.width - contentX - trailing, height: 22.0)
        metaLabel.frame = CGRect(x: completed ? contentX + 22.0 : contentX, y: 31.0, width: cardFrame.width - contentX - trailing - (completed ? 22.0 : 0.0), height: 17.0)
        progressView.frame = CGRect(x: contentX, y: 55.0, width: max(50.0, cardFrame.width - contentX - trailing - 44.0), height: 4.0)
        let percentWidth: CGFloat = 40.0
        percentLabel.frame = CGRect(x: cardFrame.width - trailing - percentWidth, y: 47.0, width: percentWidth, height: 20.0)
        let statusIconSize = FluxgramDownloadDesign.Size.statusIcon
        statusIcon.frame = CGRect(x: contentX, y: completed ? 31.5 : 71.0, width: statusIconSize, height: statusIconSize)
        statusLabel.frame = CGRect(x: contentX + 24.0, y: 68.0, width: cardFrame.width - contentX - trailing - 24.0, height: 20.0)
        let actionSize = FluxgramDownloadDesign.Size.cardAction
        actionButton.frame = CGRect(x: cardFrame.width - actionSize - FluxgramDownloadDesign.Spacing.medium, y: FluxgramDownloadDesign.Spacing.large, width: actionSize, height: actionSize)
        let moreHitArea = FluxgramDownloadDesign.Size.moreHitArea
        moreButton.frame = CGRect(x: cardFrame.width - moreHitArea - FluxgramDownloadDesign.Spacing.small, y: 62.0, width: moreHitArea, height: moreHitArea)

        let failed = ["failed", "error", "cancelled", "canceled"].contains(status)
        let paused = ["paused", "suspended"].contains(status)
        let received = max(0, item.job.received)
        let total = max(0, item.job.total)
        let downloading = ["downloading", "running", "copying", "progressing"].contains(status)
        let waiting = ["queued", "queue", "pending", "waiting", "submitted", "retrying"].contains(status) || (!completed && !failed && !paused && !downloading && received == 0)
        let fraction = total > 0 ? min(1.0, max(0.0, Float(received) / Float(total))) : 0.0
        // A freshly fetched thumbnail in the controller state takes
        // precedence over the thumbnail persisted on the NAS job. This lets
        // older cards upgrade from a low-resolution preview without changing
        // the download task itself.
        if let thumbnail = fluxgramDownloadThumbnail(item.thumbnailData ?? item.job.thumbnailData) {
            thumbnailView.image = thumbnail
            thumbnailView.contentMode = .scaleAspectFill
            thumbnailView.backgroundColor = UIColor.systemGray6
        } else {
            let configuration = UIImage.SymbolConfiguration(pointSize: 27.0, weight: .regular)
            thumbnailView.image = UIImage(systemName: "video.fill", withConfiguration: configuration)?.withTintColor(.systemGray2, renderingMode: .alwaysOriginal)
            thumbnailView.contentMode = .center
            thumbnailView.backgroundColor = UIColor.systemGray6
        }
        titleLabel.text = item.job.title
        let ext = (item.job.fileName as NSString).pathExtension.uppercased()
        var meta = ext.isEmpty ? "媒体" : ext
        if total > 0 { meta += " · \(fluxgramDownloadByteCount(total))" }
        metaLabel.text = completed ? meta + " · 已完成" : meta
        progressView.progress = fraction
        progressView.isHidden = completed || waiting || failed
        percentLabel.isHidden = progressView.isHidden
        percentLabel.text = "\(Int(fraction * 100.0))%"
        statusLabel.isHidden = false
        statusIcon.isHidden = false
        if completed {
            statusIcon.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: FluxgramDownloadDesign.statusSymbol)
            statusIcon.tintColor = .systemGreen
            statusLabel.isHidden = true
            actionButton.setImage(UIImage(systemName: "folder", withConfiguration: FluxgramDownloadDesign.regularSymbol), for: .normal)
        } else if failed {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: FluxgramDownloadDesign.statusSymbol)
            statusIcon.tintColor = .systemRed
            statusLabel.text = "下载失败 · 点击重试"
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: FluxgramDownloadDesign.regularSymbol), for: .normal)
        } else if paused {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "pause.circle.fill", withConfiguration: FluxgramDownloadDesign.statusSymbol)
            statusIcon.tintColor = .secondaryLabel
            statusLabel.text = "已暂停"
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "arrowtriangle.right.fill", withConfiguration: FluxgramDownloadDesign.regularSymbol), for: .normal)
        } else if waiting {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "clock", withConfiguration: FluxgramDownloadDesign.statusSymbol)
            statusIcon.tintColor = .secondaryLabel
            statusLabel.text = "等待中…"
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "arrowtriangle.right.circle", withConfiguration: FluxgramDownloadDesign.regularSymbol), for: .normal)
        } else {
            statusLabel.isHidden = false
            statusIcon.isHidden = true
            statusLabel.frame = CGRect(x: contentX, y: 68.0, width: cardFrame.width - contentX - trailing, height: 20.0)
            var text = "\(fluxgramDownloadByteCount(received)) / \(fluxgramDownloadByteCount(total))"
            if let speed = fluxgramDownloadSpeedText(item.speed) { text += " · \(speed)" }
            statusLabel.text = text
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: FluxgramDownloadDesign.regularSymbol), for: .normal)
        }
        moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: FluxgramDownloadDesign.subtleSymbol), for: .normal)
    }
}
