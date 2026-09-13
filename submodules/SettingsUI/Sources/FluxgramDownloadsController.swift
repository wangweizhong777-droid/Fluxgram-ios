import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore
import UndoUI
import TinyThumbnail

// Auxiliary rows use the standard opaque list treatment. The custom header
// and task cards establish their own three-level light surface hierarchy.
private let fluxgramItemListSystemStyle: ItemListSystemStyle = .legacy

private struct FluxgramDownloadsControllerState: Equatable {
    var active: [FluxgramNASDownloadJob]
    var history: [FluxgramNASDownloadJob]
    var pending: [FluxgramNASSubmission]
    var error: String
    var speeds: [String: Int64]
    var thumbnails: [String: Data]
    var historyLimit: Int
    var filter: FluxgramDownloadsFilter
    var searchQuery: String
}

private enum FluxgramDownloadsFilter: String, Equatable {
    case all = "全部"
    case active = "下载中"
    case waiting = "已暂停"
    case completed = "已完成"
    case failed = "失败"
}

private enum FluxgramAllDownloadsItem {
    case job(FluxgramNASDownloadJob, Bool, Int)
    case pending(FluxgramNASSubmission, Int)

    var createdAt: TimeInterval? {
        switch self {
        case let .job(job, _, _):
            guard let value = job.createdAt, value > 0 else { return nil }
            return value
        case let .pending(submission, _):
            return submission.createdAt > 0 ? submission.createdAt : nil
        }
    }

    var sourceIndex: Int {
        switch self {
        case let .job(_, _, index), let .pending(_, index):
            return index
        }
    }
}

private func fluxgramAllDownloadsJobIdentity(_ job: FluxgramNASDownloadJob) -> String {
    if !job.id.isEmpty {
        return "id:" + job.id
    }
    return "fallback:\(job.fileName)|\(job.downloadSubdir)|\(job.sourceUrl)|\(job.outputFile)"
}

private enum FluxgramDownloadsSection: Int32 {
    case active
    case pending
    case history
    case status
}

private func fluxgramStableHash(_ identifier: String, namespace: Int32) -> Int32 {
    var hash: UInt32 = 2_166_136_261
    for byte in identifier.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return namespace + Int32(hash % 500_000_000)
}

private func fluxgramDownloadStableId(_ job: FluxgramNASDownloadJob, namespace: Int32, index: Int) -> Int32 {
    // NAS task IDs are stable. Empty IDs need the index as a final disambiguator.
    let identifier: String
    if job.id.isEmpty {
        identifier = "\(job.fileName)|\(job.downloadSubdir)|\(job.sourceLabel)|\(job.outputFile)|\(index)"
    } else {
        identifier = job.id
    }
    return fluxgramStableHash(identifier, namespace: namespace)
}

private func fluxgramPrivateChannelMessage(for job: FluxgramNASDownloadJob) -> (channelId: Int64, messageId: Int32)? {
    if let components = URLComponents(string: job.sourceUrl),
       let host = components.host?.lowercased(),
       host == "t.me" || host == "www.t.me" {
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        if path.count >= 3,
           path[0].lowercased() == "c",
           let channelId = Int64(String(path[1])),
           let messageId = Int32(String(path[2])),
           channelId > 0,
           messageId > 0 {
            return (channelId, messageId)
        }
    }

    // Downloads created before TGAPP persisted peerType and peerAccessHash
    // only retain a positive dialog id. For the known legacy entity failure,
    // it represents the numeric component of a t.me/c private channel link.
    let error = job.error.lowercased()
    guard error.contains("could not find the input entity"),
          let storedDialogId = job.sourceDialogId,
          let messageId = job.sourceRootMessageId ?? job.sourceMessageId,
          messageId > 0 else {
        return nil
    }
    // NAS normally stores the t.me/c component directly. Accept the full
    // Telegram -100... peer id as well for older records.
    let channelId: Int64
    if storedDialogId < -1_000_000_000_000 {
        channelId = -storedDialogId - 1_000_000_000_000
    } else if storedDialogId > 0 {
        channelId = storedDialogId
    } else {
        return nil
    }
    return channelId > 0 ? (channelId, messageId) : nil
}

private struct FluxgramOriginalMessageTarget {
    let peerId: PeerId
    let messageId: MessageId
    let isForwarded: Bool
}

