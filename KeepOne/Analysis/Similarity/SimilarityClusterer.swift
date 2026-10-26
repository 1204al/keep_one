import Foundation

/// Time-adaptive similarity thresholds. Calibrated on synthetic sweeps (docs/CALIBRATION.md):
/// Vision feature-print distance between unrelated photos is ≥ 0.82 for 95 % of pairs, small crops
/// and exposure changes stay ≤ 0.42, while blur inflates it (≈0.84) — so pHash and MobileCLIP
/// cosine are fused in rather than relying on one signal.
struct SimilarityThresholds: Sendable, Equatable {
    var burstWindow: TimeInterval = 10
    var shortWindow: TimeInterval = 120
    var longWindow: TimeInterval = 1800
    var maxNeighbors = 60

    var burstFeaturePrint: Float = 0.62
    var burstHash = 14
    var burstSemantic: Float = 0.90

    var shortFeaturePrint: Float = 0.50
    var shortHash = 10
    var shortSemantic: Float = 0.93
    var shortSemanticFeaturePrintCap: Float = 0.75

    var longFeaturePrint: Float = 0.36
    var longSemanticFloor: Float = 0.85
    var longHash = 6

    var farFeaturePrint: Float = 0.22
    var farHash = 8

    /// Semantic veto: clearly different content never clusters, whatever the hash says.
    var semanticVeto: Float = 0.72
    var degradedSharpness: Float = 3.6
    var locationVetoMeters: Double = 300
    var maxComponentSize = 80

    static let standard = SimilarityThresholds()
}

struct PairEvidence: Sendable, Equatable {
    var timeDelta: TimeInterval?
    var featureDistance: Float?
    var hashDistance: Int
    var semanticCosine: Float?
    var sameBurst: Bool

    /// 0…1 combined similarity used for cohesion and ordering.
    var similarity: Float {
        var s: Float = max(0, 1 - Float(hashDistance) / 32)
        if let d = featureDistance { s = max(s, max(0, 1 - d / 1.1)) }
        if let c = semanticCosine { s = max(s, max(0, (c - 0.7) / 0.3)) }
        return min(1, s)
    }
}

struct SimilarCluster: Sendable, Equatable {
    var memberIDs: [String]
    var cohesion: Float
    var isBurst: Bool
    var maxTimeSpan: TimeInterval
}

/// Groups near-duplicate photos without all-pairs comparison and without cluster chaining:
/// candidate edges come from a sliding time window (+ burst IDs + multi-index pHash for distant
/// pairs); connected components are then re-split with complete-linkage agglomeration so every
/// pair inside a final cluster individually passes the similarity test.
struct SimilarityClusterer {
    var thresholds = SimilarityThresholds.standard
    let featurePrints: any VectorLookup
    let embeddings: any VectorLookup

    init(thresholds: SimilarityThresholds = .standard, featurePrints: any VectorLookup, embeddings: any VectorLookup) {
        self.thresholds = thresholds
        self.featurePrints = featurePrints
        self.embeddings = embeddings
    }

    init(thresholds: SimilarityThresholds = .standard, featurePrints: [String: [Float]], embeddings: [String: [Float]]) {
        self.init(thresholds: thresholds, featurePrints: featurePrints as any VectorLookup, embeddings: embeddings as any VectorLookup)
    }

    /// Date, then ID: input arrives in dictionary order, and without the tie-break photos with equal
    /// (or missing) dates swap places, renaming the group ("sim:" + first member) between refreshes.
    static func chronological(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
        let da = a.metadata.creationDate ?? .distantPast, db = b.metadata.creationDate ?? .distantPast
        return da == db ? a.id < b.id : da < db
    }

