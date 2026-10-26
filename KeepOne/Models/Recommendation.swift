import Foundation

enum ClusterKind: String, Codable, Sendable {
    case exactDuplicate
    case similar
    case burst
    case duplicateVideo
    case similarVideo

    var category: CleanupCategory {
        switch self {
        case .exactDuplicate: .exactDuplicates
        case .similar, .burst: .similarPhotos
        case .duplicateVideo, .similarVideo: .duplicateVideos
        }
    }
}

/// A group of assets where some are redundant. Keepers are never recommended for deletion
/// by the group itself.
struct AssetCluster: Sendable, Identifiable, Equatable {
    var id: String
    var kind: ClusterKind
    /// Members ordered by rank — the recommended keeper first.
    var memberIDs: [String]
    var keeperIDs: [String]
    var tier: RecommendationTier
    /// Cohesion 0…1 (mean pairwise similarity).
    var similarity: Float
    /// Why the first keeper was chosen.
    var keeperReasons: [Reason]
    /// Why each non-keeper is worse.
    var memberReasons: [String: [Reason]]
    /// Best-shot score per member (relative; used for display ordering only).
    var scores: [String: Double]
    /// Confidence for each removable member.
    var memberTiers: [String: RecommendationTier]
    /// Raw ranking features per member (for "Why this one?" and calibration).
    var memberFeatures: [String: BestShotFeatures] = [:]

    var removableIDs: [String] { memberIDs.filter { !keeperIDs.contains($0) } }
    /// Members KeepOne actually suggests removing (protected members drop out).
    var suggestedRemovals: [String] { memberIDs.filter { memberTiers[$0] != nil } }
    var primaryKeeperID: String? { keeperIDs.first ?? memberIDs.first }
}

/// One recommendation for one asset. Recommendation ≠ selection ≠ deletion.
struct Recommendation: Sendable, Identifiable, Equatable {
    var id: String
    var category: CleanupCategory
    var tier: RecommendationTier
    var reasons: [Reason]
    var clusterID: String?
    var bytes: Int64
    var bytesExact: Bool
    /// Higher = review earlier (value per second of attention).
    var priority: Double
    /// 0…1 learned probability that this user removes items like this (nil before enough decisions).
    var personalScore: Double?
    /// Whether a review screen may pre-tick this item. Never implies queueing.
    var preselect: Bool
    var creationDate: Date?
}

struct CategorySummary: Sendable, Identifiable, Equatable {
    var category: CleanupCategory
    var count: Int
    var groupCount: Int
    var bytes: Int64
    var bytesExact: Bool
    var previewIDs: [String]
    var safeCount: Int
    var likelyCount: Int
    var reviewCount: Int
    var oldest: Date?
    var newest: Date?

    var id: String { category.rawValue }

    var dominantTier: RecommendationTier {
        if safeCount >= max(likelyCount, reviewCount), safeCount > 0 { return .safe }
        if likelyCount >= reviewCount, likelyCount > 0 { return .likely }
        return .review
    }
}

struct LibraryStats: Sendable, Equatable {
    var totalCount = 0
    var photoCount = 0
    var videoCount = 0
    var screenshotCount = 0
    var livePhotoCount = 0
    var totalBytes: Int64 = 0
    var bytesExact = false
    var analyzedCount = 0
}

/// Everything the UI needs to render recommendations. Computed off the main thread.
struct RecommendationSnapshot: Sendable {
    var generatedAt: Date
    var recommendations: [String: Recommendation]
    var clusters: [String: AssetCluster]
    /// Recommendation IDs per category, in review order.
    var byCategory: [CleanupCategory: [String]]
    /// Cluster IDs per grouped category, in review order.
    var clustersByCategory: [CleanupCategory: [String]]
    var summaries: [CleanupCategory: CategorySummary]
    /// Suspected important / sensitive documents and possible evidence (never suggested).
    var protectedImportant: [String]
    /// Live Photos eligible for the explicit still-conversion mode.
    var livePhotoCandidates: [String]
    var library: LibraryStats

    static let empty = RecommendationSnapshot(
        generatedAt: .distantPast, recommendations: [:], clusters: [:], byCategory: [:],
        clustersByCategory: [:], summaries: [:], protectedImportant: [], livePhotoCandidates: [],
        library: LibraryStats()
    )

    var totalPotentialBytes: Int64 {
        summaries.values.reduce(0) { $0 + $1.bytes }
    }

    var totalCount: Int { recommendations.count }

    func summary(_ category: CleanupCategory) -> CategorySummary? { summaries[category] }

    func recommendations(in category: CleanupCategory) -> [Recommendation] {
        (byCategory[category] ?? []).compactMap { recommendations[$0] }
    }

    func clusters(in category: CleanupCategory) -> [AssetCluster] {
        (clustersByCategory[category] ?? []).compactMap { clusters[$0] }
    }
}
