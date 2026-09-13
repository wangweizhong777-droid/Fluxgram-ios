import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TinyThumbnail

// Keep enough source detail for the 88pt card and common Retina displays.
// The payload is still bounded so thumbnail upgrades cannot become media
// uploads or noticeably increase the NAS task size.
private let fluxgramThumbnailMaxPixelSize: CGFloat = 640.0
private let fluxgramThumbnailMaxBytes = 256 * 1024

/// Converts Telegram preview data to a card-sized JPEG without upscaling a
/// TinyThumbnail. The NAS payload is intentionally capped so this never turns
/// a preview request into a media upload.
func fluxgramPreparedThumbnailData(_ data: Data?, maxPixelSize: CGFloat = fluxgramThumbnailMaxPixelSize, maxBytes: Int = fluxgramThumbnailMaxBytes) -> Data? {
    guard let data else {
        return nil
    }
    // TinyThumbnail is a compact Telegram-specific payload and must be
    // expanded. Ordinary preview JPEG/PNG data should stay untouched when it
    // already fits the card; decoding and re-encoding it a second time is a
    // needless source of softness.
    let tinyThumbnailData = decodeTinyThumbnail(data: data)
    let decodedData = tinyThumbnailData ?? data
    guard let image = UIImage(data: decodedData) else {
        return data.count <= maxBytes ? data : nil
    }

    let pixelWidth = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
    let pixelHeight = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
    let sourceMax = max(pixelWidth, pixelHeight)
    if tinyThumbnailData == nil && sourceMax <= maxPixelSize && data.count <= maxBytes {
        return data
    }
    let scale = sourceMax > maxPixelSize ? maxPixelSize / sourceMax : 1.0
    let outputImage: UIImage
    if scale < 1.0 {
        let size = CGSize(width: max(1.0, floor(pixelWidth * scale)), height: max(1.0, floor(pixelHeight * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        outputImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    } else {
        outputImage = image
    }

    var quality: CGFloat = 0.82
    while quality >= 0.42 {
        if let compressed = outputImage.jpegData(compressionQuality: quality), compressed.count <= maxBytes {
            return compressed
        }
        quality -= 0.08
    }
    return outputImage.jpegData(compressionQuality: 0.35) ?? (data.count <= maxBytes ? data : nil)
}

func fluxgramImmediateThumbnailData(file: TelegramMediaFile) -> Data? {
    let representationData = file.previewRepresentations
        .sorted { lhs, rhs in
            Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height) > Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
        }
        .compactMap { $0.immediateThumbnailData }
        .first
    return fluxgramPreparedThumbnailData(representationData ?? file.immediateThumbnailData)
}

func fluxgramImmediateThumbnailData(image: TelegramMediaImage) -> Data? {
    let representationData = image.representations
        .sorted { lhs, rhs in
            Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height) > Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
        }
        .compactMap { $0.immediateThumbnailData }
        .first
    return fluxgramPreparedThumbnailData(representationData ?? image.immediateThumbnailData)
}

private func fluxgramPreviewResourceData(
    context: AccountContext,
    message: EngineMessage,
    media: AnyMediaReference,
    resource: TelegramMediaResource,
    fallback: Data?
) -> Signal<Data?, NoError> {
    let reference = media.resourceReference(resource)
    return Signal { subscriber in
        var delivered = false
        let fetchDisposable = fetchedMediaResource(
            mediaBox: context.account.postbox.mediaBox,
            userLocation: .peer(message.id.peerId),
            userContentType: .image,
            reference: reference,
            statsCategory: .image
        ).start(error: { _ in })

        let dataDisposable = context.account.postbox.mediaBox.resourceData(
            resource,
            option: .complete(waitUntilFetchStatus: false)
        ).start(next: { data in
            // MediaBox emits partial files while the preview is being fetched.
            // Do not decode and persist one of those partial JPEGs: it can
            // produce a valid but visibly blurry thumbnail.
            guard data.complete else {
                return
            }
            guard data.size > 0, let rawData = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: []) else {
                return
            }
            guard let prepared = fluxgramPreparedThumbnailData(rawData) else {
                return
            }
            delivered = true
            subscriber.putNext(prepared)
            subscriber.putCompletion()
        }, error: { _ in
            guard !delivered else { return }
            delivered = true
            subscriber.putNext(fallback)
            subscriber.putCompletion()
        }, completed: {
            guard !delivered else { return }
            delivered = true
            subscriber.putNext(fallback)
            subscriber.putCompletion()
        })

        return ActionDisposable {
            fetchDisposable.dispose()
            dataDisposable.dispose()
        }
    }
    |> timeout(12.0, queue: .mainQueue(), alternate: .single(fallback))
}

/// Loads the largest Telegram preview representation that is available for a
/// message. The source message and only the bounded preview are used; the
/// actual media file is never read or sent to the NAS.
func fluxgramMessageThumbnailData(context: AccountContext, message: EngineMessage) -> Signal<Data?, NoError> {
    if let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first {
        let fallback = fluxgramImmediateThumbnailData(file: file)
        let representation = file.previewRepresentations.max { lhs, rhs in
            Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height) < Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
        }
        if let representation {
            let media = FileMediaReference.message(message: MessageReference(message._asMessage()), media: file)
            return fluxgramPreviewResourceData(context: context, message: message, media: media.abstract, resource: representation.resource, fallback: fallback)
        }
        return .single(fallback)
    }
    if let image = message.media.compactMap({ $0 as? TelegramMediaImage }).first {
        let fallback = fluxgramImmediateThumbnailData(image: image)
        let representation = image.representations.max { lhs, rhs in
            Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height) < Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
        }
        if let representation {
            let media = ImageMediaReference.message(message: MessageReference(message._asMessage()), media: image)
            return fluxgramPreviewResourceData(context: context, message: message, media: media.abstract, resource: representation.resource, fallback: fallback)
        }
        return .single(fallback)
    }
    return .single(nil)
}
