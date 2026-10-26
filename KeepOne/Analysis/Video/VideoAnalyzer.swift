import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

protocol VideoAnalyzing: Sendable {
    func analyze(asset: AVAsset, duration: Double, semantic: SemanticEngine?) async -> (VideoFeatures, exactBytes: Int64?)
}

/// Sparse temporal sampling with AVFoundation — never decodes the whole stream.
struct AppleVideoAnalyzer: VideoAnalyzing {
    static func sampleFractions(duration: Double) -> [Double] {
        switch duration {
        case ..<2: [0.15, 0.5, 0.85]
        case ..<10: [0.02, 0.25, 0.5, 0.75, 0.95]
        default: [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98]
        }
    }

    func analyze(asset: AVAsset, duration: Double, semantic: SemanticEngine?) async -> (VideoFeatures, exactBytes: Int64?) {
        var features = VideoFeatures(
            isLocallyAvailable: true, codec: nil, frameRate: nil, dataRate: nil, frameTimes: [], frameHashes: [],
            frameLuma: [], frameSharpness: [], frameEntropy: [], interFrameChange: 0, facesSeen: 0,
            semanticEmbedding: nil, semantic: nil
        )
        var exactBytes: Int64?
        if let urlAsset = asset as? AVURLAsset,
           let size = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            exactBytes = Int64(size)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let (rate, dataRate, formats) = try? await track.load(.nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
                features.frameRate = rate
                features.dataRate = dataRate
                if let format = formats.first {
                    features.codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(format))
                }
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        let tolerance = CMTime(seconds: duration > 20 ? 1.0 : 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var embeddings: [[Float]] = []
        let fractions = Self.sampleFractions(duration: duration)
        let start = ContinuousClock.now
        for (index, fraction) in fractions.enumerated() {
            if Task.isCancelled { break }
            let time = CMTime(seconds: max(0, min(duration - 0.05, duration * fraction)), preferredTimescale: 600)
            guard let (image, actual) = try? await generator.image(at: time) else { continue }
            guard let fp = ImageMetrics.fingerprint(for: image) else { continue }
            features.frameTimes.append(actual.seconds)
            features.frameHashes.append(fp.pHash)
            features.frameLuma.append(fp.quality.meanLuma)
            features.frameSharpness.append(fp.quality.sharpness)
            features.frameEntropy.append(fp.quality.entropy)
            // Faces and semantics on a few representative frames only.
            let representative = index == 0 || index == fractions.count / 2 || index == fractions.count - 1
            if representative {
                features.facesSeen = max(features.facesSeen, await AppleVisionAnalyzer.faceCount(image))
                if let semantic, let embedding = try? await semantic.encoder.embedding(for: image) {
                    embeddings.append(embedding)
                }
            }
        }
        let elapsed = ContinuousClock.now - start
        await PerformanceMonitor.shared.record(.videoFrames, ms: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)

        if features.frameHashes.count > 1 {
            let changes = zip(features.frameHashes, features.frameHashes.dropFirst()).map { PerceptualHash.distance($0, $1) }
            features.interFrameChange = Float(changes.reduce(0, +)) / Float(changes.count)
        }
        if let semantic, let mean = VectorMath.mean(embeddings) {
            let normalized = VectorMath.normalized(mean)
            features.semanticEmbedding = VectorMath.encodeFP16(normalized)
            features.semantic = semantic.bank.features(for: normalized)
        }
        return (features, exactBytes)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        let raw = String(bytes: bytes, encoding: .ascii) ?? "?"
        switch raw {
        case "hvc1", "hev1": return "HEVC"
        case "avc1": return "H.264"
        case "ap4h", "apcn", "apch", "apcs", "apco", "ap4x": return "ProRes"
        default: return raw.trimmingCharacters(in: .whitespaces)
        }
    }
}
