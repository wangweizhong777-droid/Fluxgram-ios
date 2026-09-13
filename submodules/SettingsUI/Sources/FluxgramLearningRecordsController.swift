import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

private struct FluxgramLearningRecordsState: Equatable {
    var entries: [FluxgramDownloadMemoryEntry]
    var status: String
}

private enum FluxgramLearningRecordsSection: Int32 {
    case summary
    case records
    case actions
}

private enum FluxgramLearningRecordsEntry: ItemListNodeEntry {
    case summary(String)
    case record(Int, FluxgramDownloadMemoryEntry)
    case empty
    case sync
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .summary:
            return FluxgramLearningRecordsSection.summary.rawValue
        case .record, .empty:
            return FluxgramLearningRecordsSection.records.rawValue
        case .sync, .status:
            return FluxgramLearningRecordsSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .summary:
            return 0
        case let .record(index, entry):
            return 1000 + Int32(abs(entry.signature.hashValue % 500_000)) + Int32(index)
        case .empty:
            return 1
        case .sync:
            return 2
        case .status:
            return 3
        }
    }

    static func <(lhs: FluxgramLearningRecordsEntry, rhs: FluxgramLearningRecordsEntry) -> Bool {
        func order(_ entry: FluxgramLearningRecordsEntry) -> (Int32, Int32) {
            switch entry {
            case .summary:
                return (FluxgramLearningRecordsSection.summary.rawValue, 0)
            case let .record(index, _):
                return (FluxgramLearningRecordsSection.records.rawValue, Int32(index))
            case .empty:
                return (FluxgramLearningRecordsSection.records.rawValue, 999)
            case .sync:
                return (FluxgramLearningRecordsSection.actions.rawValue, 0)
            case .status:
                return (FluxgramLearningRecordsSection.actions.rawValue, 1)
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
        let arguments = arguments as! FluxgramLearningRecordsControllerArguments
        switch self {
        case let .summary(text):
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "AI 学习记录",
                text: .plain(text),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case let .record(_, entry):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: fluxgramLearningRecordTitle(entry),
                label: fluxgramLearningRecordLabel(entry),
                labelStyle: .multilineDetailText,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.showRecord(entry)
                }
            )
        case .empty:
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("还没有学习记录。你在聊天里点 AI 分析，然后确认/修改识别结果后，这里就会出现记录。"),
                sectionId: self.section
            )
        case .sync:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "立即同步到 NAS",
                kind: .generic,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: arguments.sync
            )
        case let .status(text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        }
    }
}

private final class FluxgramLearningRecordsControllerArguments {
    let sync: () -> Void
    let showRecord: (FluxgramDownloadMemoryEntry) -> Void

    init(sync: @escaping () -> Void, showRecord: @escaping (FluxgramDownloadMemoryEntry) -> Void) {
        self.sync = sync
        self.showRecord = showRecord
    }
}

private func fluxgramLearningRecordTime(_ value: TimeInterval) -> String {
    guard value > 0 else {
        return "未知时间"
    }
    return DateFormatter.localizedString(from: Date(timeIntervalSince1970: value), dateStyle: .short, timeStyle: .short)
}

private func fluxgramLearningTrim(_ value: String, limit: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else {
        return trimmed
    }
    let index = trimmed.index(trimmed.startIndex, offsetBy: limit)
    return String(trimmed[..<index]) + "…"
}

private func fluxgramLearningRecordTitle(_ entry: FluxgramDownloadMemoryEntry) -> String {
    if !entry.author.isEmpty {
        return entry.author
    }
    if !entry.title.isEmpty {
        return entry.title
    }
    return "未识别作者"
}

private func fluxgramLearningRecordLabel(_ entry: FluxgramDownloadMemoryEntry) -> String {
    var lines: [String] = []
    if !entry.title.isEmpty {
        lines.append("标题：\(entry.title)")
    }
    if !entry.tags.isEmpty {
        lines.append("标签：\(entry.tags.joined(separator: "、"))")
    }
    if !entry.sourceLabel.isEmpty {
        lines.append("来源：\(fluxgramLearningTrim(entry.sourceLabel, limit: 40))")
    }
    if !entry.sourceText.isEmpty {
        lines.append("原文：\(fluxgramLearningTrim(entry.sourceText.replacingOccurrences(of: "\n", with: " "), limit: 80))")
    }
    lines.append(entry.needsUpload ? "状态：待同步到 NAS" : "状态：已同步")
    lines.append("时间：\(fluxgramLearningRecordTime(entry.updatedAt))")
    return lines.joined(separator: "\n")
}

