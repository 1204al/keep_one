import Foundation

struct EngineInput: Sendable {
    var records: [AssetRecord]
    var grouping: GroupingResult
    var settings: AppSettings
    var marks: [String: AssetMark]
    /// Items already in the Trash Queue are excluded from to-do lists (never re-queued, never deleted here).
    var queued: Set<String>
    var preference: PreferenceModel
    var now: Date
}

/// Produces recommendations. It has no access to the Trash Queue mutation API or to PhotoKit:
/// recommendation ≠ selection ≠ deletion is enforced by construction.
enum RecommendationEngine {
    static func compute(_ input: EngineInput) -> RecommendationSnapshot {
        let now = input.now
        let settings = input.settings
        let byID = Dictionary(input.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var recommendations: [String: Recommendation] = [:]
        var clusters: [String: AssetCluster] = [:]
        var protectedImportant: [String] = []

        func protections(_ r: AssetRecord) -> Set<ProtectionReason> {
            ProtectionPolicy.protections(for: r, settings: settings, mark: input.marks[r.id], now: now)
        }

        // 1. Redundancy groups.
        for cluster in input.grouping.clusters {
            var live = cluster
            var removableCount = 0
            for id in cluster.removableIDs {
                guard let r = byID[id], let tier = cluster.memberTiers[id] else { continue }
                let isExactCopy = cluster.kind == .exactDuplicate || cluster.kind == .duplicateVideo
                if ProtectionPolicy.blocks(protections(r), forExactDuplicate: isExactCopy) {
                    live.memberTiers[id] = nil
                    continue
                }
                if input.queued.contains(id) { continue }
                removableCount += 1
                let size = r.storageEstimate
                var reasons = cluster.memberReasons[id] ?? []
                if cluster.kind == .similar || cluster.kind == .burst {
                    reasons.append(Reason(.similarShot, "\(cluster.memberIDs.count) shots"))
                }
                recommendations[id] = Recommendation(
                    id: id, category: cluster.kind.category, tier: tier, reasons: dedupe(reasons), clusterID: cluster.id,
                    bytes: size.bytes, bytesExact: size.isExact, priority: 0, personalScore: nil,
                    preselect: tier.isPreselectable, creationDate: r.metadata.creationDate
                )
            }
            if removableCount > 0 {
                live.tier = live.memberTiers.filter { !input.queued.contains($0.key) }.values.min() ?? live.tier
                clusters[cluster.id] = live
            }
        }

        // 2. Single-asset evidence for everything else (keepers included).
        let videoSizes = input.records.filter(\.metadata.isVideo).map { $0.storageEstimate.bytes }.sorted(by: >)
        let largeThreshold = max(150_000_000, min(500_000_000, videoSizes[safe: max(0, videoSizes.count / 10)] ?? 500_000_000))
        var livePhotoCandidates: [String] = []

        for r in input.records {
            if recommendations[r.id] != nil || input.queued.contains(r.id) { continue }
            let outcome: SingleAssetClassifier.Outcome
            if r.metadata.isImage {
                guard r.vision != nil || r.fingerprint != nil || r.metadata.isScreenshot else { continue }
                outcome = SingleAssetClassifier.classifyImage(r, settings: settings, now: now)
            } else if r.metadata.isVideo {
                outcome = SingleAssetClassifier.classifyVideo(r, settings: settings, now: now, largeThreshold: largeThreshold)
            } else {
                continue
            }
            let protection = protections(r)
            let blocked = !protection.subtracting([.recent]).isEmpty
            switch outcome {
            case .none:
                break
            case .sensitive, .evidence:
                protectedImportant.append(r.id)
            case .recommend(let category, let tier, let reasons):
                if blocked { break }
                if protection.contains(.recent) && category != .screenshots && category != .screenRecordings { break }
                let size = r.storageEstimate
                let preselect = tier.isPreselectable && category != .documents && category != .largeVideos
                recommendations[r.id] = Recommendation(
                    id: r.id, category: category, tier: tier, reasons: dedupe(reasons), clusterID: nil,
                    bytes: size.bytes, bytesExact: size.isExact, priority: 0, personalScore: nil,
                    preselect: preselect, creationDate: r.metadata.creationDate
                )
            }
            if settings.livePhotoCleanupEnabled, r.metadata.isLivePhoto, recommendations[r.id] == nil, !blocked,
               r.metadata.ageInDays(now: now) > 30 {
                livePhotoCandidates.append(r.id)
            }
        }

        // 3. Muted categories, trust and personalisation. Each item is independent and the
        // nearest-neighbour vote costs ~20 µs, so items are processed in parallel chunks.
        let clusterSizes = Dictionary(uniqueKeysWithValues: clusters.values.map { ($0.id, $0.memberIDs.count) })
        let pending = Array(recommendations)
        let preference = input.preference
        @Sendable func personalise(_ rec: Recommendation) -> Recommendation? {
            var rec = rec
            if settings.mutedCategories.contains(rec.category) { return nil }
            guard let r = byID[rec.id] else { return rec }
            switch preference.trust(for: rec.category) {
            case .reduced:
                rec.tier = rec.tier.demoted()
                rec.preselect = false
                rec.reasons.append(Reason(.lowTrust))
            case .boosted, .normal:
                break
            }
            let features = PreferenceFeatures.vector(record: r, category: rec.category, tier: rec.tier,
                                                     clusterSize: rec.clusterID.flatMap { clusterSizes[$0] } ?? 1, now: now)
            if let p = preference.probability(features) {
                rec.personalScore = p
                if p < 0.2 && rec.tier == .likely && rec.category != .exactDuplicates {
                    rec.tier = .review
                    rec.preselect = false
                    rec.reasons.append(Reason(.lowTrust))
                } else if p > 0.8 {
                    rec.reasons.append(Reason(.personalized))
                }
            }
            rec.priority = priority(rec, record: r, trust: preference.trust(for: rec.category), now: now)
            return rec
        }
        let chunkSize = 256
        let chunkCount = (pending.count + chunkSize - 1) / chunkSize
        nonisolated(unsafe) let personalised = UnsafeMutableBufferPointer<Recommendation?>.allocate(capacity: pending.count)
        personalised.initialize(repeating: nil)
        defer { personalised.deinitialize(); personalised.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            for i in (chunk * chunkSize)..<min(pending.count, (chunk + 1) * chunkSize) {
                personalised[i] = personalise(pending[i].value)
            }
        }
        for (i, entry) in pending.enumerated() { recommendations[entry.key] = personalised[i] }
        // Clusters whose members were muted or demoted stay consistent.
        for (cid, cluster) in clusters {
            let live = cluster.removableIDs.compactMap { recommendations[$0] }
            if live.isEmpty { clusters[cid] = nil; continue }
            clusters[cid]?.tier = live.map(\.tier).min() ?? cluster.tier
            for rec in live { clusters[cid]?.memberTiers[rec.id] = rec.tier }
        }

        // 4. Ordering and summaries.
        var byCategory: [CleanupCategory: [String]] = [:]
        for rec in recommendations.values { byCategory[rec.category, default: []].append(rec.id) }
        // Sort keys are looked up once per item, not twice per comparison (same order as before).
        for (category, ids) in byCategory {
            let keyed = ids.map { id in (id: id, rec: recommendations[id]!) }
            byCategory[category] = keyed.sorted { a, b in
                let ra = a.rec, rb = b.rec
                if category == .largeVideos { return ra.bytes > rb.bytes }
                if ra.tier != rb.tier { return ra.tier > rb.tier }
                if ra.priority != rb.priority { return ra.priority > rb.priority }
                return a.id < b.id
            }.map(\.id)
        }
        var clustersByCategory: [CleanupCategory: [String]] = [:]
        for cluster in clusters.values { clustersByCategory[cluster.kind.category, default: []].append(cluster.id) }
        for (category, ids) in clustersByCategory {
            let keyed = ids.map { id -> (id: String, tier: RecommendationTier, bytes: Int64) in
                let c = clusters[id]!
                return (id, c.tier, c.removableIDs.compactMap { recommendations[$0]?.bytes }.reduce(0, +))
            }
            clustersByCategory[category] = keyed.sorted { a, b in
                if a.tier != b.tier { return a.tier > b.tier }
                return a.bytes == b.bytes ? a.id < b.id : a.bytes > b.bytes
            }.map(\.id)
        }

        var summaries: [CleanupCategory: CategorySummary] = [:]
        for (category, ids) in byCategory where !ids.isEmpty {
            let recs = ids.compactMap { recommendations[$0] }
            let dates = recs.compactMap(\.creationDate)
            let previewSource: [String] = category.isGrouped
                ? (clustersByCategory[category] ?? []).compactMap { clusters[$0]?.primaryKeeperID }
                : ids
            summaries[category] = CategorySummary(
                category: category, count: recs.count, groupCount: clustersByCategory[category]?.count ?? 0,
                bytes: recs.map(\.bytes).reduce(0, +), bytesExact: recs.allSatisfy(\.bytesExact),
                previewIDs: Array(previewSource.prefix(4)),
                safeCount: recs.filter { $0.tier == .safe }.count,
                likelyCount: recs.filter { $0.tier == .likely }.count,
                reviewCount: recs.filter { $0.tier == .review }.count,
                oldest: dates.min(), newest: dates.max()
            )
        }

        return RecommendationSnapshot(
            generatedAt: now, recommendations: recommendations, clusters: clusters, byCategory: byCategory,
            clustersByCategory: clustersByCategory, summaries: summaries,
            protectedImportant: protectedImportant.sorted {
                (byID[$0]?.metadata.creationDate ?? .distantPast) > (byID[$1]?.metadata.creationDate ?? .distantPast)
            },
            livePhotoCandidates: livePhotoCandidates,
            library: libraryStats(input.records)
        )
    }

    /// Review order: confident, valuable, quick decisions first.
    static func priority(_ rec: Recommendation, record: AssetRecord, trust: CategoryTrust, now: Date) -> Double {
        var p = Double(rec.tier.rawValue) * 10
        p += log1p(Double(rec.bytes) / 1_000_000)
        p += min(3, log1p(record.metadata.ageInDays(now: now)) / 2)
        switch rec.category {
        case .exactDuplicates: p += 4
        case .similarPhotos: p += 2
        case .screenshots, .parking: p += 1.5
        default: break
        }
        if trust == .boosted { p += 2 }
        if let personal = rec.personalScore { p += (personal - 0.5) * 6 }
        return p
    }

    static func libraryStats(_ records: [AssetRecord]) -> LibraryStats {
        var stats = LibraryStats()
        stats.totalCount = records.count
        var allExact = true
        for r in records {
            if r.metadata.isImage { stats.photoCount += 1 } else if r.metadata.isVideo { stats.videoCount += 1 }
            if r.metadata.isScreenshot { stats.screenshotCount += 1 }
            if r.metadata.isLivePhoto { stats.livePhotoCount += 1 }
            let size = r.storageEstimate
            stats.totalBytes += size.bytes
            allExact = allExact && size.isExact
            if r.isAnalyzed { stats.analyzedCount += 1 }
        }
        stats.bytesExact = allExact && !records.isEmpty
        return stats
    }

    static func dedupe(_ reasons: [Reason]) -> [Reason] {
        var seen = Set<ReasonCode>()
        return reasons.filter { seen.insert($0.code).inserted }
    }
}