/// Resolves the chat/message to open for an old NAS record.
///
/// Older records only contain the chat in which the media was received. That
/// chat can be a private user (for example, a forwarding bot) while Telegram's
/// actual source channel is stored in the forwarded message metadata. Read the
/// received copy first, then prefer its `forwardInfo.sourceMessageId` when it
/// is available. The download itself still uses the received copy elsewhere;
/// this helper is only for navigation.
private func fluxgramOriginalMessageTarget(context: AccountContext, job: FluxgramNASDownloadJob) -> Signal<FluxgramOriginalMessageTarget?, NoError> {
    guard let dialogId = job.sourceDialogId,
          let fallbackMessageId = job.sourceRootMessageId ?? job.sourceMessageId else {
        return .single(nil)
    }

    let currentPeerId = PeerId(dialogId)
    let currentMessageIds: [MessageId] = {
        var ids: [MessageId] = []
        if let rootMessageId = job.sourceRootMessageId {
            ids.append(MessageId(peerId: currentPeerId, namespace: Namespaces.Message.Cloud, id: rootMessageId))
        }
        if let messageId = job.sourceMessageId,
           !ids.contains(where: { $0.id == messageId }) {
            ids.append(MessageId(peerId: currentPeerId, namespace: Namespaces.Message.Cloud, id: messageId))
        }
        return ids
    }()

    guard !currentMessageIds.isEmpty else {
        return .single(FluxgramOriginalMessageTarget(
            peerId: currentPeerId,
            messageId: MessageId(peerId: currentPeerId, namespace: Namespaces.Message.Cloud, id: fallbackMessageId),
            isForwarded: false
        ))
    }

    let messages = context.engine.messages.getMessagesLoadIfNecessary(currentMessageIds, strategy: .cloud(skipLocal: false))
    |> mapToSignal { result -> Signal<EngineMessage?, GetMessagesError> in
        switch result {
        case .progress:
            // The loader emits progress before the final result. Keep the
            // inner signal alive until that result arrives.
            return .never()
        case let .result(messages):
            // An album can have more than one stored message. Prefer a copy
            // that actually carries forwarding metadata, otherwise use the
            // root message as the normal fallback.
            let message = messages.first(where: { $0.forwardInfo?.sourceMessageId != nil }) ?? messages.first
            return .single(message.flatMap(EngineMessage.init))
        }
    }
    |> `catch` { _ -> Signal<EngineMessage?, NoError> in
        return .single(nil)
    }

    return messages
    |> mapToSignal { message -> Signal<FluxgramOriginalMessageTarget?, NoError> in
        guard let message,
              let sourceMessageId = message.forwardInfo?.sourceMessageId else {
            return .single(FluxgramOriginalMessageTarget(
                peerId: currentPeerId,
                messageId: MessageId(peerId: currentPeerId, namespace: Namespaces.Message.Cloud, id: fallbackMessageId),
                isForwarded: false
            ))
        }

        let sourcePeerId = sourceMessageId.peerId
        let sourcePeer = message.forwardInfo?.source ?? message.peers[sourcePeerId]
        if let sourcePeer, sourcePeer.id == sourcePeerId {
            // The forwarded message normally carries the complete channel
            // entity, including its access hash. Persist it before navigating
            // so the chat controller can construct a valid input peer.
            return context.account.postbox.transaction { transaction -> FluxgramOriginalMessageTarget? in
                transaction.updatePeersInternal([sourcePeer], update: { _, updatedPeer in
                    return updatedPeer
                })
                return FluxgramOriginalMessageTarget(peerId: sourcePeerId, messageId: sourceMessageId, isForwarded: true)
            }
        }

        // Privacy-protected forwards may omit the peer object. Reuse an entity
        // already cached locally when possible; the message id still points to
        // the original peer and is safe to use for navigation.
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: sourcePeerId))
        |> take(1)
        |> map { cachedPeer in
            if let cachedPeer {
                return FluxgramOriginalMessageTarget(peerId: sourcePeerId, messageId: sourceMessageId, isForwarded: true)
            }
            return nil
        }
    }
}

private func fluxgramDownloadNotificationKey(_ job: FluxgramNASDownloadJob) -> String {
    if !job.id.isEmpty {
        return job.id
    }
    if !job.outputFile.isEmpty {
        return job.outputFile
    }
    return "\(job.fileName)|\(job.sourceLabel)|\(job.downloadSubdir)"
}

private func fluxgramDownloadThumbnailKey(_ job: FluxgramNASDownloadJob) -> String {
    if !job.id.isEmpty {
        return job.id
    }
    return "\(job.fileName)|\(job.sourceUrl)|\(job.sourceMessageId ?? 0)"
}

/// Loads only Telegram's immediate preview for an older NAS task. New tasks
/// receive this data when they are submitted, while this path lets existing
/// records benefit without changing or restarting their downloads.
private func fluxgramLocalDownloadThumbnail(context: AccountContext, job: FluxgramNASDownloadJob) -> Signal<Data?, NoError> {
    var messageIds: [MessageId] = []
    if let dialogId = job.sourceDialogId {
        var peerIds: [PeerId] = [PeerId(dialogId)]
        let backendPeerId: Int64?
        if dialogId < -1_000_000_000_000 {
            backendPeerId = -dialogId - 1_000_000_000_000
        } else if dialogId > 0 {
            backendPeerId = dialogId
        } else {
            backendPeerId = -dialogId
        }
        if let backendPeerId, backendPeerId > 0 {
            peerIds.append(PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(backendPeerId)))
            peerIds.append(PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(backendPeerId)))
        }
        var seenPeerIds = Set<PeerId>()
        for peerId in peerIds where seenPeerIds.insert(peerId).inserted {
            if let rootMessageId = job.sourceRootMessageId {
                messageIds.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: rootMessageId))
            }
            if let messageId = job.sourceMessageId,
               !messageIds.contains(where: { $0.peerId == peerId && $0.id == messageId }) {
                messageIds.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId))
            }
        }
    } else if let source = fluxgramPrivateChannelMessage(for: job) {
        let peerId = EnginePeer.Id(
            namespace: Namespaces.Peer.CloudChannel,
            id: EnginePeer.Id.Id._internalFromInt64Value(source.channelId)
        )
        messageIds.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: source.messageId))
    }
    guard !messageIds.isEmpty else {
        return .single(nil)
    }

    return context.engine.messages.getMessagesLoadIfNecessary(messageIds, strategy: .cloud(skipLocal: false))
    |> mapToSignal { result -> Signal<Data?, GetMessagesError> in
        switch result {
        case .progress:
            return .never()
        case let .result(messages):
            for message in messages {
                // Prefer the largest cached/available Telegram preview. The
                // helper falls back to the bounded immediate thumbnail and
                // never reads the original media file.
                return fluxgramMessageThumbnailData(context: context, message: EngineMessage(message))
                    |> castError(GetMessagesError.self)
            }
            return .single(nil)
        }
    }
    |> `catch` { _ -> Signal<Data?, NoError> in
        return .single(nil)
    }
}

private func fluxgramDownloadNotificationText(previous: FluxgramNASDownloadsSnapshot, current: FluxgramNASDownloadsSnapshot) -> (text: String, destructive: Bool)? {
    let previousJobs = previous.active + previous.history
    let currentJobs = current.active + current.history
    var oldStatus: [String: String] = [:]
    for job in previousJobs {
        oldStatus[fluxgramDownloadNotificationKey(job)] = job.status.lowercased()
    }
    var completed = 0
    var failed = 0
    for job in currentJobs {
        let status = job.status.lowercased()
        let prior = oldStatus[fluxgramDownloadNotificationKey(job)]
        guard prior != status else {
            continue
        }
        if ["completed", "complete", "finished", "success"].contains(status) {
            completed += 1
        } else if ["failed", "error"].contains(status) {
            failed += 1
        }
    }
    if failed > 0 {
        return (failed == 1 ? "1 个 NAS 下载失败，可在记录中重试。" : "\(failed) 个 NAS 下载失败，可在记录中重试。", true)
    }
    if completed > 0 {
        return (completed == 1 ? "1 个媒体已下载到 NAS。" : "\(completed) 个媒体已下载到 NAS。", false)
    }
    return nil
}

