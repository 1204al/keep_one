import AVFoundation
import Photos
import UIKit

/// UI image loading with PhotoKit's caching manager and a small memory cache.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    // Reuse the visible cell's rendition immediately when a held preview opens. Weak values keep
    // this lookup from retaining decoded images after the main cache and cells release them.
    private let previews = NSMapTable<NSString, UIImage>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    var allowNetwork = false

    private init() {
        cache.countLimit = 600
        // Cost is decoded bytes: full-screen images (~14 MB each) and thumbnails share this cache, and
        // a count limit alone would let 600 full-screen images pile up.
        cache.totalCostLimit = 160 * 1_048_576
        manager.allowsCachingHighQualityImages = false
    }

    func cached(_ id: String, size: CGSize) -> UIImage? {
        cache.object(forKey: key(id, size))
    }

    func cachedPreview(_ id: String) -> UIImage? { previews.object(forKey: id as NSString) }

    private func key(_ id: String, _ size: CGSize) -> NSString {
        "\(id)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    func image(for id: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill,
               highQuality: Bool = false) async -> UIImage? {
        let cacheKey = key(id, targetSize)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let asset = PhotoKitLibrary.shared.asset(for: id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        options.resizeMode = highQuality ? .exact : .fast
        options.isNetworkAccessAllowed = allowNetwork || highQuality
        options.version = .current
        let image: UIImage? = await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLockBox()
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                // Opportunistic delivery may send a degraded image first; wait for the final one
                // unless that is all we will get.
                if degraded && !cancelled && !failed && image != nil && !highQuality {
                    return
                }
                guard once.claim() else { return }
                continuation.resume(returning: image)
            }
        }
        if let image { remember(image, for: id, size: targetSize) }
        return image
    }

    struct Delivery: Sendable {
        let image: UIImage
        /// False for PhotoKit's quick, low-resolution first pass.
        let isFinal: Bool
    }

    /// Opportunistic delivery as a stream: a quick (possibly degraded) image first, then the final one,
    /// so grids fill in immediately while scrolling. When the consumer stops listening — the cell
    /// scrolled away and its task was cancelled — the PhotoKit request is cancelled too, instead of
    /// decoding images nobody will see.
    func images(for id: String, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill,
                highQuality: Bool = false) -> AsyncStream<Delivery> {
        if let hit = cache.object(forKey: key(id, targetSize)) {
            return AsyncStream { $0.yield(Delivery(image: hit, isFinal: true)); $0.finish() }
        }
        guard let asset = PhotoKitLibrary.shared.asset(for: id) else { return AsyncStream { $0.finish() } }
        let options = PHImageRequestOptions()
        options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        options.resizeMode = highQuality ? .exact : .fast
        options.isNetworkAccessAllowed = allowNetwork || highQuality
        options.version = .current
        let (stream, continuation) = AsyncStream.makeStream(of: Delivery.self, bufferingPolicy: .bufferingNewest(2))
        let requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            if let image { continuation.yield(Delivery(image: image, isFinal: !degraded)) }
            if !degraded || cancelled || failed { continuation.finish() }
        }
        let manager = manager
        continuation.onTermination = { _ in manager.cancelImageRequest(requestID) }
        // If the photo service stops answering, end the stream so the cell shows its placeholder
        // instead of staying blank (finishing an already finished stream does nothing).
        let timeout = PhotoKitLibrary.requestTimeout(allowNetwork: options.isNetworkAccessAllowed)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { continuation.finish() }
        return stream
    }

    func remember(_ image: UIImage, for id: String, size: CGSize) {
        cache.setObject(image, forKey: key(id, size), cost: Self.cost(of: image))
        previews.setObject(image, forKey: id as NSString)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return Int(image.size.width * image.size.height * image.scale * image.scale * 4) }
        return cg.bytesPerRow * cg.height
    }

    func startCaching(_ ids: [String], targetSize: CGSize) {
        let assets = PhotoKitLibrary.shared.assets(for: ids)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }

    func playerItem(for id: String) async -> AVPlayerItem? {
        guard let asset = PhotoKitLibrary.shared.asset(for: id) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    func purge() {
        cache.removeAllObjects()
        previews.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }
}