    func cluster(_ input: [AssetRecord]) -> [SimilarCluster] {
        let images = input.filter { $0.metadata.isImage && $0.fingerprint != nil }
        // Sort indices, then copy once: moving whole records through a 100k-element sort is costly.
        let records = images.indices.sorted { Self.chronological(images[$0], images[$1]) }.map { images[$0] }
        guard records.count > 1 else { return [] }
        let vectors = Vectors(records, featurePrints: featurePrints, embeddings: embeddings)

        var unionFind = UnionFind(count: records.count)
        var edges = Set<Pair>()

        // 1. Sliding time window.
        for i in records.indices {
            guard let ti = records[i].metadata.creationDate else { continue }
            var j = i + 1
            var examined = 0
            while j < records.count, examined < thresholds.maxNeighbors {
                guard let tj = records[j].metadata.creationDate else { j += 1; continue }
                if tj.timeIntervalSince(ti) > thresholds.longWindow { break }
                if isSimilar(records[i], records[j], evidence: vectors.evidence(i, j)) {
                    unionFind.union(i, j)
                    edges.insert(Pair(i, j))
                }
                examined += 1
                j += 1
            }
        }

        // 2. Distant-in-time near-identical pairs via multi-index hashing (8 chunks ⇒ complete for ≤ 7 bits).
        var index = MultiIndexHash(chunks: 8)
        for r in records { _ = index.insert(r.fingerprint!.pHash) }
        for i in records.indices {
            let candidates = index.candidates(for: records[i].fingerprint!.pHash, maxDistance: thresholds.farHash, after: i)
            guard !candidates.isEmpty else { continue }
            let vi = vectors.entry(i)
            for j in candidates where !edges.contains(Pair(i, j)) {
                // Most candidates are nearby frames of the same moment, still in the ring.
                if isSimilar(records[i], records[j], evidence: vectors.evidence(i, vi, j, vectors.entry(j))) {
                    unionFind.union(i, j)
                    edges.insert(Pair(i, j))
                }
            }
        }

        // 3. Validate each component: complete linkage prevents A≈B≈C chaining when A≉C.
        var clusters: [SimilarCluster] = []
        for component in unionFind.groups() where component.count > 1 {
            for window in component.sorted().chunked(into: thresholds.maxComponentSize) where window.count > 1 {
                for members in completeLinkage(window, vectors) where members.count > 1 {
                    clusters.append(makeCluster(members, vectors))
                }
            }
        }
        return clusters.sorted { ($0.memberIDs.first ?? "") < ($1.memberIDs.first ?? "") }
    }

    /// Vectors for one clustering run, widened on demand and kept only while in use. The sliding window
    /// meets each photo up to ~60 times; a small ring of recent entries (indexed by position, so no
    /// hashing) decodes each vector once while the window passes over it, and embedding norms are
    /// computed once per photo. Nothing like a full Float copy of the library is ever built.
    private final class Vectors {
        struct Entry {
            let print: [Float]?
            let embedding: [Float]?
            /// Matches `evidence(_:_:)`: an embedding only counts when its norm is > 0.5.
            let usableEmbedding: Bool
        }

        let records: [AssetRecord]
        private let featurePrints: any VectorLookup
        private let embeddings: any VectorLookup
        // The few fields a pair test reads, so it never copies two whole records out of a class.
        private let dates: [Date?]
        private let bursts: [String?]
        private let hashes: [UInt64?]
        private static let ringSize = 256  // power of two, comfortably above the 60-neighbour window
        private var ringIndex = [Int](repeating: -1, count: ringSize)
        private var ringEntry = [Entry?](repeating: nil, count: ringSize)

        init(_ records: [AssetRecord], featurePrints: any VectorLookup, embeddings: any VectorLookup) {
            self.records = records
            self.featurePrints = featurePrints
            self.embeddings = embeddings
            dates = records.map(\.metadata.creationDate)
            bursts = records.map(\.metadata.burstIdentifier)
            hashes = records.map { $0.fingerprint?.pHash }
        }

        private func load(_ i: Int) -> Entry {
            let id = records[i].id
            let embedding = embeddings.vector(for: id)
            return Entry(print: featurePrints.vector(for: id), embedding: embedding,
                         usableEmbedding: embedding.map { VectorMath.norm($0) > 0.5 } ?? false)
        }

        func entry(_ i: Int) -> Entry {
            let slot = i & (Self.ringSize - 1)
            if ringIndex[slot] == i, let hit = ringEntry[slot] { return hit }
            let loaded = load(i)
            ringIndex[slot] = i
            ringEntry[slot] = loaded
            return loaded
        }

