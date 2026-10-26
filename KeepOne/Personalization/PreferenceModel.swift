import Foundation

/// Fixed-length feature vector describing an item at decision time.
enum PreferenceFeatures {
    static let semanticGroups: [SemanticGroup] = [
        .receipt, .parking, .productLabel, .priceTag, .ticketQR, .package, .menuSign, .screenPhoto,
        .document, .memory, .food, .meme, .accidental, .screenshotLike,
    ]
    static let categories = CleanupCategory.allCases
    static let dimension = 1 + categories.count + 16 + semanticGroups.count + 2

    static func vector(record: AssetRecord, category: CleanupCategory?, tier: RecommendationTier?,
                       clusterSize: Int, now: Date) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        var i = 0
        func push(_ x: Float) { v[i] = x; i += 1 }
        push(1)
        for c in categories { push(c == category ? 1 : 0) }
        let m = record.metadata
        push(Float(tier?.rawValue ?? 0) / 3)
        push(Float(log1p(m.ageInDays(now: now)) / 7))
        push(Float(min(record.vision?.faceCount ?? 0, 4)) / 4)
        push(record.hasPeople ? 1 : 0)
        push(record.vision?.meanFaceQuality ?? 0.5)
        push(((record.vision?.aesthetics ?? 0) + 1) / 2)
        push((record.fingerprint?.quality.sharpness ?? 5) / 10)
        push(record.fingerprint?.quality.exposureScore ?? 0.5)
        push(m.isVideo ? 1 : 0)
        push(Float(log1p(m.duration) / 6))
        push(Float(log1p(Double(record.storageEstimate.bytes) / 1_000_000) / 8))
        push(m.isScreenshot || m.isScreenRecording ? 1 : 0)
        push(Float(log1p(Double(clusterSize)) / 3))
        push(m.isFavorite ? 1 : 0)
        push(m.hasAdjustments ? 1 : 0)
        push(record.vision?.isUtility == true ? 1 : 0)
        for g in semanticGroups { push(record.semantic?.score(g) ?? record.video?.semantic?.score(g) ?? 0) }
        push((record.text?.lineCount ?? 0) > 0 ? 1 : 0)
        push(Float(min(record.text?.qrCount ?? 0, 1)))
        return v
    }
}

enum CategoryTrust: String, Sendable {
    case normal, reduced, boosted
}

struct CategoryStat: Codable, Sendable, Equatable {
    var accepted = 0
    var rejected = 0
    var total: Int { accepted + rejected }
    var acceptance: Double { total == 0 ? 0.5 : Double(accepted) / Double(total) }
}

/// Small on-device preference model: online logistic regression + k-nearest-neighbour memory over
/// decision features, blended. It only *re-prioritises* and *de-escalates*; it never auto-deletes
/// and never promotes an item to preselection on its own.
struct PreferenceModel: Sendable, Equatable {
    static let minimumExamples = 12

    var weights = [Double](repeating: 0, count: PreferenceFeatures.dimension)
    var examples: [(features: [Float], label: Double)] = []
    var categoryStats: [CleanupCategory: CategoryStat] = [:]
    var decisionCount = 0

    static func == (lhs: PreferenceModel, rhs: PreferenceModel) -> Bool {
        lhs.weights == rhs.weights && lhs.decisionCount == rhs.decisionCount && lhs.categoryStats == rhs.categoryStats
    }

    var isActive: Bool { examples.count >= Self.minimumExamples }

