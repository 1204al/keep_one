import Foundation

/// Pixel statistics computed from a small (≈384 px) thumbnail with Accelerate.
struct QualityMetrics: Codable, Sendable, Equatable {
    /// log1p(variance of Laplacian) of the sharpest image tiles (subject sharpness).
    var sharpness: Float
    /// log1p(variance of Laplacian) over the whole frame.
    var globalSharpness: Float
    /// Optional higher-resolution (≈1024 px) subject sharpness used for best-shot tie breaking.
    var detailSharpness: Float?
    /// 0…1 gradient anisotropy — directional blur produces strongly one-sided gradients.
    var motionBlur: Float
    /// Mean luminance 0…1.
    var meanLuma: Float
    var lumaStdDev: Float
    /// Fraction of pixels ≥ 250/255.
    var clippedHighlights: Float
    /// Fraction of pixels ≤ 6/255.
    var crushedShadows: Float
    /// p95 − p05 luminance spread (0…1).
    var dynamicRange: Float
    /// Shannon entropy of the luminance histogram in bits (0…8).
    var entropy: Float
    /// Hasler–Süsstrunk colourfulness, roughly 0…1.
    var colorfulness: Float
    /// Fraction of pixels with a strong gradient — "visual information".
    var edgeDensity: Float

    /// 0…1 where 1 is a well exposed frame.
    var exposureScore: Float {
        var score: Float = 1
        let midDistance = abs(meanLuma - 0.46)
        score -= max(0, midDistance - 0.12) * 1.6
        score -= max(0, clippedHighlights - 0.04) * 1.8
        score -= max(0, crushedShadows - 0.08) * 1.5
        score -= max(0, 0.35 - dynamicRange) * 0.9
        return min(1, max(0, score))
    }
}

/// Cheap fingerprint used for duplicate detection and clustering.
struct ImageFingerprint: Codable, Sendable, Equatable {
    /// 64-bit DCT perceptual hash.
    var pHash: UInt64
    /// 16×16 luminance micro-thumbnail (256 bytes) for low-resolution pixel comparison.
    var micro: Data
    /// Mean RGB colour (0…255) — guards against hash collisions between differently coloured images.
    var meanColor: [UInt8]
    var analyzedWidth: Int
    var analyzedHeight: Int
    var quality: QualityMetrics
}

struct LabelScore: Codable, Sendable, Hashable {
    var id: String
    var confidence: Float
}

/// Results of Apple Vision requests on the analysis thumbnail.
struct VisionFeatures: Codable, Sendable, Equatable {
    var faceCount: Int
    /// Vision face-capture quality per detected face (0…1).
    var faceQualities: [Float]
    /// Largest face bounding-box area as a fraction of the frame.
    var largestFaceArea: Float
    /// Faces whose bounding box touches the frame edge (cut off).
    var facesTouchingEdge: Int
    var humanCount: Int
    /// Vision aesthetics overall score (−1…1), nil when unsupported.
    var aesthetics: Float?
    /// Vision's "utility image" flag (screenshots, receipts, documents…).
    var isUtility: Bool?
    /// Lens smudge confidence (iOS 26+).
    var smudge: Float?
    /// Top scene-classification labels.
    var labels: [LabelScore]
    /// Detected text regions and the fraction of the frame they cover (model-independent text cue).
    var textRegionCount: Int? = nil
    var textCoverage: Float? = nil

    var hasSubstantialText: Bool { (textRegionCount ?? 0) >= 6 || (textCoverage ?? 0) >= 0.08 }

    var meanFaceQuality: Float? {
        guard !faceQualities.isEmpty else { return nil }
        return faceQualities.reduce(0, +) / Float(faceQualities.count)
    }

    var minFaceQuality: Float? { faceQualities.min() }
    var hasPeople: Bool { faceCount > 0 || humanCount > 0 }

