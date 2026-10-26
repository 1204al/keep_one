import AVFoundation
import CryptoKit
import Foundation
import Photos
import UIKit

/// PhotoKit-backed implementation of the library protocols.
/// All requests are local-only unless the user enabled iCloud downloads.
final class PhotoKitLibrary: NSObject, PhotoLibraryProviding, ThumbnailProviding, AssetResourceProviding, @unchecked Sendable {
    static let shared = PhotoKitLibrary()

    private let lock = NSLock()
    private var assetCache: [String: PHAsset] = [:]
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var observing = false
    /// The last full fetch and its metadata, kept current from PhotoKit's change details: after a
    /// library change only the inserted, changed and removed assets are read again, instead of every
    /// property of every asset (seconds on a 100k library, repeated on each iCloud sync burst).
    private var fetchResult: PHFetchResult<PHAsset>?
    private var metadataByID: [String: AssetMetadata]?
    /// Bumped on every change notification; a full fetch that raced with a change isn't cached.
    private var changeGeneration = 0
    /// Resolved lazily: touching PhotoKit before authorization can surface the permission prompt early.
    private var imageManager: PHImageManager { PHImageManager.default() }

    // MARK: Authorization

    func authorizationStatus() -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Metadata

    func fetchAllMetadata() async -> [AssetMetadata] {
        guard authorizationStatus().canRead else { return [] }
        // Only trust the incremental cache while change notifications are flowing into it.
        if let cached = lock.withLock({ observing ? metadataByID : nil }) { return Array(cached.values) }
        let generation = lock.withLock { changeGeneration }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.includeHiddenAssets = false
                options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                var metadata: [AssetMetadata] = []
                metadata.reserveCapacity(result.count)
                var cache: [String: PHAsset] = [:]
                cache.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image || asset.mediaType == .video else { return }
                    cache[asset.localIdentifier] = asset
                    metadata.append(Self.metadata(for: asset))
                }
                self.lock.withLock {
                    self.assetCache = cache
                    if self.changeGeneration == generation {
                        self.fetchResult = result
                        self.metadataByID = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    }
                }
                continuation.resume(returning: metadata)
            }
        }
    }

    static func metadata(for asset: PHAsset) -> AssetMetadata {
        AssetMetadata(
            id: asset.localIdentifier,
            mediaType: AssetMediaType(rawValue: asset.mediaType.rawValue) ?? .unknown,
            subtypes: MediaSubtype(rawValue: asset.mediaSubtypes.rawValue),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            hasAdjustments: asset.hasAdjustments,
            burstIdentifier: asset.burstIdentifier,
            representsBurst: asset.representsBurst,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            sourceType: AssetSourceType(rawValue: asset.sourceType.rawValue),
            adjustmentTimestamp: asset.adjustmentTimestamp
        )
    }

    func asset(for id: String) -> PHAsset? {
        if let cached = lock.withLock({ assetCache[id] }) { return cached }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if let fetched { lock.withLock { assetCache[id] = fetched } }
        return fetched
    }

    func assets(for ids: [String]) -> [PHAsset] {
        ids.compactMap(asset(for:))
    }

    // MARK: Change observation

    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = UUID()
            lock.withLock {
                continuations[token] = continuation
                if !observing {
                    observing = true
                    PHPhotoLibrary.shared().register(self)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: token) }
            }
        }
    }

    // MARK: Deletion

    func delete(_ plan: DeletionPlan) async throws -> [String] {
        guard authorizationStatus().canRead else { throw PhotoLibraryError.notAuthorized }
        var ids: [String] = []
        PHAsset.fetchAssets(withLocalIdentifiers: plan.assetIDs, options: nil).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        lock.withLock { plan.assetIDs.forEach { assetCache.removeValue(forKey: $0) } }
        // Everything was already deleted elsewhere: no system prompt, nothing to free.
        guard !ids.isEmpty else { return [] }
        let found = ids
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: found, options: nil))
            }
            return found
        } catch {
            let ns = error as NSError
            if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.userCancelled.rawValue {
                throw PhotoLibraryError.cancelled
            }
            throw PhotoLibraryError.failed(ns.localizedDescription)
        }
    }

    // MARK: Images

    func analysisImage(for id: String, maxDimension: Int, allowNetwork: Bool) async -> CGImage? {
        guard let asset = asset(for: id) else { return nil }
        if let image = await requestImage(asset: asset, maxDimension: maxDimension, allowNetwork: allowNetwork, fast: false) {
            return image
        }
        // Optimised iCloud libraries: fall back to whatever local rendition exists.
        return await requestImage(asset: asset, maxDimension: maxDimension, allowNetwork: false, fast: true)
    }

    /// How long a PhotoKit request may take before it is abandoned. If the photo service stops
    /// answering (it can crash on an unusual file), the request would otherwise never return and
    /// the scan would stall for good; a timed-out item is retried on a later scan instead.
    static func requestTimeout(allowNetwork: Bool) -> TimeInterval { allowNetwork ? 120 : 30 }

    /// Runs a callback-style PhotoKit request, resuming exactly once: with the result, or with
    /// `fallback` (and the request cancelled) after `timeout`.
    private func timedRequest<T: Sendable>(timeout: TimeInterval, fallback: T,
                                           start: (@escaping @Sendable (T) -> Void) -> PHImageRequestID) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resumed = OSAllocatedUnfairLockBox()
            let requestID = start { value in
                if resumed.claim() { continuation.resume(returning: value) }
            }
            let manager = imageManager
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                manager.cancelImageRequest(requestID)
                Log.scan.info("PhotoKit request timed out after \(Int(timeout)) s")
                continuation.resume(returning: fallback)
            }
        }
    }

    private func requestImage(asset: PHAsset, maxDimension: Int, allowNetwork: Bool, fast: Bool) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = fast ? .fastFormat : .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false
        options.version = .current
        let size = CGSize(width: maxDimension, height: maxDimension)
        let manager = imageManager
        return await timedRequest(timeout: Self.requestTimeout(allowNetwork: allowNetwork), fallback: nil) { finish in
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                // Wait for the final image, unless PhotoKit says no final image is coming.
                if degraded && !fast && !cancelled && !failed { return }
                finish(image.flatMap { $0.orientedCGImage(maxDimension: maxDimension) })
            }
        }
    }

    // MARK: Resources

    func resourceInfo(for id: String) async -> ResourceInfo {
        guard let asset = asset(for: id) else { return ResourceInfo() }
        let resources = PHAssetResource.assetResources(for: asset)
        var info = ResourceInfo()
        let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
        if #available(iOS 27.0, *) {
            info.filename = primary?.filename
            let sizes = resources.compactMap(\.dataSize)
            if !sizes.isEmpty, sizes.count == resources.count { info.bytes = Int64(sizes.reduce(0, +)) }
            info.pairedVideoBytes = resources.first { $0.type == .pairedVideo }?.dataSize.map(Int64.init)
        } else {
            info.filename = primary?.originalFilename
        }
        return info
    }

    func originalContentHash(for id: String) async -> String? {
        guard let asset = asset(for: id), asset.mediaType == .image else { return nil }
        let options = PHImageRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        let manager = imageManager
        return await timedRequest(timeout: Self.requestTimeout(allowNetwork: false), fallback: nil) { finish in
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                finish(data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
            }
        }
    }

    func videoAsset(for id: String, allowNetwork: Bool) async -> AVAsset? {
        guard let asset = asset(for: id), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .automatic
        options.version = .current
        let manager = imageManager
        let box: AVAssetBox? = await timedRequest(timeout: Self.requestTimeout(allowNetwork: allowNetwork) * 2, fallback: nil) { finish in
            manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                finish(avAsset.map(AVAssetBox.init))
            }
        }
        return box?.asset
    }
}

