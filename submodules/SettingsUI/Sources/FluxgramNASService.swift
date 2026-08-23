import Foundation
import Network
import UIKit
import CryptoKit

struct FluxgramNASSubmissionOptions: Codable, Equatable {
    var downloadSubdir: String
    var note: String
    var tags: [String]
    var inbox: Bool

    init(downloadSubdir: String = "", note: String = "", tags: [String] = [], inbox: Bool = false) {
        self.downloadSubdir = downloadSubdir.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Self.normalizedTags(tags)
        self.inbox = inbox
    }

    private static func normalizedTags(_ values: [String]) -> [String] {
        var result: [String] = []
        for rawValue in values {
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
                continue
            }
            guard !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
                continue
            }
            result.append(value)
        }
        return result
    }
}

struct FluxgramNASSubmission: Codable, Equatable {
    let backendDialogId: String
    let messageId: Int32
    let options: FluxgramNASSubmissionOptions
    let peerAccessHash: String?
    // Kept only in the on-device pending queue so video submissions can be
    // retried after a temporary NAS outage without losing their source.
    let directDocument: FluxgramNASDirectDocument?
    let createdAt: TimeInterval
    let lastAttemptAt: TimeInterval
    let attemptCount: Int
    let lastError: String

    init(backendDialogId: String, messageId: Int32, options: FluxgramNASSubmissionOptions, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil, createdAt: TimeInterval = Date().timeIntervalSince1970, lastAttemptAt: TimeInterval = 0, attemptCount: Int = 0, lastError: String = "") {
        self.backendDialogId = backendDialogId
        self.messageId = messageId
        self.options = options
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }

