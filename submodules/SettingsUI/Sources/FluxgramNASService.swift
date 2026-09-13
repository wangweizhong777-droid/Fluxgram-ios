import Foundation
import Network
import UIKit
import CryptoKit

struct FluxgramNASSubmissionOptions: Codable, Equatable {
    var downloadSubdir: String
    var title: String
    var note: String
    var tags: [String]
    var inbox: Bool

    init(downloadSubdir: String = "", title: String = "", note: String = "", tags: [String] = [], inbox: Bool = false) {
        self.downloadSubdir = downloadSubdir.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Self.normalizedTags(tags)
        self.inbox = inbox
    }

    private enum CodingKeys: String, CodingKey {
        case downloadSubdir
        case title
        case note
        case tags
        case inbox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            downloadSubdir: try container.decodeIfPresent(String.self, forKey: .downloadSubdir) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            note: try container.decodeIfPresent(String.self, forKey: .note) ?? "",
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            inbox: try container.decodeIfPresent(Bool.self, forKey: .inbox) ?? false
        )
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
    let desiredFileName: String?
    // A tiny Telegram preview copied from the source message. Keeping it in
    // the pending submission means a request that is admitted later still
    // gives the NAS download card the same media thumbnail.
    let thumbnailData: Data?
    let createdAt: TimeInterval
    let lastAttemptAt: TimeInterval
    let attemptCount: Int
    let lastError: String

    private enum CodingKeys: String, CodingKey {
        case backendDialogId
        case messageId
        case options
        case peerAccessHash
        case directDocument
        case desiredFileName
        case thumbnailData
        case createdAt
        case lastAttemptAt
        case attemptCount
        case lastError
    }

