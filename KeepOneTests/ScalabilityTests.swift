import Foundation
import Testing
@testable import KeepOne

/// The large-library optimisations must never change what the user is shown.
@Suite("Scalability optimisations keep results identical")
struct ScalabilityTests {
    /// A small synthetic library: bursts with drifting hashes and vectors, plus a few later copies.
    func library(seed: Int = 1) -> (records: [AssetRecord], prints: [String: [Float]], embeddings: [String: [Float]]) {
        var records: [AssetRecord] = []
        var prints: [String: [Float]] = [:], embeddings: [String: [Float]] = [:]
        var t = Fixtures.days(400)
        for moment in 0..<40 {
            t = t.addingTimeInterval(Double(3_600 + moment * 977))
            let base = Fixtures.stableHash("m\(moment)-\(seed)")
            for shot in 0..<(moment % 4 + 1) {
                let id = "m\(moment)s\(shot)"
                let hash = base ^ (shot == 0 ? 0 : UInt64(1) << UInt64((moment + shot * 13) % 64))
                records.append(Fixtures.record(id, date: t.addingTimeInterval(Double(shot)), hash: hash,
                                               quality: Fixtures.quality(sharpness: 4 + Float(shot % 3)),
                                               favorite: moment % 11 == 0 && shot == 1))
                prints[id] = Fixtures.vector(moment, noise: shot == 0 ? 0 : 0.05, noiseSeed: shot)
                embeddings[id] = Fixtures.vector(moment + 100, noise: shot == 0 ? 0 : 0.03, noiseSeed: shot)
            }
        }
        for copy in stride(from: 0, to: records.count, by: 9) {
            var r = records[copy]
            let original = r.id
            r.metadata.id = "copy-" + original
            r.metadata.creationDate = r.metadata.creationDate?.addingTimeInterval(40 * 86_400)
            records.append(r)
            prints[r.id] = prints[original]
            embeddings[r.id] = embeddings[original]
        }
        return (records, prints, embeddings)
    }

    func describe(_ result: GroupingResult) -> String {
        result.clusters.sorted { $0.id < $1.id }.map { c in
            "\(c.id)|\(c.memberIDs)|\(c.keeperIDs)|\(c.memberTiers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" })|\(c.similarity)"
        }.joined(separator: "\n") + "|H\(result.hashCandidates.sorted())|D\(result.detailCandidates.sorted())"
    }

    @Test func multiIndexCandidatesAfterMatchFilteringAndOrder() {
        var rng = SystemRandomNumberGenerator()
        let hashes = (0..<600).map { _ in UInt64.random(in: 0...0xFFFF, using: &rng) }  // crowded buckets
        var index = MultiIndexHash(chunks: 8)
        for h in hashes { _ = index.insert(h) }
        for i in stride(from: 0, to: hashes.count, by: 37) {
            let all = index.candidates(for: hashes[i], maxDistance: 8)
            #expect(index.candidates(for: hashes[i], maxDistance: 8, after: i) == all.filter { $0 > i })
            #expect(Set(all).count == all.count, "each candidate reported once")
        }
    }

    @Test func reusingDetectionEqualsComputingFromScratch() {
        let lib = library()
        let first = GroupingEngine.compute(records: lib.records, featurePrints: lib.prints, embeddings: lib.embeddings,
                                           context: GroupingContext(now: Fixtures.now), reusing: nil)
        // A user action: one item kept, another chosen as best shot.
        var changed = GroupingContext(now: Fixtures.now)
        changed.forcedKeepers = ["m5s1", "copy-m0s0"]
        changed.chosenKeepers = ["m7s2"]
        let fresh = GroupingEngine.compute(records: lib.records, featurePrints: lib.prints, embeddings: lib.embeddings,
                                           context: changed, reusing: nil)
        let reused = GroupingEngine.compute(records: lib.records, featurePrints: lib.prints, embeddings: lib.embeddings,
                                            context: changed, reusing: first.intermediates)
        #expect(!fresh.result.clusters.isEmpty)
        #expect(describe(reused.result) == describe(fresh.result))
    }

    @Test func packedVectorsGroupExactlyLikePersistedOnes() {
        let lib = library(seed: 2)
        // What a relaunch sees: vectors read back from their FP16 blobs.
        let roundTrip = { (v: [String: [Float]]) in v.mapValues { VectorMath.decodeFP16(VectorMath.encodeFP16($0)) } }
        var packedPrints = PackedVectors(), packedEmbeddings = PackedVectors()
        for (id, v) in lib.prints { packedPrints.set(v, for: id) }
        for (id, v) in lib.embeddings { packedEmbeddings.set(v, for: id) }
        let persisted = GroupingEngine.compute(records: lib.records, featurePrints: roundTrip(lib.prints),
                                               embeddings: roundTrip(lib.embeddings), context: GroupingContext(now: Fixtures.now))
        let packed = GroupingEngine.compute(records: lib.records, featurePrints: packedPrints, embeddings: packedEmbeddings,
                                            context: GroupingContext(now: Fixtures.now), reusing: nil).result
        #expect(!persisted.clusters.isEmpty)
        #expect(describe(packed) == describe(persisted))
    }

    @Test func detailJobsTakeWholeGroupsDeterministically() {
        let lib = library(seed: 3)
        let byID = Dictionary(uniqueKeysWithValues: lib.records.map { ($0.id, $0) })
        let grouping = GroupingEngine.compute(records: lib.records, featurePrints: lib.prints, embeddings: lib.embeddings,
                                              context: GroupingContext(now: Fixtures.now))
        let jobs = ScanCoordinator.detailJobs(grouping, records: byID, limit: 5).map(\.id)
        #expect(jobs == ScanCoordinator.detailJobs(grouping, records: byID, limit: 5).map(\.id))
        // Every similar group touched is taken completely.
        let taken = Set(jobs)
        for cluster in grouping.clusters where cluster.kind == .similar || cluster.kind == .burst {
            let members = Set(cluster.memberIDs.filter(grouping.detailCandidates.contains))
            #expect(members.isDisjoint(with: taken) || members.isSubset(of: taken))
        }
    }
}