    /// Rebuilds the model from the decision log (used at launch, after reset and after import).
    static func train(from decisions: [UserDecision], epochs: Int = 8) -> PreferenceModel {
        var model = PreferenceModel()
        model.decisionCount = decisions.count
        // Last label-bearing decision per asset wins (e.g. "trash" then "restore" ⇒ keep).
        var latest: [String: UserDecision] = [:]
        for d in decisions {
            if d.kind == .undo { latest[d.assetID] = nil }
            else if d.kind.trainingLabel != nil { latest[d.assetID] = d }
        }
        for d in latest.values.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let category = d.category {
                var stat = model.categoryStats[category] ?? CategoryStat()
                if (d.kind.trainingLabel ?? 0) >= 0.5 { stat.accepted += 1 } else { stat.rejected += 1 }
                model.categoryStats[category] = stat
            }
            if d.features.count == PreferenceFeatures.dimension, let label = d.kind.trainingLabel {
                model.examples.append((d.features, label))
            }
        }
        // Same bound as online learning: the kNN vote scans every example for every suggestion.
        if model.examples.count > 4_000 { model.examples.removeFirst(model.examples.count - 4_000) }
        for d in decisions where d.kind == .neverSuggestType {
            if let category = d.category {
                model.categoryStats[category, default: CategoryStat()].rejected += 3
            }
        }
        for _ in 0..<epochs {
            for example in model.examples { model.sgdStep(example.features, label: example.label, learningRate: 0.08) }
        }
        return model
    }

    mutating func sgdStep(_ x: [Float], label: Double, learningRate: Double, l2: Double = 1e-3) {
        guard x.count == weights.count else { return }
        let p = sigmoid(zip(weights, x).map { $0 * Double($1) }.reduce(0, +))
        let gradient = p - label
        for i in weights.indices {
            weights[i] -= learningRate * (gradient * Double(x[i]) + l2 * weights[i])
        }
    }

    /// Online update for a single new decision.
    mutating func observe(_ decision: UserDecision) {
        decisionCount += 1
        if decision.kind == .undo {
            // Approximate online: the next launch replays the log and drops the undone choice exactly.
            if let c = decision.category, let stat = categoryStats[c], stat.accepted > 0 { categoryStats[c]?.accepted -= 1 }
            return
        }
        guard let label = decision.kind.trainingLabel else {
            if decision.kind == .neverSuggestType, let c = decision.category {
                categoryStats[c, default: CategoryStat()].rejected += 3
            }
            return
        }
        if let category = decision.category {
            var stat = categoryStats[category] ?? CategoryStat()
            if label >= 0.5 { stat.accepted += 1 } else { stat.rejected += 1 }
            categoryStats[category] = stat
        }
        guard decision.features.count == PreferenceFeatures.dimension else { return }
        examples.append((decision.features, label))
        if examples.count > 4_000 { examples.removeFirst(examples.count - 4_000) }
        sgdStep(decision.features, label: label, learningRate: 0.05)
    }

    /// P(user removes items like this). nil until enough decisions exist.
    func probability(_ x: [Float]) -> Double? {
        guard isActive, x.count == weights.count else { return nil }
        let logistic = sigmoid(zip(weights, x).map { $0 * Double($1) }.reduce(0, +))
        guard let knn = nearestNeighbourVote(x) else { return logistic }
        return 0.65 * logistic + 0.35 * knn
    }

    /// Logistic part only — cheap enough to evaluate for every member of every group.
    func logisticProbability(_ x: [Float]) -> Double? {
        guard isActive, x.count == weights.count else { return nil }
        return sigmoid(zip(weights, x).map { $0 * Double($1) }.reduce(0, +))
    }

    func nearestNeighbourVote(_ x: [Float], k: Int = 7) -> Double? {
        guard examples.count >= k else { return nil }
        var nearest: [(Float, Double)] = []
        for e in examples {
            let d = VectorMath.euclidean(e.features, x)
            if nearest.count < k {
                nearest.append((d, e.label))
                nearest.sort { $0.0 < $1.0 }
            } else if d < nearest[k - 1].0 {
                nearest[k - 1] = (d, e.label)
                nearest.sort { $0.0 < $1.0 }
            }
        }
        let weighted = nearest.map { (1 / Double($0.0 + 0.05), $0.1) }
        let total = weighted.map(\.0).reduce(0, +)
        return weighted.map { $0.0 * $0.1 }.reduce(0, +) / total
    }

    func trust(for category: CleanupCategory) -> CategoryTrust {
        guard let stat = categoryStats[category] else { return .normal }
        if stat.total >= 8 && stat.acceptance < 0.3 { return .reduced }
        if stat.total >= 15 && stat.acceptance >= 0.85 { return .boosted }
        return .normal
    }

    private func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-max(-30, min(30, z)))) }
}

/// Portable export so a reinstall of a development build doesn't lose personalisation.
struct PreferencesExport: Codable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var exportedAt: Date
    var settings: AppSettings
    var decisions: [ExportedDecision]
    var marks: [String: Int]

    struct ExportedDecision: Codable, Sendable {
        var assetID: String
        var kind: Int
        var category: String?
        var context: String
        var timestamp: Date
        var features: [Float]
    }
}