private enum FluxgramDownloadsEntry: ItemListNodeEntry {
    case pendingHeader
    case pendingSummary(Int)
    case pending(Int, FluxgramNASSubmission)
    case activeHeader(String, [String], Int, String)
    case activeSummary(String)
    case clearUnfinished
    case active(Int, FluxgramNASDownloadJob, Int64?, Data?)
    case allJob(Int, FluxgramNASDownloadJob, Bool, Int64?, Data?)
    case allPending(Int, FluxgramNASSubmission)
    case historyHeader
    case historySummary(String)
    case retryFailed(Int)
    case history(Int, FluxgramNASDownloadJob, Int64?, Data?)
    case historyLoadMore
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .pendingHeader, .pendingSummary, .pending:
            return FluxgramDownloadsSection.pending.rawValue
        case .activeHeader, .activeSummary, .clearUnfinished, .active, .allJob, .allPending:
            return FluxgramDownloadsSection.active.rawValue
        case .historyHeader, .historySummary, .retryFailed, .history, .historyLoadMore:
            return FluxgramDownloadsSection.history.rawValue
        case .status:
            return FluxgramDownloadsSection.status.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .pendingHeader:
            return 0
        case .pendingSummary:
            return 1
        case let .pending(index, submission):
            // Keep the row identity tied to the request, not its position. This
            // prevents incremental refreshes from rebuilding every pending card
            // when an earlier request succeeds.
            let identifier = submission.stableKey.isEmpty ? "pending-\(index)" : submission.stableKey
            return fluxgramStableHash(identifier, namespace: 1_200_000_000)
        case .activeHeader:
            return 2
        case .activeSummary:
            return 3
        case .clearUnfinished:
            return 4
        case let .active(index, job, _, _):
            return fluxgramDownloadStableId(job, namespace: 100_000, index: index)
        case let .allJob(index, job, _, _, _):
            return fluxgramDownloadStableId(job, namespace: 300_000_000, index: index)
        case let .allPending(index, submission):
            let identifier = submission.stableKey.isEmpty ? "all-pending-\(index)" : submission.stableKey
            return fluxgramStableHash(identifier, namespace: 1_300_000_000)
        case .historyHeader:
            return 10_000
        case .historySummary:
            return 10_001
        case .retryFailed:
            return 10_002
        case let .history(index, job, _, _):
            return fluxgramDownloadStableId(job, namespace: 600_000_000, index: index)
        case .historyLoadMore:
            return 10_003
        case .status:
            return 20_000
        }
    }

    static func <(lhs: FluxgramDownloadsEntry, rhs: FluxgramDownloadsEntry) -> Bool {
        func order(_ entry: FluxgramDownloadsEntry) -> (Int32, Int) {
            switch entry {
            case .pendingHeader:
                return (FluxgramDownloadsSection.pending.rawValue, 0)
            case .pendingSummary:
                return (FluxgramDownloadsSection.pending.rawValue, 1)
            case let .pending(index, _):
                return (FluxgramDownloadsSection.pending.rawValue, index + 2)
            case .activeHeader:
                return (FluxgramDownloadsSection.active.rawValue, 0)
            case .activeSummary:
                return (FluxgramDownloadsSection.active.rawValue, 1)
            case .clearUnfinished:
                return (FluxgramDownloadsSection.active.rawValue, 2)
            case let .active(index, _, _, _):
                return (FluxgramDownloadsSection.active.rawValue, index + 3)
            case let .allJob(index, _, _, _, _), let .allPending(index, _):
                return (FluxgramDownloadsSection.active.rawValue, index + 3)
            case .historyHeader:
                return (FluxgramDownloadsSection.history.rawValue, 0)
            case .historySummary:
                return (FluxgramDownloadsSection.history.rawValue, 1)
            case .retryFailed:
                return (FluxgramDownloadsSection.history.rawValue, 2)
            case let .history(index, _, _, _):
                return (FluxgramDownloadsSection.history.rawValue, index + 3)
            case .historyLoadMore:
                return (FluxgramDownloadsSection.history.rawValue, 100_003)
        case .status:
            return (FluxgramDownloadsSection.status.rawValue, 0)
            }
        }
        let lhsOrder = order(lhs)
        let rhsOrder = order(rhs)
        if lhsOrder.0 != rhsOrder.0 {
            return lhsOrder.0 < rhsOrder.0
        }
        return lhsOrder.1 < rhsOrder.1
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramDownloadsControllerArguments
        switch self {
        case .pendingHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "本地队列", sectionId: self.section)
        case let .pendingSummary(count):
            let label = count == 0 ? "没有待提交请求" : "\(count) 个请求等待提交"
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "待提交下载",
                label: label,
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    if count > 0 {
                        arguments.retryPending(nil)
                    }
                }
            )
        case let .pending(_, submission):
            var details: [String] = [submission.options.downloadSubdir.isEmpty ? "NAS 根目录" : submission.options.downloadSubdir]
            if submission.attemptCount > 0 {
                details.append("已尝试 \(submission.attemptCount) 次")
                if submission.attemptCount >= 5 {
                    details.append("自动重试已暂停，请手动重试")
                }
            }
            if !submission.displayError.isEmpty {
                details.append(submission.displayError)
            }
            details.append("点击重试")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "消息 \(submission.messageId)",
                label: details.joined(separator: "\n"),
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.retryPending(submission)
                }
            )
        case let .activeHeader(summary, filters, selectedFilter, searchQuery):
            return FluxgramDownloadHeaderItem(
                presentationData: presentationData,
                summary: summary,
                filters: filters,
                selectedFilter: selectedFilter,
                searchQuery: searchQuery,
                sectionId: self.section,
                selectFilter: arguments.selectFilter,
                updateSearchQuery: arguments.updateSearchQuery
            )
        case let .activeSummary(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .clearUnfinished:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "清空未完成任务",
                kind: .destructive,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.clearUnfinished() }
            )
        case let .active(_, job, speed, thumbnailData):
            let failed = ["failed", "error"].contains(job.status.lowercased())
            return FluxgramDownloadCardItem(
                presentationData: presentationData,
                job: job,
                thumbnailData: thumbnailData,
                speed: speed,
                sectionId: self.section,
                cardAction: { arguments.showJob(job, !failed) },
                primaryAction: { arguments.primaryAction(job, true) },
                moreAction: { arguments.showJob(job, !failed) }
            )
        case let .allJob(_, job, isActive, speed, thumbnailData):
            let failed = ["failed", "error"].contains(job.status.lowercased())
            return FluxgramDownloadCardItem(
                presentationData: presentationData,
                job: job,
                thumbnailData: thumbnailData,
                speed: speed,
                sectionId: self.section,
                cardAction: { arguments.showJob(job, isActive && !failed) },
                primaryAction: { arguments.primaryAction(job, isActive) },
                moreAction: { arguments.showJob(job, isActive && !failed) }
            )
        case let .allPending(_, submission):
            var details: [String] = [submission.options.downloadSubdir.isEmpty ? "NAS 根目录" : submission.options.downloadSubdir]
            if submission.attemptCount > 0 {
                details.append("已尝试 \(submission.attemptCount) 次")
            }
            if !submission.displayError.isEmpty {
                details.append(submission.displayError)
            }
            details.append("点击重试")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "消息 \(submission.messageId)",
                label: details.joined(separator: "\n"),
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: { arguments.retryPending(submission) }
            )
        case let .history(_, job, speed, thumbnailData):
            return FluxgramDownloadCardItem(
                presentationData: presentationData,
                job: job,
                thumbnailData: thumbnailData,
                speed: speed,
                sectionId: self.section,
                cardAction: { arguments.showJob(job, false) },
                primaryAction: { arguments.primaryAction(job, false) },
                moreAction: { arguments.showJob(job, false) }
            )
        case .historyLoadMore:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "加载更多历史记录",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.loadMoreHistory()
                }
            )
        case .historyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "最近记录", sectionId: self.section)
        case let .historySummary(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .retryFailed(count):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "重试失败任务（\(count)）",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.retryFailed()
                }
            )
        case let .status(message):
            return ItemListTextItem(presentationData: presentationData, text: .plain(message), sectionId: self.section)
        }
    }
}

