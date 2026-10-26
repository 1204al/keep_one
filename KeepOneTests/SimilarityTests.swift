import Foundation
import Testing
@testable import KeepOne

@Suite("Similar-photo clustering")
struct SimilarityTests {
    /// Unit vectors at given angles (degrees) in a fixed plane.
    func vector(angle: Double, dimension: Int = 32) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = Float(cos(angle * .pi / 180))
        v[1] = Float(sin(angle * .pi / 180))
        return v
    }

    @Test func burstFormsOneCluster() {
        let t = Fixtures.days(20)
        let records = (0..<4).map { Fixtures.record("b\($0)", date: t.addingTimeInterval(Double($0)), hash: UInt64($0) << 40) }
        let prints = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, vector(angle: Double($0) * 5)) })
        let clusters = SimilarityClusterer(featurePrints: prints, embeddings: [:]).cluster(records)
        #expect(clusters.count == 1)
        #expect(clusters[0].memberIDs.count == 4)
    }

    @Test func clusterChainingIsPrevented() {
        // A≈B and B≈C, but A and C are clearly different (chord distances 0.52, 0.52, 1.0).
        let t = Fixtures.days(20)
        let a = Fixtures.record("A", date: t, hash: 0x0000_0000_0000_0000)
        let b = Fixtures.record("B", date: t.addingTimeInterval(4), hash: 0x0000_0000_FFFF_FFFF)
        let c = Fixtures.record("C", date: t.addingTimeInterval(8), hash: 0xFFFF_FFFF_FFFF_FFFF)
        let prints = ["A": vector(angle: 0), "B": vector(angle: 30), "C": vector(angle: 60)]
        let clusterer = SimilarityClusterer(featurePrints: prints, embeddings: [:])
        #expect(clusterer.isSimilar(a, b))
        #expect(clusterer.isSimilar(b, c))
        #expect(!clusterer.isSimilar(a, c))
        let clusters = clusterer.cluster([a, b, c])
        #expect(!clusters.contains { $0.memberIDs.contains("A") && $0.memberIDs.contains("C") })
        #expect(clusters.count == 1, "B joins exactly one neighbour")
    }

    @Test func thresholdTightensWithTimeDistance() {
        let t = Fixtures.days(20)
        let prints = ["x": vector(angle: 0), "y": vector(angle: 26)]  // distance ≈ 0.45
        let clusterer = SimilarityClusterer(featurePrints: prints, embeddings: [:])
        let x = Fixtures.record("x", date: t, hash: 0)
        let near = Fixtures.record("y", date: t.addingTimeInterval(60), hash: .max)
        let far = Fixtures.record("y", date: t.addingTimeInterval(1000), hash: .max)
        #expect(clusterer.isSimilar(x, near))
        #expect(!clusterer.isSimilar(x, far))
    }

    @Test func locationFarApartVetoesSimilarity() {
        let t = Fixtures.days(20)
        var a = Fixtures.record("a", date: t, hash: 0)
        var b = Fixtures.record("b", date: t.addingTimeInterval(300), hash: 0xFF)
        a.metadata.latitude = 50.06; a.metadata.longitude = 19.94
        b.metadata.latitude = 52.23; b.metadata.longitude = 21.01
        let prints = ["a": vector(angle: 0), "b": vector(angle: 10)]
        #expect(!SimilarityClusterer(featurePrints: prints, embeddings: [:]).isSimilar(a, b))
    }

    @Test func semanticVetoBlocksDifferentContent() {
        let t = Fixtures.days(20)
        let a = Fixtures.record("a", date: t, hash: 0)
        let b = Fixtures.record("b", date: t.addingTimeInterval(30), hash: 0xFFFF)
        let prints = ["a": vector(angle: 0), "b": vector(angle: 20)]
        let embeddings = ["a": vector(angle: 0), "b": vector(angle: 80)]
        #expect(!SimilarityClusterer(featurePrints: prints, embeddings: embeddings).isSimilar(a, b))
    }

    @Test func blurredBurstFrameStillJoinsItsGroup() {
        let t = Fixtures.days(20)
        let sharp = Fixtures.record("sharp", date: t, hash: 0)
        let blurred = Fixtures.record("blur", date: t.addingTimeInterval(2), hash: 0x3FF, quality: Fixtures.quality(sharpness: 2.2, edge: 0.005))
        let prints = ["sharp": vector(angle: 0), "blur": vector(angle: 75)]
        let embeddings = ["sharp": vector(angle: 0), "blur": vector(angle: 70)]
        #expect(SimilarityClusterer(featurePrints: prints, embeddings: embeddings).isSimilar(sharp, blurred))
    }

    @Test func screenshotsDoNotMixWithPhotos() {
        let t = Fixtures.days(20)
        let a = Fixtures.record("a", date: t, hash: 0)
        let b = Fixtures.record("b", date: t.addingTimeInterval(1), hash: 0, screenshot: true)
        #expect(!SimilarityClusterer(featurePrints: [:], embeddings: [:]).isSimilar(a, b))
    }
}
