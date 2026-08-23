import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ItemListUI
import SettingsUI

private enum FluxgramHubEntry: ItemListNodeEntry {
    case status(FluxgramHubStatus)
    case settings
    case downloads
    case favorites
    case shortVideos

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .status:
            return 0
        case .settings:
            return 1
        case .downloads:
            return 2
        case .favorites:
            return 3
        case .shortVideos:
            return 4
        }
    }

    static func <(lhs: FluxgramHubEntry, rhs: FluxgramHubEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
}

private struct FluxgramHubStatus: Equatable {
    var nasConfigured: Bool
    var nasOnline: Bool
    var activeDownloads: Int
    var pendingDownloads: Int
    var favoriteCount: Int
    var sourceCount: Int
    var error: String?

    static let initial = FluxgramHubStatus(
        nasConfigured: false,
        nasOnline: false,
        activeDownloads: 0,
        pendingDownloads: 0,
        favoriteCount: 0,
        sourceCount: 0,
        error: nil
    )

    var title: String {
        if !self.nasConfigured {
            return "Fluxgram 媒体工作台"
        }
        return self.nasOnline ? "NAS 在线" : "NAS 暂不可用"
    }

    var detail: String {
        if !self.nasConfigured {
            return "先在 Fluxgram 设置中填写 NAS 地址和访问令牌。"
        }
        var values: [String] = []
        values.append(self.activeDownloads == 0 ? "没有下载中的任务" : "下载中 \(self.activeDownloads) 个")
        if self.pendingDownloads > 0 {
            values.append("待提交 \(self.pendingDownloads) 个")
        }
        values.append("收藏箱 \(self.favoriteCount) 条")
        values.append("视频来源 \(self.sourceCount) 个")
        if let error = self.error, !error.isEmpty {
            values.append(error)
        }
        return values.joined(separator: " · ")
    }
}

private final class FluxgramHubControllerArguments {
    let openSettings: () -> Void
    let openDownloads: () -> Void
    let openFavorites: () -> Void
    let openShortVideos: () -> Void

    init(openSettings: @escaping () -> Void, openDownloads: @escaping () -> Void, openFavorites: @escaping () -> Void, openShortVideos: @escaping () -> Void) {
        self.openSettings = openSettings
        self.openDownloads = openDownloads
        self.openFavorites = openFavorites
        self.openShortVideos = openShortVideos
    }
}

private func fluxgramHubEntries() -> [FluxgramHubEntry] {
    return [
        .status(.initial),
        .settings,
        .downloads,
        .favorites,
        .shortVideos
    ]
}

private extension FluxgramHubEntry {
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramHubControllerArguments
        let action: () -> Void
        let icon: UIImage?
        let title: String
        let label: String

        switch self {
        case let .status(status):
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: status.title,
                text: .plain(status.detail),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .settings:
            action = arguments.openSettings
            icon = PresentationResourcesSettings.dataAndStorage
            title = "Fluxgram 设置"
            label = "TGAPP、令牌与 NAS 连接"
        case .downloads:
            action = arguments.openDownloads
            icon = PresentationResourcesSettings.download
            title = "NAS 下载"
            label = "队列与历史记录"
        case .favorites:
            action = arguments.openFavorites
            icon = PresentationResourcesSettings.favorites
            title = "收藏箱"
            label = "已收藏的媒体与消息"
        case .shortVideos:
            action = arguments.openShortVideos
            icon = PresentationResourcesSettings.videosBlue
            title = "短视频流"
            label = "从频道汇总可播放视频"
        }

        return ItemListDisclosureItem(
            presentationData: presentationData,
            systemStyle: .legacy,
            icon: icon,
            title: title,
            label: label,
            labelStyle: .text,
            sectionId: self.section,
            style: .blocks,
            disclosureStyle: .arrow,
            action: action
        )
    }
}

public func fluxgramHubController(context: AccountContext) -> ViewController {
    var controller: ItemListController?
    let stateValue = Atomic(value: FluxgramHubStatus.initial)
    let statePromise = ValuePromise(FluxgramHubStatus.initial, ignoreRepeated: true)
    let updateStatus: (FluxgramHubStatus) -> Void = { status in
        statePromise.set(stateValue.swap(status))
    }
    let arguments = FluxgramHubControllerArguments(
        openSettings: { controller?.push(fluxgramSettingsController(context: context)) },
        openDownloads: { controller?.push(fluxgramDownloadsController(context: context)) },
        openFavorites: { controller?.push(fluxgramFavoritesController(context: context)) },
        openShortVideos: { controller?.push(fluxgramShortVideoController(context: context)) }
    )

    let refreshStatus = {
        let favorites = FluxgramFavoriteStore.favorites().count
        let sourceCount = FluxgramShortVideoStore.sources().filter { $0.enabled }.count
        FluxgramNASService.shared.fetchStatusSummary { summary in
            updateStatus(FluxgramHubStatus(
                nasConfigured: summary.activeCount > 0 || summary.pendingCount > 0 || summary.historyCount > 0 || summary.error != nil,
                nasOnline: summary.error == nil,
                activeDownloads: summary.activeCount,
                pendingDownloads: summary.pendingCount,
                favoriteCount: favorites,
                sourceCount: sourceCount,
                error: summary.error
            ))
        }
    }

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, FluxgramHubControllerArguments)), NoError> = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, status -> (ItemListControllerState, (ItemListNodeState, FluxgramHubControllerArguments)) in
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let state = ItemListControllerState(
            presentationData: itemListPresentationData,
            title: .text("Fluxgram"),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(content: .text("刷新"), style: .regular, enabled: true, action: refreshStatus),
            backNavigationButton: nil,
            animateChanges: true
        )
        let entries: [FluxgramHubEntry] = fluxgramHubEntries().map { entry in
            if case .status = entry {
                return FluxgramHubEntry.status(status)
            }
            return entry
        }
        let listState = ItemListNodeState(
            presentationData: itemListPresentationData,
            entries: entries,
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (state, (listState, arguments))
    }

    let result: ItemListController = ItemListController(context: context, state: signal)
    controller = result
    var refreshTimer: SwiftSignalKit.Timer?
    result.didAppear = { (_: Bool) in
        refreshStatus()
        guard refreshTimer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 8.0, repeat: true, completion: refreshStatus, queue: Queue.mainQueue())
        refreshTimer = timer
        timer.start()
    }
    result.willDisappear = { (_: Bool) in
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    result.tabBarItem.title = "Fluxgram"
    // Use the same monochrome, linear icon family as the other root tabs.
    // The Item List video asset is blue/multicolor and clashes with the tab bar style.
    let icon = UIImage(bundleImageName: "Chat List/Tabs/IconCamera")?.withRenderingMode(.alwaysTemplate)
    result.tabBarItem.image = icon
    result.tabBarItem.selectedImage = icon

    return result
}