        func evidence(_ i: Int, _ j: Int) -> PairEvidence { evidence(i, entry(i), j, entry(j)) }

        func evidence(_ i: Int, _ vi: Entry, _ j: Int, _ vj: Entry) -> PairEvidence {
            let dt: TimeInterval? = {
                guard let ta = dates[i], let tb = dates[j] else { return nil }
                return abs(ta.timeIntervalSince(tb))
            }()
            let fp: Float? = {
                guard let pa = vi.print, let pb = vj.print else { return nil }
                return VectorMath.euclidean(pa, pb)
            }()
            let sem: Float? = {
                guard let ea = vi.embedding, let eb = vj.embedding, ea.count == eb.count,
                      vi.usableEmbedding, vj.usableEmbedding else { return nil }
                let c = VectorMath.dot(ea, eb)
                return c.isFinite ? c : nil
            }()
            let sameBurst = bursts[i] != nil && bursts[i] == bursts[j]
            return PairEvidence(
                timeDelta: dt, featureDistance: fp,
                hashDistance: PerceptualHash.distance(hashes[i] ?? 0, hashes[j] ?? .max),
                semanticCosine: sem, sameBurst: sameBurst
            )
        }
    }

    // MARK: Pair test

    func evidence(_ a: AssetRecord, _ b: AssetRecord) -> PairEvidence {
        let dt: TimeInterval? = {
            guard let ta = a.metadata.creationDate, let tb = b.metadata.creationDate else { return nil }
            return abs(ta.timeIntervalSince(tb))
        }()
        let fp: Float? = {
            guard let pa = featurePrints.vector(for: a.id), let pb = featurePrints.vector(for: b.id) else { return nil }
            return VectorMath.euclidean(pa, pb)
        }()
        let sem: Float? = {
            guard let ea = embeddings.vector(for: a.id), let eb = embeddings.vector(for: b.id), ea.count == eb.count else { return nil }
            let c = VectorMath.dot(ea, eb)
            return c.isFinite && VectorMath.norm(ea) > 0.5 && VectorMath.norm(eb) > 0.5 ? c : nil
        }()
        let sameBurst = a.metadata.burstIdentifier != nil && a.metadata.burstIdentifier == b.metadata.burstIdentifier
        return PairEvidence(
            timeDelta: dt, featureDistance: fp,
            hashDistance: PerceptualHash.distance(a.fingerprint?.pHash ?? 0, b.fingerprint?.pHash ?? .max),
            semanticCosine: sem, sameBurst: sameBurst
        )
    }

    func isSimilar(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
        isSimilar(a, b, evidence: evidence(a, b))
    }

    func isSimilar(_ a: AssetRecord, _ b: AssetRecord, evidence e: PairEvidence) -> Bool {
        let t = thresholds
        // Screenshots only group with screenshots.
        guard a.metadata.isScreenshot == b.metadata.isScreenshot else { return false }
        // Portrait vs landscape is a different shot unless it's the same burst.
        let orientationA = a.metadata.pixelWidth >= a.metadata.pixelHeight
        let orientationB = b.metadata.pixelWidth >= b.metadata.pixelHeight
        if orientationA != orientationB && !e.sameBurst { return false }

        let fp = e.featureDistance ?? 9
        let nearIdentical = e.hashDistance <= 4 && fp <= 0.25
        let rapid = e.sameBurst || (e.timeDelta ?? .infinity) <= t.burstWindow
        // A badly blurred frame has unreliable semantics/feature prints; inside a burst its layout (pHash) decides.
        let degraded = min(a.fingerprint?.quality.sharpness ?? 9, b.fingerprint?.quality.sharpness ?? 9) < t.degradedSharpness
        if rapid && degraded {
            return e.hashDistance <= t.burstHash || fp <= t.burstFeaturePrint
        }

        if let c = e.semanticCosine, c < t.semanticVeto, !nearIdentical { return false }
        if let meters = Geo.distance(a.metadata, b.metadata), meters > t.locationVetoMeters,
           (e.timeDelta ?? .infinity) > 60, !nearIdentical {
            return false
        }

        let dt = e.timeDelta ?? .infinity
        if e.sameBurst || dt <= t.burstWindow {
            return fp <= t.burstFeaturePrint || e.hashDistance <= t.burstHash || (e.semanticCosine ?? 0) >= t.burstSemantic
        }
        if dt <= t.shortWindow {
            return fp <= t.shortFeaturePrint || e.hashDistance <= t.shortHash
                || ((e.semanticCosine ?? 0) >= t.shortSemantic && fp <= t.shortSemanticFeaturePrintCap)
        }
        if dt <= t.longWindow {
            return (fp <= t.longFeaturePrint && (e.semanticCosine ?? 1) >= t.longSemanticFloor) || e.hashDistance <= t.longHash
        }
        return fp <= t.farFeaturePrint && e.hashDistance <= t.farHash
    }

