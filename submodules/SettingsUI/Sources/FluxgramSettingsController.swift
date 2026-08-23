import Foundation
import Security
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext

// Settings are information-dense, so use the compact opaque card treatment.
// This keeps labels and input fields readable against the dark grouped list
// background while leaving glass for navigation-level surfaces.
private let fluxgramItemListSystemStyle: ItemListSystemStyle = .legacy

struct FluxgramSettings: Equatable, Codable {
    var localBaseURL: String
    var remoteBaseURL: String
    var accessToken: String
    var notifyStatusURL: String
    var notifyStatusToken: String

    init(localBaseURL: String, remoteBaseURL: String, accessToken: String, notifyStatusURL: String = "", notifyStatusToken: String = "") {
        self.localBaseURL = localBaseURL
        self.remoteBaseURL = remoteBaseURL
        self.accessToken = accessToken
        self.notifyStatusURL = notifyStatusURL
        self.notifyStatusToken = notifyStatusToken
    }

    private enum CodingKeys: String, CodingKey {
        case localBaseURL
        case remoteBaseURL
        case accessToken
        case notifyStatusURL
        case notifyStatusToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.localBaseURL = try container.decode(String.self, forKey: .localBaseURL)
        self.remoteBaseURL = try container.decode(String.self, forKey: .remoteBaseURL)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.notifyStatusURL = try container.decodeIfPresent(String.self, forKey: .notifyStatusURL) ?? ""
        self.notifyStatusToken = try container.decodeIfPresent(String.self, forKey: .notifyStatusToken) ?? ""
    }
}

enum FluxgramSettingsStoreError: Error {
    case encoding
    case unexpectedStatus(OSStatus)
}

enum FluxgramSettingsStore {
    private static let service = "com.fluxgram.ios.settings"
    private static let account = "tgapp.configuration.v1"

    private static func query(service: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: self.account
        ]
    }

    private static var query: [String: Any] {
        return self.query(service: self.service)
    }

    static func load() throws -> FluxgramSettings {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return FluxgramSettings(localBaseURL: "", remoteBaseURL: "", accessToken: "")
        }
        guard status == errSecSuccess, let data = result as? Data, let settings = try? JSONDecoder().decode(FluxgramSettings.self, from: data) else {
            throw FluxgramSettingsStoreError.unexpectedStatus(status)
        }
        return settings
    }

    static func save(_ settings: FluxgramSettings) throws {
        guard let data = try? JSONEncoder().encode(settings) else {
            throw FluxgramSettingsStoreError.encoding
        }

        let status = SecItemCopyMatching(self.query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(self.query as CFDictionary, [
                kSecValueData as String: data
            ] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw FluxgramSettingsStoreError.unexpectedStatus(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var addQuery = self.query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw FluxgramSettingsStoreError.unexpectedStatus(addStatus)
            }
        } else {
            throw FluxgramSettingsStoreError.unexpectedStatus(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(self.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FluxgramSettingsStoreError.unexpectedStatus(status)
        }
    }
}

private enum FluxgramSettingsSection: Int32 {
    case endpoints
    case credentials
    case actions
}

private enum FluxgramSettingsEntry: ItemListNodeEntry {
    case endpointsHeader
    case endpointsInfo
    case localEndpoint(String)
    case remoteEndpoint(String)
    case notifyStatusEndpoint(String)
    case credentialsHeader
    case accessToken(String)
    case notifyStatusToken(String)
    case testConnection
    case downloads
    case notifyStatus
    case clear

    var section: ItemListSectionId {
        switch self {
        case .endpointsHeader, .endpointsInfo, .localEndpoint, .remoteEndpoint, .notifyStatusEndpoint:
            return FluxgramSettingsSection.endpoints.rawValue
        case .credentialsHeader, .accessToken, .notifyStatusToken:
            return FluxgramSettingsSection.credentials.rawValue
        case .testConnection, .downloads, .notifyStatus, .clear:
            return FluxgramSettingsSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .endpointsHeader:
            return 0
        case .endpointsInfo:
            return 1
        case .localEndpoint:
            return 2
        case .remoteEndpoint:
            return 3
        case .notifyStatusEndpoint:
            return 4
        case .credentialsHeader:
            return 5
        case .accessToken:
            return 6
        case .notifyStatusToken:
            return 7
        case .testConnection:
            return 8
        case .downloads:
            return 9
        case .notifyStatus:
            return 10
        case .clear:
            return 11
        }
    }

    static func <(lhs: FluxgramSettingsEntry, rhs: FluxgramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FluxgramSettingsControllerArguments
        switch self {
        case .endpointsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "TGAPP 地址", sectionId: self.section)
        case .endpointsInfo:
            return ItemListInfoItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "Fluxgram 控制台",
                text: .plain("NAS 下载、消息监听和后端地址集中在这里管理。内网优先，外网回退，保存后可测试连接。"),
                style: .blocks,
                sectionId: self.section,
                closeAction: nil
            )
        case let .localEndpoint(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "内网地址", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "http://192.168.1.2:3000",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.localBaseURL = value
                        return state
                    }
                },
                action: {}
            )
        case let .remoteEndpoint(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "外网地址", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "https://example.com",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.remoteBaseURL = value
                        return state
                    }
                },
                action: {}
            )
        case let .notifyStatusEndpoint(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "NAS 监听地址", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "http://192.168.1.2:30178",
                type: .regular(capitalization: false, autocorrection: false),
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.notifyStatusURL = value
                        return state
                    }
                },
                action: {}
            )
        case .credentialsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "访问令牌", sectionId: self.section)
        case let .accessToken(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(),
                text: value,
                placeholder: "访问令牌",
                type: .password,
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.accessToken = value
                        return state
                    }
                },
                action: {}
            )
        case let .notifyStatusToken(value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: NSAttributedString(string: "监听令牌", textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "tg-notify 的 NOTIFY_STATUS_TOKEN",
                type: .password,
                clearType: .always,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateState { state in
                        var state = state
                        state.notifyStatusToken = value
                        return state
                    }
                },
                action: {}
            )
        case .testConnection:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "测试 NAS 连接",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.testConnection()
                }
            )
        case .downloads:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                icon: PresentationResourcesSettings.download,
                title: "NAS 下载",
                label: "队列与历史记录",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openDownloads()
                }
            )
        case .notifyStatus:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                icon: PresentationResourcesSettings.notifications,
                title: "NAS 监听状态",
                label: "Telegram 与 Bark",
                labelStyle: .text,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openNotifyStatus()
                }
            )
        case .clear:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: fluxgramItemListSystemStyle,
                title: "清除配置",
                kind: .destructive,
                alignment: .center,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.clear()
                }
            )
        }
    }
}

