import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext
import TinyThumbnail

private struct FluxgramGlobalSearchState: Equatable {
    var query: String
    var filter: FluxgramGlobalSearchFilter
    var messages: [Message]
    var favorites: [FluxgramFavoriteMessage]
    var downloads: [FluxgramNASDownloadJob]
    var learning: [FluxgramDownloadMemoryEntry]
    var thumbnails: [String: Data]
    var isSearchingMessages: Bool

    static func == (lhs: FluxgramGlobalSearchState, rhs: FluxgramGlobalSearchState) -> Bool {
        return lhs.query == rhs.query
            && lhs.filter == rhs.filter
            && lhs.messages.map(\.id) == rhs.messages.map(\.id)
            && lhs.favorites == rhs.favorites
            && lhs.downloads == rhs.downloads
            && lhs.learning == rhs.learning
            && lhs.thumbnails == rhs.thumbnails
            && lhs.isSearchingMessages == rhs.isSearchingMessages
    }
}

private enum FluxgramGlobalSearchFilter: Int32, CaseIterable, Equatable {
    case all = 0
    case messages = 1
    case favorites = 2
    case downloads = 3
    case learning = 4

    var title: String {
        switch self {
        case .all: return "全部"
        case .messages: return "聊天消息"
        case .favorites: return "收藏箱"
        case .downloads: return "NAS 下载"
        case .learning: return "AI 学习"
        }
    }
}

private final class FluxgramGlobalSearchArguments {
    let openMessage: (Int64, Int32) -> Void
    let openFluxTok: (String) -> Void
    let updateQuery: (String) -> Void
    let updateFilter: (FluxgramGlobalSearchFilter) -> Void

    init(openMessage: @escaping (Int64, Int32) -> Void, openFluxTok: @escaping (String) -> Void, updateQuery: @escaping (String) -> Void, updateFilter: @escaping (FluxgramGlobalSearchFilter) -> Void) {
        self.openMessage = openMessage
        self.openFluxTok = openFluxTok
        self.updateQuery = updateQuery
        self.updateFilter = updateFilter
    }
}

private enum FluxgramGlobalSearchEntry: ItemListNodeEntry {
    case query(String)
    case filter(FluxgramGlobalSearchFilter, Bool)
    case status(String)
    case section(Int32, String, Int)
    case message(Int, Message)
    case favorite(Int, FluxgramFavoriteMessage)
    case download(Int, FluxgramNASDownloadJob, Data?)
    case learning(Int, FluxgramDownloadMemoryEntry)
    case empty(String)

    var section: ItemListSectionId {
        switch self {
        case .query:
            return 0
        case .filter, .status, .empty:
            return 1
        case .section, .message, .favorite, .download, .learning:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .query:
            return 0
        case let .filter(filter, _):
            return 3 + filter.rawValue
        case .status:
            return 8
        case .empty:
            return 9
        case let .section(id, _, _):
            // Keep each section header immediately before its items. ItemList
            // asserts that entries are strictly sorted by stable ID.
            return 10 + id * 1_000
        case let .message(index, _):
            return 100 + Int32(index)
        case let .favorite(index, _):
            return 1_100 + Int32(index)
        case let .download(index, _, _):
            return 2_100 + Int32(index)
        case let .learning(index, _):
            return 3_100 + Int32(index)
        }
    }

    static func < (lhs: FluxgramGlobalSearchEntry, rhs: FluxgramGlobalSearchEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: FluxgramGlobalSearchEntry, rhs: FluxgramGlobalSearchEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.query(lhsValue), .query(rhsValue)):
            // Keep the existing text field node, while allowing its item to
            // receive the latest value without writing stale text back.
            return lhsValue == rhsValue
        case let (.filter(lhsFilter, lhsSelected), .filter(rhsFilter, rhsSelected)):
            return lhsFilter == rhsFilter && lhsSelected == rhsSelected
        case let (.status(lhsValue), .status(rhsValue)):
            return lhsValue == rhsValue
        case let (.section(lhsId, lhsTitle, lhsCount), .section(rhsId, rhsTitle, rhsCount)):
            return lhsId == rhsId && lhsTitle == rhsTitle && lhsCount == rhsCount
        case let (.message(_, lhsMessage), .message(_, rhsMessage)):
            return lhsMessage.id == rhsMessage.id && lhsMessage.text == rhsMessage.text
        case let (.favorite(_, lhsFavorite), .favorite(_, rhsFavorite)):
            return lhsFavorite == rhsFavorite
        case let (.download(_, lhsJob, lhsThumbnail), .download(_, rhsJob, rhsThumbnail)):
            return lhsJob == rhsJob && lhsThumbnail == rhsThumbnail
        case let (.learning(_, lhsEntry), .learning(_, rhsEntry)):
            return lhsEntry == rhsEntry
        case let (.empty(lhsValue), .empty(rhsValue)):
            return lhsValue == rhsValue
        default:
            return false
        }
    }
}

