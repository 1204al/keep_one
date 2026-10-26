import CoreGraphics
import Foundation
@testable import KeepOne

/// Synthetic, license-free fixtures. No real photos are needed for the logic tests.
enum Fixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    static func quality(sharpness: Float = 6.5, meanLuma: Float = 0.45, entropy: Float = 7, edge: Float = 0.12,
                        clipped: Float = 0.01, crushed: Float = 0.02, dynamicRange: Float = 0.7, motion: Float = 0.1) -> QualityMetrics {
        QualityMetrics(sharpness: sharpness, globalSharpness: sharpness - 0.5, detailSharpness: nil, motionBlur: motion,
                       meanLuma: meanLuma, lumaStdDev: 0.2, clippedHighlights: clipped, crushedShadows: crushed,
                       dynamicRange: dynamicRange, entropy: entropy, colorfulness: 0.3, edgeDensity: edge)
    }

    /// 16×16 micro-thumbnail; `variation` offsets every 7th pixel (mean difference ≈ variation / 7).
    static func micro(_ value: UInt8 = 120, variation: Int = 0) -> Data {
        Data((0..<256).map { UInt8(clamping: Int(value) + ($0 % 7 == 0 ? variation : 0)) })
    }

    static func record(
        _ id: String,
        date: Date? = days(30),
        hash: UInt64? = nil,
        micro: Data = micro(),
        quality: QualityMetrics = quality(),
        width: Int = 4032, height: Int = 3024,
        favorite: Bool = false, edited: Bool = false,
        burst: String? = nil,
        screenshot: Bool = false,
        faces: [Float] = [],
        aesthetics: Float? = 0.3,
        utility: Bool? = false,
        semantic: [SemanticGroup: Float] = [:],
        video: Bool = false, duration: Double = 0,
        contentHash: String? = nil
    ) -> AssetRecord {
        var subtypes: MediaSubtype = []
        if screenshot { subtypes.insert(.screenshot) }
        var r = AssetRecord(metadata: AssetMetadata(
            id: id, mediaType: video ? .video : .image, subtypes: subtypes, creationDate: date, modificationDate: date,
            pixelWidth: width, pixelHeight: height, duration: duration, isFavorite: favorite, hasAdjustments: edited,
            burstIdentifier: burst
        ))
        if !video {
            r.fingerprint = ImageFingerprint(pHash: hash ?? stableHash(id), micro: micro, meanColor: [120, 120, 120], analyzedWidth: 384,
                                             analyzedHeight: 288, quality: quality)
            r.fingerprintVersion = PipelineVersion.fingerprint
            r.vision = VisionFeatures(faceCount: faces.count, faceQualities: faces, largestFaceArea: faces.isEmpty ? 0 : 0.05,
                                      facesTouchingEdge: 0, humanCount: faces.count, aesthetics: aesthetics, isUtility: utility,
                                      smudge: nil, labels: [])
            r.visionVersion = PipelineVersion.vision
            if !semantic.isEmpty {
                var scores = Dictionary(uniqueKeysWithValues: semantic.map { ($0.key.rawValue, $0.value) })
                let rest = max(0, 1 - semantic.values.reduce(0, +))
                scores[SemanticGroup.neutral.rawValue, default: 0] += rest
                let top = semantic.max { $0.value < $1.value }!
                r.semantic = SemanticFeatures(modelID: "test", groupScores: scores, topConcept: top.key.rawValue, topConceptScore: top.value)
                r.semanticVersion = PipelineVersion.semantic
            }
        }
        r.contentHash = contentHash
        r.storage = StorageInfo(bytes: video ? 50_000_000 : 2_500_000, isExact: true)
        return r
    }

    /// FNV-1a, so unrelated fixtures never look like duplicates by accident.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    /// Unit vector with a deterministic direction (for feature prints / embeddings).
    static func vector(_ seed: Int, dimension: Int = 64, noise: Float = 0, noiseSeed: Int = 0) -> [Float] {
        var v = (0..<dimension).map { i in Float(sin(Double(seed * 31 + i) * 1.7)) }
        if noise > 0 {
            for i in v.indices { v[i] += noise * Float(sin(Double(noiseSeed * 97 + i) * 3.3)) }
        }
        return VectorMath.normalized(v)
    }

    /// Checkerboard / noise images for pixel-metric tests.
    static func image(width: Int = 384, height: Int = 288, cell: Int = 8, luma: (Int, Int) = (20, 230)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                ctx.setFillColor(gray: CGFloat(on ? luma.1 : luma.0) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    static func flat(width: Int = 384, height: Int = 288, luma: Int) -> CGImage {
        image(width: width, height: height, cell: 1000, luma: (luma, luma))
    }

    /// Box-blurred copy (repeated downscale/upscale) — removes high frequencies.
    static func blurred(_ image: CGImage, factor: Int = 12) -> CGImage {
        let small = ImageRasterizer.luma(from: image, width: image.width / factor, height: image.height / factor)!
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var pixels = small.pixels
        let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData)!
        let smallImage = CGImage(width: small.width, height: small.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                 bytesPerRow: small.width, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        ctx.interpolationQuality = .high
        ctx.draw(smallImage, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }
}
