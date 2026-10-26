import Foundation

/// Versions of each analysis stage. Bumping one invalidates only that stage's cache.
enum PipelineVersion {
    static let fingerprint = 1
    static let vision = 2
    static let semantic = 2
    static let text = 1
    static let video = 1
    static let detail = 1
}

/// Everything KeepOne knows about one Photos asset. Persisted as a compact JSON payload;
/// large vectors (feature prints, embeddings) live in a separate table.
struct AssetRecord: Codable, Sendable, Identifiable {
    var metadata: AssetMetadata

    var fingerprint: ImageFingerprint?
    var fingerprintVersion: Int = 0

    var vision: VisionFeatures?
    var visionVersion: Int = 0

    var semantic: SemanticFeatures?
    var semanticVersion: Int = 0

    var text: TextFeatures?
    var textVersion: Int = 0

    var video: VideoFeatures?
    var videoVersion: Int = 0

    var detailVersion: Int = 0

    var storage: StorageInfo?
    /// SHA-256 of the original image data, computed only for exact-duplicate candidates.
    var contentHash: String?
    var filename: String?

    /// Consecutive analysis failures (corrupt media, unavailable asset). Capped retries.
    var failureCount: Int = 0
    var lastAnalyzedAt: Date?

    init(metadata: AssetMetadata) {
        self.metadata = metadata
    }

    var id: String { metadata.id }

    var needsFingerprint: Bool {
        metadata.isImage && (fingerprint == nil || fingerprintVersion < PipelineVersion.fingerprint) && failureCount < 3
    }

    var needsVision: Bool {
        metadata.isImage && (vision == nil || visionVersion < PipelineVersion.vision) && failureCount < 3
    }

    func needsSemantic(modelID: String?) -> Bool {
        guard metadata.isImage, failureCount < 3, let modelID else { return false }
        return semantic == nil || semanticVersion < PipelineVersion.semantic || semantic?.modelID != modelID
    }

    var needsImagePass: Bool { needsFingerprint || needsVision }

    var needsVideoPass: Bool {
        metadata.isVideo && (video == nil || videoVersion < PipelineVersion.video) && failureCount < 3
    }

    var isAnalyzed: Bool {
        metadata.isImage ? (fingerprint != nil && vision != nil) : (video != nil || metadata.mediaType != .video)
    }

    /// Best available size: exact if known, otherwise an estimate.
    var storageEstimate: StorageInfo {
        storage ?? StorageInfo(bytes: StorageEstimator.estimate(for: metadata), isExact: false)
    }

    var hasFaces: Bool { (vision?.faceCount ?? 0) > 0 }
    var hasPeople: Bool { vision?.hasPeople ?? ((video?.facesSeen ?? 0) > 0) }
}