private final class FluxgramSettingsControllerArguments {
    let updateState: ((FluxgramSettings) -> FluxgramSettings) -> Void
    let testConnection: () -> Void
    let openDownloads: () -> Void
    let openNotifyStatus: () -> Void
    let clear: () -> Void

    init(
        updateState: @escaping ((FluxgramSettings) -> FluxgramSettings) -> Void,
        testConnection: @escaping () -> Void,
        openDownloads: @escaping () -> Void,
        openNotifyStatus: @escaping () -> Void,
        clear: @escaping () -> Void
    ) {
        self.updateState = updateState
        self.testConnection = testConnection
        self.openDownloads = openDownloads
        self.openNotifyStatus = openNotifyStatus
        self.clear = clear
    }
}

private func fluxgramSettingsEntries(settings: FluxgramSettings) -> [FluxgramSettingsEntry] {
    return [
        .endpointsHeader,
        .endpointsInfo,
        .localEndpoint(settings.localBaseURL),
        .remoteEndpoint(settings.remoteBaseURL),
        .notifyStatusEndpoint(settings.notifyStatusURL),
        .credentialsHeader,
        .accessToken(settings.accessToken),
        .notifyStatusToken(settings.notifyStatusToken),
        .testConnection,
        .downloads,
        .notifyStatus,
        .clear
    ]
}

private enum FluxgramSettingsValidationError: Error {
    case missingEndpoint
    case invalidLocalEndpoint
    case invalidRemoteEndpoint
    case invalidNotifyStatusEndpoint
    case missingAccessToken
    case invalidAccessToken
    case invalidNotifyStatusToken
}

private func normalizedBaseURL(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        return ""
    }
    guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          var components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil else {
        return nil
    }

    components.scheme = scheme
    components.host = host.lowercased()
    var path = components.path
    while path.hasSuffix("/") && path != "/" {
        path.removeLast()
    }
    components.path = path == "/" ? "" : path
    return components.url?.absoluteString
}