private final class FluxgramDownloadsControllerArguments {
    let retryPending: (FluxgramNASSubmission?) -> Void
    let retryFailed: () -> Void
    let clearUnfinished: () -> Void
    let loadMoreHistory: () -> Void
    let showJob: (FluxgramNASDownloadJob, Bool) -> Void
    let primaryAction: (FluxgramNASDownloadJob, Bool) -> Void
    let selectFilter: (Int) -> Void
    let updateSearchQuery: (String) -> Void

    init(retryPending: @escaping (FluxgramNASSubmission?) -> Void, retryFailed: @escaping () -> Void, clearUnfinished: @escaping () -> Void, loadMoreHistory: @escaping () -> Void, showJob: @escaping (FluxgramNASDownloadJob, Bool) -> Void, primaryAction: @escaping (FluxgramNASDownloadJob, Bool) -> Void, selectFilter: @escaping (Int) -> Void, updateSearchQuery: @escaping (String) -> Void) {
        self.retryPending = retryPending
        self.retryFailed = retryFailed
        self.clearUnfinished = clearUnfinished
        self.loadMoreHistory = loadMoreHistory
        self.showJob = showJob
        self.primaryAction = primaryAction
        self.selectFilter = selectFilter
        self.updateSearchQuery = updateSearchQuery
    }
}

func fluxgramDownloadSpeedText(_ bytesPerSecond: Int64?) -> String? {
    guard let bytesPerSecond, bytesPerSecond > 0 else {
        return nil
    }
    let value = Double(bytesPerSecond)
    if value >= 1024.0 * 1024.0 {
        return String(format: "%.1f MB/s", value / (1024.0 * 1024.0))
    } else if value >= 1024.0 {
        return String(format: "%.0f KB/s", value / 1024.0)
    } else {
        return String(bytesPerSecond) + " B/s"
    }
}

func fluxgramDownloadThumbnail(_ data: Data?) -> UIImage? {
    guard let data else { return nil }
    // Telegram's immediateThumbnailData is a compact TinyThumbnail payload,
    // not a directly decodable JPEG. Accept ordinary image data as a fallback
    // for backend-generated previews and older records.
    if let decoded = decodeTinyThumbnail(data: data), let image = UIImage(data: decoded) {
        return image
    }
    return UIImage(data: data)
}

func fluxgramDownloadPlaceholderIcon(job: FluxgramNASDownloadJob) -> UIImage? {
    let status = job.status.lowercased()
    let symbol: String
    let color: UIColor
    if ["failed", "error"].contains(status) {
        symbol = "exclamationmark.circle.fill"; color = .systemRed
    } else if ["done", "completed", "complete", "finished", "success"].contains(status) {
        symbol = "checkmark.circle.fill"; color = .systemGreen
    } else if ["queued", "queue", "pending", "waiting", "submitted", "retrying"].contains(status) {
        symbol = "clock.fill"; color = .systemOrange
    } else {
        let ext = (job.fileName as NSString).pathExtension.lowercased()
        symbol = ["mp4", "mov", "mkv", "avi", "m4v"].contains(ext) ? "video.fill" : "doc.fill"
        color = .systemGray
    }
    return UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
}

