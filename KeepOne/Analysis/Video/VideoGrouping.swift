import Foundation

/// Duplicate and similar-video detection from sparse temporal fingerprints.
enum VideoGrouping {
    struct Group: Sendable, Equatable {
        var memberIDs: [String]
        var kind: ClusterKind
    }

    struct Thresholds: Sendable {
        var durationTolerance: Double = 0.3
        var durationRelativeTolerance: Double = 0.01
        var duplicateFrameHamming: Float = 6
        var takesWindow: TimeInterval = 900
        var takesSemantic: Float = 0.9
        static let standard = Thresholds()
    }

    /// Mean Hamming distance between aligned frame hashes, nil if not comparable.
    static func frameDistance(_ a: VideoFeatures, _ b: VideoFeatures) -> Float? {
        guard !a.frameHashes.isEmpty, a.frameHashes.count == b.frameHashes.count else { return nil }
        let total = zip(a.frameHashes, b.frameHashes).map { PerceptualHash.distance($0, $1) }.reduce(0, +)
        return Float(total) / Float(a.frameHashes.count)
    }

    static func isDuplicate(_ a: AssetRecord, _ b: AssetRecord, thresholds: Thresholds = .standard) -> Bool {
        guard let va = a.video, let vb = b.video else { return false }
        let tolerance = max(thresholds.durationTolerance, thresholds.durationRelativeTolerance * max(a.metadata.duration, b.metadata.duration))
        guard abs(a.metadata.duration - b.metadata.duration) <= tolerance else { return false }
        guard abs(a.metadata.aspectRatio - b.metadata.aspectRatio) / max(a.metadata.aspectRatio, b.metadata.aspectRatio) < 0.03 else { return false }
        guard let d = frameDistance(va, vb) else { return false }
        return d <= thresholds.duplicateFrameHamming
    }

    static func isSimilarTake(_ a: AssetRecord, _ b: AssetRecord, thresholds: Thresholds = .standard) -> Bool {
        guard let ta = a.metadata.creationDate, let tb = b.metadata.creationDate,
              abs(ta.timeIntervalSince(tb)) <= thresholds.takesWindow,
              let ea = a.video?.semanticEmbedding.map(VectorMath.decodeFP16),
              let eb = b.video?.semanticEmbedding.map(VectorMath.decodeFP16),
              ea.count == eb.count, !ea.isEmpty
        else { return false }
        return VectorMath.cosine(ea, eb) >= thresholds.takesSemantic
    }

    static func detect(_ records: [AssetRecord], thresholds: Thresholds = .standard) -> [Group] {
        let videos = records.filter { $0.metadata.isVideo && $0.video != nil }
            .sorted { ($0.metadata.duration, $0.id) < ($1.metadata.duration, $1.id) }
        guard videos.count > 1 else { return [] }

        // Duplicates: sort by duration so only neighbours within tolerance are compared.
        var dupUnion = UnionFind(count: videos.count)
        var inDuplicate = Set<Int>()
        for i in videos.indices {
            var j = i + 1
            while j < videos.count, videos[j].metadata.duration - videos[i].metadata.duration <= max(1, videos[i].metadata.duration * 0.02) {
                if isDuplicate(videos[i], videos[j], thresholds: thresholds) {
                    dupUnion.union(i, j)
                    inDuplicate.insert(i); inDuplicate.insert(j)
                }
                j += 1
            }
        }
        var groups: [Group] = dupUnion.groups().filter { $0.count > 1 }
            .map { Group(memberIDs: $0.map { videos[$0].id }.sorted(), kind: .duplicateVideo) }

        // Multiple takes: time-sorted window, complete linkage to avoid chaining.
        let remaining = videos.indices.filter { !inDuplicate.contains($0) }
            .map { videos[$0] }
            .sorted { ($0.metadata.creationDate ?? .distantPast) < ($1.metadata.creationDate ?? .distantPast) }
        var takeUnion = UnionFind(count: remaining.count)
        for i in remaining.indices {
            var j = i + 1
            while j < remaining.count, j - i <= 20 {
                if isSimilarTake(remaining[i], remaining[j], thresholds: thresholds) { takeUnion.union(i, j) }
                j += 1
            }
        }
        for component in takeUnion.groups() where component.count > 1 {
            let members = component.map { remaining[$0] }
            for cluster in completeLinkage(members, pass: { isSimilarTake($0, $1, thresholds: thresholds) }) where cluster.count > 1 {
                groups.append(Group(memberIDs: cluster.map(\.id).sorted(), kind: .similarVideo))
            }
        }
        return groups
    }

    static func completeLinkage(_ members: [AssetRecord], pass: (AssetRecord, AssetRecord) -> Bool) -> [[AssetRecord]] {
        var clusters = members.map { [$0] }
        var merged = true
        while merged {
            merged = false
            search: for x in clusters.indices {
                for y in clusters.indices where y > x {
                    if clusters[x].allSatisfy({ a in clusters[y].allSatisfy { b in pass(a, b) } }) {
                        clusters[x].append(contentsOf: clusters[y])
                        clusters.remove(at: y)
                        merged = true
                        break search
                    }
                }
            }
        }
        return clusters
    }

    /// Keeper for a video group: favourite → edited → resolution → longer → older.
    static func chooseKeeper(_ members: [AssetRecord], forcedKeepers: Set<String>) -> (ordered: [String], keepers: [String], reasons: [Reason]) {
        let ordered = members.sorted { a, b in
            let ka: [Double] = [forcedKeepers.contains(a.id) ? 1 : 0, a.metadata.isFavorite ? 1 : 0, a.metadata.hasAdjustments ? 1 : 0,
                                Double(a.metadata.pixelCount), a.metadata.duration, -(a.metadata.creationDate?.timeIntervalSince1970 ?? 0)]
            let kb: [Double] = [forcedKeepers.contains(b.id) ? 1 : 0, b.metadata.isFavorite ? 1 : 0, b.metadata.hasAdjustments ? 1 : 0,
                                Double(b.metadata.pixelCount), b.metadata.duration, -(b.metadata.creationDate?.timeIntervalSince1970 ?? 0)]
            for (x, y) in zip(ka, kb) where x != y { return x > y }
            return a.id < b.id
        }
        let best = ordered[0]
        var keepers = [best.id]
        for r in ordered.dropFirst() where forcedKeepers.contains(r.id) || r.metadata.isFavorite { keepers.append(r.id) }
        var reasons: [Reason] = []
        if forcedKeepers.contains(best.id) { reasons.append(Reason(.userChosen)) }
        if best.metadata.isFavorite { reasons.append(Reason(.favorite)) }
        if best.metadata.hasAdjustments { reasons.append(Reason(.edited)) }
        if ordered.dropFirst().contains(where: { $0.metadata.pixelCount < best.metadata.pixelCount }) {
            reasons.append(Reason(.highestResolution, Format.dimensions(best.metadata.pixelWidth, best.metadata.pixelHeight)))
        }
        if reasons.isEmpty { reasons.append(Reason(.originalCopy, Format.date(best.metadata.creationDate))) }
        return (ordered.map(\.id), keepers, reasons)
    }
}
