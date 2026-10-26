import Foundation

enum QualityIssue: String, Codable, Sendable, CaseIterable {
    case nearlyBlack
    case overexposed
    case blankFrame
    case severeBlur
    case motionBlur
    case smudgedLens
    case accidental

    var reason: ReasonCode {
        switch self {
        case .nearlyBlack: .nearlyBlack
        case .overexposed: .overexposed
        case .blankFrame: .blankFrame
        case .severeBlur: .severeBlur
        case .motionBlur: .motionBlur
        case .smudgedLens: .smudgedLens
        case .accidental: .accidentalShot
        }
    }
}

struct QualityAssessment: Sendable, Equatable {
    var issues: [QualityIssue]
    /// 0…1, how clearly this is a failed capture.
    var severity: Float
    /// True when the capture is almost certainly unusable regardless of content (black frame, covered lens).
    var isUnusable: Bool

    var isFailed: Bool { !issues.isEmpty && severity >= 0.5 }
    var reasons: [Reason] { issues.map { Reason($0.reason) } }
}

/// Decides whether a photo is a failed capture. Thresholds are expressed for the ≈384 px analysis
/// thumbnail (see ImageMetrics) and were calibrated on synthetic blur/exposure sweeps of natural
/// images (docs/CALIBRATION.md). Low quality alone never implies deletion — see RecommendationEngine.
struct QualityThresholds: Sendable {
    /// log1p(Laplacian variance) of the sharpest tiles below which a frame is badly blurred.
    var severeBlurSharpness: Float = 3.0
    /// …and the edge density below which there is no crisp detail anywhere.
    var severeBlurEdgeDensity: Float = 0.015
    var motionBlurAnisotropy: Float = 0.55
    var motionBlurSharpness: Float = 4.2
    var blackMeanLuma: Float = 0.055
    var blackDynamicRange: Float = 0.22
    var overexposedMeanLuma: Float = 0.9
    var overexposedClipped: Float = 0.4
    var blankEntropy: Float = 3.4
    var blankEdgeDensity: Float = 0.004
    var smudge: Float = 0.92
    var accidentalSemantic: Float = 0.45
    var accidentalAesthetics: Float = -0.15

    static let standard = QualityThresholds()
}

enum QualityAssessor {
    static func assess(
        quality: QualityMetrics,
        vision: VisionFeatures?,
        semantic: SemanticFeatures?,
        thresholds: QualityThresholds = .standard
    ) -> QualityAssessment {
        var issues: [QualityIssue] = []
        var severity: Float = 0
        var unusable = false

        if quality.meanLuma < thresholds.blackMeanLuma && quality.dynamicRange < thresholds.blackDynamicRange {
            issues.append(.nearlyBlack)
            severity = max(severity, 0.9)
            unusable = quality.meanLuma < 0.03
        }
        if quality.meanLuma > thresholds.overexposedMeanLuma && quality.clippedHighlights > thresholds.overexposedClipped
            && quality.dynamicRange < 0.35 {
            issues.append(.overexposed)
            severity = max(severity, 0.75)
        }
        if quality.entropy < thresholds.blankEntropy && quality.edgeDensity < thresholds.blankEdgeDensity {
            issues.append(.blankFrame)
            severity = max(severity, 0.8)
            unusable = unusable || quality.entropy < 2.2
        }
        // Blur is meaningless for black, blown-out or blank frames — report the root cause only.
        let exposureFailure = !issues.isEmpty
        if exposureFailure {
            // skip blur checks
        } else if quality.sharpness < thresholds.severeBlurSharpness && quality.edgeDensity < thresholds.severeBlurEdgeDensity {
            issues.append(.severeBlur)
            let depth = (thresholds.severeBlurSharpness - quality.sharpness) / thresholds.severeBlurSharpness
            severity = max(severity, 0.6 + min(0.3, depth))
        } else if quality.motionBlur > thresholds.motionBlurAnisotropy && quality.sharpness < thresholds.motionBlurSharpness {
            issues.append(.motionBlur)
            severity = max(severity, 0.6)
        }
        // Smudge detection fires on any soft image, so it is only reported as the sole explanation.
        if issues.isEmpty, let smudge = vision?.smudge, smudge > thresholds.smudge {
            issues.append(.smudgedLens)
            severity = max(severity, 0.5)
        }
        if let semantic, semantic.score(.accidental) > thresholds.accidentalSemantic {
            let aesthetics = vision?.aesthetics ?? 0
            if aesthetics < thresholds.accidentalAesthetics {
                issues.append(.accidental)
                severity = max(severity, 0.7)
            }
        }
        // Vision's aesthetics model is a strong corroborating signal either way.
        if let aesthetics = vision?.aesthetics, !issues.isEmpty {
            if aesthetics < -0.4 { severity = min(1, severity + 0.1) }
            if aesthetics > 0.2 { severity = max(0, severity - 0.25) }
        }
        return QualityAssessment(issues: issues, severity: severity, isUnusable: unusable)
    }

    /// Normalised (0…1) sharpness for ranking within a group, preferring the high-res measure.
    static func rankingSharpness(_ quality: QualityMetrics) -> Double {
        if let detail = quality.detailSharpness { return Double(detail) }
        return Double(quality.sharpness)
    }
}
