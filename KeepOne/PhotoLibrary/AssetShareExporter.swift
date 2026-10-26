import Foundation
import Photos

/// A full-resolution file copied from Photos for the system share sheet.
struct SharedAssetFile: Sendable {
    let url: URL
    let directory: URL

    func removeTemporaryCopy() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum AssetShareExporter {
    enum ExportError: LocalizedError {
        case unavailable, noResource

        var errorDescription: String? {
            switch self {
            case .unavailable: "This item is no longer available in Photos."
            case .noResource: "The photo or video file couldn't be found."
            }
        }
    }

    static func export(_ id: String, allowNetwork: Bool) async throws -> SharedAssetFile {
        try Task.checkCancellation()
        guard let asset = PhotoKitLibrary.shared.asset(for: id) else { throw ExportError.unavailable }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferredTypes.lazy.compactMap({ type in resources.first { $0.type == type } }).first
        else { throw ExportError.noResource }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepOneShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (resource.originalFilename as NSString).lastPathComponent
        let file = SharedAssetFile(url: directory.appendingPathComponent(filename), directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork
            // PhotoKit writes directly to disk; even a multi-GB video never becomes one Data buffer.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: file.url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            return file
        } catch {
            file.removeTemporaryCopy()
            throw error
        }
    }
}