    init(backendDialogId: String, messageId: Int32, options: FluxgramNASSubmissionOptions, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil, desiredFileName: String? = nil, thumbnailData: Data? = nil, createdAt: TimeInterval = Date().timeIntervalSince1970, lastAttemptAt: TimeInterval = 0, attemptCount: Int = 0, lastError: String = "") {
        self.backendDialogId = backendDialogId
        self.messageId = messageId
        self.options = options
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
        self.desiredFileName = desiredFileName
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backendDialogId: try container.decode(String.self, forKey: .backendDialogId),
            messageId: try container.decode(Int32.self, forKey: .messageId),
            options: try container.decode(FluxgramNASSubmissionOptions.self, forKey: .options),
            peerAccessHash: try container.decodeIfPresent(String.self, forKey: .peerAccessHash),
            directDocument: try container.decodeIfPresent(FluxgramNASDirectDocument.self, forKey: .directDocument),
            desiredFileName: try container.decodeIfPresent(String.self, forKey: .desiredFileName),
            thumbnailData: try container.decodeIfPresent(Data.self, forKey: .thumbnailData),
            createdAt: try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? Date().timeIntervalSince1970,
            lastAttemptAt: try container.decodeIfPresent(TimeInterval.self, forKey: .lastAttemptAt) ?? 0,
            attemptCount: try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0,
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        )
    }

    var stableKey: String {
        var values = [
            self.backendDialogId,
            String(self.messageId),
            self.options.downloadSubdir,
            self.options.title,
            self.options.note,
            self.options.tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: ","),
            self.options.inbox ? "1" : "0",
            self.peerAccessHash ?? ""
        ]
        values.append(self.desiredFileName ?? "")
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
            desiredFileName: self.desiredFileName,
            thumbnailData: self.thumbnailData,
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
    let requestedTitle: String
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
    let thumbnailData: Data?
    /// NAS task creation time. Older records may omit it.
    let createdAt: TimeInterval?

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
        if !self.requestedTitle.isEmpty {
            values.append(self.requestedTitle)
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
        let output = self.outputFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = self.downloadSubdir.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = self.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty || (!directory.isEmpty && !file.isEmpty) else {
            return nil
        }
        // Some NAS history records expose only downloadSubdir + fileName;
        // newer records provide outputFile. Accept both forms so callers can
        // deep-link to the same relative path.
        var path = output
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") {
            // The backend may return an absolute filesystem path. FluxTok
            // needs a path relative to its configured NAS root, so prefer the
            // persisted directory and filename when available.
            path = [directory, file].filter { !$0.isEmpty }.joined(separator: "/")
        } else if !directory.isEmpty && !path.contains("/") && !path.contains("\\") {
            path = directory + "/" + path
        }
        path = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/") else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
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
        if !self.requestedTitle.isEmpty {
            values.append("标题：\(self.requestedTitle)")
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

private func fluxgramHubEndpointError(_ reason: String) -> String {
    let normalized = reason.lowercased()
    if normalized.contains("-1001") || normalized.contains("timeout") || normalized.contains("timed out") {
        return "请求超时"
    } else if normalized.contains("-1009") || normalized.contains("not connected") {
        return "当前无网络"
    } else if normalized.contains("-1004") || normalized.contains("-1003") || normalized.contains("connection") {
        return "无法连接"
    }
    return "暂不可用"
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
    let latencyMilliseconds: Int?

    var detailText: String {
        let status = self.statusCode.map { "HTTP \($0)" } ?? "无 HTTP 响应"
        let latency = self.latencyMilliseconds.map { " · \($0) ms" } ?? ""
        return "\(self.endpointName)\n\(self.baseURL)\n\(self.message)（\(status)\(latency)）"
    }
}

public struct FluxgramHubStatusSnapshot: Equatable {
    public let local: String
    public let remote: String
    public let localLatencyMilliseconds: Int?
    public let remoteLatencyMilliseconds: Int?
    public let ai: String
    public let downloads: String
    public let learning: String
    public let notifications: String

    public init(local: String, remote: String, localLatencyMilliseconds: Int? = nil, remoteLatencyMilliseconds: Int? = nil, ai: String, downloads: String, learning: String, notifications: String) {
        self.local = local
        self.remote = remote
        self.localLatencyMilliseconds = localLatencyMilliseconds
        self.remoteLatencyMilliseconds = remoteLatencyMilliseconds
        self.ai = ai
        self.downloads = downloads
        self.learning = learning
        self.notifications = notifications
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
    public let sourceLabel: String
    public let sourceText: String
    public let thumbnailData: Data?

    public init(dialogId: Int64, messageId: Int32, document: FluxgramNASDirectDocument, sourceLabel: String = "", sourceText: String = "", thumbnailData: Data? = nil) {
        self.dialogId = dialogId
        self.messageId = messageId
        self.document = document
        self.sourceLabel = sourceLabel
        self.sourceText = sourceText
        self.thumbnailData = thumbnailData
    }
}

public struct FluxgramNASDownloadRequest: Equatable {
    public let dialogId: Int64
    public let messageId: Int32
    public let peerAccessHash: String?
    public let directDocument: FluxgramNASDirectDocument?
    public let sourceLabel: String
    public let sourceText: String
    public let desiredFileName: String?
    // Client-only type information lets the confirmation screen filter a
    // mixed selection even if Telegram cannot refresh a video reference.
    public let isVideo: Bool
    // Telegram's tiny preview is enough for both the confirmation list and
    // the NAS task card. The service sends only this preview, never the media.
    public let thumbnailData: Data?

    public init(dialogId: Int64, messageId: Int32, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil, sourceLabel: String = "", sourceText: String = "", desiredFileName: String? = nil, thumbnailData: Data? = nil, isVideo: Bool = false) {
        self.dialogId = dialogId
        self.messageId = messageId
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
        self.sourceLabel = sourceLabel
        self.sourceText = sourceText
        self.desiredFileName = desiredFileName
        self.isVideo = isVideo || directDocument != nil
        self.thumbnailData = thumbnailData
    }
}

private struct FluxgramNASDownloadPayload: Encodable {
    let downloadSubdir: String?
    let title: String?
    let note: String?
    let tags: [String]?
    let inbox: Bool?
    let peerAccessHash: String?
    let directDocument: FluxgramNASDirectDocument?
    let fileName: String?
    let thumbnailData: Data?

    init(options: FluxgramNASSubmissionOptions, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil, fileName: String? = nil, thumbnailData: Data? = nil) {
        self.downloadSubdir = options.downloadSubdir.isEmpty ? nil : options.downloadSubdir
        self.title = options.title.isEmpty ? nil : options.title
        self.note = options.note.isEmpty ? nil : options.note
        self.tags = options.tags.isEmpty ? nil : options.tags
        self.inbox = options.inbox ? true : nil
        self.peerAccessHash = peerAccessHash
        self.directDocument = directDocument
        self.fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Immediate thumbnails are normally only a few hundred bytes. Cap the
        // payload defensively so malformed local data cannot bloat a request.
        self.thumbnailData = thumbnailData.flatMap { $0.count <= 128 * 1024 ? $0 : nil }
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

public final class FluxgramNASService {
    public static let shared = FluxgramNASService()

    private static let pendingQueueKey = "com.fluxgram.ios.pending-downloads.v1"
    private static let submittedKeysKey = "com.fluxgram.ios.submitted-download-keys.v1"
    // Admission failures are retried with backoff. Once the NAS accepts a
    // task, its own downloader owns the media retry lifecycle; these limits
    // only apply while the phone is trying to hand the task over.
    private static let automaticRetryDelays: [TimeInterval] = [30.0, 120.0, 300.0, 900.0]
    private static let automaticRetryMaxAttempts = 5
    // Keep a bounded server-side backlog. The NAS can safely own a small
    // queue, while leaving very large selections on the phone until space is
    // available. This must be larger than downloader concurrency: otherwise
    // a normal NAS queue is incorrectly reported as an offline phone queue.
    private static let batchAdmissionLimit = 12
    private static let directoryCacheLifetime: TimeInterval = 30.0
    private static let submittedKeyLifetime: TimeInterval = 10.0 * 60.0
    private let workerQueue = DispatchQueue(label: "com.fluxgram.ios.nas")
    private var networkPathMonitor: NWPathMonitor?
    private var pendingRetryTimer: DispatchSourceTimer?
    private var cachedDownloadDirectories: [String]?
    private var cachedDownloadDirectoriesAt: TimeInterval = 0.0
    private var cachedDownloadDirectoriesConfigurationKey: String?
    private var recentlySubmittedKeys: [String: TimeInterval] = [:]
    // Batch admission happens off workerQueue so slow network requests do not
    // block status reads. Keep an in-flight set on the serialized queue to
    // prevent a foreground/network callback from submitting the same item.
    private var inFlightSubmissionKeys: Set<String> = []
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
                self?.syncPendingDownloadMemory()
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
            self?.syncPendingDownloadMemory()
        }
        monitor.start(queue: DispatchQueue(label: "com.fluxgram.ios.network-monitor", qos: .utility))

        // Network-path callbacks do not fire when the NAS merely finishes a
        // queued download. Poll the on-device pending queue while the app is
        // alive so admission resumes as soon as server backlog has room.
        let retryTimer = DispatchSource.makeTimerSource(queue: self.workerQueue)
        retryTimer.schedule(deadline: .now() + 20.0, repeating: 20.0)
        retryTimer.setEventHandler { [weak self] in
            guard let self, !self.loadPendingDownloads().isEmpty else {
                return
            }
            _ = self.retryPendingDownloadsLocked(maxAttempts: 4, enforceRetryInterval: true)
        }
        self.pendingRetryTimer = retryTimer
        retryTimer.resume()
    }

    // MARK: Telegram authentication (NAS session)
    func fetchTelegramAuthStatus(settings: FluxgramSettings, completion: @escaping (Result<String, Error>) -> Void) {
        self.performAuthRequest(settings: settings, path: "/api/auth/status", body: nil, completion: completion)
    }

    func sendTelegramLoginCode(settings: FluxgramSettings, phoneNumber: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.performAuthRequest(settings: settings, path: "/api/auth/send-code", body: ["phoneNumber": phoneNumber], completion: completion)
    }

    func signInTelegram(settings: FluxgramSettings, phoneNumber: String, code: String, password: String?, completion: @escaping (Result<String, Error>) -> Void) {
        var body: [String: Any] = ["phoneNumber": phoneNumber, "code": code]
        if let password, !password.isEmpty { body["password"] = password }
        self.performAuthRequest(settings: settings, path: "/api/auth/sign-in", body: body, completion: completion)
    }

    func logoutTelegram(settings: FluxgramSettings, completion: @escaping (Result<String, Error>) -> Void) {
        self.performAuthRequest(settings: settings, path: "/api/auth/logout", body: [:], completion: completion)
    }

    private func performAuthRequest(settings: FluxgramSettings, path: String, body: [String: Any]?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let configuration = FluxgramNASConfiguration(settings: settings) else {
            completion(.failure(NSError(domain: "FluxgramNAS", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先配置 NAS 地址和访问令牌。"])))
            return
        }
        self.workerQueue.async {
            var lastError: Error = NSError(domain: "FluxgramNAS", code: 2, userInfo: [NSLocalizedDescriptionKey: "NAS 请求失败。"])
            for index in configuration.baseURLs.indices {
                guard let url = URL(string: path, relativeTo: configuration.baseURLs[index]) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15.0
                request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
                switch self.execute(request) {
                case let .transportFailure(reason):
                    lastError = NSError(domain: "FluxgramNAS", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
                case let .response(response, data):
                    if (200 ... 299).contains(response.statusCode) {
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let text = object?["message"] as? String
                            ?? (object?["authorized"] as? Bool).map { "authorized:\($0)" }
                            ?? String(data: data, encoding: .utf8) ?? "操作成功"
                        DispatchQueue.main.async { completion(.success(text)) }
                        return
                    }
                    let message = self.message(for: response, data: data)
                    lastError = NSError(domain: "FluxgramNAS", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
                    if response.statusCode >= 400 && response.statusCode < 500 { break }
                }
            }
            DispatchQueue.main.async { completion(.failure(lastError)) }
        }
    }

    deinit {
        self.networkPathMonitor?.cancel()
        self.pendingRetryTimer?.cancel()
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
            directDocument: directDocument,
            desiredFileName: directDocument?.fileName,
            thumbnailData: nil
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
        let requests = directDownloads.map { download in
            FluxgramNASDownloadRequest(
                dialogId: download.dialogId,
                messageId: download.messageId,
                directDocument: download.document,
                sourceLabel: download.sourceLabel,
                sourceText: download.sourceText,
                desiredFileName: download.document.fileName,
                thumbnailData: download.thumbnailData,
                isVideo: true
            )
        }
        self.submit(downloadRequests: requests, options: options, completion: completion)
    }

    /// Submit a batch without letting a large multi-select turn into an
    /// unbounded burst of requests.  The NAS still owns the actual download
    /// queue; the client only limits admission pressure here.
    func submit(downloadRequests: [FluxgramNASDownloadRequest], options: FluxgramNASSubmissionOptions, progress: ((Int, Int) -> Void)? = nil, completion: @escaping ([FluxgramNASSubmissionResult]) -> Void) {
        guard !downloadRequests.isEmpty else {
            completion([])
            return
        }

        self.workerQueue.async { [weak self] in
            guard let self else { return }

            // Persist the whole admission set before opening network requests.
            // If iOS suspends or kills the app halfway through a large batch,
            // the not-yet-finished items remain recoverable on the next
            // foreground transition instead of silently disappearing.
            if self.configuration() != nil {
                self.pruneSubmittedKeys()
                for request in downloadRequests {
                    let submission = FluxgramNASSubmission(
                        backendDialogId: Self.backendDialogId(for: request.dialogId),
                        messageId: request.messageId,
                        options: options,
                        peerAccessHash: request.peerAccessHash,
                        directDocument: request.directDocument,
                        desiredFileName: request.desiredFileName ?? request.directDocument?.fileName,
                        thumbnailData: request.thumbnailData
                    )
                    guard submission.messageId > 0, !submission.backendDialogId.isEmpty else { continue }
                    guard self.recentlySubmittedKeys[submission.stableKey] == nil else { continue }
                    self.enqueuePending(submission)
                }
            }

            let resultsQueue = DispatchQueue(label: "com.fluxgram.ios.nas.batch-results")
            var results = [FluxgramNASSubmissionResult?](repeating: nil, count: downloadRequests.count)
            var completed = 0
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 4)
            let batchQueue = DispatchQueue(label: "com.fluxgram.ios.nas.batch", attributes: .concurrent)
            let admissionLimit: Int
            if let configuration = self.configuration() {
                // Respect the server's current active window as well as the
                // client's batch limit. This prevents a second multi-select
                // from adding more work while the NAS is already saturated.
                let activeCount: Int?
                switch self.performRead(configuration: configuration, path: ["api", "downloads"], queryItems: [URLQueryItem(name: "limit", value: "40")], timeoutInterval: 4.0) {
                case let .success(_, data):
                    // The endpoint includes completed and failed history in
                    // `downloads`; only active jobs consume admission slots.
                    activeCount = self.downloadJobs(from: data, key: "downloads")
                        .filter { ["queued", "downloading", "copying"].contains($0.status) }
                        .count
                case .failure:
                    activeCount = nil
                }
                let availableSlots = activeCount.map { max(0, Self.batchAdmissionLimit - $0) } ?? Self.batchAdmissionLimit
                admissionLimit = min(availableSlots, downloadRequests.count)
            } else {
                admissionLimit = downloadRequests.count
            }

            for (index, request) in downloadRequests.prefix(admissionLimit).enumerated() {
                group.enter()
                batchQueue.async {
                    semaphore.wait()
                    let submission = FluxgramNASSubmission(
                        backendDialogId: Self.backendDialogId(for: request.dialogId),
                        messageId: request.messageId,
                        options: options,
                        peerAccessHash: request.peerAccessHash,
                        directDocument: request.directDocument,
                        desiredFileName: request.desiredFileName ?? request.directDocument?.fileName,
                        thumbnailData: request.thumbnailData
                    )

                    // The network request is performed outside workerQueue so
                    // one slow item cannot block folder/status reads. State
                    // changes remain serialized on workerQueue afterwards.
                    let result: FluxgramNASSubmissionResult
                    if submission.messageId <= 0 || submission.backendDialogId.isEmpty {
                        result = .failed("无法识别此 Telegram 消息。")
                    } else if let configuration = self.configuration() {
                        let shouldSubmit = self.workerQueue.sync {
                            self.pruneSubmittedKeys()
                            guard self.recentlySubmittedKeys[submission.stableKey] == nil,
                                  !self.inFlightSubmissionKeys.contains(submission.stableKey) else {
                                return false
                            }
                            self.inFlightSubmissionKeys.insert(submission.stableKey)
                            return true
                        }
                        if !shouldSubmit {
                            result = .submitted("相同的下载请求已提交，未重复创建任务。")
                        } else {
                            let networkResult = self.performSubmission(submission, configuration: configuration)
                            result = self.workerQueue.sync {
                                self.inFlightSubmissionKeys.remove(submission.stableKey)
                                switch networkResult {
                                case .submitted:
                                    self.rememberSubmittedKey(submission.stableKey)
                                    self.removePending(submission)
                                case .pending:
                                    self.enqueuePending(submission.withAttempt(error: networkResult.message))
                                case .failed:
                                    // Permanent failures should not remain in
                                    // the recoverable local queue forever.
                                    self.removePending(submission)
                                }
                                return networkResult
                            }
                        }
                    } else {
                        result = .failed("请先配置 TGAPP 地址和访问令牌。")
                    }

                    resultsQueue.sync {
                        results[index] = result
                        completed += 1
                        if let progress {
                            DispatchQueue.main.async { progress(completed, downloadRequests.count) }
                        }
                    }
                    semaphore.signal()
                    group.leave()
                }
            }

            // Requests beyond the admission window are already persisted in
            // the local queue above. Report them immediately without creating
            // server jobs; the next window is opened after this group finishes.
            if admissionLimit < downloadRequests.count {
                for index in admissionLimit ..< downloadRequests.count {
                    resultsQueue.sync {
                        results[index] = .pending("已保存到本地队列，等待 NAS 现有任务完成后自动提交。")
                        completed += 1
                        if let progress {
                            DispatchQueue.main.async { progress(completed, downloadRequests.count) }
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.main) {
                if admissionLimit < downloadRequests.count {
                    // Continue admitting at most four requests. Backoff and
                    // permanent-error handling remain centralized in the
                    // existing pending-queue path.
                    self.retryPendingDownloads(automatic: true)
                }
                completion(results.compactMap { $0 })
            }
        }
    }

    func submit(downloadRequests: [FluxgramNASDownloadRequest], options: FluxgramNASSubmissionOptions, completion: @escaping ([FluxgramNASSubmissionResult]) -> Void) {
        self.submit(downloadRequests: downloadRequests, options: options, progress: nil, completion: completion)
    }

    func retryPendingDownloads(automatic: Bool = false, completion: ((Int, Int) -> Void)? = nil) {
        self.workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.retryPendingDownloadsLocked(
                maxAttempts: automatic ? 4 : .max,
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
            if self.inFlightSubmissionKeys.contains(submission.stableKey) {
                DispatchQueue.main.async {
                    completion(.pending("这条下载请求正在提交，请稍后刷新。"))
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
                    } else if case .failed = result {
                        // A definitive server response (bad token, invalid
                        // message, permission error, etc.) cannot be fixed by
                        // repeating the same request. Keep it out of the
                        // recoverable queue while still reporting the reason.
                        pending.remove(at: index)
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

    // Reads the target directory directly. A failed preflight must not be
    // treated as an empty folder: callers depend on this result for names.
    func fetchDownloadFileNames(subdir: String, completion: @escaping (Set<String>?, String?) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async { completion(nil, "请先配置 TGAPP 地址和访问令牌。") }
                return
            }
            let result = self.performRead(
                configuration: configuration,
                path: ["api", "download-file-names"],
                queryItems: [
                    URLQueryItem(name: "subdir", value: subdir),
                    URLQueryItem(name: "limit", value: "5000")
                ],
                timeoutInterval: 8.0
            )
            switch result {
            case let .success(_, data):
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let values = object["fileNames"] as? [String] else {
                    DispatchQueue.main.async { completion(nil, "NAS 返回的文件列表无效。") }
                    return
                }
                let names = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                DispatchQueue.main.async { completion(names, nil) }
            case let .failure(message):
                DispatchQueue.main.async { completion(nil, message) }
            }
        }
    }

    func fetchDownloadsIncrementally(includeHistory: Bool = true, historyLimit: Int = 30, completion: @escaping (FluxgramNASDownloadsUpdate) -> Void) {
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
                URLQueryItem(name: "limit", value: "40")
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
                URLQueryItem(name: "limit", value: String(max(1, min(historyLimit, 200))))
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
                        message: "地址无效",
                        latencyMilliseconds: nil
                    )
                }
                var request = URLRequest(url: requestURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 8.0
                request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                let startedAt = Date().timeIntervalSinceReferenceDate
                switch self.execute(request) {
                case let .transportFailure(reason):
                    return FluxgramNASEndpointTestResult(
                        endpointName: configuration.endpointName(at: index),
                        baseURL: baseURL.absoluteString,
                        statusCode: nil,
                        message: "无法连接：\(reason)",
                        latencyMilliseconds: nil
                    )
                case let .response(response, data):
                    let latency = max(0, Int(((Date().timeIntervalSinceReferenceDate - startedAt) * 1000.0).rounded()))
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
                        message: message,
                        latencyMilliseconds: latency
                    )
                }
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    public func fetchHubStatus(completion: @escaping (FluxgramHubStatusSnapshot) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            let settings = try? FluxgramSettingsStore.load()
            // Keep local and remote in fixed slots. The download configuration
            // intentionally drops empty endpoints, but the status page must
            // never shift an external endpoint into the local slot.
            let endpointValues = [
                settings?.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                settings?.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ]
            let token = settings?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var endpointStates = ["未配置", "未配置"]
            var endpointLatencies: [Int?] = [nil, nil]
            if !token.isEmpty {
                for index in endpointValues.indices {
                    let rawValue = endpointValues[index]
                    guard !rawValue.isEmpty, var components = URLComponents(string: rawValue), components.host != nil else {
                        if !rawValue.isEmpty {
                            endpointStates[index] = "地址无效"
                        }
                        continue
                    }
                    if components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).caseInsensitiveCompare("api") == .orderedSame {
                        components.path = ""
                    }
                    guard let baseURL = components.url else {
                        endpointStates[index] = "地址无效"
                        continue
                    }
                    let url = baseURL.appendingPathComponent("api").appendingPathComponent("downloads")
                    var requestComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    requestComponents?.queryItems = [URLQueryItem(name: "limit", value: "1")]
                    guard let requestURL = requestComponents?.url else {
                        endpointStates[index] = "地址无效"
                        continue
                    }
                    var request = URLRequest(url: requestURL)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 4.0
                    request.setValue(token, forHTTPHeaderField: "X-TGAPP-Token")
                    let startedAt = Date().timeIntervalSinceReferenceDate
                    switch self.execute(request) {
                    case .response(let response, _):
                        endpointLatencies[index] = max(0, Int(((Date().timeIntervalSinceReferenceDate - startedAt) * 1000.0).rounded()))
                        endpointStates[index] = (200 ... 299).contains(response.statusCode) ? "正常" : "HTTP \(response.statusCode)"
                    case .transportFailure(let reason):
                        endpointStates[index] = fluxgramHubEndpointError(reason)
                    }
                }
            } else if endpointValues.contains(where: { !$0.isEmpty }) {
                endpointStates = endpointValues.map { $0.isEmpty ? "未配置" : "缺少令牌" }
            }
            let localState = endpointStates[0]
            let remoteState = endpointStates[1]
            let pendingCount = self.loadPendingDownloads().count
            let aiState: String
            if let settings, !settings.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !settings.aiAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiState = "已配置"
            } else {
                aiState = "未配置"
            }
            let notificationState: String
            if let settings, !settings.notifyStatusURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !settings.notifyStatusToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notificationState = "已配置"
            } else {
                notificationState = "未配置"
            }
            let learningCount = FluxgramDownloadMemoryStore.pendingUploadCount()
            let snapshot = FluxgramHubStatusSnapshot(
                local: localState,
                remote: remoteState,
                localLatencyMilliseconds: endpointLatencies.indices.contains(0) ? endpointLatencies[0] : nil,
                remoteLatencyMilliseconds: endpointLatencies.indices.contains(1) ? endpointLatencies[1] : nil,
                ai: aiState,
                downloads: pendingCount == 0 ? "无待提交" : "\(pendingCount) 条待提交",
                learning: learningCount == 0 ? "已同步" : "\(learningCount) 条待同步",
                notifications: notificationState
            )
            DispatchQueue.main.async {
                completion(snapshot)
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

    /// Pause/resume/delete are thin wrappers around the NAS task API. The
    /// downloader owns all queue and file semantics; this class only forwards
    /// the user's per-card action.
    func pauseDownload(jobId: String, completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", jobId, "pause"], successMessage: "已暂停此任务。", completion: completion)
    }

    func resumeDownload(jobId: String, completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", jobId, "resume"], successMessage: "已继续此任务。", completion: completion)
    }

    func retryDownload(jobId: String, completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", jobId, "retry"], successMessage: "已提交此任务重试。", completion: completion)
    }

    func deleteDownload(jobId: String, completion: @escaping (Bool, String) -> Void) {
        self.performDelete(path: ["api", "downloads", jobId], successMessage: "已删除任务记录。", completion: completion)
    }

    func clearUnfinishedDownloads(completion: @escaping (Int, Int, String?) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async { completion(0, 0, "请先配置 TGAPP 地址和访问令牌。") }
                return
            }
            var cancelled = 0
            var failures: [String] = []
            if case let .success(_, data) = self.performRead(configuration: configuration, path: ["api", "downloads"], queryItems: [URLQueryItem(name: "limit", value: "200")], timeoutInterval: 8.0) {
                let jobs = self.downloadJobs(from: data, key: "downloads")
                for job in jobs where !job.id.isEmpty {
                    let result = self.performActionLocked(configuration: configuration, path: ["api", "downloads", job.id, "cancel"])
                    if result.success {
                        cancelled += 1
                    } else if !result.message.isEmpty {
                        failures.append("\(job.title)：\(result.message)")
                    }
                }
            }
            let pendingCount = self.loadPendingDownloads().count
            self.savePendingDownloads([])
            let error = failures.isEmpty ? nil : failures.prefix(3).joined(separator: "；")
            DispatchQueue.main.async { completion(cancelled, pendingCount, error) }
        }
    }

    func retryProblemDownloads(completion: @escaping (Bool, String) -> Void) {
        self.performAction(path: ["api", "downloads", "retry-problem"], successMessage: "已提交失败任务重试。", completion: completion)
    }

    func syncDownloadMemory(sourceLabel: String, sourceText: String, author: String, title: String, tags: [String]) {
        self.syncPendingDownloadMemory()
    }

    func syncPendingDownloadMemory(completion: ((Int, Int, String?) -> Void)? = nil) {
        self.workerQueue.async { [weak self] in
            guard let self, let configuration = self.configuration() else {
                if let completion {
                    DispatchQueue.main.async {
                        completion(0, FluxgramDownloadMemoryStore.pendingUploadCount(), "请先配置 TGAPP 地址和访问令牌。")
                    }
                }
                return
            }
            var uploadedSignatures = Set<String>()
            var endpointFailures: [String] = []
            var failedEntries = 0
            let pendingEntries = FluxgramDownloadMemoryStore.pendingUploadEntries()
            for entry in pendingEntries {
                let payload: [String: Any] = [
                    "sourceLabel": entry.sourceLabel,
                    "sourceText": entry.sourceText,
                    "author": entry.author,
                    "title": entry.title,
                    "tags": entry.tags,
                    "updatedAt": entry.updatedAt
                ]
                guard JSONSerialization.isValidJSONObject(payload) else {
                    endpointFailures.append("学习记录数据无法编码：\(entry.author.isEmpty ? entry.signature : entry.author)")
                    failedEntries += 1
                    continue
                }
                var didUploadEntry = false
                var entryFailures: [String] = []
                for (index, baseURL) in configuration.baseURLs.enumerated() {
                    let url = baseURL
                        .appendingPathComponent("api")
                        .appendingPathComponent("fluxgram")
                        .appendingPathComponent("metadata-memory")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 8.0
                    request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])
                    switch self.execute(request) {
                    case let .transportFailure(reason):
                        entryFailures.append("\(configuration.endpointDescription(at: index))：\(reason)")
                    case let .response(response, data):
                        guard (200 ... 299).contains(response.statusCode) else {
                            entryFailures.append("\(configuration.endpointDescription(at: index)) 返回：\(self.message(for: response, data: data))")
                            continue
                        }
                        uploadedSignatures.insert(entry.signature)
                        didUploadEntry = true
                        break
                    }
                }
                if didUploadEntry {
                    // A fallback endpoint may fail before another endpoint
                    // succeeds. Those transient failures belong to this
                    // entry only and must not obscure failures from other
                    // records, so discard them after this entry succeeds.
                } else {
                    failedEntries += 1
                    endpointFailures.append(contentsOf: entryFailures)
                }
            }
            FluxgramDownloadMemoryStore.markUploaded(signatures: uploadedSignatures)
            if let completion {
                let remaining = FluxgramDownloadMemoryStore.pendingUploadCount()
                let failureMessage: String?
                if !endpointFailures.isEmpty {
                    failureMessage = endpointFailures.prefix(3).joined(separator: "；")
                } else if failedEntries > 0 {
                    failureMessage = "有 \(failedEntries) 条学习记录暂未同步。"
                } else {
                    failureMessage = nil
                }
                DispatchQueue.main.async {
                    completion(uploadedSignatures.count, remaining, failureMessage)
                }
            }
        }
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
        var attemptBudget = maxAttempts
        switch self.performRead(configuration: configuration, path: ["api", "downloads"], queryItems: [URLQueryItem(name: "limit", value: "40")], timeoutInterval: 4.0) {
        case let .success(_, data):
            // Completed/error records remain in the endpoint response but do
            // not occupy a downloader slot.
            let activeCount = self.downloadJobs(from: data, key: "downloads")
                .filter { ["queued", "downloading", "copying"].contains($0.status) }
                .count
            attemptBudget = min(attemptBudget, max(0, Self.batchAdmissionLimit - activeCount))
        case .failure:
            break
        }

        for submission in pending {
            guard attempted < attemptBudget else {
                retained.append(submission)
                continue
            }
            if self.recentlySubmittedKeys[submission.stableKey] != nil {
                continue
            }
            if self.inFlightSubmissionKeys.contains(submission.stableKey) {
                retained.append(submission)
                continue
            }
            if enforceRetryInterval,
               submission.lastAttemptAt > 0,
               (submission.attemptCount >= Self.automaticRetryMaxAttempts ||
                now - submission.lastAttemptAt < Self.automaticRetryDelay(for: submission.attemptCount)) {
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

    private static func automaticRetryDelay(for attemptCount: Int) -> TimeInterval {
        let index = max(0, min(attemptCount - 1, Self.automaticRetryDelays.count - 1))
        return Self.automaticRetryDelays[index]
    }

    private func performSubmission(_ submission: FluxgramNASSubmission, configuration: FluxgramNASConfiguration, peerAccessHash: String? = nil, directDocument: FluxgramNASDirectDocument? = nil) -> FluxgramNASSubmissionResult {
        let resolvedPeerAccessHash = peerAccessHash ?? submission.peerAccessHash
        let resolvedDirectDocument = directDocument ?? submission.directDocument
        guard let body = try? JSONEncoder().encode(FluxgramNASDownloadPayload(options: submission.options, peerAccessHash: resolvedPeerAccessHash, directDocument: resolvedDirectDocument, fileName: submission.desiredFileName, thumbnailData: submission.thumbnailData)) else {
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
                    // The NAS has responded with a definitive client error
                    // (for example an invalid token or message reference).
                    // Do not submit the same download to another endpoint and
                    // then report a misleading success.
                    break
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
                    let failureMessage = self.message(for: response, data: data)
                    endpointFailures.append("\(configuration.endpointDescription(at: index)) 返回：\(failureMessage)")
                    // A concrete client error (bad token, invalid task id,
                    // etc.) will be the same on the fallback endpoint. More
                    // importantly, sending a second mutating request after a
                    // server response can hide the original error. Only
                    // server-side failures continue to the next endpoint.
                    if response.statusCode >= 400 && response.statusCode < 500 {
                        DispatchQueue.main.async {
                            completion(false, failureMessage)
                        }
                        return
                    }
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

    private func performDelete(path: [String], successMessage: String, completion: @escaping (Bool, String) -> Void) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            guard let configuration = self.configuration() else {
                DispatchQueue.main.async { completion(false, "请先配置 TGAPP 地址和访问令牌。") }
                return
            }
            var failures: [String] = []
            for (index, baseURL) in configuration.baseURLs.enumerated() {
                let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 8.0
                request.setValue(configuration.accessToken, forHTTPHeaderField: "X-TGAPP-Token")
                switch self.execute(request) {
                case let .transportFailure(reason): failures.append("\(configuration.endpointDescription(at: index)) (\(reason))")
                case let .response(response, data):
                    if (200 ... 299).contains(response.statusCode) {
                        DispatchQueue.main.async { completion(true, successMessage) }
                        return
                    }
                    let message = self.message(for: response, data: data)
                    if response.statusCode >= 400 && response.statusCode < 500 {
                        DispatchQueue.main.async { completion(false, message) }
                        return
                    }
                    failures.append("\(configuration.endpointDescription(at: index)) 返回：\(message)")
                }
            }
            DispatchQueue.main.async { completion(false, failures.isEmpty ? "NAS 请求失败。" : failures.joined(separator: "；")) }
        }
    }

    private func performActionLocked(configuration: FluxgramNASConfiguration, path: [String]) -> (success: Bool, message: String) {
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
            case let .response(response, data):
                if (200 ... 299).contains(response.statusCode) {
                    return (true, "")
                }
                let message = self.message(for: response, data: data)
                endpointFailures.append("\(configuration.endpointDescription(at: index)) 返回：\(message)")
                if response.statusCode >= 400 && response.statusCode < 500 {
                    return (false, message)
                }
            }
        }
        return (false, endpointFailures.joined(separator: "；"))
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

    func removePendingDownload(_ submission: FluxgramNASSubmission, completion: (() -> Void)? = nil) {
        self.workerQueue.async { [weak self] in
            guard let self else { return }
            self.removePending(submission)
            if let completion { DispatchQueue.main.async { completion() } }
        }
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
                requestedTitle: self.string(value, key: "title"),
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
                inbox: self.boolean(value, key: "inbox"),
                thumbnailData: self.base64Data(value, keys: ["thumbnailData", "thumbnail"]),
                createdAt: self.optionalTime(value, keys: ["createdAt", "created_at", "submittedAt", "submitted_at"])
            )
        }
    }

    private func downloadFileNames(from data: Data, key: String, subdir: String) -> Set<String> {
        return Set(self.downloadJobs(from: data, key: key).compactMap { job in
            guard job.downloadSubdir.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(subdir.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
                return nil
            }
            let name = job.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
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

    private func base64Data(_ value: [String: Any], keys: [String]) -> Data? {
        for key in keys {
            if let string = value[key] as? String, let data = Data(base64Encoded: string) {
                return data
            }
        }
        return nil
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

    private func optionalTime(_ value: [String: Any], keys: [String]) -> TimeInterval? {
        for key in keys {
            guard let raw = value[key] else {
                continue
            }
            if let number = raw as? NSNumber {
                return number.doubleValue > 10_000_000_000 ? number.doubleValue / 1_000.0 : number.doubleValue
            }
            if let string = raw as? String {
                if let number = Double(string) {
                    return number > 10_000_000_000 ? number / 1_000.0 : number
                }
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date.timeIntervalSince1970
                }
            }
        }
        return nil
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
