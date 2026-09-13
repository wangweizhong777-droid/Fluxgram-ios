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
        self.cardView.backgroundColor = .white
        self.cardView.layer.cornerRadius = 20.0
        self.cardView.layer.masksToBounds = true
        self.thumbnailView.clipsToBounds = true
        self.thumbnailView.layer.cornerRadius = 10.0
        self.titleLabel.font = UIFont.systemFont(ofSize: 16.5, weight: .semibold)
        self.titleLabel.textColor = .black
        self.titleLabel.numberOfLines = 1
        self.metaLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.metaLabel.textColor = .secondaryLabel
        self.statusLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.statusLabel.numberOfLines = 1
        self.statusIcon.contentMode = .scaleAspectFit
        self.percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14.0, weight: .medium)
        self.percentLabel.textColor = .label
        self.progressView.progressTintColor = .systemBlue
        self.progressView.trackTintColor = UIColor.systemGray5
        self.actionButton.tintColor = .secondaryLabel
        self.moreButton.tintColor = .secondaryLabel
        self.actionButton.backgroundColor = UIColor.systemGray6
        self.actionButton.layer.cornerRadius = 20.0
        self.moreButton.backgroundColor = .clear
        self.moreButton.alpha = 0.72
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
        let insets = UIEdgeInsets(top: 3.0, left: 0.0, bottom: 3.0, right: 0.0)
        let status = item.job.status.lowercased()
        let compact = ["done", "completed", "complete", "finished", "success"].contains(status)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: compact ? 92.0 : 104.0), insets: insets)
    }

    func apply(item: FluxgramDownloadCardItem, params: ListViewItemLayoutParams) {
        self.primaryAction = item.primaryAction
        self.moreAction = item.moreAction
        let width = params.width
        let status = item.job.status.lowercased()
        let completed = ["done", "completed", "complete", "finished", "success"].contains(status)
        let cardHeight: CGFloat = completed ? 86.0 : 98.0
        let thumbnailSize: CGFloat = completed ? 70.0 : 82.0
        let cardFrame = CGRect(x: params.leftInset + 20.0, y: 3.0, width: width - params.leftInset - params.rightInset - 40.0, height: cardHeight)
        cardView.frame = cardFrame
        thumbnailView.frame = CGRect(x: 8.0, y: 8.0, width: thumbnailSize, height: thumbnailSize)
        let contentX: CGFloat = completed ? 88.0 : 100.0
        let trailing: CGFloat = 62.0
        titleLabel.frame = CGRect(x: contentX, y: 7.0, width: cardFrame.width - contentX - trailing, height: 22.0)
        metaLabel.frame = CGRect(x: completed ? contentX + 22.0 : contentX, y: 31.0, width: cardFrame.width - contentX - trailing - (completed ? 22.0 : 0.0), height: 17.0)
        progressView.frame = CGRect(x: contentX, y: 55.0, width: max(50.0, cardFrame.width - contentX - trailing - 34.0), height: 4.0)
        percentLabel.frame = CGRect(x: cardFrame.width - trailing - 30.0, y: 47.0, width: 30.0, height: 20.0)
        statusIcon.frame = CGRect(x: contentX, y: completed ? 31.0 : 70.0, width: 18.0, height: 18.0)
        statusLabel.frame = CGRect(x: contentX + 24.0, y: 68.0, width: cardFrame.width - contentX - trailing - 24.0, height: 20.0)
        actionButton.frame = CGRect(x: cardFrame.width - 52.0, y: 16.0, width: 40.0, height: 40.0)
        moreButton.frame = CGRect(x: cardFrame.width - 38.0, y: completed ? 53.0 : 63.0, width: 28.0, height: 28.0)

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
            statusIcon.image = UIImage(systemName: "checkmark.circle.fill")
            statusIcon.tintColor = .systemGreen
            statusLabel.isHidden = true
            actionButton.setImage(UIImage(systemName: "folder"), for: .normal)
        } else if failed {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "exclamationmark.circle.fill")
            statusIcon.tintColor = .systemRed
            statusLabel.text = "下载失败 · 点击重试"
            statusLabel.textColor = .systemRed
            actionButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        } else if paused {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "pause.circle.fill")
            statusIcon.tintColor = .secondaryLabel
            statusLabel.text = "已暂停"
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else if waiting {
            statusLabel.isHidden = false
            statusIcon.image = UIImage(systemName: "clock")
            statusIcon.tintColor = .secondaryLabel
            statusLabel.text = "等待中…"
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            statusLabel.isHidden = false
            statusIcon.isHidden = true
            statusLabel.frame = CGRect(x: contentX, y: 68.0, width: cardFrame.width - contentX - trailing, height: 20.0)
            var text = "\(fluxgramDownloadByteCount(received)) / \(fluxgramDownloadByteCount(total))"
            if let speed = fluxgramDownloadSpeedText(item.speed) { text += " · \(speed)" }
            statusLabel.text = text
            statusLabel.textColor = .secondaryLabel
            actionButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    }
}
