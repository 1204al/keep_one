import Foundation

struct GroupingContext: Sendable {
    /// Assets that must be kept inside any group (protected, kept, user-chosen keepers).
    var forcedKeepers: Set<String> = []
    /// Assets the user explicitly picked as best shot.
    var chosenKeepers: Set<String> = []
    var protectEdited = true
    var weights = BestShotWeights.default
    var preference: PreferenceModel?
    var similarity = SimilarityThresholds.standard
    var duplicates = DuplicateThresholds.standard
    var now = Date()

    /// Identifies inputs that change grouping results (for caching).
    var cacheKey: Int {
        var h = Hasher()
        h.combine(forcedKeepers)
        h.combine(chosenKeepers)
        h.combine(protectEdited)
        h.combine(weights.asArray)
        // Personal re-ranking moves slowly; regrouping the whole library on every single tap doesn't pay.
        h.combine((preference?.decisionCount ?? -20) / 20)
        return h.finalize()
    }
}

struct GroupingResult: Sendable {
    var clusters: [AssetCluster]
    /// Assets whose original-content hash should be computed to confirm duplicates.
    var hashCandidates: Set<String>
    /// Similar-group members that would benefit from high-resolution sharpness.
    var detailCandidates: Set<String>

    static let empty = GroupingResult(clusters: [], hashCandidates: [], detailCandidates: [])
}

/// The detection half of a grouping run — what depends only on the analysed data, not on the user's
/// keepers, weights or preferences. Reused while the data is unchanged, so a Keep, Protect or
/// best-shot change re-ranks the groups instead of detecting them again.
struct GroupingIntermediates: Sendable {
    var duplicateThresholds: DuplicateThresholds
    var similarityThresholds: SimilarityThresholds
    var duplicates: DuplicateDetector.Result
    var videoGroups: [VideoGrouping.Group]
    /// The duplicate non-keepers that were excluded when `similar` was clustered.
    var similarExcluding: Set<String>
    var similar: [SimilarCluster]
}

/// Builds every group (exact duplicates, similar shots, video duplicates/takes) from cached
/// analysis. Pure and synchronous; runs off the main thread.
enum GroupingEngine {
    static func compute(
        records: [AssetRecord],
        featurePrints: [String: [Float]],
        embeddings: [String: [Float]],
        context: GroupingContext
    ) -> GroupingResult {
        compute(records: records, featurePrints: featurePrints as any VectorLookup, embeddings: embeddings as any VectorLookup,
                context: context, reusing: nil).result
    }

    static func compute(
        records: [AssetRecord],
        featurePrints: [String: [Float]],
        embeddings: [String: [Float]],
        context: GroupingContext,
        reusing previous: GroupingIntermediates?
    ) -> (result: GroupingResult, intermediates: GroupingIntermediates) {
        compute(records: records, featurePrints: featurePrints as any VectorLookup, embeddings: embeddings as any VectorLookup,
                context: context, reusing: previous)
    }

