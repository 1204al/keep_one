import Foundation

enum DuplicateEvidence: Int, Sendable, Comparable {
    case smallerCopy = 1
    case visuallyIdentical = 2
    case byteIdentical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DuplicateThresholds: Sendable, Equatable {
    /// Loose screen: anything closer than this becomes a candidate (multi-index is complete for < 4).
    var candidateHamming = 3
    var candidateMicro: Float = 2.5
    var candidateColor = 8
    /// Same-resolution "visually identical".
    var identicalHamming = 2
    var identicalMicro: Float = 1.2
    var identicalFeaturePrint: Float = 0.12
    /// Lower-resolution copy.
    var smallerCopyMicro: Float = 2.0
    var smallerCopyFeaturePrint: Float = 0.35
    var aspectTolerance = 0.02

    static let standard = DuplicateThresholds()
}

struct DuplicateGroup: Sendable, Equatable {
    var memberIDs: [String]
    /// Strongest evidence linking each member to the rest of the group.
    var evidence: [String: DuplicateEvidence]
}

/// Progressive exact-duplicate detection:
/// metadata/aspect → perceptual hash (multi-index, no all-pairs) → micro-thumbnail pixels →
/// feature print → original-content hash (only for the few remaining candidates).
enum DuplicateDetector {
    struct Result: Sendable {
        var groups: [DuplicateGroup]
        /// Assets whose original-content hash would confirm or upgrade a match.
        var hashCandidates: Set<String>
    }

    static func detect(
        records: [AssetRecord],
        featurePrints: [String: [Float]],
        thresholds: DuplicateThresholds = .standard
    ) -> Result {
        detect(records: records, featurePrints: featurePrints as any VectorLookup, thresholds: thresholds)
    }

    static func detect(
        records: [AssetRecord],
        featurePrints: any VectorLookup,
        thresholds: DuplicateThresholds = .standard
    ) -> Result {
        let images = records.filter { $0.metadata.isImage && $0.fingerprint != nil }
        guard images.count > 1 else { return Result(groups: [], hashCandidates: []) }

        var index = MultiIndexHash(chunks: 4)
        for record in images { _ = index.insert(record.fingerprint!.pHash) }

        var unionFind = UnionFind(count: images.count)
        var pairEvidence: [Int: DuplicateEvidence] = [:]
        var hashCandidates = Set<String>()

        for i in images.indices {
            let a = images[i]
            guard let fa = a.fingerprint else { continue }
            for j in index.candidates(for: fa.pHash, maxDistance: thresholds.candidateHamming, after: i) {
                let b = images[j]
                guard let fb = b.fingerprint else { continue }
                guard let evidence = compare(a, fa, b, fb, featurePrints: featurePrints, thresholds: thresholds,
                                             onAmbiguous: { hashCandidates.insert(a.id); hashCandidates.insert(b.id) })
                else { continue }
                unionFind.union(i, j)
                pairEvidence[i] = max(pairEvidence[i] ?? evidence, evidence)
                pairEvidence[j] = max(pairEvidence[j] ?? evidence, evidence)
                if a.contentHash == nil || b.contentHash == nil {
                    hashCandidates.insert(a.id)
                    hashCandidates.insert(b.id)
                }
            }
        }

        var groups: [DuplicateGroup] = []
        for members in unionFind.groups() where members.count > 1 {
            var evidence: [String: DuplicateEvidence] = [:]
            for m in members { evidence[images[m].id] = pairEvidence[m] ?? .smallerCopy }
            let ids = members.map { images[$0].id }.sorted()
            groups.append(DuplicateGroup(memberIDs: ids, evidence: evidence))
        }
        groups.sort { $0.memberIDs[0] < $1.memberIDs[0] }
        return Result(groups: groups, hashCandidates: hashCandidates)
    }