private func fluxgramDownloadDetail(job: FluxgramNASDownloadJob, speed: Int64?) -> String {
    let status = job.status.lowercased()
    let statusText: String
    switch status {
    case "queued", "queue", "pending", "waiting", "submitted": statusText = "排队中"
    case "retrying": statusText = "重试中"
    case "failed", "error": statusText = "失败：\(job.error.isEmpty ? "未知错误" : job.error)"
    case "done", "completed", "complete", "finished", "success": statusText = "已完成"
    case "cancelled", "canceled": statusText = "已取消"
    default: statusText = "下载中"
    }
    var detail = statusText
    if !job.fileName.isEmpty {
        let ext = (job.fileName as NSString).pathExtension.uppercased()
        if !ext.isEmpty {
            detail += " · \(ext)"
        }
    }
    if job.total > 0 {
        detail += " · \(fluxgramDownloadByteCount(job.total))"
    }
    if job.total > 0 {
        let percent = min(100, max(0, Int((Double(job.received) / Double(job.total)) * 100.0)))
        detail += " · \(percent)%"
    }
    detail += "\n" + job.detail
    if !job.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        detail += "\n来源：" + job.sourceLabel
    }
    let terminalStatuses = ["done", "completed", "complete", "finished", "success", "failed", "error", "cancelled", "canceled"]
    let waitingStatuses = ["queued", "queue", "pending", "waiting", "submitted", "retrying"]
    if !terminalStatuses.contains(status) && !waitingStatuses.contains(status) {
        detail += "\n速度：" + (fluxgramDownloadSpeedText(speed) ?? "测速中")
        if job.total > 0 {
            detail += " · " + fluxgramDownloadByteCount(job.received) + "/" + fluxgramDownloadByteCount(job.total)
        }
    } else if status == "failed" || status == "error" {
        detail += "\n点击任务可查看详情并重试"
    }
    return detail
}

func fluxgramDownloadByteCount(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(0, bytes))
    var index = 0
    while value >= 1024.0 && index < units.count - 1 {
        value /= 1024.0
        index += 1
    }
    return value >= 10 || index == 0 ? String(format: "%.0f %@", value, units[index]) : String(format: "%.1f %@", value, units[index])
}

private func fluxgramDownloadSummary(_ jobs: [FluxgramNASDownloadJob]) -> String {
    guard !jobs.isEmpty else { return "当前没有正在处理的任务。" }
    let waiting = jobs.filter { ["queued", "queue", "pending", "waiting", "submitted", "retrying"].contains($0.status.lowercased()) }.count
    let downloading = jobs.count - waiting
    var parts: [String] = []
    if downloading > 0 { parts.append("\(downloading) 个处理中") }
    if waiting > 0 { parts.append("\(waiting) 个排队") }
    return parts.isEmpty ? "没有正在处理的任务" : parts.joined(separator: " · ")
}

private func fluxgramHistorySummary(_ jobs: [FluxgramNASDownloadJob]) -> String {
    guard !jobs.isEmpty else { return "还没有完成或失败的记录。" }
    let failed = jobs.filter { ["failed", "error"].contains($0.status.lowercased()) }.count
    let completed = jobs.filter { ["completed", "complete", "finished", "success", "done"].contains($0.status.lowercased()) }.count
    var parts = ["共 \(jobs.count) 条记录"]
    if completed > 0 { parts.append("\(completed) 条已完成") }
    if failed > 0 { parts.append("\(failed) 条失败") }
    return parts.joined(separator: " · ")
}

private func fluxgramDownloadMatchesSearch(_ job: FluxgramNASDownloadJob, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    let values = [
        job.title,
        job.fileName,
        job.requestedTitle,
        job.sourceTitle,
        job.sourceLabel,
        job.sourceText,
        job.sourceUrl,
        job.downloadSubdir,
        job.outputFile,
        job.note,
        job.tags.joined(separator: " ")
    ]
    return values.contains { $0.localizedCaseInsensitiveContains(query) }
}

private func fluxgramSubmissionMatchesSearch(_ submission: FluxgramNASSubmission, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    let values = [
        submission.options.title,
        submission.desiredFileName ?? "",
        submission.directDocument?.fileName ?? "",
        submission.options.downloadSubdir,
        submission.options.note,
        submission.options.tags.joined(separator: " "),
        submission.backendDialogId,
        String(submission.messageId)
    ]
    return values.contains { $0.localizedCaseInsensitiveContains(query) }
}

