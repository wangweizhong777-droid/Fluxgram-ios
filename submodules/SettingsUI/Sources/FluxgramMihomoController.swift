import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

private enum FluxgramMihomoState: Equatable {
    case loading
    case loaded(FluxgramMihomoStatus)
    case failed(String)
}

private enum FluxgramMihomoEntry: ItemListNodeEntry {
    case statusHeader
    case status(String)
    case providersHeader
    case provider(id: Int32, value: FluxgramMihomoProvider)
    case groupsHeader
    case group(id: Int32, value: FluxgramMihomoGroup)
    case refresh

    var section: ItemListSectionId {
        switch self {
        case .statusHeader, .status:
            return 0
        case .providersHeader, .provider:
            return 1
        case .groupsHeader, .group:
            return 2
        case .refresh:
            return 3
        }
    }

    var stableId: Int32 {
        switch self {
        case .statusHeader: return 0
        case .status: return 1
        case .providersHeader: return 2
        case let .provider(id, _): return id
        case .groupsHeader: return 200_000
        case let .group(id, _): return id
        case .refresh: return 400_000
        }
    }

    static func <(lhs: FluxgramMihomoEntry, rhs: FluxgramMihomoEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramMihomoControllerArguments
        switch self {
        case .statusHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "Mihomo 状态", sectionId: self.section)
        case let .status(text):
            return ItemListInfoItem(presentationData: presentationData, systemStyle: .legacy, title: "运行信息", text: .plain(text), style: .blocks, sectionId: self.section, closeAction: nil)
        case .providersHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "订阅", sectionId: self.section)
        case let .provider(_, provider):
            let label = "\(provider.vehicleCount) 个节点 · 点击刷新"
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .legacy, title: provider.name, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.refreshProvider(provider.name)
            })
        case .groupsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "代理组", sectionId: self.section)
        case let .group(_, group):
            let current = group.now ?? "未选择"
            let label = "\(current) · \(group.candidates.count) 个候选节点"
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .legacy, title: group.name, label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .arrow, action: {
                arguments.selectGroup(group)
            })
        case .refresh:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .legacy, title: "刷新 Mihomo 状态", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: arguments.refresh)
        }
    }
}

private final class FluxgramMihomoControllerArguments {
    let refresh: () -> Void
    let refreshProvider: (String) -> Void
    let selectGroup: (FluxgramMihomoGroup) -> Void

    init(refresh: @escaping () -> Void, refreshProvider: @escaping (String) -> Void, selectGroup: @escaping (FluxgramMihomoGroup) -> Void) {
        self.refresh = refresh
        self.refreshProvider = refreshProvider
        self.selectGroup = selectGroup
    }
}

private func fluxgramMihomoBytes(_ value: Int64?) -> String {
    guard let value, value >= 0 else { return "暂无" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var number = Double(value)
    var index = 0
    while number >= 1024 && index < units.count - 1 {
        number /= 1024
        index += 1
    }
    return String(format: "%.2f %@", number, units[index])
}

private func fluxgramMihomoStatusText(_ state: FluxgramMihomoState) -> String {
    switch state {
    case .loading:
        return "正在读取 Mihomo 状态。"
    case let .failed(message):
        return message
    case let .loaded(status):
        let groupLines = status.groups.map { "\($0.name)：\($0.now ?? "未选择")" }
        let providerCount = status.providers.reduce(0) { $0 + $1.vehicleCount }
        return ([
            "核心版本：\(status.version ?? "未知")",
            "订阅节点：\(providerCount) 个",
        ] + groupLines).joined(separator: "\n")
    }
}

private func fluxgramMihomoEntries(_ state: FluxgramMihomoState) -> [FluxgramMihomoEntry] {
    var entries: [FluxgramMihomoEntry] = [.statusHeader, .status(fluxgramMihomoStatusText(state))]
    if case let .loaded(status) = state {
        if !status.providers.isEmpty {
            entries.append(.providersHeader)
            let providers = status.providers.sorted { $0.name < $1.name }
            entries.append(contentsOf: providers.enumerated().map { index, provider in
                .provider(id: 10 + Int32(index), value: provider)
            })
        }
        if !status.groups.isEmpty {
            entries.append(.groupsHeader)
            let groups = status.groups.sorted { $0.name < $1.name }
            entries.append(contentsOf: groups.enumerated().map { index, group in
                .group(id: 200_010 + Int32(index), value: group)
            })
        }
    }
    entries.append(.refresh)
    // ItemListControllerNode requires entries to be strictly ordered by ID.
    // Keep this invariant at the boundary even if a future section is added.
    return entries.sorted()
}

func fluxgramMihomoController(context: AccountContext, settings: FluxgramSettings) -> ViewController {
    let stateValue = Atomic(value: FluxgramMihomoState.loading)
    let statePromise = ValuePromise(FluxgramMihomoState.loading, ignoreRepeated: true)
    var controller: ItemListController?

    let presentAlert: (String) -> Void = { message in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: presentationData), title: nil, text: message, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }
    let reload: () -> Void = {
        statePromise.set(stateValue.modify { _ in .loading })
        FluxgramMihomoService.shared.fetchStatus(settings: settings) { status, error in
            statePromise.set(stateValue.modify { _ in
                if let status { return .loaded(status) }
                return .failed(error ?? "无法读取 Mihomo 状态。")
            })
        }
    }
    let refreshProvider: (String) -> Void = { name in
        FluxgramMihomoService.shared.refreshProvider(settings: settings, name: name) { success, error in
            if success {
                reload()
            } else {
                presentAlert(error ?? "订阅刷新失败。")
            }
        }
    }
    let selectGroup: (FluxgramMihomoGroup) -> Void = { group in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: group.name)]
        for candidate in group.candidates.prefix(100) {
            items.append(ActionSheetButtonItem(title: candidate + (candidate == group.now ? "（当前）" : ""), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                FluxgramMihomoService.shared.selectGroup(settings: settings, group: group.name, name: candidate) { success, error in
                    if success { reload() } else { presentAlert(error ?? "代理组切换失败。") }
                }
            }))
        }
        items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in actionSheet?.dismissAnimated() }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        controller?.present(actionSheet, in: .window(.root))
    }
    let arguments = FluxgramMihomoControllerArguments(refresh: reload, refreshProvider: refreshProvider, selectGroup: selectGroup)
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramMihomoControllerArguments)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Mihomo 管理"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: fluxgramMihomoEntries(state), style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    reload()
    return result
}
