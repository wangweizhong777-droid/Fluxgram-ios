import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore
import GalleryUI

public struct FluxgramShortVideoSource: Codable, Equatable {
    public var dialogId: Int64
    public var title: String
    public var enabled: Bool
    public var durationLimit: Int32

    public init(dialogId: Int64, title: String, enabled: Bool = true, durationLimit: Int32 = 60) {
        self.dialogId = dialogId
        self.title = title
        self.enabled = enabled
        self.durationLimit = min(max(durationLimit, 15), 600)
    }
}

public enum FluxgramShortVideoStore {
    private static let key = "com.fluxgram.ios.short-video-sources.v1"

    public static func sources() -> [FluxgramShortVideoSource] {
        guard let data = UserDefaults.standard.data(forKey: self.key),
              let sources = try? JSONDecoder().decode([FluxgramShortVideoSource].self, from: data) else {
            return []
        }
        return sources
    }

    public static func save(_ sources: [FluxgramShortVideoSource]) {
        guard let data = try? JSONEncoder().encode(sources) else {
            return
        }
        UserDefaults.standard.set(data, forKey: self.key)
        FluxgramShortVideoFeedCache.clear()
    }

    @discardableResult
    public static func add(dialogId: Int64, title: String) -> Bool {
        var sources = self.sources()
        if let index = sources.firstIndex(where: { $0.dialogId == dialogId }) {
            sources[index].title = title.isEmpty ? sources[index].title : title
            sources[index].enabled = true
            self.save(sources)
            return false
        }
        sources.append(FluxgramShortVideoSource(dialogId: dialogId, title: title))
        self.save(sources)
        return true
    }
}

private enum FluxgramShortVideoFeedCache {
    private struct Entry {
        let createdAt: TimeInterval
        let messages: [EngineRawMessage]
        let featuredMessageIds: Set<EngineMessage.Id>
    }

    private static let lifetime: TimeInterval = 10.0 * 60.0
    private static let entries = Atomic(value: [String: Entry]())
    private static let recentFirstMessageIds = Atomic(value: [String: [EngineMessage.Id]]())

    private static func key(for sources: [FluxgramShortVideoSource]) -> String {
        return sources
            .sorted { $0.dialogId < $1.dialogId }
            .map { "\($0.dialogId):\($0.enabled):\($0.durationLimit)" }
            .joined(separator: "|")
    }

    static func messages(for sources: [FluxgramShortVideoSource]) -> [EngineRawMessage]? {
        let key = self.key(for: sources)
        return self.entries.with { entries in
            guard let entry = entries[key], Date().timeIntervalSince1970 - entry.createdAt < self.lifetime else {
                return nil
            }
            // Keep the most recently scanned page at the front. Older media is
            // still shuffled on every open, preserving a varied feed without
            // burying new channel posts behind the historical pool.
            let featured = entry.messages.filter { entry.featuredMessageIds.contains($0.id) }.shuffled()
            let historical = entry.messages.filter { !entry.featuredMessageIds.contains($0.id) }.shuffled()
            var ordered = featured + historical
            let recentFirstIds = Set(self.recentFirstMessageIds.with { $0[key] ?? [] })
            if let first = ordered.first, recentFirstIds.contains(first.id) {
                let preferredCount = featured.isEmpty ? ordered.count : featured.count
                if let index = ordered.indices.first(where: { $0 < preferredCount && !recentFirstIds.contains(ordered[$0].id) }) {
                    ordered.swapAt(0, index)
                }
            }
            if let first = ordered.first {
                _ = self.recentFirstMessageIds.modify { values in
                    var values = values
                    var recent = values[key] ?? []
                    recent.removeAll { $0 == first.id }
                    recent.append(first.id)
                    values[key] = Array(recent.suffix(8))
                    return values
                }
            }
            return ordered
        }
    }

