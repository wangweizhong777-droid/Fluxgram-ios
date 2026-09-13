import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent
import TinyThumbnail

// Keep dense download controls opaque in dark mode. Translucent cards reduce
// contrast when several rows are grouped together.
private let fluxgramItemListSystemStyle: ItemListSystemStyle = .legacy

private struct FluxgramDownloadControllerState: Equatable {
    var authorName: String
    var downloadSubdir: String
    var isRootDestinationSelected: Bool
    var title: String
    var note: String
    var tags: String
    var confirmTags: Bool
    var inbox: Bool
    var selectedMessageIds: Set<Int32>
    var detectedCode: String
    var isJapaneseName: Bool
    var useClassicPath: Bool
    var destinationManuallyEdited: Bool
    var isAnalyzing: Bool
    var isCheckingDestination: Bool
    var isSubmitting: Bool
    var submissionCompletedCount: Int
    var submissionTotalCount: Int
}

private enum FluxgramDownloadSection: Int32 {
    case media
    case metadata
    case destination
    case options
}

private enum FluxgramDownloadEntry: ItemListNodeEntry {
    case mediaHeader(Int)
    case selectAll(Bool)
    case selectVideos(Bool)
    case selectImages(Bool)
    case media(Int, FluxgramNASDownloadRequest, Bool)
    case destinationHeader
    case destination(String, Bool)
    case chooseDestination
    case metadataHeader
    case author(String)
    case title(String)
    case analyzeMetadata(Bool)
    case classicPath(Bool)
    case optionsHeader
    case tags(String)
    case confirmTags(Bool)
    case note(String)
    case inbox(Bool)
    case downloadStatus

    var section: ItemListSectionId {
        switch self {
        case .mediaHeader, .selectAll, .selectVideos, .selectImages, .media:
            return FluxgramDownloadSection.media.rawValue
        case .metadataHeader, .author, .title, .analyzeMetadata:
            return FluxgramDownloadSection.metadata.rawValue
        case .destinationHeader, .destination, .chooseDestination, .classicPath:
            return FluxgramDownloadSection.destination.rawValue
        case .optionsHeader, .tags, .confirmTags, .note, .inbox, .downloadStatus:
            return FluxgramDownloadSection.options.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .mediaHeader:
            return 10
        case .selectAll:
            return 11
        case .selectVideos:
            return 12
        case .selectImages:
            return 13
        case let .media(_, download, _):
            return 100_000_000 + Int32(download.messageId % 900_000_000)
        case .destinationHeader:
            return 20
        case .destination:
            return 21
        case .chooseDestination:
            return 22
        case .metadataHeader:
            return 30
        case .author:
            return 31
        case .title:
            return 32
        case .analyzeMetadata:
            return 33
        case .classicPath:
            return 43
        case .optionsHeader:
            return 40
        case .tags:
            return 41
        case .confirmTags:
            return 42
        case .note:
            return 44
        case .inbox:
            return 45
        case .downloadStatus:
            return 46
        }
    }

    static func <(lhs: FluxgramDownloadEntry, rhs: FluxgramDownloadEntry) -> Bool {
        func sortIndex(_ entry: FluxgramDownloadEntry) -> Int {
            switch entry {
            case .mediaHeader:
                return 0
            case .selectAll:
                return 1
            case .selectVideos:
                return 2
            case .selectImages:
                return 3
            case let .media(index, _, _):
                return 4 + index
            case .metadataHeader:
                return 1_000_000
            case .author:
                return 1_000_001
            case .title:
                return 1_000_002
            case .analyzeMetadata:
                return 1_000_003
            case .classicPath:
                return 2_000_003
            case .destinationHeader:
                return 2_000_000
            case .destination:
                return 2_000_001
            case .chooseDestination:
                return 2_000_002
            case .optionsHeader:
                return 3_000_000
            case .tags:
                return 3_000_001
            case .confirmTags:
                return 3_000_002
            case .note:
                return 3_000_003
            case .inbox:
                return 3_000_004
            case .downloadStatus:
                return 3_000_005
            }
        }
        return sortIndex(lhs) < sortIndex(rhs)
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramDownloadControllerArguments
        switch self {
        case let .mediaHeader(count):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "已选媒体（\(count)）", sectionId: self.section)
        case let .selectAll(allSelected):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: allSelected ? "取消全选" : "全选",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.toggleAll()
                }
            )
        case let .selectVideos(allSelected):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: allSelected ? "取消全选视频" : "全选视频",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.toggleMediaType(true)
                }
            )
        case let .selectImages(allSelected):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: allSelected ? "取消全选图片" : "全选图片",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.toggleMediaType(false)
                }
            )
        case let .media(_, download, selected):
            let subtitle: String?
            if let document = download.directDocument, document.fileSize > 0 {
                subtitle = "\(max(1, document.fileSize / 1_048_576)) MB"
            } else {
                subtitle = nil
            }
            let thumbnail: UIImage? = download.thumbnailData
                .flatMap(decodeTinyThumbnail)
                .flatMap(UIImage.init(data:))
            return ItemListCheckboxItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                icon: thumbnail,
                iconSize: CGSize(width: 52.0, height: 52.0),
                title: download.directDocument?.fileName ?? "图片消息 \(download.messageId)",
                subtitle: subtitle,
                style: .right,
                checked: selected,
                zeroSeparatorInsets: false,
                sectionId: self.section,
                action: {
                    arguments.toggleSelection(download.messageId)
                }
            )
        case .destinationHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "第二步：选择保存位置", sectionId: self.section)
        case let .destination(value, isRootDestinationSelected):
            if isRootDestinationSelected {
                return ItemListDisclosureItem(
                    presentationData: presentationData,
                    systemStyle: fluxgramItemListSystemStyle,
                    title: "保存位置",
                    label: "NAS 根目录",
                    labelStyle: .text,
                    sectionId: self.section,
                    style: .blocks,
                    disclosureStyle: .arrow,
                    action: {
                        arguments.chooseDestination()
                    }
                )
            }
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "保存位置", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "AI 分析后自动推荐",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.downloadSubdir = value
                        state.isRootDestinationSelected = false
                        state.destinationManuallyEdited = true
                        return state
                    }
                },
                action: {}
            )
        case .chooseDestination:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "从 NAS 选择",
                label: "加载文件夹",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.chooseDestination()
                }
            )
        case .downloadStatus:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "查看 NAS 下载",
                label: "队列与历史记录",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openDownloads()
                }
            )
        case .metadataHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "第一步：确认识别信息", sectionId: self.section)
        case let .author(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "主演名", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "AI 无法识别时请填写",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateAuthor(value)
                },
                action: {}
            )
        case let .title(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "标题", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "有番号时填写",
                type: .regular(capitalization: false, autocorrection: true),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.title = value
                        return state
                    }
                },
                action: {}
            )
        case .optionsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "更多选项", sectionId: self.section)
        case let .tags(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "标签", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "可选，用逗号分隔",
                type: .regular(capitalization: false, autocorrection: true),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.tags = value
                        return state
                    }
                },
                action: {}
            )
        case let .analyzeMetadata(isAnalyzing):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: isAnalyzing ? "AI 分析中..." : "分析文字（AI）",
                kind: isAnalyzing ? .disabled : .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.analyzeMetadata()
                }
            )
        case let .classicPath(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "使用经典路径（经典/主演名）",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateClassicPath(value)
                }
            )
        case let .note(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "备注", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "可选备注",
                type: .regular(capitalization: true, autocorrection: true),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.note = value
                        return state
                    }
                },
                action: {}
            )
        case let .confirmTags(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "确认导入标签",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.confirmTags = value
                        return state
                    }
                }
            )
        case let .inbox(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "加入收件箱",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.inbox = value
                        return state
                    }
                }
            )
        }
    }
}

