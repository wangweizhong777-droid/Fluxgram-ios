import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent

private struct FluxgramDownloadControllerState: Equatable {
    var downloadSubdir: String
    var note: String
    var tags: String
    var inbox: Bool
    var selectedMessageIds: Set<Int32>
    var isSubmitting: Bool
}

private enum FluxgramDownloadSection: Int32 {
    case media
    case destination
    case metadata
}

private enum FluxgramDownloadEntry: ItemListNodeEntry {
    case mediaHeader
    case selectAll(Bool)
    case media(Int, FluxgramNASDownloadRequest, Bool)
    case destinationHeader
    case destination(String)
    case chooseDestination
    case downloadStatus
    case metadataHeader
    case note(String)
    case tags(String)
    case inbox(Bool)

    var section: ItemListSectionId {
        switch self {
        case .mediaHeader, .selectAll, .media:
            return FluxgramDownloadSection.media.rawValue
        case .destinationHeader, .destination, .chooseDestination, .downloadStatus:
            return FluxgramDownloadSection.destination.rawValue
        case .metadataHeader, .note, .tags, .inbox:
            return FluxgramDownloadSection.metadata.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .mediaHeader:
            return 10
        case .selectAll:
            return 11
        case let .media(_, download, _):
            return 100_000_000 + Int32(download.messageId % 900_000_000)
        case .destinationHeader:
            return 20
        case .destination:
            return 21
        case .chooseDestination:
            return 22
        case .downloadStatus:
            return 23
        case .metadataHeader:
            return 30
        case .note:
            return 31
        case .tags:
            return 32
        case .inbox:
            return 33
        }
    }

