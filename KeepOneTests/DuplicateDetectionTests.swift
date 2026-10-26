import Testing
@testable import KeepOne

@Suite("Exact duplicates")
struct DuplicateDetectionTests {
    @Test func byteIdenticalCopiesAreSafe() {
        let a = Fixtures.record("a", date: Fixtures.days(10), hash: 7, contentHash: "h1")
        let b = Fixtures.record("b", date: Fixtures.days(5), hash: 7, contentHash: "h1")
        let result = GroupingEngine.compute(records: [a, b], featurePrints: [:], embeddings: [:], context: GroupingContext())
        let cluster = try! #require(result.clusters.first { $0.kind == .exactDuplicate })
        #expect(cluster.keeperIDs == ["a"], "the older original is kept")
        #expect(cluster.memberTiers["b"] == .safe)
        #expect(cluster.memberReasons["b"]?.first?.code == .byteIdentical)
    }

    @Test func visuallyIdenticalWithoutHashRequestsContentHash() {
        let a = Fixtures.record("a", hash: 7)
        let b = Fixtures.record("b", hash: 7)
        let result = DuplicateDetector.detect(records: [a, b], featurePrints: [:])
        #expect(result.groups.count == 1)
        #expect(result.groups[0].evidence["b"] == .visuallyIdentical)
        #expect(result.hashCandidates == ["a", "b"])
    }

    @Test func lowerResolutionCopyIsLikelyAndKeepsTheLargest() {
        let original = Fixtures.record("orig", hash: 7, width: 4032, height: 3024)
        let copy = Fixtures.record("wa", hash: 7, width: 1600, height: 1200)
        let result = GroupingEngine.compute(records: [copy, original], featurePrints: [:], embeddings: [:], context: GroupingContext())
        let cluster = try! #require(result.clusters.first)
        #expect(cluster.keeperIDs == ["orig"])
        #expect(cluster.memberTiers["wa"] == .likely)
        #expect(cluster.memberReasons["wa"]?.first?.code == .smallerCopy)
    }

    @Test func favoriteCopyIsKeptEvenIfSmaller() {
        let big = Fixtures.record("big", hash: 7, width: 4032, height: 3024)
        let fav = Fixtures.record("fav", hash: 7, width: 2016, height: 1512, favorite: true)
        let result = GroupingEngine.compute(records: [big, fav], featurePrints: [:], embeddings: [:], context: GroupingContext())
        let cluster = try! #require(result.clusters.first)
        #expect(cluster.keeperIDs.first == "fav")
        #expect(cluster.keeperReasons.contains { $0.code == .favorite })
        #expect(cluster.memberTiers["big"] == .likely, "never SAFE when removing the larger copy")
    }

    @Test func differentImagesAreNotDuplicates() {
        let a = Fixtures.record("a", hash: 0x0000_0000_0000_0000)
        let b = Fixtures.record("b", hash: 0xFFFF_0000_FFFF_0000)
        #expect(DuplicateDetector.detect(records: [a, b], featurePrints: [:]).groups.isEmpty)
    }

    @Test func burstFramesWithSmallPixelDifferencesAreNotExactDuplicates() {
        let a = Fixtures.record("a", hash: 7, micro: Fixtures.micro(120))
        let b = Fixtures.record("b", hash: 7, micro: Fixtures.micro(120, variation: 12))
        let result = DuplicateDetector.detect(records: [a, b], featurePrints: [:])
        #expect(result.groups.isEmpty)
        #expect(result.hashCandidates.contains("a"), "ambiguous pairs are resolved by content hash, never guessed")
    }

    @Test func screenshotsAndPhotosNeverMatch() {
        let a = Fixtures.record("a", hash: 7, screenshot: true)
        let b = Fixtures.record("b", hash: 7)
        #expect(DuplicateDetector.detect(records: [a, b], featurePrints: [:]).groups.isEmpty)
    }

    @Test func multiIndexHashIsCompleteForSmallDistances() {
        var rng = SystemRandomNumberGenerator()
        let hashes = (0..<400).map { _ in UInt64.random(in: .min ... .max, using: &rng) }
        var index = MultiIndexHash(chunks: 4)
        for h in hashes { _ = index.insert(h) }
        for (i, h) in hashes.enumerated().prefix(50) {
            var probe = h
            probe ^= 1 << UInt64(i % 64)
            probe ^= 1 << UInt64((i * 7) % 64)
            let expected = Set(hashes.indices.filter { PerceptualHash.distance(hashes[$0], probe) <= 3 })
            #expect(Set(index.candidates(for: probe, maxDistance: 3)) == expected)
        }
    }
}