private func fluxgramLearningRecordsSummary(_ entries: [FluxgramDownloadMemoryEntry]) -> String {
    let pendingCount = entries.filter(\.needsUpload).count
    return [
        "这里显示 Fluxgram 在此 iPhone 上保存的确认案例。它不是训练模型，而是在你下次手动点 AI 分析时，把相似案例作为参考发给模型。",
        "本地记录：\(entries.count) 条",
        "待同步 NAS：\(pendingCount) 条"
    ].joined(separator: "\n")
}

private func fluxgramLearningRecordDetails(_ entry: FluxgramDownloadMemoryEntry) -> String {
    return [
        "作者名：\(entry.author.isEmpty ? "未填写" : entry.author)",
        "标题：\(entry.title.isEmpty ? "未填写" : entry.title)",
        "标签：\(entry.tags.isEmpty ? "未填写" : entry.tags.joined(separator: "、"))",
        "同步状态：\(entry.needsUpload ? "待同步到 NAS" : "已同步")",
        "时间：\(fluxgramLearningRecordTime(entry.updatedAt))",
        "",
        "来源：",
        entry.sourceLabel.isEmpty ? "未记录" : entry.sourceLabel,
        "",
        "原文：",
        entry.sourceText.isEmpty ? "未记录" : entry.sourceText
    ].joined(separator: "\n")
}

private func fluxgramLearningRecordsEntries(_ state: FluxgramLearningRecordsState) -> [FluxgramLearningRecordsEntry] {
    var entries: [FluxgramLearningRecordsEntry] = [
        .summary(fluxgramLearningRecordsSummary(state.entries))
    ]
    if state.entries.isEmpty {
        entries.append(.empty)
    } else {
        entries.append(contentsOf: state.entries.prefix(80).enumerated().map { .record($0.offset, $0.element) })
    }
    entries.append(.sync)
    if !state.status.isEmpty {
        entries.append(.status(state.status))
    }
    return entries
}

public func fluxgramLearningRecordsController(context: AccountContext) -> ViewController {
    let initialState = FluxgramLearningRecordsState(entries: FluxgramDownloadMemoryStore.allEntries(), status: "")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((FluxgramLearningRecordsState) -> FluxgramLearningRecordsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var controller: ItemListController?
    let refresh: (String) -> Void = { status in
        updateState { state in
            var state = state
            state.entries = FluxgramDownloadMemoryStore.allEntries()
            state.status = status
            return state
        }
    }
    let presentAlert: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            standardTextAlertController(
                theme: AlertControllerTheme(presentationData: presentationData),
                title: nil,
                text: text,
                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
            ),
            in: .window(.root)
        )
    }

    let arguments = FluxgramLearningRecordsControllerArguments(sync: {
        refresh("正在同步到 NAS…")
        FluxgramNASService.shared.syncPendingDownloadMemory { uploaded, remaining, error in
            let message: String
            if uploaded > 0 {
                if let error, remaining > 0 {
                    message = "已同步 \(uploaded) 条学习记录，剩余 \(remaining) 条。\n\(error)"
                } else {
                    message = "已同步 \(uploaded) 条学习记录，剩余 \(remaining) 条。"
                }
            } else if remaining > 0 {
                message = [
                    "暂时还有 \(remaining) 条没有同步。",
                    error ?? "请检查 TGAPP 地址、访问令牌和 NAS 后端。"
                ].joined(separator: "\n")
            } else {
                message = "学习记录已全部同步。"
            }
            refresh(message)
        }
    }, showRecord: { entry in
        presentAlert(fluxgramLearningRecordDetails(entry))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, FluxgramLearningRecordsControllerArguments)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("学习记录"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fluxgramLearningRecordsEntries(state),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