    static func store(_ messages: [EngineRawMessage], featuredMessages: [EngineRawMessage], for sources: [FluxgramShortVideoSource]) {
        let key = self.key(for: sources)
        _ = self.entries.modify { entries in
            var entries = entries
            entries[key] = Entry(
                createdAt: Date().timeIntervalSince1970,
                messages: messages,
                featuredMessageIds: Set(featuredMessages.map(\.id))
            )
            return entries
        }
        _ = self.recentFirstMessageIds.modify { values in
            var values = values
            values[key] = []
            return values
        }
    }

    static func clear() {
        _ = self.entries.modify { _ in [:] }
        _ = self.recentFirstMessageIds.modify { _ in [:] }
    }
}

private enum FluxgramShortVideoHistoryCursor {
    private static let key = "com.fluxgram.ios.short-video-history-cursors.v1"
    private static let latestPageCount = 2
    private static let historicalPageCount = 10
    private static let maximumHistoricalStartPage = 22

    static func startPage(for dialogId: Int64) -> Int {
        let values = load()
        return min(max(values[String(dialogId)] ?? latestPageCount, latestPageCount), maximumHistoricalStartPage)
    }

    static func advance(dialogId: Int64, reachedEnd: Bool) {
        var values = load()
        let current = startPage(for: dialogId)
        values[String(dialogId)] = reachedEnd || current >= maximumHistoricalStartPage
            ? latestPageCount
            : current + historicalPageCount
        save(values)
    }

    private static func load() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func save(_ values: [String: Int]) {
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private func fluxgramShortVideoDirectDocument(message: EngineRawMessage) -> FluxgramNASDirectDocument? {
    guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVideo || $0.isInstantVideo }),
          let resource = file.resource as? CloudDocumentMediaResource,
          let fileReference = resource.fileReference,
          !fileReference.isEmpty else {
        return nil
    }
    return FluxgramNASDirectDocument(
        documentId: String(resource.fileId),
        accessHash: String(resource.accessHash),
        fileReference: fileReference.base64EncodedString(),
        fileName: resource.fileName ?? file.fileName ?? "telegram-video-\(resource.fileId).mp4",
        fileSize: resource.size ?? file.size ?? 0
    )
}

private struct FluxgramShortVideoControllerState: Equatable {
    var sources: [FluxgramShortVideoSource]
    var isScanning: Bool
    var status: String
    var updatedMessageCount: Int
}

private enum FluxgramShortVideoSection: Int32 {
    case playback
    case sources
    case help
}

private func fluxgramShortVideoStableId(for dialogId: Int64) -> Int32 {
    var hash: UInt32 = 2_166_136_261
    for byte in String(dialogId).utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return 100 + Int32(hash % 900_000_000)
}

private enum FluxgramShortVideoEntry: ItemListNodeEntry {
    case play(Bool)
    case refresh
    case addSource
    case updated(Int)
    case sourcesHeader
    case source(Int, FluxgramShortVideoSource)
    case help
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .play, .refresh, .addSource, .updated:
            return FluxgramShortVideoSection.playback.rawValue
        case .sourcesHeader, .source:
            return FluxgramShortVideoSection.sources.rawValue
        case .help, .status:
            return FluxgramShortVideoSection.help.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .play:
            return 0
        case .refresh:
            return 1
        case .addSource:
            return 2
        case .updated:
            return 3
        case .sourcesHeader:
            return 4
        case let .source(_, source):
            return fluxgramShortVideoStableId(for: source.dialogId)
        case .help:
            return 1_000_000_000
        case .status:
            return 1_000_000_001
        }
    }

    static func < (lhs: FluxgramShortVideoEntry, rhs: FluxgramShortVideoEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramShortVideoControllerArguments
        switch self {
        case let .play(isScanning):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: isScanning ? "正在加载短视频..." : "播放短视频流",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.play()
                }
            )
        case .addSource:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "添加频道或群组",
                label: "选择短视频来源",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.addSource()
                }
            )
        case let .updated(count):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "查看本次更新（\(count) 个视频）",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.viewUpdated()
                }
            )
        case .refresh:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "重新扫描来源",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.refresh()
                }
            )
        case .sourcesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "短视频来源", sectionId: self.section)
        case let .source(_, source):
            let state = source.enabled ? "已启用" : "已暂停"
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: source.title.isEmpty ? "会话 \(source.dialogId)" : source.title,
                label: "\(state) · 最长 \(source.durationLimit) 秒",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.edit(source)
                }
            )
        case .help:
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("仅扫描你手动添加的 Telegram 频道和群组。视频不上传到 NAS，播放使用 Telegram 当前播放器。"),
                sectionId: self.section
            )
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class FluxgramShortVideoControllerArguments {
    let play: () -> Void
    let refresh: () -> Void
    let addSource: () -> Void
    let edit: (FluxgramShortVideoSource) -> Void
    let viewUpdated: () -> Void

    init(play: @escaping () -> Void, refresh: @escaping () -> Void, addSource: @escaping () -> Void, edit: @escaping (FluxgramShortVideoSource) -> Void, viewUpdated: @escaping () -> Void) {
        self.play = play
        self.refresh = refresh
        self.addSource = addSource
        self.edit = edit
        self.viewUpdated = viewUpdated
    }
}

