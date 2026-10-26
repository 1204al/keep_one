import Foundation

/// Per-member normalised features for best-shot ranking. Exposed for calibration and tests.
struct BestShotFeatures: Sendable, Equatable {
    var sharpness: Double
    var exposure: Double
    var faceQuality: Double
    var aesthetics: Double
    var framing: Double
    var resolution: Double
    var personal: Double
    var faceCount: Double

    var asArray: [Double] { [sharpness, exposure, faceQuality, aesthetics, framing, resolution, personal, faceCount] }
}

struct RankedMember: Sendable {
    var id: String
    var score: Double
    var features: BestShotFeatures
    var raw: RawShotFeatures
}

struct RawShotFeatures: Sendable, Equatable {
    var sharpness: Double
    var exposure: Double
    var faceQuality: Double?
    var aesthetics: Double?
    var framing: Double
    var pixelCount: Double
    var personalKeep: Double
    var faceCount: Double
}

/// Ranks the members of a similar-photo group and explains the choice in human terms.
/// Favourites, user-chosen keepers and protected items always win; aesthetics never outweighs them.
struct BestShotRanker {
    var weights: BestShotWeights
    /// Optional learned P(keep) per asset from the personal model.
    var personalKeep: [String: Double] = [:]

    struct Outcome: Sendable {
        var ordered: [RankedMember]
        var keeperIDs: [String]
        var keeperReasons: [Reason]
        var memberReasons: [String: [Reason]]
    }

    func raw(_ r: AssetRecord) -> RawShotFeatures {
        let q = r.fingerprint?.quality
        let v = r.vision
        let faceQuality: Double? = {
            guard let mean = v?.meanFaceQuality, let minQ = v?.minFaceQuality else { return nil }
            return Double(0.7 * mean + 0.3 * minQ)
        }()
        let framing: Double = {
            guard let v, v.faceCount > 0 else { return 1 }
            return 1 - Double(v.facesTouchingEdge) / Double(v.faceCount)
        }()
        return RawShotFeatures(
            sharpness: q.map(QualityAssessor.rankingSharpness) ?? 0,
            exposure: Double(q?.exposureScore ?? 0.5),
            faceQuality: faceQuality,
            aesthetics: v?.aesthetics.map(Double.init),
            framing: framing,
            pixelCount: Double(max(1, r.metadata.pixelCount)),
            personalKeep: personalKeep[r.id] ?? 0.5,
            faceCount: Double(v?.faceCount ?? 0)
        )
    }

    func rank(_ members: [AssetRecord], forcedKeepers: Set<String>, protectEdited: Bool) -> Outcome {
        let raws = members.map(raw)

        func normalize(_ values: [Double?], minSpread: Double) -> [Double] {
            let present = values.compactMap { $0 }
            guard let lo = present.min(), let hi = present.max(), hi - lo >= minSpread else {
                return values.map { _ in 0.5 }
            }
            return values.map { v in v.map { ($0 - lo) / (hi - lo) } ?? 0.5 }
        }
        let sharp = normalize(raws.map { $0.sharpness }, minSpread: 0.15)
        let expo = normalize(raws.map { $0.exposure }, minSpread: 0.04)
        let face = normalize(raws.map { $0.faceQuality }, minSpread: 0.03)
        let aest = normalize(raws.map { $0.aesthetics }, minSpread: 0.05)
        let frame = normalize(raws.map { $0.framing }, minSpread: 0.01)
        let res = normalize(raws.map { log($0.pixelCount) }, minSpread: 0.05)
        let pers = normalize(raws.map { $0.personalKeep }, minSpread: 0.05)
        let faces = normalize(raws.map { $0.faceCount }, minSpread: 0.5)

        let w = weights.normalized()
        var ranked: [RankedMember] = []
        for (i, r) in members.enumerated() {
            let f = BestShotFeatures(sharpness: sharp[i], exposure: expo[i], faceQuality: face[i], aesthetics: aest[i],
                                     framing: frame[i], resolution: res[i], personal: pers[i], faceCount: faces[i])
            var score = zip(f.asArray, w.asArray).map { $0 * $1 }.reduce(0, +)
            // Hard signals dominate the soft score.
            if forcedKeepers.contains(r.id) { score += 20 }
            if r.metadata.isFavorite { score += 10 }
            if r.metadata.hasAdjustments { score += protectEdited ? 5 : 0.3 }
            ranked.append(RankedMember(id: r.id, score: score, features: f, raw: raws[i]))
        }
        ranked.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }

        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var keepers: [String] = [ranked[0].id]
        for m in ranked.dropFirst() {
            guard let r = byID[m.id] else { continue }
            if forcedKeepers.contains(m.id) || r.metadata.isFavorite || (protectEdited && r.metadata.hasAdjustments) {
                keepers.append(m.id)
            }
        }
        // Large groups with two equally strong shots: keep both rather than guess.
        if members.count >= 6, ranked.count >= 2, keepers.count == 1, ranked[0].score - ranked[1].score < 0.03 {
            keepers.append(ranked[1].id)
        }

