import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

private enum FluxgramRulesSection: Int32 {
    case overview
    case recognition
    case downloads
    case learning
}

private enum FluxgramRulesEntry: ItemListNodeEntry {
    case overview(String)
    case authorEvidence
    case tagConfirmation
    case fileName
    case duplicateProtection
    case learningSummary(String)
    case learningRecords

    var section: ItemListSectionId {
        switch self {
        case .overview:
            return FluxgramRulesSection.overview.rawValue
        case .authorEvidence, .tagConfirmation:
            return FluxgramRulesSection.recognition.rawValue
        case .fileName, .duplicateProtection:
            return FluxgramRulesSection.downloads.rawValue
        case .learningSummary, .learningRecords:
            return FluxgramRulesSection.learning.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .overview:
            return 0
        case .authorEvidence:
            return 1
        case .tagConfirmation:
            return 2
        case .fileName:
            return 3
        case .duplicateProtection:
            return 4
        case .learningSummary:
            return 5
        case .learningRecords:
            return 6
        }
    }

    static func <(lhs: FluxgramRulesEntry, rhs: FluxgramRulesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramRulesControllerArguments
        switch self {
        case let .overview(text):
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "整理规则",
                text: .plain(text),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .authorEvidence:
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "作者名只取原文证据",
                text: .plain("AI 优先读取文字消息中的作者、主演、署名或账号；不会把 Telegram 发送者、平台名或普通话题标签当成作者。多位主演会让你选择一位。"),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .tagConfirmation:
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "关键词必须确认",
                text: .plain("只分析你手动选中的文字摘要。AI 建议的成人向、服装、动作和题材标签可编辑，只有确认后才会写入下载整理和学习记录。原文件不会上传给 AI。"),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .fileName:
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "命名与目录建议",
                text: .plain("下载前必须填写主演名。含番号时默认命名为“番号-主演名”；没有番号时为“主演名-序号”。日本主演且有番号时建议保存到“经典/主演名”，目录仍可手动修改。"),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .duplicateProtection:
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "重复保护",
                text: .plain("提交前会读取目标 NAS 目录：相同番号会提示可能重复；同名文件或同组多个媒体会自动追加 -2、-3，避免覆盖。网络异常的提交只会保存在本机等待重试。"),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case let .learningSummary(text):
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "本地学习",
                text: .plain(text),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case .learningRecords:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .legacy,
                title: "查看学习记录",
                label: "确认案例与同步状态",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: arguments.openLearningRecords
            )
        }
    }
}

private final class FluxgramRulesControllerArguments {
    let openLearningRecords: () -> Void

    init(openLearningRecords: @escaping () -> Void) {
        self.openLearningRecords = openLearningRecords
    }
}

private func fluxgramRulesEntries() -> [FluxgramRulesEntry] {
    let entries = FluxgramDownloadMemoryStore.allEntries()
    let pendingCount = entries.filter(\.needsUpload).count
    let learningSummary = [
        "已保存确认案例：\(entries.count) 条",
        pendingCount == 0 ? "同步状态：已同步或尚无记录" : "待同步到 NAS：\(pendingCount) 条",
        "学习不是训练模型。下次手动分析时，系统只将少量相关的文字案例作为参考发给 AI。"
    ].joined(separator: "\n")
    return [
        .overview("这里展示 Fluxgram 当前实际执行的识别、命名和去重逻辑。规则用于帮助你核对结果，不会自动修改 NAS 中的任务或文件。"),
        .authorEvidence,
        .tagConfirmation,
        .fileName,
        .duplicateProtection,
        .learningSummary(learningSummary),
        .learningRecords
    ]
}

func fluxgramRulesController(context: AccountContext) -> ViewController {
    var controller: ItemListController?
    let arguments = FluxgramRulesControllerArguments(openLearningRecords: {
        controller?.push(fluxgramLearningRecordsController(context: context))
    })
    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, FluxgramRulesControllerArguments)) in
        let itemListPresentationData = ItemListPresentationData(presentationData)
        let state = ItemListControllerState(
            presentationData: itemListPresentationData,
            title: .text("整理规则"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: itemListPresentationData,
            entries: fluxgramRulesEntries(),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: false
        )
        return (state, (listState, arguments))
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}