private final class FluxgramDownloadControllerArguments {
    let updateState: ((FluxgramDownloadControllerState) -> FluxgramDownloadControllerState) -> Void
    let toggleSelection: (Int32) -> Void
    let toggleAll: () -> Void
    let toggleMediaType: (Bool) -> Void
    let chooseDestination: () -> Void
    let openDownloads: () -> Void
    let analyzeMetadata: () -> Void
    let updateAuthor: (String) -> Void
    let updateClassicPath: (Bool) -> Void

    init(
        updateState: @escaping ((FluxgramDownloadControllerState) -> FluxgramDownloadControllerState) -> Void,
        toggleSelection: @escaping (Int32) -> Void,
        toggleAll: @escaping () -> Void,
        toggleMediaType: @escaping (Bool) -> Void,
        chooseDestination: @escaping () -> Void,
        openDownloads: @escaping () -> Void,
        analyzeMetadata: @escaping () -> Void,
        updateAuthor: @escaping (String) -> Void,
        updateClassicPath: @escaping (Bool) -> Void
    ) {
        self.updateState = updateState
        self.toggleSelection = toggleSelection
        self.toggleAll = toggleAll
        self.toggleMediaType = toggleMediaType
        self.chooseDestination = chooseDestination
        self.openDownloads = openDownloads
        self.analyzeMetadata = analyzeMetadata
        self.updateAuthor = updateAuthor
        self.updateClassicPath = updateClassicPath
    }
}

private func fluxgramDownloadEntries(state: FluxgramDownloadControllerState, downloadRequests: [FluxgramNASDownloadRequest]) -> [FluxgramDownloadEntry] {
    var entries: [FluxgramDownloadEntry] = []
    if !downloadRequests.isEmpty {
        entries.append(.mediaHeader(downloadRequests.count))
        if downloadRequests.count > 1 {
            entries.append(.selectAll(state.selectedMessageIds.count == downloadRequests.count))
            let videoRequests = downloadRequests.filter(\.isVideo)
            let imageRequests = downloadRequests.filter { !$0.isVideo }
            if !videoRequests.isEmpty {
                entries.append(.selectVideos(videoRequests.allSatisfy { state.selectedMessageIds.contains($0.messageId) }))
            }
            if !imageRequests.isEmpty {
                entries.append(.selectImages(imageRequests.allSatisfy { state.selectedMessageIds.contains($0.messageId) }))
            }
        }
        entries.append(contentsOf: downloadRequests.enumerated().map { index, download in
            return .media(index, download, state.selectedMessageIds.contains(download.messageId))
        })
    }
    entries.append(contentsOf: [
        .metadataHeader,
        .author(state.authorName),
        .title(state.title),
        .analyzeMetadata(state.isAnalyzing),
        .destinationHeader,
        .destination(state.downloadSubdir, state.isRootDestinationSelected),
        .chooseDestination
    ])
    // Always expose the override once a performer is known. AI can miss a
    // number in a caption, and the user explicitly decides whether a known
    // Japanese performer belongs under the classic library.
    if !state.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        entries.append(.classicPath(state.useClassicPath))
    }
    entries.append(contentsOf: [
        .optionsHeader,
        .tags(state.tags),
        .confirmTags(state.confirmTags),
        .note(state.note),
        .inbox(state.inbox),
        .downloadStatus
    ])
    return entries
}

private func fluxgramDownloadSubdirectory(_ value: String, allowRoot: Bool = true) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // An empty path is the explicit NAS root selection. New-folder input
    // passes allowRoot=false so an accidental blank folder is still rejected.
    guard (allowRoot || !value.isEmpty), !value.hasPrefix("/"), value.rangeOfCharacter(from: .newlines) == nil else {
        return nil
    }
    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    guard (allowRoot || !components.isEmpty), !components.contains("..") else {
        return nil
    }
    return components.joined(separator: "/")
}