private func fluxgramDownloadsEntries(state: FluxgramDownloadsControllerState) -> [FluxgramDownloadsEntry] {
    let activeStatuses: Set<String> = ["downloading", "running", "copying", "progressing"]
    let pausedStatuses: Set<String> = ["paused", "suspended"]
    let activeCount = state.active.filter { activeStatuses.contains($0.status.lowercased()) }.count
    let completedCount = state.history.filter { ["completed", "complete", "finished", "success", "done"].contains($0.status.lowercased()) }.count
    let headerSummary = "\(activeCount) 个任务下载中 · \(completedCount) 个已完成"
    let pausedCount = state.active.filter { pausedStatuses.contains($0.status.lowercased()) }.count
    let filters = [
        "全部 \(state.active.count + state.pending.count + state.history.count)",
        "下载中 \(activeCount)",
        "已完成 \(completedCount)",
        "已暂停 \(pausedCount)"
    ]
    let selectedFilter: Int
    switch state.filter {
    case .all: selectedFilter = 0
    case .active: selectedFilter = 1
    case .completed: selectedFilter = 2
    case .waiting: selectedFilter = 3
    case .failed: selectedFilter = 0
    }
    let searchQuery = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    var entries: [FluxgramDownloadsEntry] = [.activeHeader(headerSummary, filters, selectedFilter, state.searchQuery)]
    var visibleTaskCount = 0
    if state.filter == .all {
        // "全部" is a chronological feed. Jobs from the active list, local
        // submissions waiting for admission, and historical NAS records all
        // share the same ordering based on their real creation timestamp.
        var allItems: [FluxgramAllDownloadsItem] = []
        allItems.append(contentsOf: state.active.enumerated().compactMap {
            fluxgramDownloadMatchesSearch($0.element, query: searchQuery) ? .job($0.element, true, $0.offset) : nil
        })
        let pendingOffset = state.active.count
        allItems.append(contentsOf: state.pending.enumerated().compactMap {
            fluxgramSubmissionMatchesSearch($0.element, query: searchQuery) ? .pending($0.element, pendingOffset + $0.offset) : nil
        })
        let historyOffset = pendingOffset + state.pending.count
        let activeJobIdentities = Set(state.active.map(fluxgramAllDownloadsJobIdentity))
        allItems.append(contentsOf: state.history.enumerated().compactMap { item in
            // The NAS API can briefly return a completed job in both the
            // active snapshot and history. Keep the active representation so
            // the merged list never emits duplicate stable IDs.
            guard !activeJobIdentities.contains(fluxgramAllDownloadsJobIdentity(item.element)),
                  fluxgramDownloadMatchesSearch(item.element, query: searchQuery) else {
                return nil
            }
            return .job(item.element, false, historyOffset + item.offset)
        })

        allItems.sort { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.sourceIndex < rhs.sourceIndex
            }
        }

        entries.append(contentsOf: allItems.enumerated().map { item in
            switch item.element {
            case let .job(job, isActive, _):
                return FluxgramDownloadsEntry.allJob(
                    item.offset,
                    job,
                    isActive,
                    state.speeds[fluxgramDownloadNotificationKey(job)],
                    state.thumbnails[fluxgramDownloadThumbnailKey(job)]
                )
            case let .pending(submission, _):
                return FluxgramDownloadsEntry.allPending(item.offset, submission)
            }
        })
        visibleTaskCount += allItems.count

        let failedCount = state.history.filter {
            ["failed", "error"].contains($0.status.lowercased()) && fluxgramDownloadMatchesSearch($0, query: searchQuery)
        }.count
        if failedCount > 0 { entries.append(.retryFailed(failedCount)) }
        if state.history.count >= state.historyLimit, state.historyLimit < 200 {
            entries.append(.historyLoadMore)
        }
    } else {
        let filteredActive = state.active.filter { job in
            guard fluxgramDownloadMatchesSearch(job, query: searchQuery) else { return false }
            let status = job.status.lowercased()
            switch state.filter {
            case .all: return true
            case .active: return activeStatuses.contains(status)
            case .waiting: return pausedStatuses.contains(status)
            case .completed, .failed: return false
            }
        }
        let activeJobs = filteredActive.sorted { lhs, rhs in
            let waiting: Set<String> = ["queued", "queue", "pending", "waiting", "submitted", "retrying"]
            let leftWaiting = waiting.contains(lhs.status.lowercased())
            let rightWaiting = waiting.contains(rhs.status.lowercased())
            if leftWaiting != rightWaiting { return !leftWaiting }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        entries.append(contentsOf: activeJobs.enumerated().map { item in
            .active(item.offset, item.element, state.speeds[fluxgramDownloadNotificationKey(item.element)], state.thumbnails[fluxgramDownloadThumbnailKey(item.element)])
        })
        visibleTaskCount += activeJobs.count
        let filteredPending = state.pending.filter { fluxgramSubmissionMatchesSearch($0, query: searchQuery) }
        if !filteredPending.isEmpty {
            entries.append(.pendingSummary(filteredPending.count))
            entries.append(contentsOf: filteredPending.enumerated().map { .pending($0.offset, $0.element) })
            visibleTaskCount += filteredPending.count
        }
        let failedCount = state.history.filter {
            ["failed", "error"].contains($0.status.lowercased()) && fluxgramDownloadMatchesSearch($0, query: searchQuery)
        }.count
        if failedCount > 0 { entries.append(.retryFailed(failedCount)) }
        let filteredHistory = state.history.filter { job in
            guard fluxgramDownloadMatchesSearch(job, query: searchQuery) else { return false }
            let status = job.status.lowercased()
            switch state.filter {
            case .all: return true
            case .completed: return ["completed", "complete", "finished", "success", "done"].contains(status)
            case .failed: return ["failed", "error"].contains(status)
            case .active, .waiting: return false
            }
        }
        entries.append(contentsOf: filteredHistory.enumerated().map { item in
            .history(item.offset, item.element, state.speeds[fluxgramDownloadNotificationKey(item.element)], state.thumbnails[fluxgramDownloadThumbnailKey(item.element)])
        })
        visibleTaskCount += filteredHistory.count
        if state.history.count >= state.historyLimit, state.historyLimit < 200 {
            entries.append(.historyLoadMore)
        }
    }
    if !searchQuery.isEmpty && visibleTaskCount == 0 {
        entries.append(.status("没有找到与“\(searchQuery)”匹配的下载任务。"))
    } else if state.active.isEmpty && state.pending.isEmpty && state.history.isEmpty {
        entries.append(.status(state.error.isEmpty ? "暂时没有 NAS 下载任务。" : state.error))
    } else if !state.error.isEmpty {
        entries.append(.status(state.error))
    }
    return entries
}