    /// Returns the evidence level if a and b are duplicates, nil otherwise.
    static func compare(
        _ a: AssetRecord, _ fa: ImageFingerprint,
        _ b: AssetRecord, _ fb: ImageFingerprint,
        featurePrints: any VectorLookup,
        thresholds: DuplicateThresholds,
        onAmbiguous: () -> Void
    ) -> DuplicateEvidence? {
        // Never treat a photo and a video, or a screenshot and a camera photo, as copies.
        guard a.metadata.isScreenshot == b.metadata.isScreenshot else { return nil }
        let arA = a.metadata.aspectRatio, arB = b.metadata.aspectRatio
        guard abs(arA - arB) / max(arA, arB) <= thresholds.aspectTolerance else { return nil }

        if let ha = a.contentHash, let hb = b.contentHash, ha == hb { return .byteIdentical }

        let hamming = PerceptualHash.distance(fa.pHash, fb.pHash)
        let micro = ImageMetrics.microDifference(fa.micro, fb.micro)
        guard hamming <= thresholds.candidateHamming, micro <= thresholds.candidateMicro else { return nil }
        let colorDelta = zip(fa.meanColor, fb.meanColor).map { abs(Int($0) - Int($1)) }.max() ?? 0
        guard colorDelta <= thresholds.candidateColor else { return nil }

        let fpDistance: Float? = {
            guard let pa = featurePrints.vector(for: a.id), let pb = featurePrints.vector(for: b.id) else { return nil }
            return VectorMath.euclidean(pa, pb)
        }()
        let sameSize = a.metadata.pixelWidth == b.metadata.pixelWidth && a.metadata.pixelHeight == b.metadata.pixelHeight

        if sameSize {
            if hamming <= thresholds.identicalHamming && micro <= thresholds.identicalMicro
                && (fpDistance ?? 0) <= thresholds.identicalFeaturePrint {
                return .visuallyIdentical
            }
            // Close but not conclusive (e.g. tripod burst frames): only a content hash can settle it.
            onAmbiguous()
            return nil
        }
        if micro <= thresholds.smallerCopyMicro && (fpDistance ?? 0) <= thresholds.smallerCopyFeaturePrint {
            return .smallerCopy
        }
        return nil
    }
}

/// Chooses which copy of an exact-duplicate set to keep, with an explanation.
enum DuplicateKeeperSelector {
    struct Choice: Sendable {
        var keeperIDs: [String]
        var ordered: [String]
        var reasons: [Reason]
    }

    static func choose(members: [AssetRecord], forcedKeepers: Set<String>) -> Choice {
        func key(_ r: AssetRecord) -> [Double] {
            [
                forcedKeepers.contains(r.id) ? 1 : 0,
                r.metadata.isFavorite ? 1 : 0,
                r.metadata.hasAdjustments ? 1 : 0,
                Double(r.metadata.pixelCount),
                r.metadata.hasLocation ? 1 : 0,
                -(r.metadata.creationDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude),
                r.metadata.sourceType.contains(.userLibrary) ? 1 : 0,
            ]
        }
        let ordered = members.sorted { lhs, rhs in
            let a = key(lhs), b = key(rhs)
            for (x, y) in zip(a, b) where x != y { return x > y }
            return lhs.id < rhs.id
        }
        guard let best = ordered.first else { return Choice(keeperIDs: [], ordered: [], reasons: []) }

        var keepers = [best.id]
        // Every protected or favourite copy is kept, never silently removed.
        for r in ordered.dropFirst() where forcedKeepers.contains(r.id) || r.metadata.isFavorite {
            keepers.append(r.id)
        }

        var reasons: [Reason] = []
        let others = ordered.dropFirst()
        if forcedKeepers.contains(best.id) { reasons.append(Reason(.userChosen)) }
        if best.metadata.isFavorite, others.contains(where: { !$0.metadata.isFavorite }) { reasons.append(Reason(.favorite)) }
        if best.metadata.hasAdjustments, others.contains(where: { !$0.metadata.hasAdjustments }) { reasons.append(Reason(.edited)) }
        if others.contains(where: { $0.metadata.pixelCount < best.metadata.pixelCount }) {
            reasons.append(Reason(.highestResolution, Format.dimensions(best.metadata.pixelWidth, best.metadata.pixelHeight)))
        }
        if best.metadata.hasLocation, others.contains(where: { !$0.metadata.hasLocation }) { reasons.append(Reason(.hasLocation)) }
        if reasons.isEmpty { reasons.append(Reason(.originalCopy, Format.date(best.metadata.creationDate))) }
        return Choice(keeperIDs: keepers, ordered: ordered.map(\.id), reasons: reasons)
    }
}