private func fluxgramShortVideoEntries(_ state: FluxgramShortVideoControllerState) -> [FluxgramShortVideoEntry] {
    var entries: [FluxgramShortVideoEntry] = [.play(state.isScanning), .refresh, .addSource]
    if state.updatedMessageCount > 0 {
        entries.append(.updated(state.updatedMessageCount))
    }
    entries.append(.sourcesHeader)
    let orderedSources = state.sources.sorted { lhs, rhs in
        let lhsID = fluxgramShortVideoStableId(for: lhs.dialogId)
        let rhsID = fluxgramShortVideoStableId(for: rhs.dialogId)
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        return lhs.dialogId < rhs.dialogId
    }
    for (index, source) in orderedSources.enumerated() {
        entries.append(.source(index, source))
    }
    entries.append(.help)
    if !state.status.isEmpty {
        entries.append(.status(state.status))
    }
    return entries
}

private func fluxgramShortVideoCandidates(_ message: EngineRawMessage, limit: Int32) -> Bool {
    for media in message.media {
        guard let file = media as? TelegramMediaFile else {
            continue
        }
        guard (file.isVideo || file.isInstantVideo), !file.isAnimated, !file.isSticker, !file.isVideoSticker else {
            continue
        }
        guard let duration = file.duration, duration > 0.0, duration <= Double(limit) else {
            continue
        }
        return true
    }
    return false
}