    func label(_ id: String) -> Float {
        labels.first(where: { $0.id == id })?.confidence ?? 0
    }

    func maxLabel(_ ids: [String]) -> Float {
        ids.map(label).max() ?? 0
    }
}

/// Zero-shot semantic scores derived from the MobileCLIP embedding.
struct SemanticFeatures: Codable, Sendable, Equatable {
    var modelID: String
    /// Probability mass per `SemanticGroup` (softmax over all concepts, summed per group).
    var groupScores: [String: Float]
    var topConcept: String
    var topConceptScore: Float

    func score(_ group: SemanticGroup) -> Float { groupScores[group.rawValue] ?? 0 }

    var topGroup: SemanticGroup? {
        groupScores.max(by: { $0.value < $1.value }).flatMap { SemanticGroup(rawValue: $0.key) }
    }
}

/// Keyword/regex evidence extracted from OCR text. Raw text is never logged.
struct OCRSignals: Codable, Sendable, Equatable {
    var receipt: Float = 0
    var parking: Float = 0
    var deviceLabel: Float = 0
    var ticket: Float = 0
    var shipping: Float = 0
    var menu: Float = 0
    var sensitive: Float = 0
    var screenError: Float = 0
    var document: Float = 0
    /// Optional so caches written before this field existed still decode.
    var priceTag: Float? = nil
    var priceRows: Int = 0
    var hasCurrency: Bool = false
    var dates: [Date] = []
    /// Short human-readable evidence tokens such as "VAT" or "P2" (shown in explanations, never logged).
    var evidence: [String] = []

    var latestDate: Date? { dates.max() }
}

struct ExtractedField: Codable, Sendable, Hashable, Identifiable {
    var label: String
    var value: String
    var id: String { label + ":" + value }
}

enum ExtractedInfoKind: String, Codable, Sendable {
    case receipt, device, ticket, parking, shipping
}

/// Lightweight "save useful information" summary.
struct ExtractedInfo: Codable, Sendable, Equatable {
    var kind: ExtractedInfoKind
    var title: String
    var fields: [ExtractedField]

    var plainText: String {
        ([title] + fields.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }
}

struct TextFeatures: Codable, Sendable, Equatable {
    var lineCount: Int
    var characterCount: Int
    var meanConfidence: Float
    /// Truncated OCR text; nil for suspected sensitive documents (never persisted for those).
    var text: String?
    var signals: OCRSignals
    var barcodeCount: Int
    var qrCount: Int
    var extracted: ExtractedInfo?
}

/// Sparse temporal fingerprint and quality samples for a video.
struct VideoFeatures: Codable, Sendable, Equatable {
    var isLocallyAvailable: Bool
    var codec: String?
    var frameRate: Float?
    var dataRate: Float?
    var frameTimes: [Double]
    var frameHashes: [UInt64]
    var frameLuma: [Float]
    var frameSharpness: [Float]
    var frameEntropy: [Float]
    /// Mean Hamming distance between consecutive sampled frames (0…64).
    var interFrameChange: Float
    var facesSeen: Int
    /// Mean MobileCLIP embedding of sampled frames (FP16 bytes), used for similar-video grouping.
    var semanticEmbedding: Data?
    var semantic: SemanticFeatures?

    var meanLuma: Float { frameLuma.isEmpty ? 0.5 : frameLuma.reduce(0, +) / Float(frameLuma.count) }
    var meanSharpness: Float {
        frameSharpness.isEmpty ? 0 : frameSharpness.reduce(0, +) / Float(frameSharpness.count)
    }
    var meanEntropy: Float {
        frameEntropy.isEmpty ? 6 : frameEntropy.reduce(0, +) / Float(frameEntropy.count)
    }
}

/// On-disk size of the asset's resources.
struct StorageInfo: Codable, Sendable, Equatable {
    var bytes: Int64
    /// True when obtained from PhotoKit/AVFoundation; false for estimates.
    var isExact: Bool
}
