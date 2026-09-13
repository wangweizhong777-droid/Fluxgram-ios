import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

private func fluxgramDirectDocumentFileName(file: TelegramMediaFile, resource: CloudDocumentMediaResource) -> String {
    if let fileName = resource.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
        return fileName
    }
    if let fileName = file.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
        return fileName
    }
    if file.isVideo || file.isInstantVideo {
        return "telegram-video-\(resource.fileId).mp4"
    }
    return "telegram-document-\(resource.fileId).bin"
}

private func fluxgramSuggestedNASFileName(message: EngineMessage, originalFileName: String) -> String {
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let codeRegex = try? NSRegularExpression(pattern: #"(?i)\b([A-Z]{2,8}[-_ ]?\d{2,6})\b"#) else {
        return originalFileName
    }
    let lines = text
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let stopWords: Set<String> = [
        "无码", "破解", "高清", "磁链", "点击", "复制", "有码", "字幕",
        "流出", "合集", "周年", "纪念", "专属", "梦幻", "共演",
        "高颜妹子", "多p", "啪啪做爱", "狂插", "口交", "潮吹", "内射"
    ]
    // Platform names are often included as hashtags next to the performer.
    // They should never become part of the downloaded filename.
    let platformWords: Set<String> = [
        "stripchat", "onlyfans", "fansly", "chaturbate", "pornhub", "xhamster",
        "xvideos", "redgifs", "manyvids", "manyv1ds", "telegram", "twitter", "x"
    ]
    let separators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "，,、/|｜；;：:（）()【】[]《》<>「」『』")
    )

    let hashtagCandidates: [String] = {
        guard let hashtagRegex = try? NSRegularExpression(pattern: #"#([A-Za-z0-9_一-龥ぁ-んァ-ンー·-]{2,40})"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return hashtagRegex.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            let token = String(text[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            let normalized = token.lowercased()
            guard !token.isEmpty, !platformWords.contains(normalized), !stopWords.contains(normalized) else {
                return nil
            }
            // Keep human names and account-style handles (e.g. yang818), but
            // avoid hashtags that are clearly only a number or a long sentence.
            if token.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
                return nil
            }
            let isName = token.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}ー·・]{2,8}$"#, options: .regularExpression) != nil
            let isHandle = token.range(of: #"^(?=.*[A-Za-z])[A-Za-z0-9_.-]{3,32}$"#, options: .regularExpression) != nil
            return (isName || isHandle) ? token : nil
        }
    }()

    var baseName: String?
    for (index, line) in lines.enumerated() {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = codeRegex.firstMatch(in: line, range: range),
              let codeRange = Range(match.range(at: 1), in: line) else {
            continue
        }
        let code = String(line[codeRange]).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-").uppercased()
        var candidateText = String(line[codeRange.upperBound...])
        if index + 1 < lines.count {
            let nextLine = lines[index + 1]
            if !nextLine.hasPrefix("#") && !nextLine.lowercased().contains("magnet") && !nextLine.contains("磁链") && !nextLine.contains("链接") {
                candidateText += " \(nextLine)"
            }
        }
        var names = hashtagCandidates
        names.append(contentsOf: candidateText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                guard candidate.count >= 2 && candidate.count <= 8 else {
                    return false
                }
                guard candidate.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}ー·・]+$"#, options: .regularExpression) != nil else {
                    return false
                }
                return !stopWords.contains(candidate)
            })
        var seen = Set<String>()
        names = names.filter { seen.insert($0.lowercased()).inserted }
        if !names.isEmpty {
            baseName = "\(code) \(Array(names.prefix(8)).joined(separator: "、"))"
            break
        }
    }

    guard let baseName else {
        return originalFileName
    }
    let ext = (originalFileName as NSString).pathExtension
    return ext.isEmpty ? baseName : "\(baseName).\(ext)"
}

public func fluxgramDirectDocument(message: EngineMessage) -> FluxgramNASDirectDocument? {
    guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first,
          let resource = file.resource as? CloudDocumentMediaResource,
          let fileReference = resource.fileReference,
          !fileReference.isEmpty else {
        return nil
    }
    let originalFileName = fluxgramDirectDocumentFileName(file: file, resource: resource)
    return FluxgramNASDirectDocument(
        documentId: String(resource.fileId),
        accessHash: String(resource.accessHash),
        fileReference: fileReference.base64EncodedString(),
        fileName: fluxgramSuggestedNASFileName(message: message, originalFileName: originalFileName),
        fileSize: resource.size ?? file.size ?? 0
    )
}

public func fluxgramDirectFile(message: EngineMessage) -> TelegramMediaFile? {
    return message.media.compactMap { $0 as? TelegramMediaFile }.first
}

private func fluxgramDownloadSourceLabel(message: EngineMessage) -> String {
    return message.peers[message.id.peerId]?.debugDisplayTitle ?? ""
}