private func validatedSettings(_ settings: FluxgramSettings) throws -> FluxgramSettings {
    guard let localBaseURL = normalizedBaseURL(settings.localBaseURL) else {
        throw FluxgramSettingsValidationError.invalidLocalEndpoint
    }
    guard let remoteBaseURL = normalizedBaseURL(settings.remoteBaseURL) else {
        throw FluxgramSettingsValidationError.invalidRemoteEndpoint
    }
    guard let notifyStatusURL = normalizedBaseURL(settings.notifyStatusURL) else {
        throw FluxgramSettingsValidationError.invalidNotifyStatusEndpoint
    }
    guard !localBaseURL.isEmpty || !remoteBaseURL.isEmpty else {
        throw FluxgramSettingsValidationError.missingEndpoint
    }

    let accessToken = settings.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accessToken.isEmpty else {
        throw FluxgramSettingsValidationError.missingAccessToken
    }
    guard accessToken.rangeOfCharacter(from: .newlines) == nil else {
        throw FluxgramSettingsValidationError.invalidAccessToken
    }
    let notifyStatusToken = settings.notifyStatusToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard notifyStatusToken.rangeOfCharacter(from: .newlines) == nil else {
        throw FluxgramSettingsValidationError.invalidNotifyStatusToken
    }

    return FluxgramSettings(localBaseURL: localBaseURL, remoteBaseURL: remoteBaseURL, accessToken: accessToken, notifyStatusURL: notifyStatusURL, notifyStatusToken: notifyStatusToken)
}

private func validationMessage(_ error: FluxgramSettingsValidationError) -> String {
    switch error {
    case .missingEndpoint:
        return "请填写内网或外网 TGAPP 地址。"
    case .invalidLocalEndpoint:
        return "请输入有效的内网 HTTP 或 HTTPS 地址。"
    case .invalidRemoteEndpoint:
        return "请输入有效的外网 HTTP 或 HTTPS 地址。"
    case .invalidNotifyStatusEndpoint:
        return "请输入有效的 NAS 监听 HTTP 或 HTTPS 地址。"
    case .missingAccessToken:
        return "请输入访问令牌。"
    case .invalidAccessToken:
        return "访问令牌不能包含换行符。"
    case .invalidNotifyStatusToken:
        return "监听令牌不能包含换行符。"
    }
}

public func fluxgramSettingsController(context: AccountContext) -> ViewController {
    let initialSettings: FluxgramSettings
    do {
        initialSettings = try FluxgramSettingsStore.load()
    } catch {
        initialSettings = FluxgramSettings(localBaseURL: "", remoteBaseURL: "", accessToken: "")
    }

    let stateValue = Atomic(value: initialSettings)
    let statePromise = ValuePromise(initialSettings, ignoreRepeated: true)
    let updateState: ((FluxgramSettings) -> FluxgramSettings) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

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

    let arguments = FluxgramSettingsControllerArguments(updateState: updateState, testConnection: {
        do {
            let settings = try validatedSettings(stateValue.with { $0 })
            FluxgramNASService.shared.testConnections(settings: settings) { results in
                guard !results.isEmpty else {
                    presentAlert("无法测试连接，请检查 TGAPP 地址和访问令牌。")
                    return
                }
                presentAlert(results.map(\.detailText).joined(separator: "\n\n"))
            }
        } catch let error as FluxgramSettingsValidationError {
            presentAlert(validationMessage(error))
        } catch {
            presentAlert("无法测试 NAS 连接。")
        }
    }, openDownloads: {
        controller?.push(fluxgramDownloadsController(context: context))
    }, openNotifyStatus: {
        do {
            let settings = try validatedSettings(stateValue.with { $0 })
            controller?.push(fluxgramNotifyStatusController(context: context, settings: settings))
        } catch let error as FluxgramSettingsValidationError {
            presentAlert(validationMessage(error))
        } catch {
            presentAlert("无法读取 NAS 监听状态。")
        }
    }, clear: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(
            standardTextAlertController(
                theme: AlertControllerTheme(presentationData: presentationData),
                title: "清除配置？",
                text: "这会从此 iPhone 移除 TGAPP 地址和访问令牌。",
                actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: "清除", action: {
                        do {
                            try FluxgramSettingsStore.clear()
                            updateState { _ in
                                return FluxgramSettings(localBaseURL: "", remoteBaseURL: "", accessToken: "", notifyStatusURL: "", notifyStatusToken: "")
                            }
                        } catch {
                            presentAlert("无法清除安全设置。")
                        }
                    })
                ]
            ),
            in: .window(.root)
        )
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, FluxgramSettingsControllerArguments)) in
        let rightNavigationButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: true, action: {
            do {
                let validated = try validatedSettings(stateValue.with { $0 })
                try FluxgramSettingsStore.save(validated)
                updateState { _ in
                    return validated
                }
                controller?.navigationController?.popViewController(animated: true)
            } catch let error as FluxgramSettingsValidationError {
                presentAlert(validationMessage(error))
            } catch {
                presentAlert("无法保存安全设置。")
            }
        })
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Fluxgram"),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fluxgramSettingsEntries(settings: settings),
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