public func fluxgramDownloadsController(context: AccountContext) -> ViewController {
    let service = FluxgramNASService.shared
    let initialState = FluxgramDownloadsControllerState(
        active: [],
        history: [],
        pending: [],
        error: "",
        speeds: [:],
        thumbnails: [:],
        historyLimit: 30,
        filter: .all,
        searchQuery: ""
    )
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let isRefreshing = Atomic(value: false)
    var previousSnapshot: FluxgramNASDownloadsSnapshot?
    var speedSamples: [String: (received: Int64, timestamp: TimeInterval)] = [:]
    var sourceMessageDisposable: Disposable?
    var thumbnailDisposables: [Disposable] = []
    var requestedThumbnailKeys = Set<String>()
    var refreshGeneration = 0
    let updateState: ((FluxgramDownloadsControllerState) -> FluxgramDownloadsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let requestMissingThumbnails: ([FluxgramNASDownloadJob]) -> Void = { jobs in
        let cachedKeys = stateValue.with { Set($0.thumbnails.keys) }
        for job in jobs.prefix(30) where job.thumbnailData == nil {
            let key = fluxgramDownloadThumbnailKey(job)
            guard !cachedKeys.contains(key), requestedThumbnailKeys.insert(key).inserted else {
                continue
            }
            let disposable = (fluxgramLocalDownloadThumbnail(context: context, job: job)
            |> deliverOnMainQueue).start(next: { data in
                guard let data else { return }
                updateState { state in
                    var state = state
                    state.thumbnails[key] = data
                    return state
                }
            })
            thumbnailDisposables.append(disposable)
        }

        // Older NAS records may already contain an immediate TinyThumbnail.
        // Re-fetch only those that are clearly too small for the card so the
        // list can upgrade in place without reloading every historical job.
        for job in jobs.prefix(30) where job.thumbnailData != nil {
            let isLowResolution = job.thumbnailData.flatMap { data -> Bool? in
                guard let image = fluxgramDownloadThumbnail(data), let cgImage = image.cgImage else {
                    return nil
                }
                return max(cgImage.width, cgImage.height) < 300
            } ?? false
            guard isLowResolution else { continue }
            let key = fluxgramDownloadThumbnailKey(job)
            guard !cachedKeys.contains(key), requestedThumbnailKeys.insert(key).inserted else {
                continue
            }
            let disposable = (fluxgramLocalDownloadThumbnail(context: context, job: job)
            |> deliverOnMainQueue).start(next: { data in
                guard let data else { return }
                updateState { state in
                    var state = state
                    state.thumbnails[key] = data
                    return state
                }
            })
            thumbnailDisposables.append(disposable)
        }
    }

    var controller: ItemListController?
    let presentAlert: (String) -> Void = { message in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            standardTextAlertController(
                theme: AlertControllerTheme(presentationData: presentationData),
                title: nil,
                text: message,
                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
            ),
            in: .window(.root)
        )
    }
    let presentStatus: (String, Bool) -> Void = { message, destructive in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            UndoOverlayController(
                presentationData: presentationData,
                content: .actionSucceeded(title: nil, text: message, cancel: nil, destructive: destructive),
                elevatedLayout: false,
                animateInAsReplacement: false,
                action: { _ in return false }
            ),
            in: .current
        )
    }

    let refresh: (Bool) -> Void = { includeHistory in
        guard !isRefreshing.swap(true) else {
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        var completedRequests = 0
        let finishRequest: () -> Void = {
            completedRequests += 1
            if completedRequests >= 2 {
                _ = isRefreshing.swap(false)
            }
        }
        service.fetchPendingDownloads { pending in
            guard generation == refreshGeneration else {
                return
            }
            updateState { state in
                var state = state
                state.pending = pending
                return state
            }
            finishRequest()
        }
        let historyLimit = stateValue.with { $0.historyLimit }
        service.fetchDownloadsIncrementally(includeHistory: includeHistory, historyLimit: historyLimit) { update in
            guard generation == refreshGeneration else {
                return
            }
            switch update {
            case let .active(jobs):
                requestMissingThumbnails(jobs)
                let now = Date().timeIntervalSinceReferenceDate
                var measuredSpeeds: [String: Int64] = [:]
                for job in jobs {
                    let key = fluxgramDownloadNotificationKey(job)
                    if let previous = speedSamples[key] {
                        let elapsed = now - previous.timestamp
                        let delta = job.received - previous.received
                        if elapsed >= 0.5, delta >= 0 {
                            measuredSpeeds[key] = Int64(Double(delta) / elapsed)
                        }
                    }
                    speedSamples[key] = (job.received, now)
                }
                updateState { state in
                    var state = state
                    state.active = jobs
                    state.error = ""
                    for (key, speed) in measuredSpeeds {
                        state.speeds[key] = speed
                    }
                    return state
                }
            case let .activeOnlyFinished(jobs):
                let history = stateValue.with { $0.history }
                let snapshot = FluxgramNASDownloadsSnapshot(active: jobs, history: history)
                if let previousSnapshot, let notification = fluxgramDownloadNotificationText(previous: previousSnapshot, current: snapshot) {
                    presentStatus(notification.text, notification.destructive)
                }
                previousSnapshot = snapshot
                finishRequest()
            case let .history(jobs):
                requestMissingThumbnails(jobs)
                updateState { state in
                    var state = state
                    state.history = jobs
                    state.error = ""
                    return state
                }
            case let .finished(snapshot):
                if let previousSnapshot, let notification = fluxgramDownloadNotificationText(previous: previousSnapshot, current: snapshot) {
                    presentStatus(notification.text, notification.destructive)
                }
                previousSnapshot = snapshot
                finishRequest()
            case let .failure(message):
                updateState { state in
                    var state = state
                    state.error = message
                    return state
                }
                finishRequest()
            }
        }
    }
    let arguments = FluxgramDownloadsControllerArguments(retryPending: { submission in
        if let submission {
            service.retryPendingDownload(submission) { result in
                presentAlert(result.message)
                refresh(true)
            }
            return
        }
        service.retryPendingDownloads { submitted, remaining in
            let message: String
            if submitted > 0 {
                message = "已提交 \(submitted) 个待提交下载请求。"
            } else if remaining > 0 {
                message = "仍有 \(remaining) 个下载请求等待提交。"
            } else {
                message = "没有待提交下载请求。"
            }
            presentAlert(message)
            refresh(true)
        }
    }, retryFailed: {
        service.retryProblemDownloads { success, message in
            presentAlert(message)
            if success {
                refresh(true)
            }
        }
    }, clearUnfinished: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            standardTextAlertController(
                theme: AlertControllerTheme(presentationData: presentationData),
                title: "清空未完成任务？",
                text: "将取消 NAS 中所有进行中任务，并删除手机本地待提交队列。已完成记录会保留。",
                actions: [
                    TextAlertAction(type: .genericAction, title: "取消", action: {}),
                    TextAlertAction(type: .destructiveAction, title: "清空", action: {
                        service.clearUnfinishedDownloads { cancelled, pending, error in
                            var message = "已取消 NAS 任务：\(cancelled) 个\n已清除本地待提交：\(pending) 个"
                            if let error, !error.isEmpty {
                                message += "\n\n部分任务未能取消：\(error)"
                            }
                            presentAlert(message)
                            refresh(true)
                        }
                    })
                ]
            ),
            in: .window(.root)
        )
    }, loadMoreHistory: {
        guard !(isRefreshing.with { $0 }) else {
            return
        }
        updateState { state in
            var state = state
            state.historyLimit = min(state.historyLimit + 50, 200)
            return state
        }
        refresh(true)
    }, showJob: { job, isActive in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var actions: [ActionSheetItem] = [
            ActionSheetTextItem(title: job.title + "\n\n" + job.detailText)
        ]

        if job.hasSourceMessage {
            actions.append(ActionSheetButtonItem(title: "打开原消息", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                sourceMessageDisposable?.dispose()
                sourceMessageDisposable = (fluxgramOriginalMessageTarget(context: context, job: job)
                |> deliverOnMainQueue).start(next: { target in
                    guard let target else {
                        presentAlert("找不到这条消息。它可能已被删除，或来源频道开启了转发隐私。")
                        return
                    }
                    context.sharedContext.navigateToChat(accountId: context.account.id, peerId: target.peerId, messageId: target.messageId)
                })
            }))
        } else if let privateChannelMessage = fluxgramPrivateChannelMessage(for: job) {
            actions.append(ActionSheetButtonItem(title: "打开原消息", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                let channelId = privateChannelMessage.channelId
                let messageId = privateChannelMessage.messageId
                let peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(channelId))
                let targetMessageId = EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)
                sourceMessageDisposable?.dispose()
                sourceMessageDisposable = (context.engine.peers.findChannelById(channelId: channelId)
                |> deliverOnMainQueue).start(next: { peer in
                    guard peer != nil else {
                        presentAlert("找不到该频道。请先在 Telegram 中打开一次此聊天，再重试。")
                        return
                    }
                    context.sharedContext.navigateToChat(accountId: context.account.id, peerId: peerId, messageId: targetMessageId)
                })
            }))
        } else if !job.sourceUrl.isEmpty {
            // Older NAS jobs only have the original t.me link. Let Telegram's
            // normal URL resolver locate the private channel and message.
            actions.append(ActionSheetButtonItem(title: "打开原消息", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                context.sharedContext.openExternalUrl(
                    context: context,
                    urlContext: .generic,
                    url: job.sourceUrl,
                    forceExternal: false,
                    presentationData: presentationData,
                    navigationController: nil,
                    dismissInput: {}
                )
            }))
        }

        if let path = job.fluxTokRelativePath {
            actions.append(ActionSheetButtonItem(title: "在 FluxTok 打开", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                var components = URLComponents()
                components.scheme = "nastok"
                components.host = "play"
                components.queryItems = [URLQueryItem(name: "path", value: path)]
                guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
                    presentAlert("未检测到 FluxTok。请确认已安装最新版本。")
                    return
                }
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }))
        }

        if !job.id.isEmpty {
            actions.append(ActionSheetButtonItem(title: "删除记录", color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                let confirmation = standardTextAlertController(
                    theme: AlertControllerTheme(presentationData: presentationData),
                    title: "删除此任务？",
                    text: isActive ? "将停止任务并删除未完成的临时文件。" : "仅删除任务记录，NAS 中已完成的媒体文件会保留。",
                    actions: [
                        TextAlertAction(type: .defaultAction, title: "取消", action: {}),
                        TextAlertAction(type: .destructiveAction, title: "删除", action: {
                            service.deleteDownload(jobId: job.id) { success, message in
                                presentAlert(message)
                                if success { refresh(true) }
                            }
                        })
                    ]
                )
                controller?.present(confirmation, in: .window(.root))
            }))
        }

        let isFailed = ["failed", "error"].contains(job.status.lowercased())
        if isFailed {
            actions.append(ActionSheetButtonItem(title: "重试失败任务", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                service.retryProblemDownloads { success, message in
                    presentAlert(message)
                    if success {
                        refresh(true)
                    }
                }
            }))
        } else if isActive, !job.id.isEmpty {
            actions.append(ActionSheetButtonItem(title: "取消下载", color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                service.cancelDownload(jobId: job.id) { success, message in
                    presentAlert(message)
                    if success {
                        refresh(true)
                    }
                }
            }))
        }

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: actions),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        controller?.present(actionSheet, in: .window(.root))
    }, primaryAction: { job, isActive in
        let status = job.status.lowercased()
        if ["failed", "error", "cancelled", "canceled"].contains(status) {
            service.retryDownload(jobId: job.id) { success, message in
                presentAlert(message)
                if success { refresh(true) }
            }
        } else if ["paused", "suspended"].contains(status) || ["queued", "queue", "pending", "waiting", "submitted"].contains(status) {
            service.resumeDownload(jobId: job.id) { success, message in
                presentAlert(message)
                if success { refresh(true) }
            }
        } else if ["downloading", "running", "copying", "progressing"].contains(status) {
            service.pauseDownload(jobId: job.id) { success, message in
                presentAlert(message)
                if success { refresh(true) }
            }
        } else if !isActive, let path = job.outputFile.isEmpty ? nil : URL(fileURLWithPath: job.outputFile).deletingLastPathComponent().path {
            presentAlert("文件已保存到：\n\(path)")
        }
    }, selectFilter: { index in
        let filters: [FluxgramDownloadsFilter] = [.all, .active, .completed, .waiting]
        guard filters.indices.contains(index) else { return }
        updateState { state in
            var state = state
            state.filter = filters[index]
            return state
        }
    }, updateSearchQuery: { query in
        updateState { state in
            var state = state
            state.searchQuery = query
            return state
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramDownloadsControllerArguments)) in
        // This screen is presented modally from the download form. A
        // backNavigationButton only affects a navigation-stack back item, so
        // provide an explicit dismiss action in the navigation bar.
        let leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
            let _ = controller?.dismiss()
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(""),
            leftNavigationButton: leftNavigationButton,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: true
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fluxgramDownloadsEntries(state: state),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let result = ItemListController(context: context, state: signal)
    controller = result
    var refreshTimer: SwiftSignalKit.Timer?
    var lightweightRefreshCount = 0
    result.didAppear = { _ in
        // Status inspection must remain read-only. Pending local submissions
        // are shown above and only leave the phone after the user explicitly
        // taps a retry action, so opening this screen never changes the NAS
        // queue or competes with an in-progress download.
        refresh(true)
        guard refreshTimer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 4.0, repeat: true, completion: {
            // Only active cards are polled automatically. History is a much
            // heavier, mostly immutable list; it is loaded on entry and when
            // the user explicitly taps Refresh. This keeps large histories
            // from being downloaded and diffed every few seconds.
            lightweightRefreshCount += 1
            refresh(false)
            // As active NAS slots free up, admit the next small batch from
            // the phone queue. The service checks the server's active count
            // before submitting, so this does not add pressure to a full NAS.
            service.retryPendingDownloads(automatic: true)
        }, queue: Queue.mainQueue())
        refreshTimer = timer
        timer.start()
    }
    result.willDisappear = { _ in
        refreshGeneration += 1
        _ = isRefreshing.swap(false)
        sourceMessageDisposable?.dispose()
        sourceMessageDisposable = nil
        thumbnailDisposables.forEach { $0.dispose() }
        thumbnailDisposables.removeAll()
        lightweightRefreshCount = 0
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    return result
}