private func fluxgramShortVideoScanSummary(prefix: String, messages: [EngineRawMessage]) -> String {
    guard let latestTimestamp = messages.map(\.timestamp).max() else {
        return "\(prefix)：符合条件的视频 0 个，最新日期：无"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    let latestDate = formatter.string(from: Date(timeIntervalSince1970: Double(latestTimestamp)))
    return "\(prefix)：符合条件的视频 \(messages.count) 个，最新日期：\(latestDate)"
}

private enum FluxgramShortVideoPlaybackHistory {
    private static let key = "com.fluxgram.ios.short-video-playback-history.v1"
    private static let maximumCount = 3_000

    private static func messageKey(_ message: EngineRawMessage) -> String {
        return "\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id)"
    }

    static func markPlayed(_ message: EngineRawMessage) {
        let key = self.messageKey(message)
        var values = UserDefaults.standard.stringArray(forKey: self.key) ?? []
        values.removeAll { $0 == key }
        values.append(key)
        if values.count > self.maximumCount {
            values.removeFirst(values.count - self.maximumCount)
        }
        UserDefaults.standard.set(values, forKey: self.key)
    }

    static func prioritize(_ messages: [EngineRawMessage]) -> [EngineRawMessage] {
        let played = Set(UserDefaults.standard.stringArray(forKey: self.key) ?? [])
        let unplayedMessages = messages.filter { !played.contains(self.messageKey($0)) }.shuffled()
        let playedMessages = messages.filter { played.contains(self.messageKey($0)) }.shuffled()
        return unplayedMessages + playedMessages
    }
}

private final class FluxgramShortVideoScanner {
    private let context: AccountContext
    private let sources: [FluxgramShortVideoSource]
    private let rotatingHistory: Bool
    private let pageLimitOverride: Int?
    private let disposable = MetaDisposable()
    private var sourceIndex = 0
    private var candidates: [[EngineRawMessage]] = []
    private var latestCandidates: [[EngineRawMessage]] = []
    private var sourceMessages: [EngineRawMessage] = []
    private var sourceLatestMessages: [EngineRawMessage] = []
    private var sourceMessageIds: Set<EngineMessage.Id> = []
    private var pageLimit = 5
    private var currentPage = 0
    private var historicalStartPage = 0
    private var nextState: SearchMessagesState?
    private let completion: ([[EngineRawMessage]], [[EngineRawMessage]]) -> Void

    init(context: AccountContext, sources: [FluxgramShortVideoSource], rotatingHistory: Bool, pageLimitOverride: Int? = nil, completion: @escaping ([[EngineRawMessage]], [[EngineRawMessage]]) -> Void) {
        self.context = context
        self.sources = sources
        self.rotatingHistory = rotatingHistory
        self.pageLimitOverride = pageLimitOverride
        self.completion = completion
    }

    func start() {
        self.scanNextSource()
    }

    func cancel() {
        self.disposable.dispose()
    }

    private func scanNextSource() {
        guard self.sourceIndex < self.sources.count else {
            self.completion(self.candidates, self.latestCandidates)
            return
        }
        self.sourceMessages = []
        self.sourceLatestMessages = []
        self.sourceMessageIds = []
        self.currentPage = 0
        self.historicalStartPage = self.rotatingHistory
            ? FluxgramShortVideoHistoryCursor.startPage(for: self.sources[self.sourceIndex].dialogId)
            : 0
        self.pageLimit = self.pageLimitOverride ?? (self.rotatingHistory ? self.historicalStartPage + 10 : 5)
        self.nextState = nil
        self.scanPage()
    }

    private func scanPage() {
        let source = self.sources[self.sourceIndex]
        let signal = self.context.engine.messages.searchMessages(
            location: .peer(peerId: EnginePeer.Id(source.dialogId), fromId: nil, tags: .video, reactions: nil, threadId: nil, minDate: nil, maxDate: nil),
            query: "",
            state: self.nextState,
            limit: 100
        )
        self.disposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] result, state in
            guard let self else {
                return
            }
            let shouldCollectPage = !self.rotatingHistory
                || self.currentPage < 2
                || self.currentPage >= self.historicalStartPage
            if shouldCollectPage {
                for message in result.messages where self.sourceMessageIds.insert(message.id).inserted {
                    if fluxgramShortVideoCandidates(message, limit: source.durationLimit) {
                        self.sourceMessages.append(message)
                        if self.currentPage == 0 {
                            self.sourceLatestMessages.append(message)
                        }
                    }
                }
            }
            self.currentPage += 1
            self.nextState = state
            if self.currentPage < self.pageLimit && !result.completed {
                self.scanPage()
            } else {
                if self.rotatingHistory {
                    FluxgramShortVideoHistoryCursor.advance(dialogId: source.dialogId, reachedEnd: result.completed)
                }
                self.candidates.append(self.sourceMessages.shuffled())
                self.latestCandidates.append(self.sourceLatestMessages)
                self.sourceIndex += 1
                self.scanNextSource()
            }
        }))
    }
}