private func fluxgramGlobalSearchTextMatches(_ query: String, _ values: [String]) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
        return false
    }
    return values.contains { value in
        value.localizedCaseInsensitiveContains(normalizedQuery)
    }
}

private func fluxgramGlobalSearchMessageTitle(_ message: Message) -> (String, String) {
    let source = message.peers[message.id.peerId]?.debugDisplayTitle ?? "未知会话"
    let text = message.text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = text.isEmpty ? "媒体或无文字消息" : String(text.prefix(90))
    return (title, source)
}

private func fluxgramGlobalSearchThumbnailKey(_ job: FluxgramNASDownloadJob) -> String {
    if !job.id.isEmpty {
        return job.id
    }
    return "\(job.fileName)|\(job.sourceDialogId ?? 0)|\(job.sourceRootMessageId ?? job.sourceMessageId ?? 0)"
}

private func fluxgramGlobalSearchLocalThumbnail(context: AccountContext, job: FluxgramNASDownloadJob) -> Signal<Data?, NoError> {
    guard let dialogId = job.sourceDialogId else {
        return .single(nil)
    }
    let peerId = PeerId(dialogId)
    var ids: [MessageId] = []
    if let rootMessageId = job.sourceRootMessageId {
        ids.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: rootMessageId))
    }
    if let messageId = job.sourceMessageId,
       !ids.contains(where: { $0.id == messageId }) {
        ids.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId))
    }
    guard !ids.isEmpty else {
        return .single(nil)
    }
    return context.engine.messages.getMessagesLoadIfNecessary(ids, strategy: .cloud(skipLocal: false))
    |> mapToSignal { result -> Signal<Data?, GetMessagesError> in
        switch result {
        case .progress:
            return .never()
        case let .result(messages):
            for message in messages {
                if let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first,
                   let data = file.immediateThumbnailData {
                    return .single(data)
                }
                if let image = message.media.compactMap({ $0 as? TelegramMediaImage }).first,
                   let data = image.immediateThumbnailData {
                    return .single(data)
                }
            }
            return .single(nil)
        }
    }
    |> `catch` { _ -> Signal<Data?, NoError> in
        return .single(nil)
    }
}

private func fluxgramGlobalSearchEntries(state: FluxgramGlobalSearchState) -> [FluxgramGlobalSearchEntry] {
    // The node is retained by the stable ID; the value is still propagated so
    // list updates never restore a stale empty string over live input.
    var entries: [FluxgramGlobalSearchEntry] = [.query(state.query)]
    let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !query.isEmpty else {
        entries.append(.empty("搜索聊天消息、收藏箱、NAS 下载记录和 AI 学习记录。"))
        return entries
    }

    entries.append(contentsOf: FluxgramGlobalSearchFilter.allCases.map { .filter($0, $0 == state.filter) })

    if state.isSearchingMessages {
        entries.append(.status("正在搜索 Telegram 消息…"))
    }

    var resultCount = 0
    if (state.filter == .all || state.filter == .messages) && !state.messages.isEmpty {
        entries.append(.section(0, "聊天消息", state.messages.count))
        entries.append(contentsOf: state.messages.enumerated().map { .message($0.offset, $0.element) })
        resultCount += state.messages.count
    }
    if (state.filter == .all || state.filter == .favorites) && !state.favorites.isEmpty {
        entries.append(.section(1, "收藏箱", state.favorites.count))
        entries.append(contentsOf: state.favorites.enumerated().map { .favorite($0.offset, $0.element) })
        resultCount += state.favorites.count
    }
    if (state.filter == .all || state.filter == .downloads) && !state.downloads.isEmpty {
        entries.append(.section(2, "NAS 下载", state.downloads.count))
        entries.append(contentsOf: state.downloads.enumerated().map { item in
            let job = item.element
            return .download(item.offset, job, state.thumbnails[fluxgramGlobalSearchThumbnailKey(job)])
        })
        resultCount += state.downloads.count
    }
    if (state.filter == .all || state.filter == .learning) && !state.learning.isEmpty {
        entries.append(.section(3, "AI 学习记录", state.learning.count))
        entries.append(contentsOf: state.learning.enumerated().map { .learning($0.offset, $0.element) })
        resultCount += state.learning.count
    }
    if resultCount == 0 && !state.isSearchingMessages {
        entries.append(.empty("没有找到匹配内容。可以试试作者名、番号、标题或标签。"))
    }
    return entries
}

