import Foundation

/// One unit of attention in a review session.
enum ReviewUnit: Hashable, Sendable, Identifiable {
    case group(String)
    case single(String)

    var id: String {
        switch self {
        case .group(let id): "g:" + id
        case .single(let id): "s:" + id
        }
    }
}

/// Item-by-item sessions. The guided cleanup itself works in sets (`CleanupSetBuilder`).
enum SessionMode: Hashable, Sendable, Identifiable {
    case allSafe
    case category(CleanupCategory)
    case swipe

    var id: String {
        switch self {
        case .allSafe: "safe"
        case .category(let c): "cat." + c.rawValue
        case .swipe: "swipe"
        }
    }

    var title: String {
        switch self {
        case .allSafe: "All safe items"
        case .category(let c): c.title
        case .swipe: "Quick swipe"
        }
    }
}

/// Builds manageable review sessions — never "20,438 similar images · DELETE ALL".
enum ReviewQueueBuilder {
    static func build(snapshot: RecommendationSnapshot, mode: SessionMode, excluding reviewed: Set<String> = []) -> [ReviewUnit] {
        func groupUnits(_ category: CleanupCategory, minTier: RecommendationTier = .review) -> [ReviewUnit] {
            snapshot.clusters(in: category)
                .filter { $0.tier >= minTier && !reviewed.contains("g:" + $0.id) }
                .map { ReviewUnit.group($0.id) }
        }
        func singleUnits(_ category: CleanupCategory, minTier: RecommendationTier = .review) -> [ReviewUnit] {
            snapshot.recommendations(in: category)
                .filter { $0.clusterID == nil && $0.tier >= minTier && !reviewed.contains("s:" + $0.id) }
                .map { ReviewUnit.single($0.id) }
        }

        switch mode {
        case .category(let category):
            return category.isGrouped ? groupUnits(category) : singleUnits(category)

        case .allSafe:
            return CleanupCategory.allCases.flatMap { c in
                c.isGrouped ? groupUnits(c, minTier: .safe) : singleUnits(c, minTier: .safe)
            }

        case .swipe:
            // Ambiguous single items: the swipe deck is for "Needs review", not for bulk.
            let singles = snapshot.recommendations.values
                .filter { $0.clusterID == nil && $0.tier == .review && !reviewed.contains("s:" + $0.id) && $0.category != .largeVideos }
                .sorted { a, b in
                    let ua = abs((a.personalScore ?? 0.5) - 0.5), ub = abs((b.personalScore ?? 0.5) - 0.5)
                    return a.priority + ua * 4 > b.priority + ub * 4
                }
            return Array(singles.prefix(50)).map { .single($0.id) }
        }
    }
}