        let keeperRaw = ranked[0].raw
        let keeperRecord = byID[ranked[0].id]!
        var keeperReasons: [Reason] = []
        if forcedKeepers.contains(keeperRecord.id) { keeperReasons.append(Reason(.userChosen)) }
        if keeperRecord.metadata.isFavorite { keeperReasons.append(Reason(.favorite)) }
        if keeperRecord.metadata.hasAdjustments { keeperReasons.append(Reason(.edited)) }
        let others = ranked.dropFirst().map(\.raw)
        if let maxOther = others.map(\.sharpness).max(), keeperRaw.sharpness - maxOther > 0.15 {
            keeperReasons.append(Reason(.sharpest))
        }
        if let kf = keeperRaw.faceQuality, let maxOther = others.compactMap(\.faceQuality).max(), kf - maxOther > 0.03 {
            keeperReasons.append(Reason(.bestFaces))
        }
        if let maxOther = others.map(\.faceCount).max(), keeperRaw.faceCount > maxOther {
            keeperReasons.append(Reason(.eyesOpen, "\(Int(keeperRaw.faceCount)) faces visible"))
        }
        if let maxOther = others.map(\.exposure).max(), keeperRaw.exposure - maxOther > 0.04 {
            keeperReasons.append(Reason(.bestExposure))
        }
        if let ka = keeperRaw.aesthetics, let maxOther = others.compactMap(\.aesthetics).max(), ka - maxOther > 0.05 {
            keeperReasons.append(Reason(.bestAesthetics))
        }
        if keeperRaw.framing == 1, others.contains(where: { $0.framing < 1 }) { keeperReasons.append(Reason(.wellFramed)) }
        if let maxOther = others.map(\.pixelCount).max(), keeperRaw.pixelCount > maxOther * 1.1 {
            keeperReasons.append(Reason(.highestResolution))
        }
        if keeperReasons.isEmpty {
            // Explain via the feature contributing most over the runner-up.
            let diffs = zip(ranked[0].features.asArray, ranked[safe: 1]?.features.asArray ?? []).map { $0 - $1 }
            let contributions = zip(diffs, w.asArray).map { $0 * $1 }
            let codes: [ReasonCode] = [.sharpest, .bestExposure, .bestFaces, .bestAesthetics, .wellFramed, .highestResolution, .personalized, .eyesOpen]
            if let best = contributions.indices.max(by: { contributions[$0] < contributions[$1] }), contributions[best] > 0 {
                keeperReasons.append(Reason(codes[best]))
            } else {
                keeperReasons.append(Reason(.bestAesthetics))
            }
        }
        keeperReasons.append(Reason(.sameScene, "\(members.count - 1) other similar \(members.count == 2 ? "shot" : "shots")"))

        var memberReasons: [String: [Reason]] = [:]
        for m in ranked where !keepers.contains(m.id) {
            var reasons: [Reason] = []
            if let r = byID[m.id], r.metadata.burstIdentifier != nil, r.metadata.burstIdentifier == keeperRecord.metadata.burstIdentifier {
                reasons.append(Reason(.burstFrame))
            }
            if keeperRaw.sharpness - m.raw.sharpness > 0.35 { reasons.append(Reason(.blurrierThanKeeper)) }
            if let kf = keeperRaw.faceQuality, let mf = m.raw.faceQuality, kf - mf > 0.06 { reasons.append(Reason(.worseFaces)) }
            if keeperRaw.exposure - m.raw.exposure > 0.1 { reasons.append(Reason(.worseExposure)) }
            if let ka = keeperRaw.aesthetics, let ma = m.raw.aesthetics, ka - ma > 0.12 { reasons.append(Reason(.lowerAesthetics)) }
            if m.raw.pixelCount < keeperRaw.pixelCount * 0.8 { reasons.append(Reason(.lowerResolution)) }
            if reasons.isEmpty { reasons.append(Reason(.similarShot)) }
            memberReasons[m.id] = reasons
        }
        return Outcome(ordered: ranked, keeperIDs: keepers, keeperReasons: keeperReasons, memberReasons: memberReasons)
    }
}

/// Online calibration of best-shot weights from "Change best shot" decisions (pairwise perceptron).
enum BestShotCalibrator {
    static func update(weights: BestShotWeights, chosen: BestShotFeatures, rejected: BestShotFeatures,
                       learningRate: Double = 0.05) -> BestShotWeights {
        let w = weights.asArray
        let diff = zip(chosen.asArray, rejected.asArray).map { $0 - $1 }
        let margin = zip(w, diff).map { $0 * $1 }.reduce(0, +)
        guard margin <= 0.02 else { return weights }  // already ranks the user's choice higher
        let updated = zip(w, diff).map { $0 + learningRate * $1 }
        return BestShotWeights(array: updated).normalized()
    }
}
