import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ItemListUI
import SettingsUI

private enum FluxgramHubEntry: ItemListNodeEntry {
    case settings
    case downloads
    case favorites
    case shortVideos

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .settings:
            return 0
        case .downloads:
            return 1
        case .favorites:
            return 2
        case .shortVideos:
            return 3
        }
    }

    static func <(lhs: FluxgramHubEntry, rhs: FluxgramHubEntry) -> Bool {
        return lhs.stableId < rhs.stableId
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
    let arguments = FluxgramHubControllerArguments(
        openSettings: { controller?.push(fluxgramSettingsController(context: context)) },
        openDownloads: { controller?.push(fluxgramDownloadsController(context: context)) },
        openFavorites: { controller?.push(fluxgramFavoritesController(context: context)) },
        openShortVideos: { controller?.push(fluxgramShortVideoController(context: context)) }
    )

    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, FluxgramHubControllerArguments)) in
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let state = ItemListControllerState(
            presentationData: itemListPresentationData,
            title: .text("Fluxgram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: nil,
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: itemListPresentationData,
            entries: fluxgramHubEntries(),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: false
        )
        return (state, (listState, arguments))
    }

    let result = ItemListController(context: context, state: signal)
    controller = result

    result.tabBarItem.title = "Fluxgram"
    // Use the same monochrome, linear icon family as the other root tabs.
    // The Item List video asset is blue/multicolor and clashes with the tab bar style.
    let icon = UIImage(bundleImageName: "Chat List/Tabs/IconCamera")?.withRenderingMode(.alwaysTemplate)
    result.tabBarItem.image = icon
    result.tabBarItem.selectedImage = icon

    return result
}