    /// `reusing` must come from a run over exactly the same records and vectors.
    static func compute(
        records: [AssetRecord],
        featurePrints: any VectorLookup,
        embeddings: any VectorLookup,
        context: GroupingContext,
        reusing previous: GroupingIntermediates?
    ) -> (result: GroupingResult, intermediates: GroupingIntermediates) {
        var clusters: [AssetCluster] = []
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let forced = context.forcedKeepers.union(context.chosenKeepers)
        let reuse = previous.flatMap {
            $0.duplicateThresholds == context.duplicates && $0.similarityThresholds == context.similarity ? $0 : nil
        }

        // 1. Exact duplicates.
        let duplicates = reuse?.duplicates
            ?? DuplicateDetector.detect(records: records, featurePrints: featurePrints, thresholds: context.duplicates)
        var duplicateNonKeepers = Set<String>()
        for group in duplicates.groups {
            let members = group.memberIDs.compactMap { byID[$0] }
            guard members.count > 1 else { continue }
            let choice = DuplicateKeeperSelector.choose(members: members, forcedKeepers: forced)
            guard let keeperID = choice.keeperIDs.first, let keeper = byID[keeperID] else { continue }
            var memberReasons: [String: [Reason]] = [:]
            var memberTiers: [String: RecommendationTier] = [:]
            for id in choice.ordered where !choice.keeperIDs.contains(id) {
                guard let m = byID[id] else { continue }
                let (reason, tier) = duplicateReason(member: m, keeper: keeper, evidence: group.evidence[id] ?? .smallerCopy)
                memberReasons[id] = [reason]
                memberTiers[id] = tier
                duplicateNonKeepers.insert(id)
            }
            guard !memberTiers.isEmpty else { continue }
            clusters.append(AssetCluster(
                id: "dup:" + group.memberIDs[0], kind: .exactDuplicate, memberIDs: choice.ordered, keeperIDs: choice.keeperIDs,
                tier: memberTiers.values.min() ?? .likely, similarity: 1, keeperReasons: choice.reasons,
                memberReasons: memberReasons, scores: [:], memberTiers: memberTiers
            ))
        }

        // 2. Similar shots (duplicate non-keepers are already handled above).
        let clusterer = SimilarityClusterer(thresholds: context.similarity, featurePrints: featurePrints, embeddings: embeddings)
        let similarClusters: [SimilarCluster]
        if let reuse, reuse.similarExcluding == duplicateNonKeepers {
            similarClusters = reuse.similar
        } else {
            similarClusters = clusterer.cluster(records.filter { !duplicateNonKeepers.contains($0.id) })
        }
        var detailCandidates = Set<String>()
        for similar in similarClusters {
            let members = similar.memberIDs.compactMap { byID[$0] }
            guard members.count > 1 else { continue }
            var ranker = BestShotRanker(weights: context.weights)
            if let preference = context.preference, preference.isActive {
                for m in members {
                    let x = PreferenceFeatures.vector(record: m, category: .similarPhotos, tier: .likely,
                                                      clusterSize: members.count, now: context.now)
                    if let p = preference.logisticProbability(x) { ranker.personalKeep[m.id] = 1 - p }
                }
            }
            let outcome = ranker.rank(members, forcedKeepers: forced, protectEdited: context.protectEdited)
            let keeper = byID[outcome.keeperIDs[0]]!
            var memberTiers: [String: RecommendationTier] = [:]
            for m in members where !outcome.keeperIDs.contains(m.id) {
                memberTiers[m.id] = similarTier(member: m, keeper: keeper, cluster: similar, clusterer: clusterer, ranker: ranker)
            }
            for m in members where m.fingerprint?.quality.detailSharpness == nil { detailCandidates.insert(m.id) }
            guard !memberTiers.isEmpty else { continue }
            clusters.append(AssetCluster(
                id: "sim:" + similar.memberIDs[0], kind: similar.isBurst ? .burst : .similar,
                memberIDs: outcome.ordered.map(\.id), keeperIDs: outcome.keeperIDs,
                tier: memberTiers.values.min() ?? .review, similarity: similar.cohesion,
                keeperReasons: outcome.keeperReasons, memberReasons: outcome.memberReasons,
                scores: Dictionary(uniqueKeysWithValues: outcome.ordered.map { ($0.id, $0.score) }),
                memberTiers: memberTiers,
                memberFeatures: Dictionary(uniqueKeysWithValues: outcome.ordered.map { ($0.id, $0.features) })
            ))
        }

        // 3. Videos.
        let videoGroups = reuse?.videoGroups ?? VideoGrouping.detect(records)
        for group in videoGroups {
            let members = group.memberIDs.compactMap { byID[$0] }
            guard members.count > 1 else { continue }
            let choice = VideoGrouping.chooseKeeper(members, forcedKeepers: forced)
            var memberReasons: [String: [Reason]] = [:]
            var memberTiers: [String: RecommendationTier] = [:]
            for id in choice.ordered where !choice.keepers.contains(id) {
                guard let m = byID[id], let keeper = byID[choice.keepers[0]] else { continue }
                if group.kind == .duplicateVideo {
                    let sameSize = m.metadata.pixelCount == keeper.metadata.pixelCount
                    memberReasons[id] = [Reason(.duplicateVideo)]
                    memberTiers[id] = sameSize && abs(m.metadata.duration - keeper.metadata.duration) < 0.2 ? .safe : .likely
                } else {
                    memberReasons[id] = [Reason(.similarVideo)]
                    memberTiers[id] = .review
                }
            }
            guard !memberTiers.isEmpty else { continue }
            clusters.append(AssetCluster(
                id: "vid:" + group.memberIDs[0], kind: group.kind, memberIDs: choice.ordered, keeperIDs: choice.keepers,
                tier: memberTiers.values.min() ?? .review, similarity: 1, keeperReasons: choice.reasons,
                memberReasons: memberReasons, scores: [:], memberTiers: memberTiers
            ))
        }

        let result = GroupingResult(clusters: clusters, hashCandidates: duplicates.hashCandidates, detailCandidates: detailCandidates)
        let intermediates = GroupingIntermediates(
            duplicateThresholds: context.duplicates, similarityThresholds: context.similarity, duplicates: duplicates,
            videoGroups: videoGroups, similarExcluding: duplicateNonKeepers, similar: similarClusters
        )
        return (result, intermediates)
    }

