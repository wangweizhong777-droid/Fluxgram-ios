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

public func fluxgramDirectDocument(message: EngineMessage) -> FluxgramNASDirectDocument? {
    guard let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first,
          let resource = file.resource as? CloudDocumentMediaResource,
          let fileReference = resource.fileReference,
          !fileReference.isEmpty else {
        return nil
    }
    return FluxgramNASDirectDocument(
        documentId: String(resource.fileId),
        accessHash: String(resource.accessHash),
        fileReference: fileReference.base64EncodedString(),
        fileName: fluxgramDirectDocumentFileName(file: file, resource: resource),
        fileSize: resource.size ?? file.size ?? 0
    )
}

public func fluxgramDirectFile(message: EngineMessage) -> TelegramMediaFile? {
    return message.media.compactMap { $0 as? TelegramMediaFile }.first
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
            if let document = fluxgramDirectDocument(message: refreshedMessage) {
                downloads[index] = FluxgramNASDirectDownload(
                    dialogId: message.id.peerId.toInt64(),
                    messageId: message.id.id,
                    document: document
                )
            }
            completedCount += 1
            if completedCount == videoMessages.count {
                completion(downloads.compactMap { $0 })
            } else {
                refreshNext()
            }
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
                directDocument: download.document
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
                peerAccessHash: peerAccessHash
            )
        }
        completion(requests)
    }
}