private func fluxgramInterleavedShortVideos(_ sources: [[EngineRawMessage]]) -> [EngineRawMessage] {
    var queues = sources.filter { !$0.isEmpty }.map { $0.shuffled() }
    var result: [EngineRawMessage] = []
    var lastSource = -1
    while !queues.isEmpty {
        let choices = queues.indices.filter { queues.count == 1 || $0 != lastSource }
        guard let sourceIndex = choices.randomElement(), !queues[sourceIndex].isEmpty else { break }
        // Each queue is already shuffled. Popping from the end keeps random
        // interleaving linear instead of shifting an array on every selection.
        result.append(queues[sourceIndex].removeLast())
        lastSource = sourceIndex
        if queues[sourceIndex].isEmpty {
            queues.remove(at: sourceIndex)
            if lastSource >= queues.count { lastSource = -1 }
        }
    }
    return result
}

public func fluxgramShortVideoController(context: AccountContext) -> ViewController {
    let initialState = FluxgramShortVideoControllerState(sources: FluxgramShortVideoStore.sources(), isScanning: false, status: "", updatedMessageCount: 0)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((FluxgramShortVideoControllerState) -> FluxgramShortVideoControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var controller: ItemListController?
    var scanner: FluxgramShortVideoScanner?
    var updatedMessages: [EngineRawMessage] = []
    let presentAlert: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: presentationData), title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }
    let persistSources: ([FluxgramShortVideoSource]) -> Void = { sources in
        FluxgramShortVideoStore.save(sources)
        updateState { state in
            var state = state
            state.sources = sources
            return state
        }
    }
    let openFeed: ([EngineRawMessage]) -> Void = { candidates in
        let feed = FluxgramShortVideoFeedController(context: context, messages: FluxgramShortVideoPlaybackHistory.prioritize(candidates))
        feed.messageViewed = { message in
            FluxgramShortVideoPlaybackHistory.markPlayed(message)
        }
        feed.downloadRequested = { [weak feed] message in
            fluxgramDownloadFolderActionSheet(
                context: context,
                dialogId: message.id.peerId.toInt64(),
                messageId: message.id.id,
                peerAccessHash: nil,
                directDocument: fluxgramShortVideoDirectDocument(message: message),
                present: { controller in
                    feed?.present(controller, in: .window(.root))
                }
            )
        }
        feed.sourceMessageRequested = { [weak feed] message in
            guard let feed, let navigationController = feed.navigationController as? NavigationController,
                  let peer = message.peers[message.id.peerId] else {
                return
            }
            context.sharedContext.navigateToChatController(
                NavigateToChatControllerParams(
                    navigationController: navigationController,
                    context: context,
                    chatLocation: .peer(EnginePeer(peer)),
                    subject: .message(id: .id(message.id), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false),
                    keepStack: .always,
                    useExisting: false
                )
            )
        }
        controller?.push(feed)
    }

    var startPlayback: ((Bool) -> Void)!
    startPlayback = { forceScan in
        let enabledSources = stateValue.with { $0.sources.filter(\.enabled) }
        guard !enabledSources.isEmpty else {
            presentAlert("请先添加并启用至少一个频道或群组。")
            return
        }
        guard !stateValue.with({ $0.isScanning }) else {
            return
        }
        let cachedCandidates = FluxgramShortVideoFeedCache.messages(for: enabledSources)
        if !forceScan, let cachedCandidates, !cachedCandidates.isEmpty {
            updateState {
                var state = $0
                state.status = fluxgramShortVideoScanSummary(prefix: "已使用缓存", messages: cachedCandidates)
                return state
            }
            openFeed(cachedCandidates)
            return
        }
        updateState {
            var state = $0
            state.isScanning = true
            state.status = forceScan
                ? "正在读取 \(enabledSources.count) 个来源的最新视频..."
                : "正在快速读取 \(enabledSources.count) 个来源..."
            return state
        }
        scanner = FluxgramShortVideoScanner(
            context: context,
            sources: enabledSources,
            rotatingHistory: false,
            pageLimitOverride: forceScan ? 2 : 1,
            completion: { groups, latestGroups in
            let latestCandidates = fluxgramInterleavedShortVideos(latestGroups)
            let candidates: [EngineRawMessage]
            let allCandidates = fluxgramInterleavedShortVideos(groups)
            let latestIds = Set(latestCandidates.map(\.id))
            let cachedIds = Set(cachedCandidates?.map(\.id) ?? [])
            let newCandidates = allCandidates.filter { !cachedIds.contains($0.id) }
            if forceScan, let cachedCandidates {
                candidates = latestCandidates + newCandidates.filter { !latestIds.contains($0.id) } + cachedCandidates.filter { cachedMessage in
                    !latestIds.contains(cachedMessage.id) && !newCandidates.contains(where: { newMessage in newMessage.id == cachedMessage.id })
                }
            } else {
                candidates = latestCandidates + allCandidates.filter { !latestIds.contains($0.id) }
            }
            let updatedCandidates = forceScan ? newCandidates : []
            if forceScan {
                updatedMessages = updatedCandidates
            } else {
                updatedMessages = []
            }
            scanner = nil
            updateState {
                var state = $0
                state.isScanning = false
                let summary = fluxgramShortVideoScanSummary(prefix: forceScan ? "刷新完成" : "扫描完成", messages: candidates)
                state.status = forceScan
                    ? "本次更新发现 \(updatedCandidates.count) 个新视频；\(summary)"
                    : summary
                state.updatedMessageCount = forceScan ? updatedCandidates.count : 0
                return state
            }
            guard !candidates.isEmpty else {
                return
            }
            FluxgramShortVideoFeedCache.store(candidates, featuredMessages: latestCandidates + updatedCandidates, for: enabledSources)
            if !forceScan {
                openFeed(candidates)
            }
        })
        scanner?.start()
    }
    let arguments = FluxgramShortVideoControllerArguments(play: {
        startPlayback(false)
    }, refresh: {
        startPlayback(true)
    }, addSource: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let selection = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyGroupsAndChannels, .excludeSecretChats, .excludeSavedMessages, .doNotSearchMessages], hasContactSelector: false, title: "添加短视频来源"))
        selection.peerSelected = { [weak selection] peer, _ in
            let wasAdded = FluxgramShortVideoStore.add(dialogId: peer.id.toInt64(), title: peer.debugDisplayTitle)
            persistSources(FluxgramShortVideoStore.sources())
            selection?.dismiss()
            presentAlert(wasAdded ? "已加入短视频来源。" : "该会话已启用为短视频来源。")
        }
        controller?.push(selection)
        _ = presentationData
    }, edit: { source in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: source.title.isEmpty ? "短视频来源" : source.title)]
        items.append(ActionSheetButtonItem(title: source.enabled ? "暂停此来源" : "启用此来源", color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            var sources = FluxgramShortVideoStore.sources()
            if let index = sources.firstIndex(where: { $0.dialogId == source.dialogId }) {
                sources[index].enabled.toggle()
                persistSources(sources)
            }
        }))
        for duration in [15, 30, 60, 180, 600] {
            items.append(ActionSheetButtonItem(title: "最长 \(duration) 秒\(source.durationLimit == duration ? "（当前）" : "")", color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                var sources = FluxgramShortVideoStore.sources()
                if let index = sources.firstIndex(where: { $0.dialogId == source.dialogId }) {
                    sources[index].durationLimit = Int32(duration)
                    persistSources(sources)
                }
            }))
        }
        items.append(ActionSheetButtonItem(title: "移除此来源", color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            persistSources(FluxgramShortVideoStore.sources().filter { $0.dialogId != source.dialogId })
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in actionSheet?.dismissAnimated() })])])
        controller?.present(actionSheet, in: .window(.root))
    }, viewUpdated: {
        guard !updatedMessages.isEmpty else {
            return
        }
        openFeed(updatedMessages)
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramShortVideoControllerArguments)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("短视频流"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: true)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: fluxgramShortVideoEntries(state), style: .blocks, emptyStateItem: nil, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let result = ItemListController(context: context, state: signal)
    result.willDisappear = { _ in
        scanner?.cancel()
    }
    controller = result
    return result
}