    static func duplicateReason(member: AssetRecord, keeper: AssetRecord, evidence: DuplicateEvidence) -> (Reason, RecommendationTier) {
        if let a = member.contentHash, let b = keeper.contentHash, a == b {
            return (Reason(.byteIdentical), .safe)
        }
        if member.metadata.pixelCount < keeper.metadata.pixelCount {
            return (Reason(.smallerCopy, Format.dimensions(member.metadata.pixelWidth, member.metadata.pixelHeight)), .likely)
        }
        if member.metadata.pixelCount > keeper.metadata.pixelCount {
            // The keeper won on favourite/edit status despite lower resolution — let the user look.
            return (Reason(.duplicateOfKeeper), .likely)
        }
        return evidence >= .visuallyIdentical ? (Reason(.visuallyIdentical), .safe) : (Reason(.duplicateOfKeeper), .likely)
    }

    /// SAFE only for obviously redundant burst-like frames where the keeper is objectively better;
    /// REVIEW when the differences are probably expressions or the group is loose.
    static func similarTier(member: AssetRecord, keeper: AssetRecord, cluster: SimilarCluster,
                            clusterer: SimilarityClusterer, ranker: BestShotRanker) -> RecommendationTier {
        let e = clusterer.evidence(keeper, member)
        let k = ranker.raw(keeper), m = ranker.raw(member)
        let sharpnessGap = k.sharpness - m.sharpness
        let memberFailed = member.fingerprint.map {
            QualityAssessor.assess(quality: $0.quality, vision: member.vision, semantic: member.semantic).isFailed
        } ?? false
        let nearlySameFrame = (e.featureDistance ?? 9) <= 0.35 || e.hashDistance <= 8
        let rapid = e.sameBurst || (e.timeDelta ?? .infinity) <= 3

        if member.metadata.isFavorite || member.metadata.hasAdjustments { return .review }
        if rapid && nearlySameFrame && (sharpnessGap >= 0.6 || memberFailed) { return .safe }

        let bothHaveFaces = (k.faceQuality != nil) && (m.faceQuality != nil)
        if bothHaveFaces, let kf = k.faceQuality, let mf = m.faceQuality, abs(kf - mf) < 0.05, abs(sharpnessGap) < 0.2 {
            return .review  // probably different expressions — a human call
        }
        if cluster.cohesion < 0.45 || cluster.maxTimeSpan > 600 { return .review }
        return .likely
    }
}
