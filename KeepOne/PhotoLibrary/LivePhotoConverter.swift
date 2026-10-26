import Foundation
import Photos

/// Explicit, opt-in Live Photo cleanup: saves a still copy (same date, location, favourite and
/// albums) so the original Live Photo can then go through the normal Trash Queue + final review.
enum LivePhotoConverter {
    enum ConversionError: Error, LocalizedError {
        case notFound, notLive, noPhotoResource, readFailed

        var errorDescription: String? {
            switch self {
            case .notFound: "The photo is no longer available."
            case .notLive: "This photo isn't a Live Photo."
            case .noPhotoResource: "The still image couldn't be found."
            case .readFailed: "The photo couldn't be read (it may only be in iCloud)."
            }
        }
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    /// Returns the local identifier of the new still photo.
    static func makeStillCopy(of id: String, allowNetwork: Bool) async throws -> String {
        guard let asset = PhotoKitLibrary.shared.asset(for: id) else { throw ConversionError.notFound }
        guard asset.mediaSubtypes.contains(.photoLive) else { throw ConversionError.notLive }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo })
        else { throw ConversionError.noPhotoResource }

        let buffer = Buffer()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                buffer.data.append(chunk)
            } completionHandler: { error in
                if error != nil { continuation.resume(throwing: ConversionError.readFailed) } else { continuation.resume() }
            }
        }

        let source = asset
        let containing = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        let data = buffer.data
        let identifier = Buffer()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite
            if let placeholder = request.placeholderForCreatedAsset {
                identifier.data = Data(placeholder.localIdentifier.utf8)
                containing.enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
            }
        }
        return String(decoding: identifier.data, as: UTF8.self)
    }

    /// Bytes reclaimed by dropping the paired video (exact on iOS 27+, estimated otherwise).
    static func pairedVideoBytes(for id: String) -> StorageInfo {
        if #available(iOS 27.0, *), let asset = PhotoKitLibrary.shared.asset(for: id),
           let size = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo })?.dataSize {
            return StorageInfo(bytes: Int64(size), isExact: true)
        }
        return StorageInfo(bytes: 2_600_000, isExact: false)
    }
}