private extension FluxgramGlobalSearchEntry {
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramGlobalSearchArguments
        switch self {
        case let .query(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "搜索", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "搜索聊天、收藏、下载和学习记录",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: arguments.updateQuery,
                action: {}
            )
        case let .filter(filter, selected):
            return ItemListCheckboxItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: filter.title,
                style: .right,
                checked: selected,
                zeroSeparatorInsets: false,
                sectionId: self.section,
                action: { arguments.updateFilter(filter) }
            )
        case let .status(text), let .empty(text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section,
                style: .blocks,
                textSize: .generic,
                textAlignment: .natural
            )
        case let .section(_, title, count):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: "\(title) · \(count)",
                sectionId: self.section
            )
        case let .message(_, message):
            let (title, source) = fluxgramGlobalSearchMessageTitle(message)
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: source,
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: { arguments.openMessage(message.id.peerId.toInt64(), message.id.id) }
            )
        case let .favorite(_, favorite):
            let label = favorite.tags.isEmpty ? favorite.sourceTitle : favorite.tags.joined(separator: "、")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: favorite.title,
                label: label,
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: { arguments.openMessage(favorite.dialogId, favorite.messageId) }
            )
        case let .download(_, job, cachedThumbnail):
            let label = job.detail.isEmpty ? "NAS 下载记录" : job.detail
            let playbackPath = job.fluxTokRelativePath
            let thumbnail = fluxgramDownloadThumbnail(job.thumbnailData ?? cachedThumbnail)
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: thumbnail,
                title: job.title,
                label: label,
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: playbackPath == nil ? .none : .arrow,
                action: playbackPath.map { path in
                    { arguments.openFluxTok(path) }
                }
            )
        case let .learning(_, entry):
            let title = entry.author.isEmpty ? (entry.title.isEmpty ? "未命名案例" : entry.title) : entry.author
            let label = [entry.title, entry.tags.joined(separator: "、")].filter { !$0.isEmpty }.joined(separator: " · ")
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: label.isEmpty ? "AI 学习案例" : label,
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: nil
            )
        }
    }
}