    var stableKey: String {
        var values = [
            self.backendDialogId,
            String(self.messageId),
            self.options.downloadSubdir,
            self.options.note,
            self.options.tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: ","),
            self.options.inbox ? "1" : "0",
            self.peerAccessHash ?? ""
        ]
        if let directDocument = self.directDocument {
            values.append(directDocument.documentId)
            values.append(directDocument.accessHash)
            values.append(directDocument.fileName)
            values.append(String(directDocument.fileSize))
        } else {
            values.append(contentsOf: ["", "", "", ""])
        }
        // Length-prefix each field so a delimiter in a user-entered tag or note
        // cannot make two different submissions share an idempotency key.
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    var idempotencyKey: String {
        var hasher = SHA256()
        hasher.update(data: Data(self.stableKey.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var legacyStableKey: String {
        return "\(self.backendDialogId):\(self.messageId):\(self.options.downloadSubdir)"
    }

    func hasSameQueueIdentity(as other: FluxgramNASSubmission) -> Bool {
        if self.stableKey == other.stableKey {
            return true
        }
        // Older app versions only keyed default-option requests by dialog,
        // message and directory. Keep those queued requests retryable without
        // allowing a tagged or direct-document request to collide with them.
        let canUseLegacyIdentity = self.options.note.isEmpty && self.options.tags.isEmpty && !self.options.inbox && self.directDocument == nil
            && other.options.note.isEmpty && other.options.tags.isEmpty && !other.options.inbox && other.directDocument == nil
        return canUseLegacyIdentity && self.legacyStableKey == other.legacyStableKey
    }

    func withAttempt(error: String) -> FluxgramNASSubmission {
        return FluxgramNASSubmission(
            backendDialogId: self.backendDialogId,
            messageId: self.messageId,
            options: self.options,
            peerAccessHash: self.peerAccessHash,
            directDocument: self.directDocument,
            createdAt: self.createdAt,
            lastAttemptAt: Date().timeIntervalSince1970,
            attemptCount: self.attemptCount + 1,
            lastError: error
        )
    }

    var displayError: String {
        return fluxgramLocalizedDownloadError(self.lastError)
    }
}

enum FluxgramNASSubmissionResult: Equatable {
    case submitted(String)
    case pending(String)
    case failed(String)

    var message: String {
        switch self {
        case let .submitted(message), let .pending(message), let .failed(message):
            return message
        }
    }
}

struct FluxgramNASDownloadJob: Equatable {
    let id: String
    let status: String
    let fileName: String
    let downloadSubdir: String
    let sourceLabel: String
    let outputFile: String
    let received: Int64
    let total: Int64
    let error: String
    let sourceTitle: String
    let sourceText: String
    let sourceUrl: String
    let sourceDialogId: Int64?
    let sourceMessageId: Int32?
    let sourceRootMessageId: Int32?
    let tags: [String]
    let note: String
    let inbox: Bool

    var title: String {
        return self.fileName.isEmpty ? "媒体文件" : self.fileName
    }

    var detail: String {
        var values: [String] = []
        if !self.status.isEmpty {
            values.append(fluxgramLocalizedDownloadStatus(self.status))
        }
        if let progressPercent {
            values.append("\(progressPercent)%")
        }
        if !self.downloadSubdir.isEmpty {
            values.append(self.downloadSubdir)
        }
        if !self.sourceLabel.isEmpty {
            values.append(self.sourceLabel)
        }
        if !self.displayError.isEmpty {
            values.append(self.displayError)
        }
        return values.joined(separator: " - ")
    }

    var hasSourceMessage: Bool {
        return self.sourceDialogId != nil && (self.sourceRootMessageId != nil || self.sourceMessageId != nil)
    }

    var fluxTokRelativePath: String? {
        let path = self.outputFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    var displayError: String {
        let error = self.error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !error.isEmpty else {
            return ["failed", "error"].contains(self.status.lowercased()) ? "下载失败，请重试。" : ""
        }
        return fluxgramLocalizedDownloadError(error)
    }

    var detailText: String {
        var values: [String] = ["状态：\(fluxgramLocalizedDownloadStatus(self.status))"]
        if let progressPercent {
            values.append("进度：\(progressPercent)%")
        }
        if !self.downloadSubdir.isEmpty {
            values.append("保存目录：\(self.downloadSubdir)")
        }
        if !self.outputFile.isEmpty {
            values.append("输出文件：\(self.outputFile)")
        }
        if !self.sourceTitle.isEmpty {
            values.append("来源：\(self.sourceTitle)")
        } else if !self.sourceLabel.isEmpty {
            values.append("来源：\(self.sourceLabel)")
        }
        if !self.sourceText.isEmpty {
            values.append("来源说明：\(self.sourceText)")
        }
        if !self.tags.isEmpty {
            values.append("标签：\(self.tags.joined(separator: "、"))")
        }
        if !self.note.isEmpty {
            values.append("备注：\(self.note)")
        }
        if self.inbox {
            values.append("已加入收件箱")
        }
        if !self.sourceUrl.isEmpty {
            values.append("来源链接：\(self.sourceUrl)")
        }
        if !self.displayError.isEmpty {
            values.append("错误：\(self.displayError)")
        }
        return values.joined(separator: "\n")
    }

    private var progressPercent: Int64? {
        guard self.total > 0 else {
            return nil
        }
        let received = min(max(self.received, 0), self.total)
        return Int64((Double(received) / Double(self.total) * 100.0).rounded(.down))
    }
}

struct FluxgramNotifyListenerStatus: Decodable, Equatable {
    struct Counters: Decodable, Equatable {
        let polls: Int
        let realtimeMessages: Int
        let pollingMessages: Int
        let mutedSkipped: Int
        let barkSuccess: Int
        let barkFailure: Int
    }

    let ok: Bool
    let version: String
    let enabled: Bool?
    let connection: String
    let realtimeHealthy: Bool
    let pollingSeeded: Bool
    let lastTelegramSyncAt: String?
    let lastRealtimeUpdateAt: String?
    let lastBarkSuccessAt: String?
    let lastBarkFailureAt: String?
    let counters: Counters
}

private func fluxgramLocalizedDownloadStatus(_ status: String) -> String {
    switch status.lowercased() {
    case "queued", "queue", "pending":
        return "排队中"
    case "downloading", "download":
        return "下载中"
    case "completed", "complete", "finished", "success":
        return "已完成"
    case "failed", "error":
        return "失败"
    case "cancelled", "canceled":
        return "已取消"
    case "paused":
        return "已暂停"
    default:
        return status
    }
}

private func fluxgramLocalizedDownloadError(_ error: String) -> String {
    let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    let normalized = trimmed.lowercased()
    let summary: String
    if normalized.contains("401") || normalized.contains("unauthorized") {
        summary = "TGAPP 鉴权失败，请检查访问令牌。"
    } else if normalized.contains("403") || normalized.contains("forbidden") {
        summary = "TGAPP 拒绝了这次请求，请检查账号权限。"
    } else if normalized.contains("404") || normalized.contains("not found") {
        summary = "服务器未找到对应资源，请确认来源消息仍可访问。"
    } else if normalized.contains("timeout") || normalized.contains("timed out") || normalized.contains("-1001") {
        summary = "NAS 请求超时，请检查网络后重试。"
    } else if normalized.contains("network") || normalized.contains("connection") || normalized.contains("无法连接") {
        summary = "无法连接 NAS 服务，请检查网络后重试。"
    } else {
        return trimmed
    }

    // Keep endpoint and HTTP status diagnostics available below the stable UI text.
    return trimmed == summary ? summary : "\(summary)\n\(trimmed)"
}

struct FluxgramNASDownloadsSnapshot: Equatable {
    let active: [FluxgramNASDownloadJob]
    let history: [FluxgramNASDownloadJob]
}

enum FluxgramNASDownloadsUpdate {
    case active([FluxgramNASDownloadJob])
    case activeOnlyFinished([FluxgramNASDownloadJob])
    case history([FluxgramNASDownloadJob])
    case finished(FluxgramNASDownloadsSnapshot)
    case failure(String)
}

struct FluxgramNASEndpointTestResult: Equatable {
    let endpointName: String
    let baseURL: String
    let statusCode: Int?
    let message: String

    var detailText: String {
        let status = self.statusCode.map { "HTTP \($0)" } ?? "无 HTTP 响应"
        return "\(self.endpointName)\n\(self.baseURL)\n\(self.message)（\(status)）"
    }
}

public struct FluxgramNASDirectDocument: Codable, Equatable {
    public let documentId: String
    public let accessHash: String
    public let fileReference: String
    public let fileName: String
    public let fileSize: Int64

    public init(documentId: String, accessHash: String, fileReference: String, fileName: String, fileSize: Int64) {
        self.documentId = documentId
        self.accessHash = accessHash
        self.fileReference = fileReference
        self.fileName = fileName
        self.fileSize = fileSize
    }
}

public struct FluxgramNASDirectDownload: Equatable {
    public let dialogId: Int64
    public let messageId: Int32
    public let document: FluxgramNASDirectDocument

    public init(dialogId: Int64, messageId: Int32, document: FluxgramNASDirectDocument) {
        self.dialogId = dialogId
        self.messageId = messageId
        self.document = document
    }
}

public struct FluxgramNASDownloadRequest: Equatable {
    public let dialogId: Int64
    public let messageId: Int32
    public let peerAccessHash: String?
    public let directDocument: FluxgramNASDirectDocument?

    public init(dialogId: Int64, messageId: Int32, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil) {
        self.dialogId = dialogId
        self.messageId = messageId
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
    }
}

private struct FluxgramNASDownloadPayload: Encodable {
    let downloadSubdir: String?
    let note: String?
    let tags: [String]?
    let inbox: Bool?
    let peerAccessHash: String?
    let directDocument: FluxgramNASDirectDocument?

    init(options: FluxgramNASSubmissionOptions, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil) {
        self.downloadSubdir = options.downloadSubdir.isEmpty ? nil : options.downloadSubdir
        self.note = options.note.isEmpty ? nil : options.note
        self.tags = options.tags.isEmpty ? nil : options.tags
        self.inbox = options.inbox ? true : nil
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
    }
}

private struct FluxgramNASResponseError: Decodable {
    let error: String?
    let message: String?
}

private enum FluxgramNASRequestResult {
    case response(HTTPURLResponse, Data)
    case transportFailure(String)
}

private enum FluxgramNASReadResult {
    case success(URL, Data)
    case failure(String)
}

final class FluxgramNASService {
    static let shared = FluxgramNASService()

    private static let pendingQueueKey = "com.fluxgram.ios.pending-downloads.v1"
    private static let submittedKeysKey = "com.fluxgram.ios.submitted-download-keys.v1"
    private static let automaticRetryInterval: TimeInterval = 60.0
    private static let automaticRetryLimit = 3
    private static let directoryCacheLifetime: TimeInterval = 30.0
    private static let submittedKeyLifetime: TimeInterval = 10.0 * 60.0
    private let workerQueue = DispatchQueue(label: "com.fluxgram.ios.nas")
    private var networkPathMonitor: NWPathMonitor?
    private var cachedDownloadDirectories: [String]?
    private var cachedDownloadDirectoriesAt: TimeInterval = 0.0
    private var cachedDownloadDirectoriesConfigurationKey: String?
    private var recentlySubmittedKeys: [String: TimeInterval] = [:]
    private var didBecomeActiveObserver: NSObjectProtocol?

    private init() {
        self.recentlySubmittedKeys = Self.loadSubmittedKeys()
        self.didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
            using: { [weak self] _ in
                // A foreground transition is the earliest reliable point to
                // retry requests created while the NAS was unreachable.
                self?.retryPendingDownloads(automatic: true)
            }
        )

        let monitor = NWPathMonitor()
        self.networkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // A foreground transition is not guaranteed when Wi-Fi or the
            // remote route comes back. The serial service queue preserves the
            // endpoint fallback order and keeps retries idempotent.
            self?.retryPendingDownloads(automatic: true)
        }
        monitor.start(queue: DispatchQueue(label: "com.fluxgram.ios.network-monitor", qos: .utility))
    }

    deinit {
        self.networkPathMonitor?.cancel()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    static func backendDialogId(for dialogId: Int64) -> String {
        if dialogId < -1_000_000_000_000 {
            return String(-dialogId - 1_000_000_000_000)
        } else if dialogId < 0 {
            return String(-dialogId)
        } else {
            return String(dialogId)
        }
    }

    func submit(dialogId: Int64, messageId: Int32, options: FluxgramNASSubmissionOptions, peerAccessHash: String?, directDocument: FluxgramNASDirectDocument?, completion: @escaping (FluxgramNASSubmissionResult) -> Void) {
        let submission = FluxgramNASSubmission(
            backendDialogId: Self.backendDialogId(for: dialogId),
            messageId: messageId,
            options: options,
            peerAccessHash: peerAccessHash,
            directDocument: directDocument
        )
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.submitOrQueue(submission)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func submit(directDownloads: [FluxgramNASDirectDownload], options: FluxgramNASSubmissionOptions, completion: @escaping ([FluxgramNASSubmissionResult]) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let results = directDownloads.map { download -> FluxgramNASSubmissionResult in
                let submission = FluxgramNASSubmission(
                    backendDialogId: Self.backendDialogId(for: download.dialogId),
                    messageId: download.messageId,
                    options: options,
                    directDocument: download.document
                )
                guard submission.messageId > 0, !submission.backendDialogId.isEmpty else {
                    return .failed("无法识别此 Telegram 消息。")
                }
                return self.submitOrQueue(submission)
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func submit(downloadRequests: [FluxgramNASDownloadRequest], options: FluxgramNASSubmissionOptions, completion: @escaping ([FluxgramNASSubmissionResult]) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let results = downloadRequests.map { request -> FluxgramNASSubmissionResult in
                let submission = FluxgramNASSubmission(
                    backendDialogId: Self.backendDialogId(for: request.dialogId),
                    messageId: request.messageId,
                    options: options,
                    peerAccessHash: request.peerAccessHash,
                    directDocument: request.directDocument
                )
                return self.submitOrQueue(submission)
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func retryPendingDownloads(automatic: Bool = false, completion: ((Int, Int) -> Void)? = nil) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.retryPendingDownloadsLocked(
                maxAttempts: automatic ? Self.automaticRetryLimit : .max,
                enforceRetryInterval: automatic
            )
            if let completion {
                DispatchQueue.main.async {
                    completion(result.submitted, result.remaining)
                }
            }
        }
    }

    func fetchPendingDownloads(completion: @escaping ([FluxgramNASSubmission]) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let pending = self.loadPendingDownloads()
            DispatchQueue.main.async {
                completion(pending)
            }
        }
    }

    func retryPendingDownload(_ submission: FluxgramNASSubmission, completion: @escaping (FluxgramNASSubmissionResult) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async {
                    completion(.failed("请先配置 TGAPP 地址和访问令牌。"))
                }
                return
            }

            var pending = self.loadPendingDownloads()
            self.pruneSubmittedKeys()
            if self.recentlySubmittedKeys[submission.stableKey] != nil {
                pending.removeAll { $0.hasSameQueueIdentity(as: submission) }
                self.savePendingDownloads(pending)
                DispatchQueue.main.async {
                    completion(.submitted("相同的下载请求已提交，未重复创建任务。"))
                }
                return
            }

            var result = self.performSubmission(submission, configuration: configuration)
            if let index = pending.firstIndex(where: { $0.hasSameQueueIdentity(as: submission) }) {
                switch result {
                case .submitted:
                    self.rememberSubmittedKey(submission.stableKey)
                    pending.remove(at: index)
                case .pending, .failed:
                    if self.requiresFreshSubmission(submission, result: result) {
                        pending.remove(at: index)
                        result = .failed("这条旧的离线请求未保存私聊授权信息，已从本地队列移除。请从原会话重新选择媒体下载。")
                    } else {
                        pending[index] = submission.withAttempt(error: result.message)
                    }
                }
                self.savePendingDownloads(pending)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func fetchDownloadDirectories(completion: @escaping ([String]?, String?) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async {
                    completion(nil, "请先配置 TGAPP 地址和访问令牌。")
                }
                return
            }
            let configurationKey = configuration.directoryCacheKey
            if let cachedDownloadDirectories = self.cachedDownloadDirectories,
               self.cachedDownloadDirectoriesConfigurationKey == configurationKey,
               Date().timeIntervalSince1970 - self.cachedDownloadDirectoriesAt < Self.directoryCacheLifetime {
                DispatchQueue.main.async {
                    completion(cachedDownloadDirectories, nil)
                }
                return
            }
            let result = self.performRead(configuration: configuration, path: ["api", "download-directories"], queryItems: [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "maxDepth", value: "4")
            ], timeoutInterval: 2.0)
            switch result {
            case let .success(_, data):
                let directories = self.downloadDirectories(from: data)
                self.cachedDownloadDirectories = directories
                self.cachedDownloadDirectoriesAt = Date().timeIntervalSince1970
                self.cachedDownloadDirectoriesConfigurationKey = configurationKey
                DispatchQueue.main.async {
                    completion(directories, nil)
                }
            case let .failure(message):
                DispatchQueue.main.async {
                    completion(nil, message)
                }
            }
        }
    }

    func fetchDownloadsIncrementally(includeHistory: Bool = true, completion: @escaping (FluxgramNASDownloadsUpdate) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async {
                    completion(.failure("请先配置 TGAPP 地址和访问令牌。"))
                }
                return
            }

            let activeResult = self.performRead(configuration: configuration, path: ["api", "downloads"], queryItems: [
                URLQueryItem(name: "limit", value: "100")
            ])
            let activeData: Data
            switch activeResult {
            case let .success(_, data):
                activeData = data
            case let .failure(message):
                DispatchQueue.main.async {
                    completion(.failure(message))
                }
                return
            }

            let active = self.downloadJobs(from: activeData, key: "downloads")
            DispatchQueue.main.async {
                completion(.active(active))
            }

            guard includeHistory else {
                DispatchQueue.main.async {
                    completion(.activeOnlyFinished(active))
                }
                return
            }

            let historyResult = self.performRead(configuration: configuration, path: ["api", "download-history"], queryItems: [
                URLQueryItem(name: "limit", value: "100")
            ])
            let historyData: Data
            switch historyResult {
            case let .success(_, data):
                historyData = data
            case let .failure(message):
                DispatchQueue.main.async {
                    completion(.failure(message))
                }
                return
            }

            let snapshot = FluxgramNASDownloadsSnapshot(
                active: active,
                history: self.downloadJobs(from: historyData, key: "history")
            )
            DispatchQueue.main.async {
                completion(.history(snapshot.history))
                completion(.finished(snapshot))
            }
        }
    }

    func fetchDownloads(completion: @escaping (FluxgramNASDownloadsSnapshot?, String?) -> Void) {
        self.fetchDownloadsIncrementally { update in
            switch update {
            case .active:
                break
            case .activeOnlyFinished:
                break
            case let .finished(snapshot):
                completion(snapshot, nil)
            case let .failure(message):
                completion(nil, message)
            case .history:
                break
            }
        }
    }

    func testConnections(settings: FluxgramSettings, completion: @escaping ([FluxgramNASEndpointTestResult]) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self, let configuration = FluxgramNASConfiguration(settings: settings) else {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }

            let results = configuration.baseURLs.enumerated().map { index, baseURL in
                let url = baseURL
                    .appendingPathComponent("api")
                    .appendingPathComponent("downloads")
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
                guard let requestURL = components?.url else {
                    return FluxgramNASEndpointTestResult(
                        endpointName: configuration.endpointName(at: index),
                        baseURL: baseURL.absoluteString,
                        statusCode: nil,
                        message: "地址无效"
                    )
                }
                var request = URLRequest(url: requestURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 8.0
                request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                switch self.execute(request) {
                case let .transportFailure(reason):
                    return FluxgramNASEndpointTestResult(
                        endpointName: configuration.endpointName(at: index),
                        baseURL: baseURL.absoluteString,
                        statusCode: nil,
                        message: "无法连接：\(reason)"
                    )
                case let .response(response, data):
                    let message: String
                    if (200 ... 299).contains(response.statusCode) {
                        message = "可用"
                    } else {
                        message = self.message(for: response, data: data)
                    }
                    return FluxgramNASEndpointTestResult(
                        endpointName: configuration.endpointName(at: index),
                        baseURL: baseURL.absoluteString,
                        statusCode: response.statusCode,
                        message: message
                    )
                }
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func fetchNotifyListenerStatus(settings: FluxgramSettings, completion: @escaping (FluxgramNotifyListenerStatus?, String?) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            let rawURL = settings.notifyStatusURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = (settings.notifyStatusToken.isEmpty ? settings.accessToken : settings.notifyStatusToken).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else {
                DispatchQueue.main.async { completion(nil, "请先填写 NAS 监听地址。") }
                return
            }
            guard !token.isEmpty, let requestURL = Self.notifyStatusURL(rawURL) else {
                DispatchQueue.main.async { completion(nil, "NAS 监听地址或访问令牌无效。") }
                return
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 8.0
            request.setValue(token, forHTTPHeaderField: "X-TGAPP-Token")
            switch self.execute(request) {
            case let .transportFailure(reason):
                DispatchQueue.main.async { completion(nil, "无法连接 NAS 监听服务（\(reason)）。") }
            case let .response(response, data):
                guard (200 ... 299).contains(response.statusCode) else {
                    DispatchQueue.main.async { completion(nil, self.message(for: response, data: data)) }
                    return
                }
                guard let status = try? JSONDecoder().decode(FluxgramNotifyListenerStatus.self, from: data), status.ok else {
                    DispatchQueue.main.async { completion(nil, "NAS 监听服务返回的数据无效。") }
                    return
                }
                DispatchQueue.main.async { completion(status, nil) }
            }
        }
    }

    func setNotifyListenerEnabled(settings: FluxgramSettings, enabled: Bool, completion: @escaping (FluxgramNotifyListenerStatus?, String?) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            let rawURL = settings.notifyStatusURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = (settings.notifyStatusToken.isEmpty ? settings.accessToken : settings.notifyStatusToken).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, !token.isEmpty, let requestURL = Self.notifyControlURL(rawURL) else {
                DispatchQueue.main.async { completion(nil, "NAS 监听地址或访问令牌无效。") }
                return
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 8.0
            request.setValue(token, forHTTPHeaderField: "X-TGAPP-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
            switch self.execute(request) {
            case let .transportFailure(reason):
                DispatchQueue.main.async { completion(nil, "无法连接 NAS 监听服务（\(reason)）。") }
            case let .response(response, data):
                guard (200 ... 299).contains(response.statusCode) else {
                    DispatchQueue.main.async { completion(nil, self.message(for: response, data: data)) }
                    return
                }
                guard let status = try? JSONDecoder().decode(FluxgramNotifyListenerStatus.self, from: data), status.ok else {
                    DispatchQueue.main.async { completion(nil, "NAS 监听服务返回的数据无效。") }
                    return
                }
                DispatchQueue.main.async { completion(status, nil) }
            }
        }
    }

    func cancelDownload(jobId: String, completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", jobId, "cancel"], successMessage: "已取消下载任务。", completion: completion)
    }

    func retryProblemDownloads(completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", "retry-problem"], successMessage: "已提交失败任务重试。", completion: completion)
    }

    private func submitOrQueue(_ submission: FluxgramNASSubmission) -> FluxgramNASSubmissionResult {
        guard submission.messageId > 0, !submission.backendDialogId.isEmpty else {
            return .failed("无法识别此 Telegram 消息。")
        }
        guard let configuration = self.configuration() else {
            return .failed("请先配置 TGAPP 地址和访问令牌。")
        }

        let now = Date().timeIntervalSince1970
        self.pruneSubmittedKeys(now: now)
        if self.recentlySubmittedKeys[submission.stableKey] != nil {
            return .submitted("相同的下载请求已提交，未重复创建任务。")
        }

        let result = self.performSubmission(submission, configuration: configuration)
        switch result {
        case .submitted:
            self.recentlySubmittedKeys[submission.stableKey] = now
            self.saveSubmittedKeys()
            self.removePending(submission)
            return result
        case .pending:
            self.enqueuePending(submission.withAttempt(error: result.message))
            return .pending("NAS 当前不可用，下载请求已保存到本地队列。")
        case .failed:
            return result
        }
    }

    private func retryPendingDownloadsLocked(maxAttempts: Int, enforceRetryInterval: Bool) -> (submitted: Int, remaining: Int) {
        guard let configuration = self.configuration() else {
            return (0, self.loadPendingDownloads().count)
        }
        var pending = self.loadPendingDownloads()
        var submitted = 0
        var attempted = 0
        let now = Date().timeIntervalSince1970
        var retained: [FluxgramNASSubmission] = []
        self.pruneSubmittedKeys(now: now)

        for submission in pending {
            guard attempted < maxAttempts else {
                retained.append(submission)
                continue
            }
            if self.recentlySubmittedKeys[submission.stableKey] != nil {
                continue
            }
            if enforceRetryInterval,
               submission.lastAttemptAt > 0,
               now - submission.lastAttemptAt < Self.automaticRetryInterval {
                retained.append(submission)
                continue
            }
            attempted += 1
            let result = self.performSubmission(submission, configuration: configuration)
            switch result {
            case .submitted:
                submitted += 1
                self.rememberSubmittedKey(submission.stableKey)
            case .pending, .failed:
                if !self.requiresFreshSubmission(submission, result: result) {
                    retained.append(submission.withAttempt(error: result.message))
                }
            }
        }
        pending = retained
        self.savePendingDownloads(pending)
        return (submitted, pending.count)
    }

    private func performSubmission(_ submission: FluxgramNASSubmission, configuration: FluxgramNASConfiguration, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil) -> FluxgramNASSubmissionResult {
        let resolvedPeerAccessHash = peerAccessHash ?? submission.peerAccessHash
        let resolvedDirectDocument = directDocument ?? submission.directDocument
        guard let body = try? JSONEncoder().encode(FluxgramNASDownloadPayload(options: submission.options, peerAccessHash: resolvedPeerAccessHash, directDocument: resolvedDirectDocument)) else {
            return .failed("无法准备下载请求。")
        }
        var retryableFailures: [String] = []
        var terminalFailures: [String] = []
        for (index, baseURL) in configuration.baseURLs.enumerated() {
            let url = baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("dialogs")
                .appendingPathComponent(submission.backendDialogId)
                .appendingPathComponent("messages")
                .appendingPathComponent(String(submission.messageId))
                .appendingPathComponent(resolvedDirectDocument == nil ? "download" : "download-direct")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8.0
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
            request.setValue(submission.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

            switch self.execute(request) {
            case let .transportFailure(reason):
                retryableFailures.append("\(configuration.endpointDescription(at: index)) (\(reason))")
                continue
            case let .response(response, data):
                if (200 ... 299).contains(response.statusCode) {
                    return .submitted("已加入 NAS 下载队列。")
                }
                let failure = "\(configuration.endpointDescription(at: index)) 返回：\(self.message(for: response, data: data))"
                if response.statusCode == 408 || response.statusCode == 425 || response.statusCode == 429 || response.statusCode >= 500 {
                    retryableFailures.append(failure)
                } else {
                    terminalFailures.append(failure)
                }
                continue
            }
        }
        if !terminalFailures.isEmpty {
            let retryable = retryableFailures.isEmpty ? "" : "；\(retryableFailures.joined(separator: "、"))"
            return .failed("\((terminalFailures + [retryable].filter { !$0.isEmpty }).joined(separator: "；"))")
        }
        if !retryableFailures.isEmpty {
            return .pending("\(retryableFailures.joined(separator: "、")) 均不可用。")
        }
        if retryableFailures.isEmpty {
            return .pending("无法连接 NAS 服务。")
        }
        return .pending("NAS 服务暂时不可用。")
    }

    private func requiresFreshSubmission(_ submission: FluxgramNASSubmission, result: FluxgramNASSubmissionResult) -> Bool {
        guard submission.peerAccessHash == nil else {
            return false
        }
        return result.message.contains("TGAPP 无法解析这个私聊用户")
    }

    private func performRead(configuration: FluxgramNASConfiguration, path: [String], queryItems: [URLQueryItem], timeoutInterval: TimeInterval = 8.0) -> FluxgramNASReadResult {
        var endpointFailures: [String] = []
        for (index, baseURL) in configuration.baseURLs.enumerated() {
            var components = URLComponents(url: path.reduce(baseURL) { $0.appendingPathComponent($1) }, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            guard let url = components?.url else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeoutInterval
            request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
            switch self.execute(request) {
            case let .transportFailure(reason):
                endpointFailures.append("\(configuration.endpointDescription(at: index)) (\(reason))")
                continue
            case let .response(response, data):
                guard (200 ... 299).contains(response.statusCode) else {
                    endpointFailures.append("\(configuration.endpointDescription(at: index)) 返回：\(self.message(for: response, data: data))")
                    continue
                }
                return .success(url, data)
            }
        }
        if endpointFailures.isEmpty {
            return .failure("无法连接 NAS 服务。")
        }
        return .failure(endpointFailures.joined(separator: "；"))
    }

    private func performAction(path: [String], successMessage: String, completion: @escaping (Bool, String) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async {
                    completion(false, "请先配置 TGAPP 地址和访问令牌。")
                }
                return
            }

            var endpointFailures: [String] = []
            for (index, baseURL) in configuration.baseURLs.enumerated() {
                let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 8.0
                request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                switch self.execute(request) {
                case let .transportFailure(reason):
                    endpointFailures.append("\(configuration.endpointDescription(at: index)) (\(reason))")
                    continue
                case let .response(response, data):
                    if (200 ... 299).contains(response.statusCode) {
                        DispatchQueue.main.async {
                            completion(true, successMessage)
                        }
                        return
                    }
                    endpointFailures.append("\(configuration.endpointDescription(at: index)) 返回：\(self.message(for: response, data: data))")
                    // These actions are backend-owned state transitions. Try
                    // the next configured endpoint only after the first one
                    // has completed, never concurrently.
                    continue
                }
            }
            DispatchQueue.main.async {
                let message = endpointFailures.isEmpty
                    ? "NAS 请求失败。"
                    : "\(endpointFailures.joined(separator: "；"))"
                completion(false, message)
            }
        }
    }

    private func execute(_ request: URLRequest) -> FluxgramNASRequestResult {
        let semaphore = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var responseData = Data()
        var transportFailureReason: String?
        let task = URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            response = urlResponse as? HTTPURLResponse
            responseData = data ?? Data()
            if let error = error as NSError? {
                transportFailureReason = "\(error.domain) \(error.code)"
            }
            semaphore.signal()
        }
        task.resume()
        // URLSession can remain in DNS/TCP setup longer than the request's
        // nominal timeout. This worker is not the main queue, but an
        // unbounded wait still blocks every later folder/status/retry request.
        let timeout = max(1.0, min(request.timeoutInterval, 60.0) + 2.0)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return .transportFailure("请求超时")
        }
        if let transportFailureReason {
            return .transportFailure(transportFailureReason)
        }
        if response == nil {
            return .transportFailure("没有收到 HTTP 响应")
        }
        return .response(response!, responseData)
    }

    private static func notifyEndpointURL(_ value: String, endpoint: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = trimmedPath.isEmpty || trimmedPath == "status" || trimmedPath == "control" ? "/\(endpoint)" : "/\(trimmedPath)/\(endpoint)"
        return components.url
    }

    private static func notifyStatusURL(_ value: String) -> URL? {
        return Self.notifyEndpointURL(value, endpoint: "status")
    }

    private static func notifyControlURL(_ value: String) -> URL? {
        return Self.notifyEndpointURL(value, endpoint: "control")
    }

    private func configuration() -> FluxgramNASConfiguration? {
        guard let settings = try? FluxgramSettingsStore.load() else {
            return nil
        }
        return FluxgramNASConfiguration(settings: settings)
    }

    private func enqueuePending(_ submission: FluxgramNASSubmission) {
        var pending = self.loadPendingDownloads()
        if let index = pending.firstIndex(where: { $0.hasSameQueueIdentity(as: submission) }) {
            pending[index] = submission
        } else {
            pending.append(submission)
        }
        self.savePendingDownloads(pending)
    }

    private func removePending(_ submission: FluxgramNASSubmission) {
        let pending = self.loadPendingDownloads().filter { !$0.hasSameQueueIdentity(as: submission) }
        self.savePendingDownloads(pending)
    }

    private func loadPendingDownloads() -> [FluxgramNASSubmission] {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingQueueKey) else {
            return []
        }
        return (try? JSONDecoder().decode([FluxgramNASSubmission].self, from: data)) ?? []
    }

    private func savePendingDownloads(_ submissions: [FluxgramNASSubmission]) {
        guard let data = try? JSONEncoder().encode(submissions) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.pendingQueueKey)
    }

    private static func loadSubmittedKeys() -> [String: TimeInterval] {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.submittedKeysKey) else {
            return [:]
        }
        let now = Date().timeIntervalSince1970
        return raw.reduce(into: [String: TimeInterval]()) { result, entry in
            guard let number = entry.value as? NSNumber else {
                return
            }
            let timestamp = number.doubleValue
            guard now - timestamp < Self.submittedKeyLifetime else {
                return
            }
            result[entry.key] = timestamp
        }
    }

