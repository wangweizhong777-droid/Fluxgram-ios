import Foundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import AlertUI
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent

public struct FluxgramFavoriteMessage: Codable, Equatable {
    public let dialogId: Int64
    public let messageId: Int32
    public let sourceTitle: String
    public let title: String
    public let tags: [String]
    public let createdAt: TimeInterval

    public var identifier: String {
        return "\(self.dialogId):\(self.messageId)"
    }
}

public enum FluxgramFavoriteStore {
    private static let key = "com.fluxgram.ios.favorites.v1"
    private static let lock = NSLock()
    private static let persistenceQueue = DispatchQueue(label: "com.fluxgram.ios.favorites.persistence", qos: .utility)
    private static var cachedFavorites: [FluxgramFavoriteMessage]?

    public static func favorites() -> [FluxgramFavoriteMessage] {
        self.lock.lock()
        if let cachedFavorites = self.cachedFavorites {
            self.lock.unlock()
            return cachedFavorites
        }
        let favorites: [FluxgramFavoriteMessage]
        if let data = UserDefaults.standard.data(forKey: self.key),
           let decoded = try? JSONDecoder().decode([FluxgramFavoriteMessage].self, from: data) {
            favorites = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            favorites = []
        }
        self.cachedFavorites = favorites
        self.lock.unlock()
        return favorites
    }

    public static func add(messages: [EngineMessage], tags: [String]) -> Int {
        let normalizedTags = self.normalizedTags(tags)
        guard !messages.isEmpty, !normalizedTags.isEmpty else {
            return 0
        }
        var merged = Dictionary(uniqueKeysWithValues: self.favorites().map { ($0.identifier, $0) })
        var addedCount = 0
        for message in messages {
            let favorite = self.favorite(from: message, tags: normalizedTags)
            if let existing = merged[favorite.identifier] {
                let tags = self.normalizedTags(existing.tags + normalizedTags)
                merged[favorite.identifier] = FluxgramFavoriteMessage(
                    dialogId: existing.dialogId,
                    messageId: existing.messageId,
                    sourceTitle: favorite.sourceTitle,
                    title: favorite.title,
                    tags: tags,
                    createdAt: existing.createdAt
                )
            } else {
                merged[favorite.identifier] = favorite
                addedCount += 1
            }
        }
        self.save(Array(merged.values))
        return addedCount
    }

    public static func remove(identifiers: Set<String>) {
        guard !identifiers.isEmpty else {
            return
        }
        self.save(self.favorites().filter { !identifiers.contains($0.identifier) })
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            for component in tag.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }) {
                let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
                    continue
                }
                result.append(String(value))
            }
        }
        return result
    }

    private static func favorite(from message: EngineMessage, tags: [String]) -> FluxgramFavoriteMessage {
        let sourceTitle = message.peers[message.id.peerId]?.debugDisplayTitle ?? "未知会话"
        let title: String
        if let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first {
            title = file.fileName ?? (file.isVideo ? "视频消息" : "文件消息")
        } else if message.media.contains(where: { $0 is TelegramMediaImage }) {
            title = "图片消息"
        } else {
            let text = message.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = text.isEmpty ? "消息 \(message.id.id)" : String(text.prefix(80))
        }
        return FluxgramFavoriteMessage(
            dialogId: message.id.peerId.toInt64(),
            messageId: message.id.id,
            sourceTitle: sourceTitle,
            title: title,
            tags: tags,
            createdAt: Date().timeIntervalSince1970
        )
    }

    private static func save(_ favorites: [FluxgramFavoriteMessage]) {
        let sortedFavorites = favorites.sorted { $0.createdAt > $1.createdAt }
        self.lock.lock()
        self.cachedFavorites = sortedFavorites
        self.lock.unlock()

        // Encoding a large collection on the main thread makes tag filtering
        // and returning from a chat visibly stutter. The in-memory snapshot is
        // updated synchronously; disk persistence is serialized in order.
        self.persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(sortedFavorites) else {
                return
            }
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }
}

