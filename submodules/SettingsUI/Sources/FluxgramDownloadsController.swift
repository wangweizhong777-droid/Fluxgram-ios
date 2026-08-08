import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore
import UndoUI

private struct FluxgramDownloadsControllerState: Equatable {
    var active: [FluxgramNASDownloadJob]
    var history: [FluxgramNASDownloadJob]
    var pending: [FluxgramNASSubmission]
    var error: String
}

private enum FluxgramDownloadsSection: Int32 {
    case pending
    case active
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

private func fluxgramDownloadNotificationKey(_ job: FluxgramNASDownloadJob) -> String {
    if !job.id.isEmpty {
        return job.id
    }
    if !job.outputFile.isEmpty {
        return job.outputFile
    }
    return "\(job.fileName)|\(job.sourceLabel)|\(job.downloadSubdir)"
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
    case activeHeader
    case active(Int, FluxgramNASDownloadJob)
    case historyHeader
    case history(Int, FluxgramNASDownloadJob)
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .pendingHeader, .pendingSummary, .pending:
            return FluxgramDownloadsSection.pending.rawValue
        case .activeHeader, .active:
            return FluxgramDownloadsSection.active.rawValue
        case .historyHeader, .history:
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
        case let .active(index, job):
            return fluxgramDownloadStableId(job, namespace: 100_000, index: index)
        case .historyHeader:
            return 10_000
        case let .history(index, job):
            return fluxgramDownloadStableId(job, namespace: 600_000_000, index: index)
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
            case let .active(index, _):
                return (FluxgramDownloadsSection.active.rawValue, index + 1)
            case .historyHeader:
                return (FluxgramDownloadsSection.history.rawValue, 0)
            case let .history(index, _):
                return (FluxgramDownloadsSection.history.rawValue, index + 1)
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
                systemStyle: .glass,
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
            }
            if !submission.displayError.isEmpty {
                details.append(submission.displayError)
            }
            details.append("点击重试")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
        case .activeHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "NAS 下载", sectionId: self.section)
        case let .active(_, job):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: job.title,
                label: job.detail,
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.showJob(job, true)
                }
            )
        case let .history(_, job):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: job.title,
                label: job.detail,
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.showJob(job, false)
                }
            )
        case .historyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "最近记录", sectionId: self.section)
        case let .status(message):
            return ItemListTextItem(presentationData: presentationData, text: .plain(message), sectionId: self.section)
        }
    }
}

private final class FluxgramDownloadsControllerArguments {
    let retryPending: (FluxgramNASSubmission?) -> Void
    let showJob: (FluxgramNASDownloadJob, Bool) -> Void

    init(retryPending: @escaping (FluxgramNASSubmission?) -> Void, showJob: @escaping (FluxgramNASDownloadJob, Bool) -> Void) {
        self.retryPending = retryPending
        self.showJob = showJob
    }
}

private func fluxgramDownloadsEntries(state: FluxgramDownloadsControllerState) -> [FluxgramDownloadsEntry] {
    var entries: [FluxgramDownloadsEntry] = [
        .pendingHeader,
        .pendingSummary(state.pending.count)
    ]
    entries.append(contentsOf: state.pending.enumerated().map { .pending($0.offset, $0.element) })
    entries.append(.activeHeader)
    entries.append(contentsOf: state.active.enumerated().map { .active($0.offset, $0.element) })
    entries.append(.historyHeader)
    entries.append(contentsOf: state.history.enumerated().map { .history($0.offset, $0.element) })
    if state.active.isEmpty && state.history.isEmpty {
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
        error: ""
    )
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let isRefreshing = Atomic(value: false)
    var previousSnapshot: FluxgramNASDownloadsSnapshot?
    var refreshGeneration = 0
    let updateState: ((FluxgramDownloadsControllerState) -> FluxgramDownloadsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
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
        service.fetchDownloadsIncrementally(includeHistory: includeHistory) { update in
            guard generation == refreshGeneration else {
                return
            }
            switch update {
            case let .active(jobs):
                updateState { state in
                    var state = state
                    state.active = jobs
                    state.error = ""
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
    }, showJob: { job, isActive in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var actions: [ActionSheetItem] = [
            ActionSheetTextItem(title: job.title + "\n\n" + job.detailText)
        ]

        if job.hasSourceMessage, let dialogId = job.sourceDialogId,
           let messageId = job.sourceRootMessageId ?? job.sourceMessageId {
            actions.append(ActionSheetButtonItem(title: "打开原消息", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                let peerId = EnginePeer.Id(dialogId)
                let targetMessageId = EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)
                context.sharedContext.navigateToChat(accountId: context.account.id, peerId: peerId, messageId: targetMessageId)
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

        if isActive, !job.id.isEmpty {
            actions.append(ActionSheetButtonItem(title: "取消下载", color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                service.cancelDownload(jobId: job.id) { success, message in
                    presentAlert(message)
                    if success {
                        refresh(true)
                    }
                }
            }))
        } else if ["failed", "error"].contains(job.status.lowercased()) {
            actions.append(ActionSheetButtonItem(title: "重试失败任务", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                service.retryProblemDownloads { success, message in
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
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramDownloadsControllerArguments)) in
        let rightNavigationButton = ItemListNavigationButton(content: .text("刷新"), style: .regular, enabled: true, action: {
            refresh(true)
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("NAS 下载"),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
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
        // Retrying is intentionally scoped to this screen so normal chat
        // navigation never competes with a backlog of NAS submissions.
        refresh(true)
        service.retryPendingDownloads(automatic: true) { _, _ in
            refresh(true)
        }
        guard refreshTimer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 4.0, repeat: true, completion: {
            // Active cards update frequently. History is sampled periodically
            // as well so a completed task does not disappear from the list
            // until the user performs a manual refresh.
            lightweightRefreshCount += 1
            refresh(lightweightRefreshCount % 3 == 0)
        }, queue: Queue.mainQueue())
        refreshTimer = timer
        timer.start()
    }
    result.willDisappear = { _ in
        refreshGeneration += 1
        _ = isRefreshing.swap(false)
        lightweightRefreshCount = 0
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    return result
}
