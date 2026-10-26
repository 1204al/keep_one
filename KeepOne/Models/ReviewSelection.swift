import Foundation

enum GroupRemovalMode: String, Sendable {
    case keepBest
    case entireGroups
}

/// A group selection uses the members the user saw, even if scanning finds new groups meanwhile.
/// This only chooses items for the Trash Queue; deletion still requires the final review.
struct GroupRemovalPlan: Sendable, Equatable {
    let assetIDs: [String]

    init(clusters: [AssetCluster], mode: GroupRemovalMode, available: Set<String>, queued: Set<String>,
         protected: Set<String> = []) {
        let keepers = Set(clusters.flatMap { $0.keeperIDs + [$0.primaryKeeperID].compactMap { $0 } })
        var seen = Set<String>()
        assetIDs = clusters.flatMap { cluster in
            let candidates = mode == .entireGroups ? cluster.memberIDs : cluster.suggestedRemovals
            return candidates.filter { id in
                available.contains(id) && !queued.contains(id)
                    && (mode == .entireGroups || (!keepers.contains(id) && !protected.contains(id)))
                    && seen.insert(id).inserted
            }
        }
    }
}

/// Unchecking a photo changes automatic selection, without hiding or protecting the photo.
/// An explicit selection can always opt it back in.
struct ReviewSelectionMemory: Codable, Sendable, Equatable {
    private(set) var excludedIDs: Set<String> = []

    mutating func rememberChange(from before: Set<String>, to after: Set<String>) {
        excludedIDs.formUnion(before.subtracting(after))
        excludedIDs.subtract(after.subtracting(before))
    }

    func automaticIDs(from candidates: [String], queued: Set<String>, limit: Int) -> [String] {
        Array(candidates.lazy.filter { !excludedIDs.contains($0) && !queued.contains($0) }.prefix(max(0, limit)))
    }

    func automaticIDs(in category: CleanupCategory, from recommendations: [Recommendation], queued: Set<String>, limit: Int) -> [String] {
        let candidates = recommendations.filter { category == .priceTags || $0.preselect }.map(\.id)
        return automaticIDs(from: candidates, queued: queued, limit: limit)
    }
}

/// A Photos-style drag selects a continuous range. Reversing the drag restores the original
/// selection outside that range; crossing a photo repeatedly never toggles it back and forth.
struct ReviewSelectionDrag {
    let ids: [String]
    let original: Set<String>
    let anchor: Int
    let selects: Bool
    let limit: Int

    init?(ids: [String], selection: Set<String>, startingAt id: String, limit: Int) {
        guard let anchor = ids.firstIndex(of: id) else { return nil }
        self.ids = ids
        self.original = selection
        self.anchor = anchor
        self.selects = !selection.contains(id)
        self.limit = limit
    }

    func selection(endingAt id: String) -> Set<String> {
        guard let end = ids.firstIndex(of: id) else { return original }
        let range = ids[min(anchor, end)...max(anchor, end)]
        if !selects { return original.subtracting(range) }
        var result = original
        for index in stride(from: anchor, through: end, by: end >= anchor ? 1 : -1) {
            if result.count >= limit { break }
            result.insert(ids[index])
        }
        return result
    }
}