public func fluxgramFavoriteTagAlert(context: AccountContext, completion: @escaping ([String]) -> Void) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let inputState = AlertInputFieldComponent.ExternalState()
    let doneIsEnabled = inputState.valueSignal
    |> map { value in
        return !FluxgramFavoriteStore.normalizedTags([value]).isEmpty
    }
    var apply: (() -> Void)?
    let content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
        AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: "添加到收藏箱"))),
        AnyComponentWithIdentity(id: "input", component: AnyComponent(AlertInputFieldComponent(
            context: context,
            initialValue: nil,
            placeholder: "输入标签，用逗号分隔",
            hasClearButton: true,
            keyboardType: .default,
            autocapitalizationType: .none,
            autocorrectionType: .yes,
            isInitiallyFocused: true,
            externalState: inputState,
            returnKeyAction: {
                apply?()
            }
        )))
    ]
    let controller = AlertScreen(
        configuration: AlertScreen.Configuration(allowInputInset: true),
        content: content,
        actions: [
            .init(title: presentationData.strings.Common_Cancel),
            .init(title: presentationData.strings.Common_Done, type: .default, action: {
                apply?()
            }, autoDismiss: false, isEnabled: doneIsEnabled)
        ],
        updatedPresentationData: (presentationData, context.sharedContext.presentationData)
    )
    apply = {
        let tags = FluxgramFavoriteStore.normalizedTags([inputState.value])
        guard !tags.isEmpty else {
            inputState.animateError()
            return
        }
        controller.dismiss()
        completion(tags)
    }
    return controller
}

private struct FluxgramFavoriteGroup: Equatable {
    let key: String
    let tags: [String]
    let favorites: [FluxgramFavoriteMessage]
}

private func fluxgramFavoriteGroupKey(tags: [String]) -> String {
    FluxgramFavoriteStore.normalizedTags(tags).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { $0.localizedLowercase }.joined(separator: "\u{001f}")
}

private func fluxgramFavoriteGroupStableId(_ key: String, selecting: Bool) -> Int32 {
    var hash: UInt32 = 2_166_136_261
    for byte in key.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    let namespace: UInt32 = selecting ? 700_000_000 : 300_000_000
    return Int32(namespace + hash % 200_000_000)
}

private func fluxgramFavoriteGroups(_ favorites: [FluxgramFavoriteMessage]) -> [FluxgramFavoriteGroup] {
    var grouped: [String: [FluxgramFavoriteMessage]] = [:]
    for favorite in favorites {
        grouped[fluxgramFavoriteGroupKey(tags: favorite.tags), default: []].append(favorite)
    }
    return grouped.map { key, values in
        let sorted = values.sorted { $0.createdAt > $1.createdAt }
        let tags = FluxgramFavoriteStore.normalizedTags(sorted.flatMap(\.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return FluxgramFavoriteGroup(key: key, tags: tags, favorites: sorted)
    }.sorted { ($0.favorites.first?.createdAt ?? 0) > ($1.favorites.first?.createdAt ?? 0) }
}

private struct FluxgramFavoriteGroupsState: Equatable {
    var favorites: [FluxgramFavoriteMessage]
    var filter: String
    var isSelectingGroups: Bool
    var selectedGroupKeys: Set<String>
}

private enum FluxgramFavoriteGroupsEntry: ItemListNodeEntry {
    case filter(String)
    case header(Int)
    case empty(String)
    case group(Int, FluxgramFavoriteGroup, Bool, Bool)
    case downloadGroups(Int, Int)

    var section: ItemListSectionId {
        switch self {
        case .filter: return 0
        case .header, .empty, .group: return 1
        case .downloadGroups: return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .filter: return 0
        case .header: return 1
        case .empty: return 2
        case let .group(_, group, _, isSelecting):
            // The selection view changes the concrete ListViewItem class.
            // Use a separate ID so ItemList replaces the disclosure node with
            // an interactive checkbox node instead of reusing the old node.
            // The group key keeps the row identity stable when filtering or
            // sorting changes the visible order.
            return fluxgramFavoriteGroupStableId(group.key, selecting: isSelecting)
        // This command belongs to the section after all tag groups. Its ID
        // must sort after selection-mode group IDs or ItemList asserts while
        // applying the section transition.
        case .downloadGroups: return 1_200_000_000
        }
    }

    static func < (lhs: FluxgramFavoriteGroupsEntry, rhs: FluxgramFavoriteGroupsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramFavoriteGroupsArguments
        switch self {
        case let .filter(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "筛选", textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "输入标签、来源或消息", type: .regular(capitalization: false, autocorrection: true), clearType: .always, sectionId: self.section, textUpdated: arguments.updateFilter, action: {})
        case let .header(count):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: count == 0 ? "暂无收藏" : "收藏会话（\(count)）", sectionId: self.section)
        case let .group(_, group, selected, isSelecting):
            let title = group.tags.isEmpty ? "未分类" : group.tags.joined(separator: "、")
            let sourceTitles = Array(Set(group.favorites.map(\.sourceTitle))).sorted()
            let source = sourceTitles.count == 1 ? sourceTitles[0] : "\(sourceTitles.count) 个来源"
            let last = group.favorites.first?.title ?? ""
            if isSelecting {
                return ItemListCheckboxItem(
                    presentationData: presentationData,
                    systemStyle: .glass,
                    title: title,
                    subtitle: "\(group.favorites.count) 条消息 · \(source)\n\(last)",
                    style: .right,
                    checked: selected,
                    zeroSeparatorInsets: false,
                    sectionId: self.section,
                    action: {
                        arguments.toggleGroup(group.key)
                    }
                )
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "\(group.favorites.count) 条消息 · \(source)\n\(last)", labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: { arguments.openGroup(group) })
        case let .empty(text):
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "收藏箱是空的",
                text: .plain(text),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case let .downloadGroups(groupCount, mediaCount):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "下载选中的标签组（\(groupCount) 组，\(mediaCount) 项）",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: arguments.downloadSelectedGroups
            )
        }
    }
}

