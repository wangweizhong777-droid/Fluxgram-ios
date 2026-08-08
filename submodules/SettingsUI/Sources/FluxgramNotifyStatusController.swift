import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

private enum FluxgramNotifyStatusSection: Int32 {
    case status
    case actions
}

private enum FluxgramNotifyStatusState: Equatable {
    case loading
    case loaded(FluxgramNotifyListenerStatus)
    case updating(FluxgramNotifyListenerStatus)
    case failed(String)
}

private enum FluxgramNotifyStatusEntry: ItemListNodeEntry {
    case statusHeader
    case details(String)
    case enabled(Bool)
    case refresh

    var section: ItemListSectionId {
        switch self {
        case .statusHeader, .details, .enabled:
            return FluxgramNotifyStatusSection.status.rawValue
        case .refresh:
            return FluxgramNotifyStatusSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .statusHeader:
            return 0
        case .details:
            return 1
        case .enabled:
            return 2
        case .refresh:
            return 3
        }
    }

    static func <(lhs: FluxgramNotifyStatusEntry, rhs: FluxgramNotifyStatusEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramNotifyStatusControllerArguments
        switch self {
        case .statusHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "NAS 通知监听", sectionId: self.section)
        case let .details(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .enabled(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "消息推送",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.setEnabled(value)
                }
            )
        case .refresh:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "刷新状态",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: arguments.refresh
            )
        }
    }
}

private final class FluxgramNotifyStatusControllerArguments {
    let refresh: () -> Void
    let setEnabled: (Bool) -> Void

    init(refresh: @escaping () -> Void, setEnabled: @escaping (Bool) -> Void) {
        self.refresh = refresh
        self.setEnabled = setEnabled
    }
}

private func fluxgramNotifyStatusTime(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "暂无" }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else { return value }
    return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)
}

private func fluxgramNotifyStatusDetails(_ state: FluxgramNotifyStatusState) -> String {
    switch state {
    case .loading:
        return "正在读取 NAS 通知监听状态。"
    case let .failed(message):
        return message
    case let .loaded(status):
        return fluxgramNotifyStatusDetails(status)
    case let .updating(status):
        return fluxgramNotifyStatusDetails(status) + "\n正在切换消息推送状态。"
    }
}

private func fluxgramNotifyStatusDetails(_ status: FluxgramNotifyListenerStatus) -> String {
        let connection: String
        switch status.connection {
        case "realtime":
            connection = "实时监听正常"
        case "polling":
            connection = "轮询兜底中"
        default:
            connection = "连接中断"
        }
        return [
            "消息推送：\((status.enabled ?? true) ? "已开启" : "已关闭")",
            "连接：\(connection)",
            "上次同步：\(fluxgramNotifyStatusTime(status.lastTelegramSyncAt))",
            "Bark 最近成功：\(fluxgramNotifyStatusTime(status.lastBarkSuccessAt))",
            "Bark 最近失败：\(fluxgramNotifyStatusTime(status.lastBarkFailureAt))",
            "静音过滤：\(status.counters.mutedSkipped) 条",
            "实时处理：\(status.counters.realtimeMessages) 条",
            "轮询处理：\(status.counters.pollingMessages) 条",
            "Bark 成功/失败：\(status.counters.barkSuccess) / \(status.counters.barkFailure)"
        ].joined(separator: "\n")
}

private func fluxgramNotifyStatusEntries(_ state: FluxgramNotifyStatusState) -> [FluxgramNotifyStatusEntry] {
    var entries: [FluxgramNotifyStatusEntry] = [.statusHeader, .details(fluxgramNotifyStatusDetails(state))]
    switch state {
    case let .loaded(status), let .updating(status):
        entries.append(.enabled(status.enabled ?? true))
    case .loading, .failed:
        break
    }
    entries.append(.refresh)
    return entries
}

func fluxgramNotifyStatusController(context: AccountContext, settings: FluxgramSettings) -> ViewController {
    let stateValue = Atomic(value: FluxgramNotifyStatusState.loading)
    let statePromise = ValuePromise(FluxgramNotifyStatusState.loading, ignoreRepeated: true)
    let reload: () -> Void = {
        statePromise.set(stateValue.modify { _ in .loading })
        FluxgramNASService.shared.fetchNotifyListenerStatus(settings: settings) { status, error in
            statePromise.set(stateValue.modify { _ in
                if let status {
                    return .loaded(status)
                }
                return .failed(error ?? "无法读取 NAS 监听状态。")
            })
        }
    }
    let setEnabled: (Bool) -> Void = { enabled in
        guard case let .loaded(status) = stateValue.with({ $0 }) else { return }
        statePromise.set(stateValue.modify { _ in .updating(status) })
        FluxgramNASService.shared.setNotifyListenerEnabled(settings: settings, enabled: enabled) { updatedStatus, error in
            statePromise.set(stateValue.modify { _ in
                if let updatedStatus {
                    return .loaded(updatedStatus)
                }
                return .failed(error ?? "无法切换 NAS 消息推送。")
            })
        }
    }
    let arguments = FluxgramNotifyStatusControllerArguments(refresh: reload, setEnabled: setEnabled)
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramNotifyStatusControllerArguments)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("NAS 监听状态"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fluxgramNotifyStatusEntries(state),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }
    reload()
    return ItemListController(context: context, state: signal)
}