    private func rememberSubmittedKey(_ key: String) {
        self.recentlySubmittedKeys[key] = Date().timeIntervalSince1970
        self.saveSubmittedKeys()
    }

    private func pruneSubmittedKeys(now: TimeInterval = Date().timeIntervalSince1970) {
        self.recentlySubmittedKeys = self.recentlySubmittedKeys.filter { now - $0.value < Self.submittedKeyLifetime }
        self.saveSubmittedKeys()
    }

    private func saveSubmittedKeys() {
        let values = self.recentlySubmittedKeys.reduce(into: [String: NSNumber]()) { result, entry in
            result[entry.key] = NSNumber(value: entry.value)
        }
        UserDefaults.standard.set(values, forKey: Self.submittedKeysKey)
    }

    private func downloadDirectories(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object["subdirs"] as? [String] else {
            return []
        }
        return values.filter { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value.range(of: "fluxtok", options: .caseInsensitive) == nil
        }
    }

    private func downloadJobs(from data: Data, key: String) -> [FluxgramNASDownloadJob] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object[key] as? [[String: Any]] else {
            return []
        }
        return values.map { value in
            return FluxgramNASDownloadJob(
                id: self.string(value, key: "id"),
                status: self.string(value, key: "status"),
                fileName: self.string(value, key: "fileName"),
                downloadSubdir: self.string(value, key: "downloadSubdir"),
                sourceLabel: self.string(value, key: "sourceLabel"),
                outputFile: self.string(value, key: "outputFile"),
                received: self.integer(value, key: "received"),
                total: self.integer(value, key: "total"),
                error: self.string(value, key: "error"),
                sourceTitle: self.string(value, key: "sourceTitle"),
                sourceText: self.string(value, key: "sourceText"),
                sourceUrl: self.string(value, key: "sourceUrl"),
                sourceDialogId: self.optionalInteger(value, key: "sourceDialogId"),
                sourceMessageId: self.optionalInteger(value, key: "sourceMessageId").map(Int32.init),
                sourceRootMessageId: self.optionalInteger(value, key: "sourceRootMessageId").map(Int32.init),
                tags: self.stringArray(value, key: "tags"),
                note: self.string(value, key: "note"),
                inbox: self.boolean(value, key: "inbox")
            )
        }
    }

    private func string(_ value: [String: Any], key: String) -> String {
        if let string = value[key] as? String {
            return string
        }
        if let number = value[key] as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func integer(_ value: [String: Any], key: String) -> Int64 {
        if let number = value[key] as? NSNumber {
            return number.int64Value
        }
        if let string = value[key] as? String, let number = Int64(string) {
            return number
        }
        return 0
    }

    private func optionalInteger(_ value: [String: Any], key: String) -> Int64? {
        guard value[key] != nil else {
            return nil
        }
        let result = self.integer(value, key: key)
        return result == 0 ? nil : result
    }

    private func stringArray(_ value: [String: Any], key: String) -> [String] {
        guard let values = value[key] as? [Any] else {
            return []
        }
        return values.compactMap { item in
            guard let string = item as? String else {
                return nil
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func boolean(_ value: [String: Any], key: String) -> Bool {
        if let bool = value[key] as? Bool {
            return bool
        }
        if let number = value[key] as? NSNumber {
            return number.boolValue
        }
        if let string = value[key] as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return false
    }

    private func message(for response: HTTPURLResponse, data: Data) -> String {
        let status = "HTTP \(response.statusCode)"
        let withStatus: (String) -> String = { message in
            return message.range(of: status, options: .caseInsensitive) == nil ? "\(message)（\(status)）" : message
        }
        if let decoded = try? JSONDecoder().decode(FluxgramNASResponseError.self, from: data), let message = decoded.error ?? decoded.message, !message.isEmpty {
            let normalized = message.lowercased()
            if normalized.contains("could not find the input entity") || normalized.contains("input entity") {
                return withStatus("TGAPP 无法解析这个私聊用户。请从原会话重新选择媒体下载，或确认 NAS 使用的 Telegram 账号可以访问该会话。")
            }
            return withStatus(message)
        }
        if response.statusCode == 401 {
            return withStatus("TGAPP 鉴权失败。")
        }
        return "NAS 请求失败（\(status)）。"
    }
}

private struct FluxgramNASConfiguration {
    let baseURLs: [URL]
    let endpointNames: [String]
    let accessToken: String

    var directoryCacheKey: String {
        return self.baseURLs.map(\.absoluteString).joined(separator: "|")
    }

    init?(settings: FluxgramSettings) {
        let accessToken = settings.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [
            (settings.localBaseURL, "内网 NAS"),
            (settings.remoteBaseURL, "外网 NAS")
        ]
        var baseURLs: [URL] = []
        var endpointNames: [String] = []
        for (value, endpointName) in values {
            guard let url = Self.apiRootURL(value), !value.isEmpty else {
                continue
            }
            guard !baseURLs.contains(where: { $0.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
                continue
            }
            baseURLs.append(url)
            endpointNames.append(endpointName)
        }
        guard !baseURLs.isEmpty, !accessToken.isEmpty else {
            return nil
        }
        self.baseURLs = baseURLs
        self.endpointNames = endpointNames
        self.accessToken = accessToken
    }

    func endpointName(at index: Int) -> String {
        return self.endpointNames.indices.contains(index) ? self.endpointNames[index] : "NAS"
    }

    func endpointDescription(at index: Int) -> String {
        guard self.baseURLs.indices.contains(index) else {
            return self.endpointName(at: index)
        }
        return "\(self.endpointName(at: index))（\(self.baseURLs[index].absoluteString)）"
    }

    private static func apiRootURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else {
            return nil
        }
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "api" {
            components.path = ""
        }
        return components.url
    }
}