private final class FluxgramFavoriteGroupsArguments {
    let updateFilter: (String) -> Void
    let openGroup: (FluxgramFavoriteGroup) -> Void
    let toggleGroup: (String) -> Void
    let downloadSelectedGroups: () -> Void

    init(updateFilter: @escaping (String) -> Void, openGroup: @escaping (FluxgramFavoriteGroup) -> Void, toggleGroup: @escaping (String) -> Void, downloadSelectedGroups: @escaping () -> Void) {
        self.updateFilter = updateFilter
        self.openGroup = openGroup
        self.toggleGroup = toggleGroup
        self.downloadSelectedGroups = downloadSelectedGroups
    }
}

private func fluxgramFilteredFavoriteGroups(_ state: FluxgramFavoriteGroupsState) -> [FluxgramFavoriteGroup] {
    let groups = fluxgramFavoriteGroups(state.favorites)
    let filter = state.filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !filter.isEmpty else { return groups }
    return groups.filter { group in
        let value = (group.tags + group.favorites.flatMap { [$0.sourceTitle, $0.title] }).joined(separator: " ")
        return value.range(of: filter, options: .caseInsensitive) != nil
    }
}

public func fluxgramFavoritesController(context: AccountContext) -> ViewController {
    let initialState = FluxgramFavoriteGroupsState(favorites: FluxgramFavoriteStore.favorites(), filter: "", isSelectingGroups: false, selectedGroupKeys: [])
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((FluxgramFavoriteGroupsState) -> FluxgramFavoriteGroupsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    var controller: ItemListController?
    let presentAlert: (String) -> Void = { text in
        let data = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: data), title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: data.strings.Common_OK, action: {})]), in: .window(.root))
    }
    let arguments = FluxgramFavoriteGroupsArguments(updateFilter: { value in
        updateState { state in
            var state = state
            state.filter = value
            return state
        }
    }, openGroup: { group in
        controller?.push(fluxgramFavoriteGroupController(context: context, group: group))
    }, toggleGroup: { key in
        updateState { state in
            var state = state
            if state.selectedGroupKeys.contains(key) {
                state.selectedGroupKeys.remove(key)
            } else {
                state.selectedGroupKeys.insert(key)
            }
            return state
        }
    }, downloadSelectedGroups: {
        let selection = stateValue.with { state -> (favorites: [FluxgramFavoriteMessage], defaultFolder: String?) in
            let groups = fluxgramFilteredFavoriteGroups(state)
            let selectedGroups = groups
                .filter { state.selectedGroupKeys.contains($0.key) }
            let favorites = selectedGroups.flatMap(\.favorites)
            var seen = Set<String>()
            let defaultFolder = selectedGroups
                .map { $0.tags.isEmpty ? "未分类" : $0.tags.joined(separator: "、") }
                .joined(separator: "、")
            return (favorites.filter { seen.insert($0.identifier).inserted }, defaultFolder.isEmpty ? nil : defaultFolder)
        }
        guard !selection.favorites.isEmpty else {
            presentAlert("请先选择至少一个标签组。")
            return
        }
        let messageIds = selection.favorites.map {
            EngineMessage.Id(peerId: EnginePeer.Id($0.dialogId), namespace: Namespaces.Message.Cloud, id: $0.messageId)
        }
        let _ = (context.account.postbox.messagesAtIds(messageIds)
        |> map { messages -> [EngineMessage] in
            messages.map(EngineMessage.init).sorted(by: { $0.index < $1.index })
        }
        |> deliverOnMainQueue).start(next: { messages in
            guard !messages.isEmpty else {
                presentAlert("所选标签组的原消息已不可用。")
                return
            }
            fluxgramRefreshedDownloadRequests(context: context, messages: messages) { requests in
                guard let first = requests.first else {
                    presentAlert("所选标签组中没有可下载的图片或视频。")
                    return
                }
                fluxgramDownloadFolderActionSheet(
                    context: context,
                    dialogId: first.dialogId,
                    messageId: first.messageId,
                    peerAccessHash: nil,
                    directDocument: nil,
                    downloadRequests: requests,
                    defaultDownloadSubdir: selection.defaultFolder,
                    present: { controller?.present($0, in: .window(.root)) }
                )
            }
        })
    })
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramFavoriteGroupsArguments)) in
        let groups = fluxgramFilteredFavoriteGroups(state)
        let rightNavigationButton = ItemListNavigationButton(
            content: .text(state.isSelectingGroups ? "完成" : "选择"),
            style: .regular,
            enabled: true,
            action: {
                updateState { state in
                    var state = state
                    state.isSelectingGroups.toggle()
                    if !state.isSelectingGroups {
                        state.selectedGroupKeys.removeAll()
                    }
                    return state
                }
            }
        )
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("收藏箱"), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: true)
        var entries: [FluxgramFavoriteGroupsEntry] = [.filter(state.filter), .header(groups.count)]
        if groups.isEmpty {
            let emptyText = state.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "在聊天中选择媒体或消息，点击“加入收藏箱”后，它们会按标签整理到这里。"
                : "没有匹配“\(state.filter)”的收藏。可以换个标签、来源或关键词。"
            entries.append(.empty(emptyText))
        } else {
            entries.append(contentsOf: groups.enumerated().map { .group($0.offset, $0.element, state.selectedGroupKeys.contains($0.element.key), state.isSelectingGroups) })
        }
        let selectedGroups = groups.filter { state.selectedGroupKeys.contains($0.key) }
        if state.isSelectingGroups, !selectedGroups.isEmpty {
            let mediaCount = Set(selectedGroups.flatMap(\.favorites).map(\.identifier)).count
            entries.append(.downloadGroups(selectedGroups.count, mediaCount))
        }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}