public func fluxgramGlobalSearchController(context: AccountContext, openMessage: @escaping (Int64, Int32) -> Void) -> ViewController {
    var controller: ItemListController?
    var searchDisposable: Disposable?
    var searchTimer: SwiftSignalKit.Timer?
    var searchGeneration = 0
    var cachedDownloads: [FluxgramNASDownloadJob] = []
    var thumbnailDisposables: [Disposable] = []
    let initialState = FluxgramGlobalSearchState(query: "", filter: .all, messages: [], favorites: [], downloads: [], learning: [], thumbnails: [:], isSearchingMessages: false)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)

    let updateState: (@escaping (FluxgramGlobalSearchState) -> FluxgramGlobalSearchState) -> Void = { update in
        let state = stateValue.modify(update)
        statePromise.set(state)
    }

    let updateQuery: (String) -> Void = { query in
        searchGeneration += 1
        let generation = searchGeneration
        searchTimer?.invalidate()
        searchTimer = nil
        searchDisposable?.dispose()
        searchDisposable = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allFavorites = FluxgramFavoriteStore.favorites()
        let allLearning = FluxgramDownloadMemoryStore.allEntries()
        let favoriteMatches = allFavorites.filter { favorite in
            fluxgramGlobalSearchTextMatches(trimmed, [favorite.sourceTitle, favorite.title] + favorite.tags)
        }
        let learningMatches = allLearning.filter { entry in
            fluxgramGlobalSearchTextMatches(trimmed, [entry.sourceLabel, entry.sourceText, entry.author, entry.title] + entry.tags)
        }
        let downloads = cachedDownloads.filter { job in
            fluxgramGlobalSearchTextMatches(trimmed, [job.fileName, job.downloadSubdir, job.requestedTitle, job.sourceLabel, job.outputFile, job.sourceTitle, job.sourceText, job.note] + job.tags)
        }
        updateState { state in
            var state = state
            state.query = query
            state.messages = []
            state.favorites = trimmed.isEmpty ? [] : favoriteMatches
            state.downloads = trimmed.isEmpty ? [] : downloads
            state.learning = trimmed.isEmpty ? [] : learningMatches
            state.isSearchingMessages = !trimmed.isEmpty
            return state
        }

        guard !trimmed.isEmpty else {
            return
        }

        searchTimer = SwiftSignalKit.Timer(timeout: 0.25, repeat: false, completion: {
            guard generation == searchGeneration else {
                return
            }
            let signal = context.engine.messages.searchMessages(
                location: .general(scope: .everywhere, groupId: nil, tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil),
                query: trimmed,
                state: nil,
                limit: 40
            )
            searchDisposable = (signal
            |> take(1)
            |> deliverOnMainQueue).start(next: { result, _ in
                guard generation == searchGeneration else {
                    return
                }
                updateState { state in
                    var state = state
                    state.messages = result.messages
                    state.isSearchingMessages = false
                    return state
                }
            })
            searchTimer = nil
        }, queue: Queue.mainQueue())
        searchTimer?.start()
    }

    let updateFilter: (FluxgramGlobalSearchFilter) -> Void = { filter in
        updateState { state in
            var state = state
            state.filter = filter
            return state
        }
    }

    let openFluxTok: (String) -> Void = { path in
        var components = URLComponents()
        components.scheme = "nastok"
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            controller?.present(
                standardTextAlertController(
                    theme: AlertControllerTheme(presentationData: presentationData),
                    title: nil,
                    text: "未检测到 FluxTok。请确认已安装最新版本。",
                    actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                ),
                in: .window(.root)
            )
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    let arguments = FluxgramGlobalSearchArguments(openMessage: openMessage, openFluxTok: openFluxTok, updateQuery: updateQuery, updateFilter: updateFilter)

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramGlobalSearchArguments)) in
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(
            presentationData: itemListPresentationData,
            title: .text("全局搜索"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: true
        )
        let listState = ItemListNodeState(
            presentationData: itemListPresentationData,
            entries: fluxgramGlobalSearchEntries(state: state),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let result = ItemListController(context: context, state: signal)
    controller = result
    result.didAppear = { _ in
        FluxgramNASService.shared.fetchDownloads { snapshot, _ in
            guard let snapshot else {
                return
            }
            let allJobs = snapshot.active + snapshot.history
            cachedDownloads = allJobs
            let query = stateValue.with { $0.query }
            let downloads = cachedDownloads.filter { job in
                fluxgramGlobalSearchTextMatches(query, [job.fileName, job.downloadSubdir, job.requestedTitle, job.sourceLabel, job.outputFile, job.sourceTitle, job.sourceText, job.note] + job.tags)
            }
            updateState { state in
                var state = state
                state.downloads = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : downloads
                return state
            }
            thumbnailDisposables.forEach { $0.dispose() }
            thumbnailDisposables.removeAll()
            for job in allJobs.prefix(20) where job.thumbnailData == nil && job.sourceDialogId != nil && (job.sourceRootMessageId != nil || job.sourceMessageId != nil) {
                let disposable = (fluxgramGlobalSearchLocalThumbnail(context: context, job: job)
                |> deliverOnMainQueue).start(next: { data in
                    guard let data else { return }
                    updateState { state in
                        var state = state
                        state.thumbnails[fluxgramGlobalSearchThumbnailKey(job)] = data
                        return state
                    }
                })
                thumbnailDisposables.append(disposable)
            }
        }
    }
    result.willDisappear = { _ in
        searchTimer?.invalidate()
        searchTimer = nil
        searchDisposable?.dispose()
        searchDisposable = nil
        thumbnailDisposables.forEach { $0.dispose() }
        thumbnailDisposables.removeAll()
    }

    return result
}