    static func <(lhs: FluxgramDownloadEntry, rhs: FluxgramDownloadEntry) -> Bool {
        func sortIndex(_ entry: FluxgramDownloadEntry) -> Int {
            switch entry {
            case .mediaHeader:
                return 0
            case .selectAll:
                return 1
            case let .media(index, _, _):
                return 2 + index
            case .destinationHeader:
                return 1_000_000
            case .destination:
                return 1_000_001
            case .chooseDestination:
                return 1_000_002
            case .downloadStatus:
                return 1_000_003
            case .metadataHeader:
                return 2_000_000
            case .note:
                return 2_000_001
            case .tags:
                return 2_000_002
            case .inbox:
                return 2_000_003
            }
        }
        return sortIndex(lhs) < sortIndex(rhs)
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramDownloadControllerArguments
        switch self {
        case .mediaHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "相册视频", sectionId: self.section)
        case let .selectAll(allSelected):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: allSelected ? "取消全选" : "全选",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.toggleAll()
                }
            )
        case let .media(_, download, selected):
            let subtitle: String?
            if let document = download.directDocument, document.fileSize > 0 {
                subtitle = "\(max(1, document.fileSize / 1_048_576)) MB"
            } else {
                subtitle = nil
            }
            return ItemListCheckboxItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "下载位置", sectionId: self.section)
        case let .destination(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "子文件夹", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "NAS 根目录",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.downloadSubdir = value
                        return state
                    }
                },
                action: {}
            )
        case .chooseDestination:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
                systemStyle: .glass,
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
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "附加信息", sectionId: self.section)
        case let .note(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
        case let .tags(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
        case let .inbox(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
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
    let chooseDestination: () -> Void
    let openDownloads: () -> Void

    init(
        updateState: @escaping ((FluxgramDownloadControllerState) -> FluxgramDownloadControllerState) -> Void,
        toggleSelection: @escaping (Int32) -> Void,
        toggleAll: @escaping () -> Void,
        chooseDestination: @escaping () -> Void,
        openDownloads: @escaping () -> Void
    ) {
        self.updateState = updateState
        self.toggleSelection = toggleSelection
        self.toggleAll = toggleAll
        self.chooseDestination = chooseDestination
        self.openDownloads = openDownloads
    }
}

private func fluxgramDownloadEntries(state: FluxgramDownloadControllerState, downloadRequests: [FluxgramNASDownloadRequest]) -> [FluxgramDownloadEntry] {
    var entries: [FluxgramDownloadEntry] = []
    if downloadRequests.count > 1 {
        entries.append(.mediaHeader)
        entries.append(.selectAll(state.selectedMessageIds.count == downloadRequests.count))
        entries.append(contentsOf: downloadRequests.enumerated().map { index, download in
            return .media(index, download, state.selectedMessageIds.contains(download.messageId))
        })
    }
    entries.append(contentsOf: [
        .destinationHeader,
        .destination(state.downloadSubdir),
        .chooseDestination,
        .downloadStatus,
        .metadataHeader,
        .note(state.note),
        .tags(state.tags),
        .inbox(state.inbox)
    ])
    return entries
}

private func fluxgramDownloadSubdirectory(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.hasPrefix("/"), value.rangeOfCharacter(from: .newlines) == nil else {
        return nil
    }
    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty, !components.contains("..") else {
        return nil
    }
    return components.joined(separator: "/")
}

private func fluxgramNewDownloadFolderAlert(context: AccountContext, submit: @escaping (String) -> Void) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let inputState = AlertInputFieldComponent.ExternalState()
    let doneIsEnabled = inputState.valueSignal
    |> map { value in
        return fluxgramDownloadSubdirectory(value) != nil
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
        guard let folder = fluxgramDownloadSubdirectory(inputState.value) else {
            inputState.animateError()
            return
        }
        controller.dismiss()
        submit(folder)
    }
    return controller
}

public func fluxgramDownloadFolderActionSheet(context: AccountContext, dialogId: Int64, messageId: Int32, peerAccessHash: String?, directDocument: FluxgramNASDirectDocument?, directDownloads: [FluxgramNASDirectDownload] = [], downloadRequests: [FluxgramNASDownloadRequest] = [], defaultDownloadSubdir: String? = nil, present: @escaping (ViewController) -> Void) {
    let requests: [FluxgramNASDownloadRequest]
    if !downloadRequests.isEmpty {
        requests = downloadRequests
    } else if !directDownloads.isEmpty {
        requests = directDownloads.map { download in
            return FluxgramNASDownloadRequest(dialogId: download.dialogId, messageId: download.messageId, directDocument: download.document)
        }
    } else if let directDocument {
        requests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, directDocument: directDocument)]
    } else {
        requests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, peerAccessHash: peerAccessHash)]
    }
    let service = FluxgramNASService.shared
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let defaultFolder = defaultDownloadSubdir.flatMap(fluxgramDownloadSubdirectory)

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
        let options = FluxgramNASSubmissionOptions(downloadSubdir: folder)
        service.submit(downloadRequests: requests, options: options) { results in
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
            if failed.isEmpty, queued == 0 {
                presentAlert("已将 \(requests.count) 个项目加入 NAS 下载队列。")
            } else {
                let errors = failed.prefix(2).map(\.message).joined(separator: "\n")
                var details: [String] = []
                if submitted > 0 { details.append("已加入 NAS 队列：\(submitted) 个") }
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
                        downloadRequests: downloadRequests
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

public func fluxgramDownloadController(context: AccountContext, dialogId: Int64, messageId: Int32, peerAccessHash: String?, directDocument: FluxgramNASDirectDocument?, directDownloads: [FluxgramNASDirectDownload] = [], downloadRequests: [FluxgramNASDownloadRequest] = []) -> ViewController {
    let resolvedDownloadRequests: [FluxgramNASDownloadRequest]
    if !downloadRequests.isEmpty {
        resolvedDownloadRequests = downloadRequests
    } else if !directDownloads.isEmpty {
        resolvedDownloadRequests = directDownloads.map { download in
            FluxgramNASDownloadRequest(dialogId: download.dialogId, messageId: download.messageId, directDocument: download.document)
        }
    } else if let directDocument {
        resolvedDownloadRequests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, directDocument: directDocument)]
    } else {
        resolvedDownloadRequests = [FluxgramNASDownloadRequest(dialogId: dialogId, messageId: messageId, peerAccessHash: peerAccessHash)]
    }
    let initialState = FluxgramDownloadControllerState(downloadSubdir: "", note: "", tags: "", inbox: false, selectedMessageIds: Set(resolvedDownloadRequests.map(\.messageId)), isSubmitting: false)
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
                        controller?.push(fluxgramDownloadsController(context: context))
                    })
                ],
                actionLayout: .vertical
            ),
            in: .window(.root)
        )
    }

    let chooseDestination: () -> Void = {
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
        controller?.present(actionSheet, in: .window(.root))
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
        chooseDestination: chooseDestination,
        openDownloads: {
            controller?.push(fluxgramDownloadsController(context: context))
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramDownloadControllerArguments)) in
        let hasSelectedDownloads = !state.selectedMessageIds.isEmpty
        let rightNavigationButton = ItemListNavigationButton(content: .text(state.isSubmitting ? "提交中..." : "下载"), style: .bold, enabled: hasSelectedDownloads && !state.isSubmitting, action: {
            let currentState = stateValue.with { $0 }
            guard !currentState.isSubmitting, !currentState.selectedMessageIds.isEmpty else {
                return
            }
            let tags = currentState.tags.components(separatedBy: ",")
            let options = FluxgramNASSubmissionOptions(
                downloadSubdir: currentState.downloadSubdir,
                note: currentState.note,
                tags: tags,
                inbox: currentState.inbox
            )
            let selectedRequests = resolvedDownloadRequests.filter { currentState.selectedMessageIds.contains($0.messageId) }
            updateState { state in
                var state = state
                state.isSubmitting = true
                return state
            }
            service.submit(downloadRequests: selectedRequests, options: options) { results in
                updateState { state in
                    var state = state
                    state.isSubmitting = false
                    return state
                }
                let outcomes = zip(selectedRequests, results)
                let failed = outcomes.compactMap { request, result -> (FluxgramNASDownloadRequest, String)? in
                    if case .failed = result { return (request, result.message) }
                    return nil
                }
                let queued = outcomes.filter { _, result in
                    if case .pending = result { return true }
                    return false
                }.count
                if failed.isEmpty, queued == 0 {
                    presentSubmissionResult(selectedRequests.count)
                } else {
                    updateState { state in
                        var state = state
                        state.selectedMessageIds = Set(failed.map { $0.0.messageId })
                        return state
                    }
                    let submittedCount = selectedRequests.count - failed.count - queued
                    let errors = failed.prefix(2).map { $0.1 }.joined(separator: "\n")
                    var details: [String] = []
                    if submittedCount > 0 { details.append("已加入 NAS 队列：\(submittedCount) 个") }
                    if queued > 0 { details.append("已保存到本地队列：\(queued) 个，恢复连接后会自动提交") }
                    if !errors.isEmpty { details.append("请重试仍被选中的 \(failed.count) 个项目。\n\(errors)") }
                    presentAlert(details.joined(separator: "\n\n"))
                }
            }
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("下载到 NAS"),
            leftNavigationButton: nil,
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