private func fluxgramRecommendedDownloadSubdir(author: String, code: String, isJapaneseName: Bool, useClassicPath: Bool, rootDirectories: [String]) -> String {
    let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
    // FC2 catalogue numbers use the shared classic bucket rather than a
    // performer folder. Keep the match strict so unrelated codes such as
    // FC2PPV-12345 continue through the normal recommendation rules.
    if fluxgramIsFC2DownloadCode(code) {
        return "经典/FC2"
    }
    guard !trimmedAuthor.isEmpty else {
        return ""
    }
    if useClassicPath {
        return "经典/\(trimmedAuthor)"
    }
    let matching = rootDirectories
        .filter { path in
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 1 else { return false }
            return String(parts[0]).lowercased().hasPrefix(trimmedAuthor.lowercased())
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    return matching.first ?? trimmedAuthor
}

private func fluxgramIsFC2DownloadCode(_ code: String) -> Bool {
    let normalizedCode = fluxgramNormalizedDownloadCode(code)
    return normalizedCode.range(of: #"^FC2-\d+$"#, options: .regularExpression) != nil
}

// Catalogue numbers are commonly written as FC2-PPV-123, fc2_ppv 123, or
// with extra spaces. Compare the semantic number while preserving the user's
// original filename text. This prevents duplicate downloads caused only by
// punctuation/case differences.
private func fluxgramNormalizedDownloadCode(_ code: String) -> String {
    let value = code
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    let collapsed = value.replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
    return collapsed.replacingOccurrences(of: #"^FC2-PPV-"#, with: "FC2-", options: .regularExpression)
}

private func fluxgramAllocatedDownloadRequests(
    _ requests: [FluxgramNASDownloadRequest],
    author: String,
    code: String,
    sourceText: String,
    occupiedFileNames: Set<String>
) -> [FluxgramNASDownloadRequest] {
    var occupied = Set(occupiedFileNames.map { $0.lowercased() })
    var nextSequence = 1

    return requests.map { request in
        let originalFileName = request.directDocument?.fileName ?? "telegram-media"
        var candidate: String
        if !code.isEmpty {
            let baseCandidate = fluxgramDesiredDownloadFileName(
                originalFileName: originalFileName,
                sourceText: sourceText,
                author: author,
                title: "",
                sequenceIndex: nextSequence,
                codeOverride: code.isEmpty ? nil : code
            )
            // Keep numbered works stable, but never let two selected media or
            // an existing NAS file overwrite one another. A suffix is only
            // introduced for an exact filename collision.
            candidate = baseCandidate
            var collisionSequence = 2
            while occupied.contains(candidate.lowercased()) {
                candidate = fluxgramCollisionFileName(baseCandidate, sequence: collisionSequence)
                collisionSequence += 1
            }
            occupied.insert(candidate.lowercased())
        } else {
            repeat {
                candidate = fluxgramDesiredDownloadFileName(
                    originalFileName: originalFileName,
                    sourceText: sourceText,
                    author: author,
                    title: "",
                    sequenceIndex: nextSequence,
                    codeOverride: nil
                )
                nextSequence += 1
            } while occupied.contains(candidate.lowercased())
            occupied.insert(candidate.lowercased())
        }

        let adjustedDocument = request.directDocument.map { document in
            FluxgramNASDirectDocument(
                documentId: document.documentId,
                accessHash: document.accessHash,
                fileReference: document.fileReference,
                fileName: candidate,
                fileSize: document.fileSize
            )
        }
        return FluxgramNASDownloadRequest(
            dialogId: request.dialogId,
            messageId: request.messageId,
            peerAccessHash: request.peerAccessHash,
            directDocument: adjustedDocument,
            sourceLabel: request.sourceLabel,
            sourceText: request.sourceText,
            desiredFileName: candidate,
            thumbnailData: request.thumbnailData,
            isVideo: request.isVideo
        )
    }
}

private func fluxgramDeduplicatedDownloadRequests(_ requests: [FluxgramNASDownloadRequest]) -> [FluxgramNASDownloadRequest] {
    var seen = Set<String>()
    return requests.filter { request in
        let documentKey = request.directDocument.map { "\($0.documentId):\($0.accessHash)" } ?? ""
        let key = "\(request.dialogId):\(request.messageId):\(documentKey)"
        return seen.insert(key).inserted
    }
}

private func fluxgramCollisionFileName(_ fileName: String, sequence: Int) -> String {
    let ext = (fileName as NSString).pathExtension
    let suffix = "-\(max(sequence, 2))"
    if ext.isEmpty {
        return fileName + suffix
    }
    let base = (fileName as NSString).deletingPathExtension
    return "\(base)\(suffix).\(ext)"
}

private func fluxgramNewDownloadFolderAlert(context: AccountContext, submit: @escaping (String) -> Void) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let inputState = AlertInputFieldComponent.ExternalState()
    let doneIsEnabled = inputState.valueSignal
    |> map { value in
        return fluxgramDownloadSubdirectory(value, allowRoot: false) != nil
    }
    var apply: (() -> Void)?
    let content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
        AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: "新建 NAS 文件夹"))),
        AnyComponentWithIdentity(id: "input", component: AnyComponent(AlertInputFieldComponent(
            context: context,
            initialValue: nil,
            placeholder: "输入文件夹或子文件夹路径",
            hasClearButton: true,
            keyboardType: .default,
            autocapitalizationType: .none,
            autocorrectionType: .no,
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
        guard let folder = fluxgramDownloadSubdirectory(inputState.value, allowRoot: false) else {
            inputState.animateError()
            return
        }
        controller.dismiss()
        submit(folder)
    }
    return controller
}

private struct FluxgramDownloadMetadataResult {
    let authors: [String]
    let title: String
    let tags: [String]
    let isJapaneseName: Bool?
}

private func fluxgramParseDownloadMetadata(_ text: String) -> FluxgramDownloadMetadataResult? {
    var authors: [String] = []
    var title = ""
    var tags: [String] = []
    var isJapaneseName: Bool?
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            continue
        }
        let separator = line.firstIndex(of: ":") ?? line.firstIndex(of: "：")
        guard let separator else {
            continue
        }
        let label = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`*"))
        guard !value.isEmpty, value != "未识别", value.lowercased() != "unknown", value != "无" else {
            continue
        }
        if label.contains("作者") || label.contains("主演") || label.contains("author") {
            authors = value
                .components(separatedBy: CharacterSet(charactersIn: "、,，;；|/"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "未识别" }
        } else if label.contains("标题") || label.contains("title") {
            title = value
        } else if label.contains("关键词") || label.contains("标签") || label.contains("keyword") || label.contains("tag") {
            tags = value
                .components(separatedBy: CharacterSet(charactersIn: "、,，;；|"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                .filter { !$0.isEmpty && $0 != "未识别" }
        } else if label.contains("日本") || label.contains("japanese") {
            if ["是", "yes", "true", "1"].contains(value.lowercased()) { isJapaneseName = true }
            if ["否", "no", "false", "0"].contains(value.lowercased()) { isJapaneseName = false }
        }
    }
    guard !authors.isEmpty || !title.isEmpty || !tags.isEmpty else {
        return nil
    }
    return FluxgramDownloadMetadataResult(authors: Array(authors.prefix(8)), title: title, tags: Array(tags.prefix(8)), isJapaneseName: isJapaneseName)
}

private final class FluxgramNASFolderPickerArguments {
    let select: (String?) -> Void

    init(select: @escaping (String?) -> Void) {
        self.select = select
    }
}

private enum FluxgramNASFolderPickerEntry: ItemListNodeEntry {
    case header
    case status(String)
    case root
    case create
    case folder(String)

    var section: ItemListSectionId { 0 }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .status: return 1
        case .root: return 2
        case .create: return 3
        case let .folder(path):
            var hash: UInt32 = 2_166_136_261
            for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            return 100 + Int32(hash % 500_000_000)
        }
    }

    static func < (lhs: FluxgramNASFolderPickerEntry, rhs: FluxgramNASFolderPickerEntry) -> Bool {
        // ItemList requires a strict weak ordering.  Comparing the section
        // order and stable id with `||` can report both `lhs < rhs` and
        // `rhs < lhs` when an item from an earlier section happens to have a
        // larger id, which triggers an assertion while applying updates.
        func sectionOrder(_ entry: FluxgramNASFolderPickerEntry) -> Int {
            switch entry {
            case .header: return 0
            case .status: return 1
            case .root: return 2
            case .create: return 3
            case .folder: return 4
            }
        }
        let lhsSection = sectionOrder(lhs)
        let rhsSection = sectionOrder(rhs)
        if lhsSection != rhsSection {
            return lhsSection < rhsSection
        }
        // Folder rows are published in display-name order.  Use that same
        // order here; comparing their hash-based stable ids would disagree
        // with the array order and trigger ItemList's sorted-entry assert.
        if case let .folder(lhsPath) = lhs, case let .folder(rhsPath) = rhs {
            let comparison = lhsPath.localizedStandardCompare(rhsPath)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let select = (arguments as! FluxgramNASFolderPickerArguments).select
        switch self {
        case .header:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "NAS 文件夹", sectionId: self.section)
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .root:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .legacy, title: "NAS 根目录", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { select("") })
        case .create:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .legacy, title: "新建文件夹", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { select(nil) })
        case let .folder(path):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .legacy, title: path, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { select(path) })
        }
    }
}

private func fluxgramNASFolderPickerController(context: AccountContext, selected: @escaping (String) -> Void) -> ViewController {
    let service = FluxgramNASService.shared
    struct State: Equatable { var folders: [String]; var status: String }
    let initialState = State(folders: [], status: "正在加载 NAS 文件夹…")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((State) -> State) -> Void = { f in statePromise.set(stateValue.modify { f($0) }) }
    var controller: ItemListController?

    let choose: (String?) -> Void = { folder in
        if let folder {
            selected(folder)
            controller?.dismiss()
        } else {
            controller?.present(fluxgramNewDownloadFolderAlert(context: context, submit: { folder in
                selected(folder)
                controller?.dismiss()
            }), in: .window(.root))
        }
    }
    let pickerArguments = FluxgramNASFolderPickerArguments(select: choose)
    let signal: Signal<(ItemListControllerState, (ItemListNodeState, FluxgramNASFolderPickerArguments)), NoError> = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramNASFolderPickerArguments)) in
        let entries: [FluxgramNASFolderPickerEntry] = [.header, .status(state.status), .root, .create] + state.folders.map { .folder($0) }
        // This controller is presented modally (not pushed on a navigation
        // stack), so `backNavigationButton` only changes the next controller's
        // back-item title and does not render a tappable button here. Expose a
        // real left navigation action so the user can always return to the
        // download form without selecting a folder.
        let backButton = ItemListNavigationButton(content: .text("返回"), style: .regular, enabled: true, action: {
            controller?.dismiss()
        })
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("选择 NAS 文件夹"), leftNavigationButton: backButton, rightNavigationButton: nil, backNavigationButton: nil, animateChanges: false),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false), pickerArguments)
        )
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    service.fetchDownloadDirectories { folders, error in
        // The NAS can return the same directory more than once (for example
        // when both a parent and a recursive listing are present).  Duplicate
        // entries have identical stable ids and make ItemList assert during a
        // diff, so normalize and sort the list before publishing it.
        let normalizedFolders = Array(Set((folders ?? []).compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        updateState { _ in State(folders: normalizedFolders, status: error ?? "") }
    }
    return result
}

public func fluxgramDownloadFolderActionSheet(context: AccountContext, dialogId: Int64, messageId: Int32, peerAccessHash: String?, directDocument: FluxgramNASDirectDocument?, directDownloads: [FluxgramNASDirectDownload] = [], downloadRequests: [FluxgramNASDownloadRequest] = [], defaultDownloadSubdir: String? = nil, sourceLabel: String = "", sourceText: String = "", metadataSourceText: String = "", present: @escaping (ViewController) -> Void) {
    let requests: [FluxgramNASDownloadRequest]
    if !downloadRequests.isEmpty {
        requests = downloadRequests
    } else if !directDownloads.isEmpty {
        requests = directDownloads.map { download in
            return FluxgramNASDownloadRequest(
                dialogId: download.dialogId,
                messageId: download.messageId,
                directDocument: download.document,
                sourceLabel: download.sourceLabel,
                sourceText: download.sourceText,
                thumbnailData: download.thumbnailData
            )
        }
    } else if let directDocument {
        requests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, directDocument: directDocument, sourceLabel: sourceLabel, sourceText: sourceText)]
    } else {
        requests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, peerAccessHash: peerAccessHash, sourceLabel: sourceLabel, sourceText: sourceText)]
    }
    // Every entry point uses the same editable confirmation flow. The older
    // folder sheet submitted immediately and could bypass performer input,
    // physical NAS collision checks, and the final filename preview.
    let resolvedMetadataSourceText = metadataSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? requests.map { $0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        : metadataSourceText
    present(fluxgramDownloadController(
        context: context,
        dialogId: dialogId,
        messageId: messageId,
        peerAccessHash: peerAccessHash,
        directDocument: directDocument,
        directDownloads: directDownloads,
        downloadRequests: requests,
        sourceLabel: sourceLabel,
        sourceText: sourceText,
        metadataSourceText: resolvedMetadataSourceText
    ))
    return

    let service = FluxgramNASService.shared
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let suggestedFolder = FluxgramDownloadMemoryStore.suggestions(for: requests).author
    let defaultFolder = defaultDownloadSubdir.flatMap { fluxgramDownloadSubdirectory($0) } ?? fluxgramDownloadSubdirectory(suggestedFolder)

    let presentAlert: (String) -> Void = { message in
        present(standardTextAlertController(
            theme: AlertControllerTheme(presentationData: presentationData),
            title: nil,
            text: message,
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        ))
    }

    let didFinishChoosingFolder = Atomic(value: false)
    var activeFolderSheet: ActionSheetController?
    let submit: (String) -> Void = { folder in
        activeFolderSheet?.dismissAnimated()
        let suggestion = FluxgramDownloadMemoryStore.suggestions(for: requests)
        let options = FluxgramNASSubmissionOptions(downloadSubdir: folder, title: suggestion.title)
        let preparedRequests = requests.enumerated().map { index, request -> FluxgramNASDownloadRequest in
            guard let document = request.directDocument else {
                return request
            }
            let fileName = fluxgramDesiredDownloadFileName(
                originalFileName: document.fileName,
                sourceText: request.sourceText,
                author: folder,
                title: suggestion.title,
                sequenceIndex: index + 1
            )
            let adjustedDocument = FluxgramNASDirectDocument(
                documentId: document.documentId,
                accessHash: document.accessHash,
                fileReference: document.fileReference,
                fileName: fileName,
                fileSize: document.fileSize
            )
            return FluxgramNASDownloadRequest(
                dialogId: request.dialogId,
                messageId: request.messageId,
                peerAccessHash: request.peerAccessHash,
                directDocument: adjustedDocument,
                sourceLabel: request.sourceLabel,
                sourceText: request.sourceText,
                thumbnailData: request.thumbnailData,
                isVideo: request.isVideo
            )
        }
        FluxgramDownloadMemoryStore.learn(requests: requests, author: folder, title: suggestion.title, tags: [])
        FluxgramNASService.shared.syncDownloadMemory(
            sourceLabel: requests.first?.sourceLabel ?? "",
            sourceText: requests.first?.sourceText ?? "",
            author: folder,
            title: suggestion.title,
            tags: []
        )
        service.submit(downloadRequests: preparedRequests, options: options) { results in
            let submitted = results.filter {
                if case .submitted = $0 { return true }
                return false
            }.count
            let queued = results.filter {
                if case .pending = $0 { return true }
                return false
            }.count
            let failed = results.filter {
                if case .failed = $0 { return true }
                return false
            }
            let duplicates = results.filter {
                if case let .submitted(message) = $0 { return message.contains("未重复") }
                return false
            }.count
            if failed.isEmpty, queued == 0 {
                if duplicates > 0 {
                    presentAlert("已处理 NAS 请求：\(requests.count - duplicates) 个新任务，\(duplicates) 个请求已确认在队列中，未创建重复任务。")
                } else {
                    presentAlert("已将 \(requests.count) 个项目加入 NAS 下载队列。")
                }
            } else {
                let errors = failed.prefix(2).map(\.message).joined(separator: "\n")
                var details: [String] = []
                if submitted > 0 { details.append("已加入 NAS 队列：\(submitted) 个") }
                if duplicates > 0 { details.append("\(duplicates) 个请求已确认在 NAS 队列中，未创建重复任务") }
                if queued > 0 { details.append("已保存到本地队列：\(queued) 个，恢复连接后会自动提交") }
                if !errors.isEmpty { details.append("未提交：\(failed.count) 个\n\(errors)") }
                presentAlert(details.joined(separator: "\n\n"))
            }
        }
    }
    let title = requests.count > 1 ? "为 \(requests.count) 个项目选择 NAS 文件夹" : "选择 NAS 文件夹"
    let presentFolderSheet: ([String], Bool) -> Void = { directories, isLoading in
        let actionSheet = ActionSheetController(presentationData: presentationData)
        activeFolderSheet = actionSheet
        var folderItems: [ActionSheetItem] = [
            ActionSheetTextItem(title: isLoading ? "\(title)\n正在加载已有文件夹..." : title)
        ]
        if let defaultFolder {
            folderItems.append(ActionSheetButtonItem(title: "保存到：\(defaultFolder)", color: .accent, action: {
                guard !didFinishChoosingFolder.swap(true) else {
                    return
                }
                submit(defaultFolder)
            }))
        }
        folderItems.append(contentsOf: [
            ActionSheetButtonItem(title: "NAS 根目录", color: .accent, action: {
                guard !didFinishChoosingFolder.swap(true) else {
                    return
                }
                submit("")
            }),
            ActionSheetButtonItem(title: "新建文件夹", color: .accent, action: {
                guard !didFinishChoosingFolder.swap(true) else {
                    return
                }
                actionSheet.dismissAnimated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    present(fluxgramNewDownloadFolderAlert(context: context, submit: submit))
                }
            }),
            ActionSheetButtonItem(title: "更多下载选项", color: .accent, action: {
                guard !didFinishChoosingFolder.swap(true) else {
                    return
                }
                actionSheet.dismissAnimated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    present(fluxgramDownloadController(
                        context: context,
                        dialogId: dialogId,
                        messageId: messageId,
                        peerAccessHash: peerAccessHash,
                        directDocument: directDocument,
                        directDownloads: directDownloads,
                        downloadRequests: downloadRequests,
                        sourceLabel: sourceLabel,
                        sourceText: sourceText,
                        metadataSourceText: metadataSourceText
                    ))
                }
            })
        ])
        for directory in directories {
            folderItems.append(ActionSheetButtonItem(title: directory, color: .accent, action: {
                guard !didFinishChoosingFolder.swap(true) else {
                    return
                }
                submit(directory)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: folderItems),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    _ = didFinishChoosingFolder.swap(true)
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        present(actionSheet)
    }

    presentFolderSheet([], true)
    service.fetchDownloadDirectories { directories, error in
        guard !didFinishChoosingFolder.with({ $0 }) else {
            return
        }
        if let error {
            activeFolderSheet?.dismissAnimated()
            activeFolderSheet = nil
            presentAlert(error)
            return
        }
        guard let directories else {
            activeFolderSheet?.dismissAnimated()
            activeFolderSheet = nil
            presentAlert("无法加载 NAS 文件夹。")
            return
        }
        activeFolderSheet?.dismissAnimated()
        presentFolderSheet(directories, false)
    }
}

public func fluxgramDownloadController(context: AccountContext, dialogId: Int64, messageId: Int32, peerAccessHash: String?, directDocument: FluxgramNASDirectDocument?, directDownloads: [FluxgramNASDirectDownload] = [], downloadRequests: [FluxgramNASDownloadRequest] = [], sourceLabel: String = "", sourceText: String = "", metadataSourceText: String = "") -> ViewController {
    let resolvedDownloadRequests: [FluxgramNASDownloadRequest]
    if !downloadRequests.isEmpty {
        resolvedDownloadRequests = downloadRequests
    } else if !directDownloads.isEmpty {
        resolvedDownloadRequests = directDownloads.map { download in
            FluxgramNASDownloadRequest(
                dialogId: download.dialogId,
                messageId: download.messageId,
                directDocument: download.document,
                sourceLabel: download.sourceLabel,
                sourceText: download.sourceText,
                thumbnailData: download.thumbnailData
            )
        }
    } else if let directDocument {
        resolvedDownloadRequests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, directDocument: directDocument, sourceLabel: sourceLabel, sourceText: sourceText)]
    } else {
        resolvedDownloadRequests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, peerAccessHash: peerAccessHash, sourceLabel: sourceLabel, sourceText: sourceText)]
    }
    let metadataSuggestion = FluxgramDownloadMemoryStore.suggestions(for: resolvedDownloadRequests)
    let groupSourceText = metadataSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? resolvedDownloadRequests.map { $0.sourceText }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        : metadataSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let detectedCode = fluxgramDownloadCode(from: groupSourceText) ?? ""
    var rootDirectories: [String] = []
    let initialAuthor = metadataSuggestion.author.isEmpty && fluxgramIsFC2DownloadCode(detectedCode)
        ? "素人"
        : metadataSuggestion.author
    let initialState = FluxgramDownloadControllerState(
        authorName: initialAuthor,
        downloadSubdir: metadataSuggestion.author,
        isRootDestinationSelected: false,
        title: metadataSuggestion.title,
        note: "",
        tags: metadataSuggestion.tags.joined(separator: ", "),
        confirmTags: false,
        inbox: false,
        selectedMessageIds: Set(resolvedDownloadRequests.map(\.messageId)),
        detectedCode: detectedCode,
        isJapaneseName: false,
        useClassicPath: false,
        destinationManuallyEdited: false,
        isAnalyzing: false,
        isCheckingDestination: false,
        isSubmitting: false,
        submissionCompletedCount: 0,
        submissionTotalCount: 0
    )
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((FluxgramDownloadControllerState) -> FluxgramDownloadControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let service = FluxgramNASService.shared

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
    let presentSubmissionResult: (Int) -> Void = { count in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            standardTextAlertController(
                theme: AlertControllerTheme(presentationData: presentationData),
                title: nil,
                text: count == 1 ? "已加入 NAS 下载队列。" : "已将 \(count) 个媒体加入 NAS 下载队列。",
                actions: [
                    TextAlertAction(type: .genericAction, title: "稍后查看", action: {}),
                    TextAlertAction(type: .defaultAction, title: "查看 NAS 下载", action: {
                        // The download form is presented modally, so it does
                        // not have a navigation stack to push onto. Present
                        // the NAS queue from the root window after the alert
                        // has dismissed instead of silently doing nothing.
                        DispatchQueue.main.async {
                            controller?.present(fluxgramDownloadsController(context: context), in: .window(.root))
                        }
                    })
                ],
                actionLayout: .vertical
            ),
            in: .window(.root)
        )
    }

    let analyzeMetadata: () -> Void = {
        let currentState = stateValue.with { $0 }
        guard !currentState.isAnalyzing else {
            return
        }
        let selectedRequests = resolvedDownloadRequests.filter { currentState.selectedMessageIds.contains($0.messageId) }
        let sourceText = groupSourceText.isEmpty
            ? selectedRequests.map { $0.sourceText }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
            : groupSourceText
        guard !sourceText.isEmpty else {
            presentAlert("选中的媒体没有文字消息，AI 无法分析。")
            return
        }

        updateState { state in
            var state = state
            state.isAnalyzing = true
            return state
        }
        let memoryPrompt = fluxgramAIRecognitionMemoryPrompt(sourceLabel: "NAS 下载 AI 分析", sourceText: sourceText)
        let aiInput = """
        请分析下面选中媒体对应的 Telegram 文字，只返回作者名、标题和关键词，不要分析图片或视频本身。
        选中的文字：
        \(sourceText)

        \(memoryPrompt)
        """
        FluxgramAIService.shared.analyzeDownloadMetadata(text: aiInput) { result in
            updateState { state in
                var state = state
                state.isAnalyzing = false
                return state
            }
            switch result {
            case let .success(aiResult):
                guard let parsed = fluxgramParseDownloadMetadata(aiResult.text) else {
                    presentAlert("AI 返回的格式无法识别，请重试。")
                    return
                }
                let applyMetadata: (String) -> Void = { selectedAuthor in
                    updateState { state in
                        var state = state
                        // AI may recover the catalogue number even when the
                        // initial source-text pass missed it. Feed both
                        // responses into the same strict code detector before
                        // calculating the destination recommendation.
                        let combinedMetadataText = [groupSourceText, aiResult.text]
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .joined(separator: "\n")
                        if let detectedCode = fluxgramDownloadCode(from: combinedMetadataText) {
                            state.detectedCode = detectedCode
                        }
                        if !selectedAuthor.isEmpty {
                            state.authorName = selectedAuthor
                        } else if parsed.authors.isEmpty,
                                  state.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  fluxgramIsFC2DownloadCode(state.detectedCode) {
                            state.authorName = "素人"
                        }
                        if !parsed.title.isEmpty { state.title = parsed.title }
                        if !parsed.tags.isEmpty {
                            state.tags = parsed.tags.joined(separator: ", ")
                            // AI suggestions are editable but never imported
                            // until the user explicitly enables confirmation.
                            state.confirmTags = false
                        }
                        if let isJapaneseName = parsed.isJapaneseName {
                            state.isJapaneseName = isJapaneseName
                        }
                        // A numbered work with a Japanese performer defaults
                        // to the classic library path, but remains editable.
                        state.useClassicPath = state.isJapaneseName && !state.detectedCode.isEmpty
                        state.destinationManuallyEdited = false
                        state.isRootDestinationSelected = false
                        if !state.destinationManuallyEdited {
                            state.downloadSubdir = fluxgramRecommendedDownloadSubdir(
                                author: state.authorName,
                                code: state.detectedCode,
                                isJapaneseName: state.isJapaneseName,
                                useClassicPath: state.useClassicPath,
                                rootDirectories: rootDirectories
                            )
                        }
                        return state
                    }
                    presentAlert("AI 已填入作者名、标题和关键词，你可以继续修改后下载。")
                }
                if parsed.authors.count > 1 {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let actionSheet = ActionSheetController(presentationData: presentationData)
                    let authorItems = parsed.authors.map { author in
                        ActionSheetButtonItem(title: author, color: .accent, action: {
                            actionSheet.dismissAnimated()
                            applyMetadata(author)
                        })
                    }
                    actionSheet.setItemGroups([
                        ActionSheetItemGroup(items: [ActionSheetTextItem(title: "请选择主演名")]),
                        ActionSheetItemGroup(items: authorItems),
                        ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { actionSheet.dismissAnimated() })])
                    ])
                    controller?.present(actionSheet, in: .window(.root))
                } else {
                    applyMetadata(parsed.authors.first ?? "")
                }
            case let .failure(error):
                presentAlert(error.localizedDescription)
            }
        }
    }

    let updateAuthor: (String) -> Void = { value in
        updateState { state in
            var state = state
            state.authorName = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Changing the performer starts a new recommendation. This also
            // prevents an old manually selected folder from being reused for
            // a different performer.
            state.destinationManuallyEdited = false
            state.isRootDestinationSelected = false
            state.downloadSubdir = fluxgramRecommendedDownloadSubdir(
                author: state.authorName,
                code: state.detectedCode,
                isJapaneseName: state.isJapaneseName,
                useClassicPath: state.useClassicPath,
                rootDirectories: rootDirectories
            )
            return state
        }
    }
    let updateClassicPath: (Bool) -> Void = { value in
        updateState { state in
            var state = state
            state.useClassicPath = value
            state.destinationManuallyEdited = false
            state.isRootDestinationSelected = false
            state.downloadSubdir = fluxgramRecommendedDownloadSubdir(
                author: state.authorName,
                code: state.detectedCode,
                isJapaneseName: state.isJapaneseName,
                useClassicPath: value,
                rootDirectories: rootDirectories
            )
            return state
        }
    }

    let chooseDestination: () -> Void = {
        let picker = fluxgramNASFolderPickerController(context: context, selected: { folder in
            updateState { state in
                var state = state
                state.downloadSubdir = folder
                state.isRootDestinationSelected = folder.isEmpty
                state.destinationManuallyEdited = true
                return state
            }
        })
        controller?.present(picker, in: .current)
    }
    /*
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var didFinish = false
        let setItems: ([String], String?) -> Void = { directories, status in
            var items: [ActionSheetItem] = []
            if let status {
                items.append(ActionSheetTextItem(title: status))
            }
            items.append(contentsOf: [
                ActionSheetButtonItem(title: "NAS 根目录", color: .accent, action: {
                    guard !didFinish else { return }
                    didFinish = true
                    actionSheet.dismissAnimated()
                    updateState { state in
                        var state = state
                        state.downloadSubdir = ""
                        state.destinationManuallyEdited = true
                        return state
                    }
                }),
                ActionSheetButtonItem(title: "新建文件夹", color: .accent, action: {
                    guard !didFinish else { return }
                    didFinish = true
                    actionSheet.dismissAnimated()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        controller?.present(fluxgramNewDownloadFolderAlert(context: context, submit: { folder in
                            updateState { state in
                                var state = state
                                state.downloadSubdir = folder
                                state.destinationManuallyEdited = true
                                return state
                            }
                        }), in: .window(.root))
                    }
                })
            ])
            for directory in directories {
                items.append(ActionSheetButtonItem(title: directory, color: .accent, action: {
                    guard !didFinish else { return }
                    didFinish = true
                    actionSheet.dismissAnimated()
                    updateState { state in
                        var state = state
                        state.downloadSubdir = directory
                        state.destinationManuallyEdited = true
                        return state
                    }
                }))
            }
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: {
                        didFinish = true
                        actionSheet.dismissAnimated()
                    })
                ])
            ])
        }

        // Show the useful actions immediately. Directory discovery continues
        // in the background and replaces this sheet's contents when ready.
        setItems([], "正在加载已有文件夹…")
        // Use the global overlay host so the picker is always above the
        // already-presented download controller and its dim view.
        controller?.presentInGlobalOverlay(actionSheet, with: nil)
        service.fetchDownloadDirectories { directories, error in
            guard !didFinish else {
                return
            }
            if let directories {
                setItems(directories, nil)
            } else {
                setItems([], error ?? "无法加载 NAS 文件夹。")
            }
        }
    }
    */
    service.fetchDownloadDirectories { directories, _ in
        rootDirectories = (directories ?? []).filter { $0.split(separator: "/", omittingEmptySubsequences: true).count == 1 }
        updateState { state in
            var state = state
            if !state.destinationManuallyEdited {
                state.isRootDestinationSelected = false
                state.downloadSubdir = fluxgramRecommendedDownloadSubdir(
                    author: state.authorName,
                    code: state.detectedCode,
                    isJapaneseName: state.isJapaneseName,
                    useClassicPath: state.useClassicPath,
                    rootDirectories: rootDirectories
                )
            }
            return state
        }
    }
    let arguments = FluxgramDownloadControllerArguments(
        updateState: updateState,
        toggleSelection: { messageId in
            updateState { state in
                var state = state
                if state.selectedMessageIds.contains(messageId) {
                    state.selectedMessageIds.remove(messageId)
                } else {
                    state.selectedMessageIds.insert(messageId)
                }
                return state
            }
        },
        toggleAll: {
            updateState { state in
                var state = state
                if state.selectedMessageIds.count == resolvedDownloadRequests.count {
                    state.selectedMessageIds.removeAll()
                } else {
                    state.selectedMessageIds = Set(resolvedDownloadRequests.map(\.messageId))
                }
                return state
            }
        },
        toggleMediaType: { isVideo in
            updateState { state in
                var state = state
                let matchingIds = Set(resolvedDownloadRequests.filter { $0.isVideo == isVideo }.map(\.messageId))
                guard !matchingIds.isEmpty else {
                    return state
                }
                if matchingIds.isSubset(of: state.selectedMessageIds) {
                    state.selectedMessageIds.subtract(matchingIds)
                } else {
                    state.selectedMessageIds.formUnion(matchingIds)
                }
                return state
            }
        },
        chooseDestination: chooseDestination,
        openDownloads: {
            controller?.present(fluxgramDownloadsController(context: context), in: .window(.root))
        },
        analyzeMetadata: analyzeMetadata,
        updateAuthor: updateAuthor,
        updateClassicPath: updateClassicPath
    )

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramDownloadControllerArguments)) in
        let hasSelectedDownloads = !state.selectedMessageIds.isEmpty
        let leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
            let _ = controller?.dismiss()
        })
        let submitTitle: String
        if state.isSubmitting, state.submissionTotalCount > 0 {
            submitTitle = "提交 \(state.submissionCompletedCount)/\(state.submissionTotalCount)"
        } else {
            submitTitle = state.isSubmitting ? "提交中..." : "下载"
        }
        let rightNavigationButton = ItemListNavigationButton(content: .text(submitTitle), style: .bold, enabled: hasSelectedDownloads && !state.isSubmitting, action: {
            let currentState = stateValue.with { $0 }
            guard !currentState.isSubmitting, !currentState.selectedMessageIds.isEmpty else {
                return
            }
            guard !currentState.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentAlert("请先填写主演名后再下载。")
                return
            }
            guard let validSubdir = fluxgramDownloadSubdirectory(currentState.downloadSubdir) else {
                presentAlert("请先选择有效的 NAS 保存目录。")
                return
            }
            let tags = currentState.confirmTags ? currentState.tags.components(separatedBy: ",") : []
            let options = FluxgramNASSubmissionOptions(
                downloadSubdir: validSubdir,
                title: currentState.title,
                note: currentState.note,
                tags: tags,
                inbox: currentState.inbox
            )
            let selectedRequests = fluxgramDeduplicatedDownloadRequests(
                resolvedDownloadRequests.filter { currentState.selectedMessageIds.contains($0.messageId) }
            )
            updateState { state in
                var state = state
                state.isSubmitting = true
                state.submissionCompletedCount = 0
                state.submissionTotalCount = selectedRequests.count
                return state
            }
            service.fetchDownloadFileNames(subdir: validSubdir) { names, error in
                guard let names else {
                    updateState { state in
                        var state = state
                        state.isSubmitting = false
                        return state
                    }
                    presentAlert(error ?? "无法读取 NAS 目录，已取消下载。")
                    return
                }
                let adjustedRequests = fluxgramAllocatedDownloadRequests(
                    selectedRequests,
                    author: currentState.authorName,
                    code: currentState.detectedCode,
                    sourceText: groupSourceText,
                    occupiedFileNames: names
                )
                let previewNames = adjustedRequests.prefix(3).compactMap { $0.desiredFileName }.joined(separator: "\n")
                let remaining = adjustedRequests.count > 3 ? "\n…等 \(adjustedRequests.count) 个文件" : ""
                let normalizedCode = fluxgramNormalizedDownloadCode(currentState.detectedCode)
                let existingSameCode = normalizedCode.isEmpty ? [] : names.filter { name in
                    guard let existingCode = fluxgramDownloadCode(from: name) else { return false }
                    return fluxgramNormalizedDownloadCode(existingCode) == normalizedCode
                }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                let duplicateWarning: String
                if existingSameCode.isEmpty {
                    duplicateWarning = ""
                } else {
                    let displayedNames = existingSameCode.prefix(8).joined(separator: "\n")
                    let more = existingSameCode.count > 8 ? "\n…还有 \(existingSameCode.count - 8) 个媒体" : ""
                    duplicateWarning = "已有疑似重复媒体\n番号：\(currentState.detectedCode)\n当前 NAS 目录已有：\n\(displayedNames)\(more)\n\n是否确认仍要下载？\n\n"
                }
                controller?.present(
                    standardTextAlertController(
                        theme: AlertControllerTheme(presentationData: presentationData),
                        title: existingSameCode.isEmpty ? "确认下载" : "已有疑似重复媒体",
                        text: "\(duplicateWarning)保存到：\(validSubdir.isEmpty ? "NAS 根目录" : validSubdir)\n\n\(previewNames)\(remaining)",
                        actions: [
                            TextAlertAction(type: .genericAction, title: "取消", action: {
                                updateState { state in
                                    var state = state
                                    state.isSubmitting = false
                                    return state
                                }
                            }),
                            TextAlertAction(type: .defaultAction, title: existingSameCode.isEmpty ? "继续下载" : "确认仍要下载", action: {
                                FluxgramDownloadMemoryStore.learn(requests: selectedRequests, author: currentState.authorName, title: currentState.title, tags: tags)
                                service.syncDownloadMemory(
                                    sourceLabel: selectedRequests.first?.sourceLabel ?? "",
                                    sourceText: groupSourceText,
                                    author: currentState.authorName,
                                    title: currentState.title,
                                    tags: tags
                                )
                                service.submit(downloadRequests: adjustedRequests, options: options, progress: { completed, total in
                                    updateState { state in
                                        var state = state
                                        state.submissionCompletedCount = completed
                                        state.submissionTotalCount = total
                                        return state
                                    }
                                }) { results in
                                    updateState { state in
                                        var state = state
                                        state.isSubmitting = false
                                        state.submissionCompletedCount = 0
                                        state.submissionTotalCount = 0
                                        return state
                                    }
                                    let outcomes = zip(adjustedRequests, results)
                                    let failed = outcomes.compactMap { request, result -> (FluxgramNASDownloadRequest, String)? in
                                        if case .failed = result { return (request, result.message) }
                                        return nil
                                    }
                                    let queued = outcomes.filter { _, result in
                                        if case .pending = result { return true }
                                        return false
                                    }.count
                                    let duplicates = outcomes.filter { _, result in
                                        if case let .submitted(message) = result {
                                            return message.contains("未重复")
                                        }
                                        return false
                                    }.count
                                    let accepted = outcomes.filter { _, result in
                                        if case .submitted = result { return true }
                                        return false
                                    }.count - duplicates
                                    if failed.isEmpty, queued == 0 {
                                        if duplicates > 0 {
                                            presentAlert("已处理 NAS 请求：\(max(0, accepted)) 个新任务，\(duplicates) 个请求已确认在队列中，未创建重复任务。")
                                        } else {
                                            presentSubmissionResult(adjustedRequests.count)
                                        }
                                    } else {
                                        updateState { state in
                                            var state = state
                                            state.selectedMessageIds = Set(failed.map { $0.0.messageId })
                                            return state
                                        }
                                        let submittedCount = max(0, accepted)
                                        let errors = failed.prefix(2).map { $0.1 }.joined(separator: "\n")
                                        var details: [String] = []
                                        if submittedCount > 0 { details.append("已加入 NAS 队列：\(submittedCount) 个") }
                                        if duplicates > 0 { details.append("\(duplicates) 个请求已确认在 NAS 队列中，未创建重复任务") }
                                        if queued > 0 { details.append("已保存到本地队列：\(queued) 个，恢复连接后会自动提交") }
                                        if !errors.isEmpty { details.append("请重试仍被选中的 \(failed.count) 个项目。\n\(errors)") }
                                        presentAlert(details.joined(separator: "\n\n"))
                                    }
                                }
                            })
                        ],
                        actionLayout: .vertical
                    ),
                    in: .window(.root)
                )
            }
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("下载到 NAS"),
            leftNavigationButton: leftNavigationButton,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fluxgramDownloadEntries(state: state, downloadRequests: resolvedDownloadRequests),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}
