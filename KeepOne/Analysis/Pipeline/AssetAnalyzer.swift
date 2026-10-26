import CoreGraphics
import Foundation

struct ImageAnalysisResult: Sendable {
    var record: AssetRecord
    var featurePrint: [Float]?
    var embedding: [Float]?
}

/// Stateless per-asset analysis. Runs on the global concurrent executor, never the main thread.
/// Images are analysed from a ≈384 px rendition; higher resolutions are requested only for OCR
/// and best-shot tie-breaking.
struct AssetAnalyzer: Sendable {
    static let analysisDimension = 384
    static let ocrDimension = 1600
    static let detailDimension = 1024

    let thumbnails: any ThumbnailProviding
    let resources: any AssetResourceProviding
    let vision: any VisionAnalyzing
    let semantic: SemanticEngine?
    let text: any TextAnalyzing
    let video: any VideoAnalyzing

    func analyzeImage(_ input: AssetRecord, allowNetwork: Bool) async -> ImageAnalysisResult {
        var record = input
        var result = ImageAnalysisResult(record: record)
        let needsPixels = record.needsImagePass || record.needsSemantic(modelID: semantic?.modelID)

        if needsPixels {
            let image = await measure(.thumbnail) {
                await thumbnails.analysisImage(for: record.id, maxDimension: Self.analysisDimension, allowNetwork: allowNetwork)
            }
            guard let image else {
                record.failureCount += 1
                result.record = record
                return result
            }
            if record.needsFingerprint {
                if let fingerprint = await measure(.pixelMetrics, { ImageMetrics.fingerprint(for: image) }) {
                    // Preserve an earlier high-resolution measurement if pixels didn't change.
                    var fp = fingerprint
                    fp.quality.detailSharpness = record.fingerprint?.quality.detailSharpness
                    record.fingerprint = fp
                    record.fingerprintVersion = PipelineVersion.fingerprint
                }
            }
            if record.needsVision {
                let output = await vision.analyze(image)
                record.vision = output.features
                record.visionVersion = PipelineVersion.vision
                result.featurePrint = output.featurePrint
            }
            if let semantic, record.needsSemantic(modelID: semantic.modelID) {
                if let (embedding, features) = try? await measure(.semantic, { try await semantic.analyze(image) }) {
                    record.semantic = features
                    record.semanticVersion = PipelineVersion.semantic
                    result.embedding = embedding
                }
            }
        }
        if record.filename == nil || record.storage?.isExact != true {
            let info = await resources.resourceInfo(for: record.id)
            if let name = info.filename { record.filename = name }
            if let bytes = info.bytes { record.storage = StorageInfo(bytes: bytes, isExact: true) }
        }
        record.failureCount = 0
        record.lastAnalyzedAt = Date()
        result.record = record
        return result
    }

    /// OCR + barcodes on a larger rendition, only for likely documents/references.
    func analyzeText(_ input: AssetRecord, allowNetwork: Bool) async -> AssetRecord {
        var record = input
        guard let image = await thumbnails.analysisImage(for: record.id, maxDimension: Self.ocrDimension, allowNetwork: allowNetwork)
        else {
            record.textVersion = PipelineVersion.text  // unavailable locally — don't retry every launch
            return record
        }
        let output = await measure(.ocr) { await text.recognize(image) }
        let signals = OCRSignalExtractor.extract(lines: output.lines)
        let reference = SingleAssetClassifier.referenceEvidence(record)
        let sensitive = signals.sensitive >= 0.35 || SingleAssetClassifier.sensitiveScore(record) >= 0.35
        let characters = output.lines.reduce(0) { $0 + $1.count }
        var storedText: String?
        if !sensitive && !output.lines.isEmpty {
            storedText = String(output.lines.joined(separator: "\n").prefix(1500))
        }
        record.text = TextFeatures(
            lineCount: output.lines.count, characterCount: characters, meanConfidence: output.meanConfidence,
            text: storedText, signals: signals, barcodeCount: output.barcodeCount, qrCount: output.qrCount,
            extracted: sensitive ? nil : InfoExtractor.extract(lines: output.lines, signals: signals, category: reference?.category)
        )
        record.textVersion = PipelineVersion.text
        return record
    }

    func analyzeVideo(_ input: AssetRecord, allowNetwork: Bool) async -> AssetRecord {
        var record = input
        guard let asset = await resources.videoAsset(for: record.id, allowNetwork: allowNetwork) else {
            record.video = VideoFeatures(
                isLocallyAvailable: false, codec: nil, frameRate: nil, dataRate: nil, frameTimes: [], frameHashes: [],
                frameLuma: [], frameSharpness: [], frameEntropy: [], interFrameChange: 0, facesSeen: 0,
                semanticEmbedding: nil, semantic: nil
            )
            record.videoVersion = PipelineVersion.video
            return record
        }
        let (features, bytes) = await video.analyze(asset: asset, duration: record.metadata.duration, semantic: semantic)
        record.video = features
        record.videoVersion = PipelineVersion.video
        if let bytes { record.storage = StorageInfo(bytes: bytes, isExact: true) }
        if record.filename == nil || record.storage?.isExact != true {
            let info = await resources.resourceInfo(for: record.id)
            record.filename = info.filename ?? record.filename
            if let exact = info.bytes { record.storage = StorageInfo(bytes: exact, isExact: true) }
        }
        record.lastAnalyzedAt = Date()
        return record
    }

    /// High-resolution subject sharpness for best-shot tie-breaking.
    func analyzeDetail(_ input: AssetRecord, allowNetwork: Bool) async -> AssetRecord {
        var record = input
        record.detailVersion = PipelineVersion.detail
        guard var fingerprint = record.fingerprint,
              let image = await thumbnails.analysisImage(for: record.id, maxDimension: Self.detailDimension, allowNetwork: allowNetwork)
        else { return record }
        fingerprint.quality.detailSharpness = await measure(.detailSharpness) { ImageMetrics.detailSharpness(for: image) }
        record.fingerprint = fingerprint
        return record
    }

    func computeContentHash(_ input: AssetRecord) async -> AssetRecord {
        var record = input
        record.contentHash = await measure(.contentHash) { await resources.originalContentHash(for: record.id) } ?? "unavailable:" + record.id
        return record
    }
}