    // MARK: Complete linkage

    /// Complete linkage over record indices. Linkage between merged clusters is kept
    /// incrementally (min similarity, all-pairs pass), which is exact for complete linkage and avoids
    /// rescanning every member pair on each merge.
    private func completeLinkage(_ members: [Int], _ vectors: Vectors) -> [[Int]] {
        let n = members.count
        let records = vectors.records
        guard n > 2 else {
            return n == 2 && isSimilar(records[members[0]], records[members[1]], evidence: vectors.evidence(members[0], members[1]))
                ? [members] : members.map { [$0] }
        }
        // pass[x][y] / link[x][y]: every member pair passes / minimum pair similarity, per cluster pair.
        var pass = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        var link = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = members[i], b = members[j]
                let e = vectors.evidence(a, b)
                let ok = isSimilar(records[a], records[b], evidence: e)
                pass[i][j] = ok; pass[j][i] = ok
                link[i][j] = e.similarity; link[j][i] = e.similarity
            }
        }
        // Slot k holds the cluster that started at member k; `order` keeps the original cluster order
        // so ties resolve exactly as before (first pair in scan order wins).
        var clusters: [[Int]] = (0..<n).map { [$0] }
        var order = Array(0..<n)
        while true {
            var best: (Int, Int, Float)?
            for x in 0..<order.count {
                for y in (x + 1)..<order.count {
                    let cx = order[x], cy = order[y]
                    if pass[cx][cy], link[cx][cy] > (best?.2 ?? -1) { best = (x, y, link[cx][cy]) }
                }
            }
            guard let (x, y, _) = best else { break }
            let cx = order[x], cy = order[y]
            for cz in order where cz != cx && cz != cy {
                pass[cx][cz] = pass[cx][cz] && pass[cy][cz]; pass[cz][cx] = pass[cx][cz]
                link[cx][cz] = min(link[cx][cz], link[cy][cz]); link[cz][cx] = link[cx][cz]
            }
            clusters[cx].append(contentsOf: clusters[cy])
            order.remove(at: y)
        }
        return order.map { clusters[$0].map { members[$0] } }
    }

    private func makeCluster(_ members: [Int], _ vectors: Vectors) -> SimilarCluster {
        var total: Float = 0
        var pairs = 0
        for i in members.indices {
            for j in members.indices where j > i {
                total += vectors.evidence(members[i], members[j]).similarity
                pairs += 1
            }
        }
        let records = members.map { vectors.records[$0] }
        let dates = records.compactMap(\.metadata.creationDate)
        let span = (dates.max() ?? .distantPast).timeIntervalSince(dates.min() ?? .distantPast)
        let bursts = Set(records.map(\.metadata.burstIdentifier))
        let isBurst = bursts.count == 1 && bursts.first! != nil
        let ordered = records.sorted(by: Self.chronological)
        return SimilarCluster(
            memberIDs: ordered.map(\.id), cohesion: pairs > 0 ? total / Float(pairs) : 1,
            isBurst: isBurst, maxTimeSpan: max(0, span)
        )
    }

    private struct Pair: Hashable {
        let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }
}