extension PhotoKitLibrary: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let targets = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            changeGeneration += 1
            applyIncrementally(changeInstance)
            return Array(continuations.values)
        }
        targets.forEach { $0.yield() }
    }

    /// Caller holds `lock`. Falls back to a full fetch next time whenever PhotoKit can't describe the
    /// change incrementally.
    private func applyIncrementally(_ change: PHChange) {
        guard let result = fetchResult, var byID = metadataByID else { return }
        guard let details = change.changeDetails(for: result) else { return }  // nothing in our fetch changed
        guard details.hasIncrementalChanges else {
            fetchResult = nil
            metadataByID = nil
            return
        }
        for asset in details.removedObjects {
            byID[asset.localIdentifier] = nil
            assetCache[asset.localIdentifier] = nil
        }
        for asset in details.insertedObjects + details.changedObjects {
            guard asset.mediaType == .image || asset.mediaType == .video else {
                byID[asset.localIdentifier] = nil
                continue
            }
            byID[asset.localIdentifier] = Self.metadata(for: asset)
            assetCache[asset.localIdentifier] = asset
        }
        fetchResult = details.fetchResultAfterChanges
        metadataByID = byID
    }
}

/// Carries a PhotoKit-provided AVAsset across the request callback (read-only use afterwards).
final class AVAssetBox: @unchecked Sendable {
    let asset: AVAsset
    init(_ asset: AVAsset) { self.asset = asset }
}

/// One-shot flag for callback APIs that may fire more than once.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

extension UIImage {
    /// CGImage with orientation applied, downscaled so the long side ≤ maxDimension.
    func orientedCGImage(maxDimension: Int) -> CGImage? {
        guard let cg = cgImage else { return nil }
        let longSide = max(size.width * scale, size.height * scale)
        if imageOrientation == .up && longSide <= CGFloat(maxDimension) * 1.25 { return cg }
        let factor = min(1, CGFloat(maxDimension) / longSide)
        let target = CGSize(width: (size.width * scale * factor).rounded(), height: (size.height * scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }.cgImage
    }
}