private func fluxgramDownloadSourceText(message: EngineMessage) -> String {
    return message.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func fluxgramDownloadThumbnailData(message: EngineMessage) -> Data? {
    if let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first {
        return fluxgramImmediateThumbnailData(file: file)
    }
    if let image = message.media.compactMap({ $0 as? TelegramMediaImage }).first {
        return fluxgramImmediateThumbnailData(image: image)
    }
    return nil
}

public func fluxgramRefreshedDirectDownloads(context: AccountContext, messages: [EngineMessage], completion: @escaping ([FluxgramNASDirectDownload]) -> Void) {
    let videoMessages: [(EngineMessage, TelegramMediaFile)] = messages.compactMap { message in
        guard let file = fluxgramDirectFile(message: message), file.isVideo || file.isInstantVideo else {
            return nil
        }
        return (message, file)
    }
    guard !videoMessages.isEmpty else {
        completion([])
        return
    }

    // Refresh a small bounded batch so multi-select download menus do not wait
    // for every Telegram file reference in series. The result array preserves
    // message order, while an unavailable reference simply falls back to the
    // normal message download path in the caller.
    var nextIndex = 0
    var completedCount = 0
    var downloads = [FluxgramNASDirectDownload?](repeating: nil, count: videoMessages.count)
    let workerCount = min(4, videoMessages.count)

    func refreshNext() {
        guard nextIndex < videoMessages.count else {
            return
        }
        let index = nextIndex
        nextIndex += 1
        let (message, file) = videoMessages[index]
        let _ = (context.engine.resources.refreshFileReference(message: message, file: file)
        |> deliverOnMainQueue).start(next: { refreshedFile in
            let refreshedMessage: EngineMessage
            if let refreshedFile {
                let rawMessage = message._asMessage()
                refreshedMessage = EngineMessage(rawMessage.withUpdatedMedia(rawMessage.media.map { media in
                    return media.id == file.id ? refreshedFile : media
                }))
            } else {
                refreshedMessage = message
            }
            let finish: (Data?) -> Void = { thumbnailData in
                if let document = fluxgramDirectDocument(message: refreshedMessage) {
                    downloads[index] = FluxgramNASDirectDownload(
                        dialogId: message.id.peerId.toInt64(),
                        messageId: message.id.id,
                        document: document,
                        sourceLabel: fluxgramDownloadSourceLabel(message: refreshedMessage),
                        sourceText: fluxgramDownloadSourceText(message: refreshedMessage),
                        thumbnailData: thumbnailData ?? fluxgramDownloadThumbnailData(message: refreshedMessage)
                    )
                }
                completedCount += 1
                if completedCount == videoMessages.count {
                    completion(downloads.compactMap { $0 })
                } else {
                    refreshNext()
                }
            }

            // Fetch the largest available preview resource before submitting
            // the task. If Telegram cannot provide it quickly, the helper
            // emits the bounded immediate-thumbnail fallback and the task is
            // still submitted normally.
            let _ = (fluxgramMessageThumbnailData(context: context, message: refreshedMessage)
            |> deliverOnMainQueue).start(next: { thumbnailData in
                finish(thumbnailData)
            })
        })
    }

    for _ in 0 ..< workerCount {
        refreshNext()
    }
}

public func fluxgramRefreshedDownloadRequests(context: AccountContext, messages: [EngineMessage], completion: @escaping ([FluxgramNASDownloadRequest]) -> Void) {
    fluxgramRefreshedDirectDownloads(context: context, messages: messages) { downloads in
        let videoRequests = Dictionary(uniqueKeysWithValues: downloads.map { download in
            (download.messageId, FluxgramNASDownloadRequest(
                dialogId: download.dialogId,
                messageId: download.messageId,
                directDocument: download.document,
                sourceLabel: download.sourceLabel,
                sourceText: download.sourceText,
                thumbnailData: download.thumbnailData,
                isVideo: true
            ))
        })
        let requests = messages.compactMap { message -> FluxgramNASDownloadRequest? in
            guard message.media.contains(where: { media in
                media is TelegramMediaImage || (media as? TelegramMediaFile).map { $0.isVideo || $0.isInstantVideo } == true
            }) else {
                return nil
            }
            if let videoRequest = videoRequests[message.id.id] {
                return videoRequest
            }
            // A file-reference refresh can fail temporarily. Keep the media in
            // the selection instead of silently dropping it; NAS can still
            // resolve the original message through the regular endpoint.
            let peerAccessHash = (message.peers[message.id.peerId] as? TelegramUser).flatMap { peer in
                peer.accessHash.map { String($0.value) }
            }
            return FluxgramNASDownloadRequest(
                dialogId: message.id.peerId.toInt64(),
                messageId: message.id.id,
                peerAccessHash: peerAccessHash,
                sourceLabel: fluxgramDownloadSourceLabel(message: message),
                sourceText: fluxgramDownloadSourceText(message: message),
                thumbnailData: fluxgramDownloadThumbnailData(message: message),
                isVideo: message.media.contains(where: { ($0 as? TelegramMediaFile).map { $0.isVideo || $0.isInstantVideo } == true })
            )
        }
        completion(requests)
    }
}