private struct FluxgramFavoriteGroupState: Equatable {
    var favorites: [FluxgramFavoriteMessage]
    var selectedIdentifiers: Set<String>
}

private enum FluxgramFavoriteGroupEntry: ItemListNodeEntry {
    case header(Int)
    case favorite(Int, FluxgramFavoriteMessage, Bool)
    case download(Int)
    case remove

    var section: ItemListSectionId {
        switch self {
        case .header, .favorite: return 0
        case .download, .remove: return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .favorite(index, _, _): return 100 + Int32(index)
        case .download: return 10_000
        case .remove: return 10_001
        }
    }

    static func < (lhs: FluxgramFavoriteGroupEntry, rhs: FluxgramFavoriteGroupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramFavoriteGroupArguments
        switch self {
        case let .header(count):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "\(count) 条消息", sectionId: self.section)
        case let .favorite(_, favorite, selected):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: "\(favorite.sourceTitle) · \(favorite.title)", subtitle: formatter.string(from: Date(timeIntervalSince1970: favorite.createdAt)), style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.toggle(favorite.identifier) })
        case let .download(count):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "下载选中的 \(count) 项到 NAS", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.download)
        case .remove:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "移除选中收藏", kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: arguments.remove)
        }
    }
}

private final class FluxgramFavoriteGroupArguments {
    let toggle: (String) -> Void
    let download: () -> Void
    let remove: () -> Void

