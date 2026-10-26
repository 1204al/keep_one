import CoreGraphics
import Foundation
import Vision

struct VisionOutput: Sendable {
    var features: VisionFeatures
    var featurePrint: [Float]?
}

protocol VisionAnalyzing: Sendable {
    func analyze(_ image: CGImage) async -> VisionOutput
}

/// Apple Vision: feature prints, faces + capture quality (no identity), humans, aesthetics,
/// scene labels and lens smudge. Each request is isolated so one unsupported request (e.g. on
/// the Simulator) never loses the others.
struct AppleVisionAnalyzer: VisionAnalyzing {
    func analyze(_ image: CGImage) async -> VisionOutput {
        let handler = ImageRequestHandler(image)

        let featurePrint: [Float]? = await measure(.featurePrint) {
            guard let obs = try? await handler.perform(GenerateImageFeaturePrintRequest()) else { return nil }
            return Self.floats(from: obs)
        }

        let start = ContinuousClock.now
        var faces = (try? await handler.perform(DetectFaceRectanglesRequest())) ?? []
        faces = faces.filter { $0.confidence >= 0.5 && $0.boundingBox.width * $0.boundingBox.height >= 0.0015 }
        var qualities: [Float] = []
        if !faces.isEmpty {
            var request = DetectFaceCaptureQualityRequest()
            request.inputFaceObservations = faces
            if let scored = try? await handler.perform(request) {
                qualities = scored.compactMap { $0.captureQuality?.score }
            }
        }
        var humanRequest = DetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let humans = ((try? await handler.perform(humanRequest)) ?? []).filter { $0.confidence >= 0.6 }
        let aesthetics = try? await handler.perform(CalculateImageAestheticsScoresRequest())
        let labels = ((try? await handler.perform(ClassifyImageRequest())) ?? [])
            .filter { $0.confidence >= 0.1 && VisionLabel.interesting.contains($0.identifier) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(12)
            .map { LabelScore(id: $0.identifier, confidence: $0.confidence) }
        let textBoxes = (try? await handler.perform(DetectTextRectanglesRequest())) ?? []
        let textArea = textBoxes.map { Float($0.boundingBox.width * $0.boundingBox.height) }.reduce(0, +)
        var smudge: Float?
        if #available(iOS 26.0, *) {
            smudge = (try? await handler.perform(DetectLensSmudgeRequest()))?.confidence
        }
        let elapsed = ContinuousClock.now - start
        await PerformanceMonitor.shared.record(.vision, ms: Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)

        let largestFace = faces.map { Float($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        let touching = faces.filter { f in
            let b = f.boundingBox
            return b.origin.x < 0.01 || b.origin.y < 0.01 || b.origin.x + b.width > 0.99 || b.origin.y + b.height > 0.99
        }.count

        let features = VisionFeatures(
            faceCount: faces.count, faceQualities: qualities, largestFaceArea: largestFace,
            facesTouchingEdge: touching, humanCount: humans.count,
            aesthetics: aesthetics?.overallScore, isUtility: aesthetics?.isUtility, smudge: smudge,
            labels: Array(labels), textRegionCount: textBoxes.count, textCoverage: min(1, textArea)
        )
        return VisionOutput(features: features, featurePrint: featurePrint)
    }

    /// Fast face count only (video frames).
    static func faceCount(_ image: CGImage) async -> Int {
        let faces = (try? await ImageRequestHandler(image).perform(DetectFaceRectanglesRequest())) ?? []
        return faces.filter { $0.confidence >= 0.6 }.count
    }

    static func floats(from observation: FeaturePrintObservation) -> [Float] {
        let data = observation.data
        switch observation.elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default:
            return []
        }
    }
}