    init(toggle: @escaping (String) -> Void, download: @escaping () -> Void, remove: @escaping () -> Void) {
        self.toggle = toggle
        self.download = download
        self.remove = remove
    }
}

private func fluxgramFavoriteGroupController(context: AccountContext, group: FluxgramFavoriteGroup) -> ViewController {
    let initialState = FluxgramFavoriteGroupState(favorites: group.favorites, selectedIdentifiers: [])
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((FluxgramFavoriteGroupState) -> FluxgramFavoriteGroupState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    var controller: ItemListController?
    let presentAlert: (String) -> Void = { text in
        let data = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: data), title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: data.strings.Common_OK, action: {})]), in: .window(.root))
    }
    let removeSelected: () -> Void = {
        let selected = stateValue.with { $0.selectedIdentifiers }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: data), title: "移除收藏？", text: "这不会删除 Telegram 中的原消息。", actions: [
            TextAlertAction(type: .genericAction, title: data.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: "移除", action: {
                FluxgramFavoriteStore.remove(identifiers: selected)
                _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
            })
        ]), in: .window(.root))
    }
    let downloadSelected: () -> Void = {
        let selected = stateValue.with { state in state.favorites.filter { state.selectedIdentifiers.contains($0.identifier) } }
        let ids = selected.map { EngineMessage.Id(peerId: EnginePeer.Id($0.dialogId), namespace: Namespaces.Message.Cloud, id: $0.messageId) }
        let _ = (context.account.postbox.messagesAtIds(ids)
        |> map { messages -> [EngineMessage] in messages.map(EngineMessage.init).sorted(by: { $0.index < $1.index }) }
        |> deliverOnMainQueue).start(next: { messages in
            guard !messages.isEmpty else { presentAlert("所选收藏的原消息已不可用。"); return }
            fluxgramRefreshedDownloadRequests(context: context, messages: messages) { requests in
                guard let first = requests.first else { presentAlert("所选收藏中没有可下载的图片或视频。"); return }
                fluxgramDownloadFolderActionSheet(context: context, dialogId: first.dialogId, messageId: first.messageId, peerAccessHash: nil, directDocument: nil, downloadRequests: requests, present: { controller?.present($0, in: .window(.root)) })
            }
        })
    }
    let arguments = FluxgramFavoriteGroupArguments(
        toggle: { identifier in
            updateState { state in
                var state = state
                if state.selectedIdentifiers.contains(identifier) { state.selectedIdentifiers.remove(identifier) } else { state.selectedIdentifiers.insert(identifier) }
                return state
            }
        },
        download: downloadSelected,
        remove: removeSelected
    )
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramFavoriteGroupArguments)) in
        let title = group.tags.isEmpty ? "未分类" : group.tags.joined(separator: "、")
        var entries: [FluxgramFavoriteGroupEntry] = [.header(state.favorites.count)]
        entries.append(contentsOf: state.favorites.enumerated().map { .favorite($0.offset, $0.element, state.selectedIdentifiers.contains($0.element.identifier)) })
        if !state.selectedIdentifiers.isEmpty { entries.append(.download(state.selectedIdentifiers.count)); entries.append(.remove) }
        let allIdentifiers = Set(state.favorites.map(\.identifier))
        let rightNavigationButton = ItemListNavigationButton(
            content: .text(state.selectedIdentifiers == allIdentifiers && !allIdentifiers.isEmpty ? "取消全选" : "全选"),
            style: .regular,
            enabled: !allIdentifiers.isEmpty,
            action: {
                updateState { state in
                    var state = state
                    state.selectedIdentifiers = state.selectedIdentifiers == allIdentifiers ? [] : allIdentifiers
                    return state
                }
            }
        )
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: true)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}
